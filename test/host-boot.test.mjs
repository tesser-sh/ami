import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";

const repo = join(import.meta.dirname, "..");
const SCRIPT = readFileSync(join(repo, "fleet/host/tesser-host-boot"), "utf8");
const HOSTD = "#!/bin/sh\necho hostd\n";
const SHA = createHash("sha256").update(HOSTD).digest("hex");
const VERSION = "hostd-0123456789ab";
const IMAGE = { id: "build-42", root: "a".repeat(64), kernel: "b".repeat(64) };

let dir;
let imds;
let s3;
let sts;
let cell;
let userData = "";
let s3Hits = [];
let stsHits = [];
let cellHits = [];
let cellAnswer = null;
let cellReplies = [];

const listen = (server) => new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "host-boot-"));
  imds = createServer((req, res) => {
    const send = (status, body = "") => res.writeHead(status).end(body);
    const path = new URL(req.url, "http://imds").pathname;
    if (path === "/latest/api/token") return req.method === "PUT" ? send(200, "imds-token") : send(405);
    if (req.headers["x-aws-ec2-metadata-token"] !== "imds-token") return send(401);
    if (path === "/latest/user-data") return send(200, userData);
    if (path === "/latest/meta-data/placement/region") return send(200, "us-west-2");
    if (path === "/latest/meta-data/iam/security-credentials/") return send(200, "tesser-fleet-host");
    if (path === "/latest/meta-data/iam/security-credentials/tesser-fleet-host") {
      return send(200, JSON.stringify({ AccessKeyId: "AKIATEST", SecretAccessKey: "secret", Token: "session-token" }));
    }
    send(404);
  });
  s3 = createServer((req, res) => {
    s3Hits.push({ path: req.url, authorization: req.headers.authorization ?? "", token: req.headers["x-amz-security-token"] ?? "" });
    if (req.url === `/hostd/${VERSION}/${SHA}`) res.writeHead(200).end(HOSTD);
    else if (req.url === `/hostd/${VERSION}/${"f".repeat(64)}`) res.writeHead(200).end("#!/bin/sh\necho evil\n");
    else res.writeHead(404).end();
  });
  sts = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      stsHits.push({ authorization: req.headers.authorization ?? "", token: req.headers["x-amz-security-token"] ?? "", body: new URLSearchParams(body) });
      res.writeHead(200).end(JSON.stringify({ GetWebIdentityTokenResponse: { GetWebIdentityTokenResult: { WebIdentityToken: "host-identity-token" } } }));
    });
  });
  cell = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      cellHits.push({ path: req.url, authorization: req.headers.authorization ?? "", body: JSON.parse(body) });
      const reply = cellReplies.shift();
      if (reply !== undefined) return reply(res);
      res.writeHead(200).end(JSON.stringify(cellAnswer ?? { accessKeyId: "ASIAHOSTDREADER0", secretAccessKey: "temp/secret+key=", sessionToken: "temp+session/token=", expiration: "2099-01-01T00:00:00Z", bucket: "tesser-fleet-images-prod-131798513069-us-west-2", region: "us-west-2" }));
    });
  });
  imds.port = await listen(imds);
  s3.port = await listen(s3);
  sts.port = await listen(sts);
  cell.port = await listen(cell);
});

after(() => {
  imds.close();
  s3.close();
  sts.close();
  cell.close();
});

async function boot({ tries = 1, root = mkdtempSync(join(dir, "root-")), swapsOn = "" } = {}) {
  const bin = join(root, "bin");
  mkdirSync(bin, { recursive: true });
  const systemctl = join(root, "systemctl.log");
  const swaps = join(root, "swap.log");
  mkdirSync(join(root, "zswap"), { recursive: true });
  writeFileSync(join(root, "meminfo"), "MemTotal:        8388608 kB\nMemFree:         1024 kB\n");
  const shim = (name, body) => {
    writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };
  shim("systemctl", `echo "$@" >> ${systemctl}`);
  shim("fallocate", 'truncate -s "$2" "$3"');
  shim("mkswap", `echo "mkswap $@" >> ${swaps}`);
  shim("swapon", `case "$1" in --show*) printf '%s' '${swapsOn}'; exit 0 ;; esac; echo "swapon $@" >> ${swaps}`);
  shim("mountpoint", "exit 0");
  const script = SCRIPT.replace(/^imds=.*$/m, `imds=http://127.0.0.1:${imds.port}`)
    .replace(/^s3=.*$/m, `s3=http://127.0.0.1:${s3.port}`)
    .replace(/^sts=.*$/m, `sts=http://127.0.0.1:${sts.port}/`)
    .replace(/^cell=.*$/m, `cell=http://127.0.0.1:${cell.port}`)
    .replace(/^etc=.*$/m, `etc=${root}/etc/tesser`)
    .replace(/^opt=.*$/m, `opt=${root}/opt/tesser`)
    .replace(/^srv=.*$/m, `srv=${root}/srv`)
    .replace(/^zswap=.*$/m, `zswap=${root}/zswap`)
    .replace(/^meminfo=.*$/m, `meminfo=${root}/meminfo`)
    .replace(/^tries=.*$/m, `tries=${tries}`)
    .replace(/^pause=.*$/m, "pause=0");
  const file = join(root, "tesser-host-boot");
  writeFileSync(file, script);
  const run = spawn("bash", [file], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  run.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const code = await new Promise((resolve) => run.on("close", resolve));
  return { code, stderr, root, systemctl, swaps };
}

function config(overrides = {}) {
  return JSON.stringify({
    hostId: "h-0123456789ab",
    cellUrl: "https://api.tesser.sh",
    bucket: "tesser-fleet-prod-131798513069",
    hostd: { version: VERSION, sha256: SHA },
    image: IMAGE,
    ...overrides,
  });
}

test("the hostd the cell named is fetched with credentials the cell gave for the host's identity token, installed, configured and started", async () => {
  userData = config();
  s3Hits = [];
  stsHits = [];
  cellHits = [];
  cellAnswer = null;
  const run = await boot();
  assert.equal(run.code, 0, run.stderr);
  assert.equal(readFileSync(join(run.root, `opt/tesser/${VERSION}`), "utf8"), HOSTD);
  assert.equal(readlinkSync(join(run.root, "opt/tesser/hostd")), VERSION);
  assert.equal(stsHits.length, 1);
  assert.match(stsHits[0].authorization, /^AWS4-HMAC-SHA256 Credential=AKIATEST\/\d{8}\/us-west-2\/sts\/aws4_request/);
  assert.equal(stsHits[0].token, "session-token");
  assert.equal(stsHits[0].body.get("Action"), "GetWebIdentityToken");
  assert.equal(stsHits[0].body.get("Audience.member.1"), "https://api.tesser.sh");
  assert.deepEqual(cellHits, [{ path: "/v1/fleet/creds", authorization: "Bearer host-identity-token", body: { keys: [`hostd/${VERSION}/${SHA}`] } }]);
  assert.equal(s3Hits.length, 1);
  assert.equal(s3Hits[0].path, `/hostd/${VERSION}/${SHA}`);
  assert.match(s3Hits[0].authorization, /^AWS4-HMAC-SHA256 Credential=ASIAHOSTDREADER0\/\d{8}\/us-west-2\/s3\/aws4_request/);
  assert.equal(s3Hits[0].token, "temp+session/token=");
  assert.doesNotMatch(run.stderr, /temp\/secret|temp\+session/);
  const cfg = JSON.parse(readFileSync(join(run.root, "etc/tesser/hostd.json"), "utf8"));
  assert.deepEqual(cfg, {
    hostId: "h-0123456789ab",
    cellUrl: "https://api.tesser.sh",
    bucket: "tesser-fleet-prod-131798513069",
    image: IMAGE,
    golden: `${run.root}/srv/golden`,
    vms: `${run.root}/srv/vms`,
    jail: `${run.root}/srv/jail`,
    firecracker: "/usr/local/bin/firecracker",
    jailer: "/usr/local/bin/jailer",
    snapshotEditor: "/usr/local/bin/snapshot-editor",
  });
  assert.equal(lstatSync(join(run.root, "etc/tesser/hostd.json")).mode & 0o077, 0);
  assert.equal(readFileSync(run.systemctl, "utf8"), "enable --now --no-block tesser-hostd\n");
});

test("a host swaps on a file in /srv half the size of its memory, behind zstd zswap, and only once", async () => {
  userData = config();
  const run = await boot();
  assert.equal(run.code, 0, run.stderr);
  const swap = join(run.root, "srv/swap");
  assert.equal(lstatSync(swap).size, 4 * 2 ** 30);
  assert.equal(lstatSync(swap).mode & 0o777, 0o600);
  assert.equal(readFileSync(run.swaps, "utf8"), `mkswap ${swap}.new\nswapon ${swap}\n`);
  assert.deepEqual(["compressor", "max_pool_percent", "enabled"].map((f) => readFileSync(join(run.root, "zswap", f), "utf8")), ["zstd\n", "20\n", "Y\n"]);
  const again = await boot({ root: run.root, swapsOn: `${swap}\n` });
  assert.equal(again.code, 0, again.stderr);
  assert.equal(readFileSync(again.swaps, "utf8"), `mkswap ${swap}.new\nswapon ${swap}\n`);
});

test("an org's host asks its org's cell path for hostd credentials and hands hostd its org id", async () => {
  userData = config({ orgId: "org_0123456789ab" });
  s3Hits = [];
  stsHits = [];
  cellHits = [];
  cellAnswer = null;
  const run = await boot();
  assert.equal(run.code, 0, run.stderr);
  assert.deepEqual(cellHits.map((h) => h.path), ["/v1/fleet/org_0123456789ab/creds"]);
  const cfg = JSON.parse(readFileSync(join(run.root, "etc/tesser/hostd.json"), "utf8"));
  assert.equal(cfg.orgId, "org_0123456789ab");
  assert.equal(cfg.cellUrl, "https://api.tesser.sh");
});

test("a hosted host fetches hostd from its region's images bucket with its instance role, and never asks STS or the cell", async () => {
  const imagesBucket = "tesser-fleet-images-prod-131798513069-us-west-2";
  userData = config({ imagesBucket });
  s3Hits = [];
  stsHits = [];
  cellHits = [];
  const run = await boot();
  assert.equal(run.code, 0, run.stderr);
  assert.equal(readFileSync(join(run.root, `opt/tesser/${VERSION}`), "utf8"), HOSTD);
  assert.equal(stsHits.length, 0);
  assert.equal(cellHits.length, 0);
  assert.equal(s3Hits.length, 1);
  assert.equal(s3Hits[0].path, `/hostd/${VERSION}/${SHA}`);
  assert.match(s3Hits[0].authorization, /^AWS4-HMAC-SHA256 Credential=AKIATEST\/\d{8}\/us-west-2\/s3\/aws4_request/);
  assert.equal(s3Hits[0].token, "session-token");
  assert.doesNotMatch(run.stderr, /secret|session-token/);
  const cfg = JSON.parse(readFileSync(join(run.root, "etc/tesser/hostd.json"), "utf8"));
  assert.equal(cfg.imagesBucket, imagesBucket);
  assert.equal(cfg.bucket, "tesser-fleet-prod-131798513069");
  assert.equal(readFileSync(run.systemctl, "utf8"), "enable --now --no-block tesser-hostd\n");
});

test("a hosted hostd whose sha256 is not the one the cell named is never installed", async () => {
  userData = config({ imagesBucket: "tesser-fleet-images-prod-131798513069-us-west-2", hostd: { version: VERSION, sha256: "f".repeat(64) } });
  cellHits = [];
  const run = await boot();
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /tesser-host-boot: refusing hostd/);
  assert.equal(cellHits.length, 0);
  assert.equal(existsSync(join(run.root, `opt/tesser/${VERSION}`)), false);
  assert.equal(existsSync(join(run.root, "etc/tesser/hostd.json")), false);
});

test("an answer from the cell that is not credentials for a bucket fetches nothing", async () => {
  for (const answer of [{ urls: {} }, { accessKeyId: "ASIAHOSTDREADER0", secretAccessKey: "s", sessionToken: "t", bucket: "x.s3.evil.com/", region: "us-west-2" }, { accessKeyId: "ASIAHOSTDREADER0", secretAccessKey: "s", sessionToken: "t", bucket: "tesser-fleet-images", region: "us-west-2/../x" }]) {
    userData = config();
    s3Hits = [];
    cellAnswer = answer;
    const run = await boot();
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /tesser-host-boot: refusing hostd .* the cell sent no credentials/);
    assert.equal(s3Hits.length, 0);
    assert.equal(existsSync(join(run.root, "etc/tesser/hostd.json")), false);
  }
  cellAnswer = null;
});

test("a cell answer cut off mid-body is fetched again from scratch", async () => {
  userData = config();
  s3Hits = [];
  cellHits = [];
  cellAnswer = null;
  cellReplies = [(res) => {
    res.writeHead(200, { "content-length": "400" });
    res.write('{"accessKeyId":"ASIAHOSTDREADER0","secretAccessKey":"temp/sec', () => res.destroy());
  }];
  const run = await boot({ tries: 3 });
  assert.equal(run.code, 0, run.stderr);
  assert.equal(cellHits.length, 2);
  assert.equal(s3Hits.length, 1);
});

test("a cell that refuses the host is asked once, and its error is printed", async () => {
  userData = config();
  s3Hits = [];
  cellHits = [];
  cellReplies = [(res) => res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "instance i-0abc is not a fleet host" }))];
  const run = await boot({ tries: 3 });
  assert.notEqual(run.code, 0);
  assert.equal(cellHits.length, 1);
  assert.match(run.stderr, /the cell answered 401: \{"error":"instance i-0abc is not a fleet host"\}/);
  assert.match(run.stderr, /tesser-host-boot: refusing hostd .* the cell gave no credentials/);
  assert.equal(s3Hits.length, 0);
  assert.equal(existsSync(join(run.root, "etc/tesser/hostd.json")), false);
});

test("a cell that keeps failing is retried, then its last error is printed", async () => {
  userData = config();
  cellHits = [];
  cellReplies = [0, 1, 2].map(() => (res) => res.writeHead(503).end("busy"));
  const run = await boot({ tries: 3 });
  assert.notEqual(run.code, 0);
  assert.equal(cellHits.length, 3);
  assert.match(run.stderr, /the cell answered 503: busy/);
});

test("a hostd whose sha256 is not the one the cell named is never installed", async () => {
  userData = config({ hostd: { version: VERSION, sha256: "f".repeat(64) } });
  const run = await boot();
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /tesser-host-boot: refusing hostd/);
  assert.equal(existsSync(join(run.root, `opt/tesser/${VERSION}`)), false);
  assert.equal(existsSync(join(run.root, "etc/tesser/hostd.json")), false);
  assert.equal(existsSync(run.systemctl), false);
});

test("user-data that is not the expected JSON refuses to boot before anything is fetched", async () => {
  const bad = [
    "#!/bin/bash\ntouch /tmp/pwned",
    "[]",
    config({ extra: "x" }),
    config({ hostId: "h-$(reboot)" }),
    config({ cellUrl: "http://api.tesser.sh" }),
    config({ cellUrl: "https://api.tesser.sh/evil" }),
    config({ bucket: "Bad_Bucket" }),
    config({ hostd: { version: "../../etc/passwd", sha256: SHA } }),
    config({ hostd: { version: VERSION, sha256: SHA, extra: 1 } }),
    config({ image: { ...IMAGE, id: "../x" } }),
    config({ image: { id: IMAGE.id, root: IMAGE.root } }),
    config({ files: "cell" }),
    config({ imagesBucket: "tesser-fleet-images-prod-131798513069-us-west-2", extra: "x" }),
    config({ imagesBucket: "x.s3.evil.com" }),
    config({ imagesBucket: "Bad_Bucket" }),
    config({ imagesBucket: "" }),
    config({ imagesBucket: 1 }),
    config({ imagesBucket: null }),
    config({ orgId: "org_0123456789ab/../x" }),
    config({ orgId: "org_$(reboot)" }),
    config({ orgId: "" }),
    config({ orgId: null }),
    config({ orgId: "org_0123456789ab", imagesBucket: "tesser-fleet-images-prod-131798513069-us-west-2" }),
  ];
  for (const data of bad) {
    userData = data;
    s3Hits = [];
    const run = await boot();
    assert.notEqual(run.code, 0, data);
    assert.match(run.stderr, /tesser-host-boot: refusing user-data/);
    assert.equal(s3Hits.length, 0);
    assert.equal(existsSync(join(run.root, "etc/tesser/hostd.json")), false);
  }
});

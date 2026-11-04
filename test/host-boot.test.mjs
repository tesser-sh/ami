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
let userData = "";
let s3Hits = [];

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
  imds.port = await listen(imds);
  s3.port = await listen(s3);
});

after(() => {
  imds.close();
  s3.close();
});

async function boot() {
  const root = mkdtempSync(join(dir, "root-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  const systemctl = join(root, "systemctl.log");
  const shim = (name, body) => {
    writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };
  shim("systemctl", `echo "$@" >> ${systemctl}`);
  shim("swapoff", "exit 0");
  shim("swapon", "exit 0");
  shim("mountpoint", "exit 0");
  const script = SCRIPT.replace(/^imds=.*$/m, `imds=http://127.0.0.1:${imds.port}`)
    .replace(/^s3=.*$/m, `s3=http://127.0.0.1:${s3.port}`)
    .replace(/^etc=.*$/m, `etc=${root}/etc/tesser`)
    .replace(/^opt=.*$/m, `opt=${root}/opt/tesser`)
    .replace(/^srv=.*$/m, `srv=${root}/srv`)
    .replace(/^tries=.*$/m, "tries=1")
    .replace(/^pause=.*$/m, "pause=0");
  const file = join(root, "tesser-host-boot");
  writeFileSync(file, script);
  const run = spawn("bash", [file], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  run.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const code = await new Promise((resolve) => run.on("close", resolve));
  return { code, stderr, root, systemctl };
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

test("the hostd the cell named is fetched with the host's role, installed, configured and started", async () => {
  userData = config();
  s3Hits = [];
  const run = await boot();
  assert.equal(run.code, 0, run.stderr);
  assert.equal(readFileSync(join(run.root, `opt/tesser/${VERSION}`), "utf8"), HOSTD);
  assert.equal(readlinkSync(join(run.root, "opt/tesser/hostd")), VERSION);
  assert.equal(s3Hits.length, 1);
  assert.match(s3Hits[0].authorization, /^AWS4-HMAC-SHA256 Credential=AKIATEST\/\d{8}\/us-west-2\/s3\/aws4_request/);
  assert.equal(s3Hits[0].token, "session-token");
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

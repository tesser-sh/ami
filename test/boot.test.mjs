import { spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";

const repo = join(import.meta.dirname, "..");
const BOOT_SCRIPT = readFileSync(join(repo, "boot/tesser-boot"), "utf8");
const BOOT_UNIT = readFileSync(join(repo, "boot/tesser-boot.service"), "utf8");
const VERIFIER = readFileSync(join(repo, "verify/verify.mjs"), "utf8");
const BOX_ID = "box_0123456789abcdef";
const TOKEN = `tsr_b_${BOX_ID}_${"a".repeat(32)}`;
const BUNDLE = 'console.log("boxd");\n';
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const TEST_KEY = publicKey.export({ format: "jwk" }).x;
const STATEMENT = JSON.stringify({ kind: "boxd", version: "sha-test", sha256: createHash("sha256").update(BUNDLE).digest("hex") });
const SIGNATURE = `${sign(null, Buffer.from(STATEMENT), privateKey).toString("base64")}\n`;

let dir;
let caFile;
let imds;
let cell;
let userData = "";
let signature = SIGNATURE;
let cellHits = 0;

const listen = (server) => new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));

function testVerifier(root) {
  const line = /^const RELEASE_PUBLIC_KEY = "[A-Za-z0-9_-]+";$/m;
  assert.match(VERIFIER, line);
  const file = join(root, "tesser-verify-boxd");
  writeFileSync(file, VERIFIER.replace(line, `const RELEASE_PUBLIC_KEY = "${TEST_KEY}";`));
  chmodSync(file, 0o755);
  return file;
}

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "boot-"));
  caFile = join(dir, "cert.pem");
  const keyFile = join(dir, "key.pem");
  const made = spawnSync(
    "openssl",
    ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", keyFile, "-out", caFile],
    { encoding: "utf8" },
  );
  if (made.status !== 0) throw new Error(`openssl: ${made.stderr}`);
  imds = createHttpServer((req, res) => {
    const send = (status, body = "") => res.writeHead(status).end(body);
    const path = new URL(req.url, "http://imds").pathname;
    if (path === "/latest/api/token") return req.method === "PUT" ? send(200, "imds-token") : send(405);
    if (req.headers["x-aws-ec2-metadata-token"] !== "imds-token") return send(401);
    if (path === "/latest/user-data") return send(200, userData);
    if (path === "/latest/meta-data/local-ipv4") return send(200, "10.0.1.5");
    if (path === "/latest/meta-data/mac") return send(200, "0a:00:00:00:00:01");
    if (path === "/latest/meta-data/network/interfaces/macs/0a:00:00:00:00:01/vpc-ipv4-cidr-blocks") return send(200, "10.0.0.0/16\n100.64.0.0/20");
    send(404);
  });
  cell = createHttpsServer({ cert: readFileSync(caFile), key: readFileSync(keyFile) }, (req, res) => {
    cellHits += 1;
    const path = new URL(req.url, "https://cell").pathname;
    const body = { "/v1/boxd/bundle": BUNDLE, "/v1/boxd/statement": STATEMENT, "/v1/boxd/statement.sig": signature }[path];
    if (body === undefined) res.writeHead(404).end();
    else res.writeHead(200).end(body);
  });
  imds.port = await listen(imds);
  cell.port = await listen(cell);
});

after(() => {
  imds.close();
  cell.close();
});

async function boot() {
  const root = mkdtempSync(join(dir, "root-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  const systemctl = join(root, "systemctl.log");
  writeFileSync(join(bin, "systemctl"), `#!/bin/sh\necho "$@" >> ${systemctl}\n`);
  chmodSync(join(bin, "systemctl"), 0o755);
  const verifier = testVerifier(root);
  const group = spawnSync("id", ["-gn"], { encoding: "utf8" }).stdout.trim();
  const script = BOOT_SCRIPT.replace(/^imds=.*$/m, `imds=http://127.0.0.1:${imds.port}`)
    .replace(/^etc=.*$/m, `etc=${root}/etc/tesser`)
    .replace(/^opt=.*$/m, `opt=${root}/opt/tesser`)
    .replace(/^verifier=.*$/m, `verifier=${verifier}`)
    .replace(/^owner=.*$/m, `owner=${userInfo().username}`)
    .replace(/^group=.*$/m, `group=${group}`)
    .replace(/^tries=.*$/m, "tries=2")
    .replace(/^pause=.*$/m, "pause=0");
  const file = join(root, "tesser-boot");
  writeFileSync(file, script);
  const run = spawn("bash", [file], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, CURL_CA_BUNDLE: caFile }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  run.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const code = await new Promise((resolve) => run.on("close", resolve));
  return { code, stderr, root, systemctl };
}

function config(overrides = {}) {
  return JSON.stringify({ orgId: "org_x", boxId: BOX_ID, cellUrl: `https://localhost:${cell.port}`, boxToken: TOKEN, ...overrides });
}

test("the unit runs the script once, before boxd has a config, and never for long", () => {
  assert.match(BOOT_UNIT, /^ConditionPathExists=!\/etc\/tesser\/boxd\.json$/m);
  assert.match(BOOT_UNIT, /^TimeoutStartSec=300$/m);
});

test("the shipped verifier trusts only the release key", () => {
  const d = mkdtempSync(join(dir, "verify-"));
  writeFileSync(join(d, "boxd.js"), BUNDLE);
  writeFileSync(join(d, "statement"), STATEMENT);
  writeFileSync(join(d, "statement.sig"), SIGNATURE);
  const args = [join(d, "boxd.js"), join(d, "statement"), join(d, "statement.sig")];
  const real = spawnSync(process.execPath, [join(repo, "verify/verify.mjs"), ...args], { encoding: "utf8" });
  assert.equal(real.status, 1);
  assert.match(real.stderr, /not signed by the trusted key/);
  const swapped = spawnSync(process.execPath, [testVerifier(d), ...args], { encoding: "utf8" });
  assert.equal(swapped.status, 0, swapped.stderr);
  assert.equal(swapped.stdout.trim(), "sha-test");
});

test("a signed bundle installs, the user-data becomes boxd's config, and boxd starts", async () => {
  userData = config();
  signature = SIGNATURE;
  const run = await boot();
  assert.equal(run.stderr, "");
  assert.equal(run.code, 0);
  assert.equal(readFileSync(join(run.root, "opt/tesser/boxd.js"), "utf8"), BUNDLE);
  assert.deepEqual(JSON.parse(readFileSync(join(run.root, "etc/tesser/boxd.json"), "utf8")), {
    orgId: "org_x",
    boxId: BOX_ID,
    cellUrl: `https://localhost:${cell.port}`,
    boxToken: TOKEN,
    privateIp: "10.0.1.5",
    vpcCidrs: ["10.0.0.0/16", "100.64.0.0/20"],
  });
  assert.equal(readFileSync(run.systemctl, "utf8"), "enable --now --no-block tesser-boxd\n");
});

test("a bundle whose signature does not verify is never installed", async () => {
  userData = config();
  signature = Buffer.from("x".repeat(64)).toString("base64");
  const run = await boot();
  signature = SIGNATURE;
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /tesser-verify-boxd: refusing/);
  assert.equal(existsSync(join(run.root, "opt/tesser/boxd.js")), false);
  assert.equal(existsSync(join(run.root, "etc/tesser/boxd.json")), false);
  assert.equal(existsSync(run.systemctl), false);
});

test("user-data that is not the expected JSON refuses to boot before anything is fetched from the cell", async () => {
  const bad = [
    "#!/bin/sh\ntouch /tmp/pwned",
    "[]",
    config({ extra: "x" }),
    config({ cellUrl: `http://localhost:${cell.port}` }),
    config({ cellUrl: `https://localhost:${cell.port}/evil` }),
    config({ boxToken: `tsr_b_box_ffffffffffffffff_${"a".repeat(32)}` }),
    config({ boxId: "box_$(reboot)" }),
  ];
  for (const data of bad) {
    userData = data;
    const before = cellHits;
    const run = await boot();
    assert.notEqual(run.code, 0, data);
    assert.match(run.stderr, /tesser-boot: refusing user-data/);
    assert.equal(cellHits, before);
    assert.equal(existsSync(join(run.root, "etc/tesser/boxd.json")), false);
  }
});

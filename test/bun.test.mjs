import { spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";

const repo = join(import.meta.dirname, "..");
const SHIM = readFileSync(join(repo, "shim/bun"), "utf8");
const ARCH = { x64: "x64", arm64: "aarch64" }[process.arch];
const RELEASES = ["1.2.3", "1.2.4"];
const DEFAULT = "9.9.9";

let dir;
let root;
let bin;
let server;
let downloads = 0;

const fakeBun = (version) => `#!/bin/sh\necho "${version} \${0##*/} $*"\n`;

function write(path, content) {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, content);
}

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "bun-"));
  const zips = {};
  for (const version of RELEASES) {
    const src = join(dir, "src", version);
    write(join(src, `bun-linux-${ARCH}`, "bun"), fakeBun(version));
    chmodSync(join(src, `bun-linux-${ARCH}`, "bun"), 0o755);
    const zipped = spawnSync("zip", ["-qr", "bun.zip", `bun-linux-${ARCH}`], { cwd: src, encoding: "utf8" });
    if (zipped.status !== 0) throw new Error(`zip: ${zipped.stderr}`);
    zips[`/bun-v${version}/bun-linux-${ARCH}.zip`] = readFileSync(join(src, "bun.zip"));
  }
  server = createServer((req, res) => {
    const zip = zips[req.url];
    if (zip === undefined) return res.writeHead(404).end();
    downloads += 1;
    res.writeHead(200).end(zip);
  });
  const port = await new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));

  root = join(dir, "usr-local-bun");
  write(join(root, "default"), `${DEFAULT}\n`);
  write(join(root, "versions", DEFAULT, "bin", "bun"), fakeBun(DEFAULT));
  chmodSync(join(root, "versions", DEFAULT, "bin", "bun"), 0o755);
  bin = join(dir, "bin");
  write(
    join(bin, "bun"),
    SHIM.replace(/^root=.*$/m, `root=${root}`).replace(/^releases=.*$/m, `releases=http://127.0.0.1:${port}`),
  );
  chmodSync(join(bin, "bun"), 0o755);
  symlinkSync("bun", join(bin, "bunx"));
});

after(() => server.close());

function project(files) {
  const base = mkdtempSync(join(dir, "repo-"));
  for (const [path, content] of Object.entries(files)) write(join(base, path), content);
  return base;
}

function run(cwd, name = "bun") {
  const child = spawn(join(bin, name), ["x"], { cwd });
  const out = { stdout: "", stderr: "" };
  child.stdout.on("data", (chunk) => (out.stdout += chunk));
  child.stderr.on("data", (chunk) => (out.stderr += chunk));
  return new Promise((resolve) => child.on("close", (status) => resolve({ status, ...out })));
}

test("with no pin, the image's bun runs and nothing is fetched", async () => {
  const before = downloads;
  const r = await run(project({ "package.json": '{"name":"app"}' }));
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `${DEFAULT} bun x\n`);
  assert.equal(downloads, before);
});

test("a .bun-version pins it from any depth below, installed on first use only", async () => {
  const base = project({ ".bun-version": "1.2.3\n", "packages/a/package.json": '{"name":"a"}' });
  const before = downloads;
  const first = await run(join(base, "packages/a"));
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.stdout, "1.2.3 bun x\n");
  assert.match(first.stderr, /bun: installing 1\.2\.3, pinned by .*\.bun-version/);
  const again = await run(base);
  assert.equal(again.stdout, "1.2.3 bun x\n");
  assert.equal(again.stderr, "");
  assert.equal(downloads, before + 1);
  assert.equal(statSync(join(root, "versions", "1.2.3")).mode & 0o777, 0o755);
  assert.equal((await run(base, "bunx")).stdout, "1.2.3 bunx x\n");
});

test("packageManager in package.json pins it, and the nearest pin wins", async () => {
  const base = project({
    "package.json": '{\n  "name": "mono",\n  "packageManager": "bun@1.2.4+sha512.abc"\n}',
    "packages/a/package.json": '{"name":"a","packageManager":"pnpm@10.0.0"}',
    "packages/b/.bun-version": "v1.2.3",
  });
  assert.equal((await run(join(base, "packages/a"))).stdout, "1.2.4 bun x\n");
  assert.equal((await run(join(base, "packages/b"))).stdout, "1.2.3 bun x\n");
});

test("a pin that is not an exact version runs the image's bun, and says so", async () => {
  const r = await run(project({ ".bun-version": "latest\n" }));
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `${DEFAULT} bun x\n`);
  assert.match(r.stderr, /pins "latest", not an exact version; running 9\.9\.9/);
});

test("a release that cannot be fetched fails and leaves nothing behind", async () => {
  const r = await run(project({ ".bun-version": "4.0.4" }));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /bun: could not install 4\.0\.4/);
  assert.deepEqual(
    readdirSync(join(root, "versions")).filter((name) => name.includes("4.0.4")),
    [],
  );
});

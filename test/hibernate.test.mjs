import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { open } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";

const repo = join(import.meta.dirname, "..");
const HANDLER = readFileSync(join(repo, "hibernate/tesser-hibernate"), "utf8");
const EVENT = readFileSync(join(repo, "hibernate/tesser-sleep"), "utf8");
const PAGECACHE = join(repo, "hibernate/pagecache");
const SBTN = ["button/sleep", "SBTN", "00000080", "00000000"];
const LNXSLPBN = ["button/sleep", "LNXSLPBN:00", "00000080", "00000001"];
const MEM_KB = 8_000_000;

function box({ state = "file", swapOn = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), "hibernate-"));
  const bin = join(root, "bin");
  const power = join(root, "power");
  mkdirSync(bin);
  mkdirSync(power);
  if (state === "file") writeFileSync(join(power, "state"), "");
  if (state === "fifo") spawnSync("mkfifo", [join(power, "state")]);
  if (state === "broken") mkdirSync(join(power, "state"));
  writeFileSync(join(power, "image_size"), "0\n");
  writeFileSync(join(root, "meminfo"), `MemTotal:       ${MEM_KB} kB\nMemFree:        1000 kB\n`);
  writeFileSync(join(root, "swaps"), `Filename\tType\tSize\tUsed\tPriority\n${swapOn ? "/swap-hibinit file 100 0 0\n" : ""}`);
  const calls = join(root, "calls.log");
  for (const name of ["logger", "sysctl", "swapon", "systemctl", "systemd-run"]) {
    writeFileSync(join(bin, name), `#!/bin/sh\necho "${name} $*" >> ${calls}\n`);
    chmodSync(join(bin, name), 0o755);
  }
  writeFileSync(join(bin, "python3"), `#!/bin/sh\necho "python3 $*" >> ${calls}\n[ "$2" = snapshot ] && printf '/home/ubuntu/a\\0/usr/b\\0'\nexit 0\n`);
  chmodSync(join(bin, "python3"), 0o755);
  const script = HANDLER.replace(/^power=.*$/m, `power=${power}`)
    .replace(/^meminfo=.*$/m, `meminfo=${root}/meminfo`)
    .replace(/^swaps=.*$/m, `swaps=${root}/swaps`)
    .replace(/^run=.*$/m, `run=${root}/tesser-hibernate`)
    .replace(/^cache=.*$/m, `cache=${root}/lib/pagecache`)
    .replace(/^pagecache=.*$/m, `pagecache=${root}/pagecache`)
    .replace(/^sysctls=.*$/m, `sysctls=${root}/99-tesser.conf`);
  writeFileSync(join(root, "tesser-hibernate"), script);
  const press = (event) =>
    new Promise((resolve) => {
      const run = spawn("bash", [join(root, "tesser-hibernate"), ...event], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, stdio: "ignore" });
      run.on("close", resolve);
    });
  const log = () => (existsSync(calls) ? readFileSync(calls, "utf8") : "");
  return { root, power, press, log };
}

const hibernated = (b) => readFileSync(join(b.power, "state"), "utf8") === "disk\n";

test("the sleep button event reaches the handler whichever device EC2 presses", () => {
  const event = new RegExp(EVENT.match(/^event=(.*)$/m)[1]);
  assert.match(SBTN.join(" "), event);
  assert.match(LNXSLPBN.join(" "), event);
  assert.match(EVENT, /^action=\/usr\/local\/sbin\/tesser-hibernate %e$/m);
});

for (const event of [SBTN, LNXSLPBN]) {
  test(`${event[1]} hibernates into the swap file, tuned to keep the most in the image`, async () => {
    const b = box();
    assert.equal(await b.press(event), 0);
    assert.ok(hibernated(b));
    const log = b.log();
    assert.match(log, /^sysctl -q -w vm\.swappiness=1$/m);
    assert.match(log, /^swapon --priority=0 \/swap-hibinit$/m);
    assert.equal(readFileSync(join(b.power, "image_size"), "utf8").trim(), String(Math.floor(MEM_KB * 1024 * 0.45)));
    assert.ok(log.indexOf("vm.swappiness=1") < log.indexOf(`sysctl -q -p ${b.root}/99-tesser.conf`));
    assert.equal(readFileSync(join(b.root, "lib/pagecache"), "utf8"), "/home/ubuntu/a\0/usr/b\0");
    assert.match(log, new RegExp(`^systemd-run .* python3 ${b.root}/pagecache reload ${b.root}/lib/pagecache$`, "m"));
    assert.doesNotMatch(log, /poweroff/);
  });
}

test("a swap file that is already on keeps its place", async () => {
  const b = box({ swapOn: true });
  assert.equal(await b.press(SBTN), 0);
  assert.ok(hibernated(b));
  assert.doesNotMatch(b.log(), /swapon/);
});

test("a second press while hibernating, and the one acpid delivers right after the resume, do nothing", async () => {
  const b = box({ state: "fifo" });
  const first = b.press(SBTN);
  while (!b.log().includes("swapon")) await new Promise((r) => setTimeout(r, 10));
  assert.equal(await b.press(LNXSLPBN), 0);
  assert.equal(b.log().match(/^python3 .* snapshot/gm).length, 1);
  const state = await open(join(b.power, "state"), "r");
  assert.equal((await state.readFile("utf8")).trim(), "disk");
  await state.close();
  assert.equal(await first, 0);
  assert.equal(await b.press(LNXSLPBN), 0);
  assert.equal(b.log().match(/^python3 .* snapshot/gm).length, 1);
  assert.match(b.log(), /^logger -t tesser-hibernate ignoring button\/sleep LNXSLPBN:00 .* right after a resume$/m);
});

test("a box that can't hibernate powers off instead of waiting out EC2", async () => {
  const b = box({ state: "broken" });
  await b.press(SBTN);
  const log = b.log();
  assert.match(log, /^systemctl poweroff$/m);
  assert.match(log, new RegExp(`^sysctl -q -p ${b.root}/99-tesser.conf$`, "m"));
  assert.doesNotMatch(log, /systemd-run/);
  assert.equal(existsSync(join(b.root, "tesser-hibernate.resumed")), false);
});

test("pagecache lists cached files on one filesystem and reads them back, skipping what is gone", () => {
  const root = mkdtempSync(join(tmpdir(), "pagecache-"));
  mkdirSync(join(root, "nested"));
  writeFileSync(join(root, "nested/hot.js"), "x".repeat(100_000));
  writeFileSync(join(root, "swap"), "s".repeat(4096));
  writeFileSync(join(root, "empty"), "");
  readFileSync(join(root, "nested/hot.js"));
  const snap = spawnSync("python3", [PAGECACHE, "snapshot", root, join(root, "swap")]);
  assert.equal(snap.status, 0, String(snap.stderr));
  const listed = snap.stdout.toString().split("\0").filter(Boolean);
  assert.ok(listed.includes(join(root, "nested/hot.js")), listed.join(","));
  assert.ok(!listed.includes(join(root, "swap")));
  assert.ok(!listed.includes(join(root, "empty")));
  writeFileSync(join(root, "list"), [...listed, join(root, "gone")].join("\0") + "\0");
  const reload = spawnSync("python3", [PAGECACHE, "reload", join(root, "list")], { encoding: "utf8" });
  assert.equal(reload.status, 0, reload.stderr);
  assert.match(reload.stderr, new RegExp(`read ${listed.length + 1} files`));
});

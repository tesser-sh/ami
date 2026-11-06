import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";

const repo = join(import.meta.dirname, "..");
const INIT = readFileSync(join(repo, "boot/initrd/init"), "utf8");
const PARTUUID = "3cbf38ee-669e-4657-b829-2f3940f9578e";
const OFFSET = 34816;
const CAT = spawnSync("sh", ["-c", "command -v cat"], { encoding: "utf8" }).stdout.trim();

function boot({ hibernated = false, freshEra = false, eraFile = null, diskSectors = 16777216, twins = false, badEra = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), "initrd-"));
  const bin = join(root, "bin");
  const sys = join(root, "sys");
  const dev = join(root, "dev");
  const newroot = join(root, "newroot");
  const calls = join(root, "calls.log");
  for (const d of [bin, dev, newroot, join(sys, "power")]) mkdirSync(d, { recursive: true });
  const disk = join(sys, "devices/nvme0n1");
  const parts = { nvme0n1p1: { start: 2099200, size: 14677983, partition: 1, dev: "259:1" }, nvme0n1p2: { start: 1275904, size: 821249, partition: 2, dev: "259:2" } };
  mkdirSync(join(sys, "class/block"), { recursive: true });
  symlinkSync(disk, join(sys, "class/block/nvme0n1"));
  for (const [name, p] of Object.entries(parts)) {
    mkdirSync(join(disk, name), { recursive: true });
    for (const [k, v] of Object.entries(p)) writeFileSync(join(disk, name, k), `${v}\n`);
    symlinkSync(join(disk, name), join(sys, "class/block", name));
  }
  for (const f of ["resume", "resume_offset"]) writeFileSync(join(sys, "power", f), "");
  if (eraFile !== null) {
    mkdirSync(join(newroot, "var/lib/tesser"), { recursive: true });
    writeFileSync(join(newroot, "var/lib/tesser/era"), eraFile);
  }
  const shim = (name, body) => {
    writeFileSync(join(bin, name), `#!/usr/bin/env bash\necho "${name} $*" >> ${calls}\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };
  for (const name of ["mount", "sfdisk", "resize2fs", "switch_root", "sleep", "poweroff"]) shim(name, "exit 0");
  shim("dmsetup", badEra ? `[[ "$*" == *" era "* && ! -e ${root}/era-zeroed ]] && exit 1; exit 0` : "exit 0");
  shim("blkid", `case "$*" in *PARTUUID=${PARTUUID}*) echo /dev/nvme0n1p1; ${twins ? "echo /dev/nvme1n1p1" : ""} ;; *PARTLABEL*nvme0n1p2) echo tesser-era ;; esac`);
  shim("debugfs", `echo ${OFFSET}`);
  shim("blockdev", `case "$1" in --getsz) [ "$2" = /dev/nvme0n1 ] && echo ${diskSectors} || echo 14677983 ;; esac; exit 0`);
  shim("dd", `case "$*" in *of=/dev/nvme0n1p2*) touch ${root}/era-zeroed ;; *"skip=${OFFSET * 4096 + 4086} "*) ${hibernated ? "printf S1SUSPEND" : "printf SWAPSPACE2"} ;; *nvme0n1p2*) ${freshEra ? "head -c 4096 /dev/zero" : "printf era"} ;; esac`);
  writeFileSync(join(bin, "cat"), `#!/usr/bin/env bash\n[[ $(readlink /proc/$$/fd/1) == */power/resume ]] && echo "resume $(${CAT} "$@")" >> ${calls}\nexec ${CAT} "$@"\n`);
  chmodSync(join(bin, "cat"), 0o755);
  writeFileSync(join(root, "cmdline"), `BOOT_IMAGE=/vmlinuz root=/dev/mapper/hroot tesser.root=PARTUUID=${PARTUUID} console=ttyS0\n`);
  const script = INIT.replace(/^dev=.*$/m, `dev=${dev}`)
    .replace(/^sys=.*$/m, `sys=${sys}`)
    .replace(/^cmdline=.*$/m, `cmdline=${root}/cmdline`)
    .replace(/^newroot=.*$/m, `newroot=${newroot}`);
  writeFileSync(join(root, "init"), script);
  const run = spawnSync("bash", [join(root, "init")], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8" });
  const log = existsSync(calls) ? readFileSync(calls, "utf8") : "";
  const era = existsSync(join(newroot, "var/lib/tesser/era")) ? readFileSync(join(newroot, "var/lib/tesser/era"), "utf8").trim() : null;
  return { run, log, era, offset: readFileSync(join(sys, "power/resume_offset"), "utf8").trim() };
}

const at = (log, re) => log.split("\n").findIndex((l) => re.test(l));

test("a box with a hibernation image in its swap file resumes from p1 before dm-era is ever loaded", () => {
  const b = boot({ hibernated: true });
  assert.equal(b.offset, String(OFFSET));
  const resume = at(b.log, /^resume 259:1$/);
  const era = at(b.log, /^dmsetup create/);
  assert.ok(resume >= 0, b.log);
  assert.ok(era > resume, b.log);
});

test("without an image it never asks the kernel to resume, and puts hroot on dm-era over p1 with 512 KiB blocks", () => {
  const b = boot();
  assert.equal(at(b.log, /^resume /), -1);
  assert.match(b.log, /^dmsetup create --noudevsync hera --table 0 14677983 era \/dev\/nvme0n1p2 \/dev\/nvme0n1p1 1024$/m);
  assert.match(b.log, /^dmsetup create --noudevsync hroot --table 0 14677983 linear \S+\/dev\/mapper\/hera 0$/m);
  assert.ok(at(b.log, /^switch_root .*\/sbin\/init$/) > at(b.log, /^dmsetup create/));
  assert.ok(at(b.log, /^dd if=\/dev\/nvme0n1p2 /) < at(b.log, /^dmsetup create --noudevsync hera/), "era metadata is read before dm-era formats it");
});

test("two disks with the box's PARTUUID power the instance off instead of guessing", () => {
  const b = boot({ twins: true });
  assert.equal(at(b.log, /^dmsetup create/), -1);
  assert.ok(at(b.log, /^poweroff -f$/) >= 0, b.log);
});

test("era metadata dm-era can't read is made again and says nothing is known", () => {
  const b = boot({ badEra: true, eraFile: "since 3\n" });
  assert.ok(at(b.log, /^dd .*of=\/dev\/nvme0n1p2/) >= 0, b.log);
  assert.match(b.era, /^reset /);
  assert.ok(at(b.log, /^switch_root/) >= 0);
});

test("p1 grows to the end of a bigger volume before dm-era is made over it", () => {
  const b = boot({ diskSectors: 83886080 });
  const grow = at(b.log, /^sfdisk .* -N 1 \/dev\/nvme0n1$/);
  assert.ok(grow >= 0, b.log);
  assert.ok(at(b.log, /^dmsetup create/) > grow);
  assert.equal(at(boot().log, /^sfdisk/), -1);
});

test("era metadata made on a pristine disk counts from era 0, made again on a used one says nothing is known", () => {
  assert.equal(boot({ freshEra: true }).era, "since 0");
  assert.match(boot({ freshEra: true, eraFile: "since 3\n" }).era, /^reset \d{4}-\d\d-\d\dT/);
  assert.equal(boot({ eraFile: "since 3\n" }).era, "since 3");
});

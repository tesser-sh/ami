# tesser box image

This repo is the whole recipe for the AMI every [tesser](https://tesser.sh) box boots from. It holds everything that goes into the image, and every published AMI is built from it by a public GitHub Actions run.

## What's in the image

Stock Ubuntu 24.04 LTS from Canonical, the newest one Canonical has published when the build runs (`box.pkr.hcl` filters on Canonical's account and the noble amd64 name). Each image records the exact base AMI id in its `tesser:base` tag and in its release notes. `build.yml` rebuilds every Monday as well as on every push to `main`, so OS patches arrive within a week. On top of the base:

- **[`setup.sh`](setup.sh):** the dev toolchain a box needs.
  - the tesser kernel's bzImage (6.18 LTS, [below](#the-kernel)) in place of every Ubuntu kernel, which `setup.sh` purges. MongoDB 8 refuses to start on kernels 6.19 through 7.0.13 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)); 6.18 is below that. grub boots it with [`boot/09_tesser`](boot/09_tesser), its only entry, and a small initramfs whose [`init`](boot/initrd/init) puts the root filesystem under dm: `hera` is dm-era over the root partition, with its metadata on a `tesser-era` partition cut from the end of `/boot`, so a move can ask which blocks changed since the image was made, and `hroot`, the root, is linear over it, so a move can mirror it and every write still goes through era (`/var/lib/tesser/era` names the era it was made in, and `/etc/tesser/base` the image). Era sees every write: the init grows the partition to the volume and the filesystem with it (cloud-init's growpart and resizefs are off), and resumes a hibernation image before it ever loads era. The command line hides what differs between an m8a and a Firecracker microVM from the start (`clearcpuid=aperfmperf,monitor idle=halt lapic=notscdeadline nmi_watchdog=0 efi=noruntime`) and holds five `virtio_mmio.device=` slots where a microVM's dummy disk (on IRQ 5, level-triggered on Nitro and edge in Firecracker), root, swap, home and NIC appear. cloud-init's hotplug hook and multipathd are off, and LVM never scans virtio or nbd disks;
  - build tools, git (from the git-core PPA), docker with compose and buildx, rsync, nbd-client (boxd streams repo snapshots onto a box through it);
  - node 22 and 24 through fnm;
  - bun through [`shim/bun`](shim/bun), installed as `bun` and `bunx`. It runs the version the repo pins, from the nearest `.bun-version` or `"packageManager": "bun@<version>"` in a `package.json` at or above the working directory, and installs that release from bun's GitHub releases under `~/.bun/versions` the first time it runs. A repo that pins nothing gets the newest bun as of the build;
  - uv for python, and mise for ruby. mise installs only precompiled ruby (`ruby.compile = false`) and reads `.ruby-version`, so `mise install` gets the repo's ruby. It trusts every mise config under `/home/ubuntu`, and its shims are on every PATH. Both are the newest releases as of the build;
  - passwordless sudo for `ubuntu`;
  - no login banner: sshd's `pam_motd` is off, so a new ssh session doesn't wait on update-motd's scripts;
  - higher inotify limits;
  - swap in compressed memory (zram, up to 8 GB), so a memory spike slows a box down instead of getting a process OOM-killed.

  It also turns off unattended upgrades and needrestart's automatic restarts, so a box never patches or restarts itself in the middle of your work.
- **[`boot/`](boot):** runs once, on first boot.
  - `tesser-boot` reads the box's config from EC2 user-data. It must be strict JSON with exactly three keys (`orgId`, `boxId`, `cellUrl`), none of them secret: boxd proves which instance it runs on with a token STS signs for the instance profile. Until the control plane stops sending it, a fourth `boxToken` key is accepted and passed to boxd.
  - It downloads boxd, the box agent, from that cell and installs it only if `tesser-verify-boxd` accepts it.
  - `tesser-boxd.service` runs boxd as `ubuntu`.
- **[`hibernate/`](hibernate):** what happens when tesser hibernates a box instead of stopping it.
  - `tesser-hibernate` replaces Ubuntu's handler for EC2's sleep button. It acts on the `LNXSLPBN` event as well as `SBTN` (Ubuntu's only knew `SBTN`, and a missed event leaves the instance stopping for 20 minutes before EC2 cold boots it), runs once per hibernation, and ignores the duplicate event EC2 sends right after a resume.
  - Before hibernating it keeps anonymous memory in the image (`vm.swappiness=1`, image size just under half of RAM, the most the kernel can hold) and remembers which files were in the page cache; after the resume [`pagecache`](hibernate/pagecache) reads them back in parallel.
  - The image goes to the swap file EC2's agent creates, at priority 0 so everyday swapping stays in zram. The initramfs finds that file on the root partition itself and resumes from it (the agent's grub line can't name a dm device, so it's off). Ubuntu's resume hook, a `swapoff` that pages the whole image back in from EBS 4 KB at a time, is diverted away.
  - If the kernel can't hibernate, the box powers off, so the instance stops instead of waiting out EC2.
- **[`config/`](config):** the sysctl settings, the zram swap device, and `allow_userdata: false`, which stops cloud-init from ever running user-data as a script. User-data is data here, never code.
- **[`verify/verify.mjs`](verify/verify.mjs):** installed as `/usr/local/bin/tesser-verify-boxd`. It checks three things:
  - boxd's statement carries an ed25519 signature by tesser's release key;
  - the statement is for boxd;
  - the downloaded bundle's sha256 matches the statement.

  Node built-ins only. On every build, the workflow first runs it against the boxd that api.tesser.sh serves right now, so this verifier and the live signed boxd can't drift apart.
- **[`smoke.sh`](smoke.sh):** runs after the build instance reboots into the image's kernel, and on the fleet guest in a microVM. It fails the build unless what boxes run works on that kernel: the kernel is the only one installed and `/` is on dm-era (on EC2), zram compresses with zstd, node 22 and 24, bun and uv run, mise as `ubuntu` sees `ruby.compile = false`, docker runs on overlayfs with a memory cgroup limit, a container reaches the internet over its bridge, a published port answers on the box's address, `docker buildx` builds an image, and mongo 8, postgres 17 and redis 7 each start and answer their own client's ping within a minute. What it pulls is deleted again. No eBPF tooling ships in the image; docker's cgroup device filter is the BPF it exercises.
- **[`cleanup.sh`](cleanup.sh):** removes the build instance's SSH host keys, authorized keys and cloud-init state before imaging, and starts a new era, the one every box from the image counts its changed blocks from.

Nothing else. The image holds no secrets and no tesser code beyond the verifier, the boot script and the bun shim above. boxd is fetched and verified at boot.

[`test/boot.test.mjs`](test/boot.test.mjs) runs `boot/tesser-boot` under bash against a fake IMDS and a local HTTPS cell, with the real verifier (its key swapped for a test key) and a `systemctl` shim. It checks that a signed boxd installs, that a bad signature or bad user-data installs nothing, and that the shipped verifier trusts only the release key. [`test/hibernate.test.mjs`](test/hibernate.test.mjs) runs `tesser-hibernate` with shims for the kernel's files and the tools it calls: both sleep button events hibernate, a second press while hibernating and the one right after the resume do nothing, a failed hibernation powers off, and `pagecache` lists cached files and reads them back. [`test/initrd.test.mjs`](test/initrd.test.mjs) runs the initramfs's `init` with shims for the disk tools and a fake sysfs: a box with a hibernation image in its swap file resumes before dm-era is loaded, otherwise `hera` is dm-era over p1 with 512 KiB blocks and `hroot` linear over it, p1 grows to a bigger volume before that, and new era metadata says `since 0` on a pristine disk and `reset` on a used one. [`test/bun.test.mjs`](test/bun.test.mjs) runs `shim/bun` against a local release server and checks which version each pin picks, that a release downloads once, that one already under `~/.bun/versions` never downloads, and that a failed download leaves nothing behind. Plain node, no dependencies: `node --test test/*.test.mjs`. Both run on every pull request and before every build.

## Fleet images

The same build makes the images for tesser's own bare-metal hosts, which run boxes as Firecracker microVMs. Every release's [`fleet.json`](fleet.json) names them:

- **The host AMI** ([`host.pkr.hcl`](host.pkr.hcl), [`fleet/host/`](fleet/host), tagged `tesser:ami=host`, us-west-2 and us-east-1, public while the region's public-AMI quota has room): the same Ubuntu and kernel track as the box image, with Firecracker, jailer and snapshot-editor at the release [`fleet/versions`](fleet/versions) pins by sha256, transparent huge pages on, KSM off, and `tesser-host-boot`. On every boot that reads the host's config from user-data (strict JSON, never a script), formats the first empty disk as XFS `/srv`, swaps on a file there half the size of memory behind zswap (the most the cell overcommits a host's memory by), and fetches hostd, the host agent. A hosted host's user-data names its region's private images bucket (`imagesBucket`), which it reads with its instance role; a self-hosted host's user-data names its org (`orgId`), and it gets temporary credentials scoped to that one file from that org's `/v1/fleet/<org id>/creds`, then hands hostd the org id. It runs hostd only if its sha256 is the one in the user-data.
- **The guest image** (`images/build-<run id>/` in each region's images bucket, with the sha256 of each file in `fleet.json`): the tesser kernel's `vmlinux` (below), and the root disk [`fleet/guest-image.sh`](fleet/guest-image.sh) builds by running `setup.sh` with `TESSER_TARGET=firecracker` inside a microVM: the box image, minus the EC2 kernel and hibernation, plus [`fleet/guest/`](fleet/guest), which lets the host snapshot the box, start it from a template and personalize it. The build fails unless `smoke.sh` passes in it and the result boots on that kernel as a template and settles.

[`test/host-boot.test.mjs`](test/host-boot.test.mjs) runs `tesser-host-boot` against a fake IMDS, STS, cell and S3: a hosted host reads hostd from its images bucket with its role and never asks STS or the cell, a self-hosted one fetches it with the credentials the cell gave for its identity token, a refusing or failing cell or a bad answer fetches nothing, hostd installs only with the named sha256, and bad user-data fetches nothing.

## The kernel

[`kernel/build.sh`](kernel/build.sh) builds the tesser kernel: kernel.org's 6.18 LTS release that [`fleet/versions`](fleet/versions) pins by sha256, the patches in [`kernel/patches/`](kernel/patches), and Firecracker's 6.18 guest config for its pinned release plus [`kernel/tesser.config`](kernel/tesser.config), everything built in, no modules. Box AMIs boot its `bzImage`, fleet microVMs its `vmlinux` (Firecracker can't resume a hibernation image under a bzImage boot). The patches let a hibernation image made by one machine resume on another (an EC2 instance, a microVM, a loader on a fresh instance) as long as it's the same kernel build, skip restoring any PCI device that isn't there after such a resume, and let userspace add a PCI root bus the booting machine didn't have (`/sys/bus/pci/add_root_bus`), so a box born in a microVM finds an EC2 instance's ENA and volumes. A resume needs the exact build, so the build is reproducible and its version string (`uname -v`) is a hash of everything that goes into it.

[`images.yml`](.github/workflows/images.yml) builds it and the guest image, and runs `smoke.sh` on that kernel in Firecracker, for every build and every pull request that touches them. [`kernel-bump.yml`](.github/workflows/kernel-bump.yml) checks kernel.org every morning: when a newer 6.18 release is out (stable releases are how CVE fixes reach a longterm kernel), it pins it on a branch, builds and smoke-tests it, and opens a pull request. Merging it publishes the next images; a box gets the new kernel at its next boot from them.

## How to verify an AMI

- Every AMI is built by [`build.yml`](.github/workflows/build.yml) from a commit of this repo, in a public run. Each run creates a [release](../../releases) named `build-<run id>` that lists its AMI ids and base AMI and links the run and the commit it built. tesser's own deploy pins the latest release and moves to each new one on its own.
- [`amis.json`](amis.json) holds the current AMI id per region. Its git history is the history of every published image, and each commit names the commit it was built from.
- Each image is tagged `tesser:source=<commit sha>` and `tesser:base=<Canonical AMI id>`, and owned by tesser's AWS account `131798513069`:

  ```sh
  aws ec2 describe-images --region us-west-2 --owners 131798513069 \
    --filters 'Name=name,Values=tesser-box-*' \
    --query 'Images[].[ImageId,Name,CreationDate,Tags[?Key==`tesser:source`]|[0].Value,Tags[?Key==`tesser:base`]|[0].Value]' --output table
  ```

Check that the AMI you launch appears in a run's output, and read this repo at that commit.

## Copy it into your own account

Only the **newest 2** images per region stay public. Older ones are deregistered, so copy an image you rely on promptly:

```sh
aws ec2 copy-image --region us-west-2 --source-region us-west-2 \
  --source-image-id ami-... --name tesser-box-<sha>
```

With Pulumi:

```ts
new aws.ec2.AmiCopy("tesser-box", {
  sourceAmiId: "ami-...",
  sourceAmiRegion: "us-west-2",
});
```

Pin the AMI id from a specific build, and when you review, read this repo at that build's commit sha. Never `main`: it moves.

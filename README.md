# tesser box image

This repo is the whole recipe for the AMI every [tesser](https://tesser.sh) box boots from. It holds everything that goes into the image, and every published AMI is built from it by a public GitHub Actions run.

## What's in the image

Stock Ubuntu 24.04 LTS from Canonical, the newest one Canonical has published when the build runs (`box.pkr.hcl` filters on Canonical's account and the noble amd64 name). Each image records the exact base AMI id in its `tesser:base` tag and in its release notes. `build.yml` rebuilds every Monday as well as on every push to `main`, so OS patches arrive within a week. On top of the base:

- **[`setup.sh`](setup.sh):** the dev toolchain a box needs.
  - build tools, git (from the git-core PPA), docker and compose, rsync;
  - node 22 and 24 through fnm, and bun;
  - passwordless sudo for `ubuntu`;
  - higher inotify limits.

  It also turns off unattended upgrades and needrestart's automatic restarts, so a box never patches or restarts itself in the middle of your work.
- **[`boot/`](boot):** runs once, on first boot.
  - `tesser-boot` reads the box's config from EC2 user-data. It must be strict JSON with exactly three keys (`orgId`, `boxId`, `cellUrl`), none of them secret: boxd proves which instance it runs on with a token STS signs for the instance profile. Until the control plane stops sending it, a fourth `boxToken` key is accepted and passed to boxd.
  - It downloads boxd, the box agent, from that cell and installs it only if `tesser-verify-boxd` accepts it.
  - `tesser-boxd.service` runs boxd as `ubuntu`.
- **[`config/`](config):** the sysctl settings, and `allow_userdata: false`, which stops cloud-init from ever running user-data as a script. User-data is data here, never code.
- **[`verify/verify.mjs`](verify/verify.mjs):** installed as `/usr/local/bin/tesser-verify-boxd`. It checks three things:
  - boxd's statement carries an ed25519 signature by tesser's release key;
  - the statement is for boxd;
  - the downloaded bundle's sha256 matches the statement.

  Node built-ins only. On every build, the workflow first runs it against the boxd that api.tesser.sh serves right now, so this verifier and the live signed boxd can't drift apart.
- **[`cleanup.sh`](cleanup.sh):** removes the build instance's SSH host keys, authorized keys and cloud-init state before imaging.

Nothing else. The image holds no secrets and no tesser code beyond the verifier and boot script above. boxd is fetched and verified at boot.

[`test/boot.test.mjs`](test/boot.test.mjs) runs `boot/tesser-boot` under bash against a fake IMDS and a local HTTPS cell, with the real verifier (its key swapped for a test key) and a `systemctl` shim. It checks that a signed boxd installs, that a bad signature or bad user-data installs nothing, and that the shipped verifier trusts only the release key. Plain node, no dependencies: `node --test test/boot.test.mjs`. It runs on every pull request and before every build.

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

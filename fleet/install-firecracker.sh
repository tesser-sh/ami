#!/bin/bash
# Installs the pinned Firecracker, jailer and snapshot-editor into <dir>, from
# the release tarball whose sha256 fleet/versions pins.
# usage: install-firecracker.sh <dir>
set -euo pipefail
dest=${1:?dir}
source "$(dirname "$0")/versions"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/fc.tgz" "https://github.com/firecracker-microvm/firecracker/releases/download/$firecracker/firecracker-$firecracker-x86_64.tgz"
echo "$firecracker_sha256  $work/fc.tgz" | sha256sum -c --quiet
tar xzf "$work/fc.tgz" -C "$work"
release=$work/release-$firecracker-x86_64
(cd "$release" && sha256sum -c --quiet --ignore-missing SHA256SUMS)
for bin in firecracker jailer snapshot-editor; do
  install -D -m 755 "$release/$bin-$firecracker-x86_64" "$dest/$bin"
done
"$dest/firecracker" --version | head -1

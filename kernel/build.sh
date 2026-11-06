#!/bin/bash
# Builds the tesser kernel, the one kernel every box runs: an EC2 box boots its
# bzImage, a fleet microVM and the move loader boot its vmlinux (Firecracker
# can't restore a hibernation image under a bzImage boot). kernel.org's pinned
# 6.18 LTS release, the patches next to this script, Firecracker's 6.18 guest
# config for its pinned release plus tesser.config. Everything is built in;
# there are no modules.
# A hibernation image resumes only under the same build, so the build is
# reproducible: its version string is a hash of everything that goes into it,
# the compiler and linker included.
# usage: build.sh <out dir>
set -euo pipefail
out=${1:?out dir}
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../fleet/versions"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/linux.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v${kernel%%.*}.x/linux-$kernel.tar.xz"
echo "$kernel_sha256  $work/linux.tar.xz" | sha256sum -c --quiet
curl -fsSL -o "$work/config" "https://raw.githubusercontent.com/firecracker-microvm/firecracker/$firecracker/resources/guest_configs/microvm-kernel-ci-x86_64-${kernel%.*}.config"
echo "$kernel_config_sha256  $work/config" | sha256sum -c --quiet
tar xJf "$work/linux.tar.xz" -C "$work"
cd "$work/linux-$kernel"
for p in "$here"/patches/*.patch; do patch -p1 -s < "$p"; done
build=$(cat "$here/build.sh" "$here/tesser.config" "$here"/patches/*.patch "$work/config" | { echo "$kernel $kernel_sha256 $(cc --version | head -1) $(ld --version | head -1)"; cat; } | sha256sum | cut -c1-12)
export KBUILD_BUILD_VERSION=$build KBUILD_BUILD_TIMESTAMP=1970-01-01 KBUILD_BUILD_USER=tesser KBUILD_BUILD_HOST=tesser
cp "$work/config" .config
scripts/kconfig/merge_config.sh -m -Q .config "$here/tesser.config" > /dev/null
make RUSTC=false olddefconfig > /dev/null
missing=$(grep -o '^CONFIG_[A-Z0-9_]*=y' "$here/tesser.config" | while read -r o; do grep -qx "$o" .config || echo "${o%=y}"; done)
[[ -z $missing ]] || { echo "build.sh: not built in:" $missing >&2; exit 1; }
! grep -q '^CONFIG_MODULES=y' .config || { echo "build.sh: modules are on" >&2; exit 1; }
make -j"$(nproc)" RUSTC=false bzImage vmlinux > /dev/null
install -D -m 644 vmlinux "$out/vmlinux"
install -D -m 644 arch/x86/boot/bzImage "$out/bzImage"
install -D -m 644 .config "$out/config"
echo "$(make -s kernelrelease) $(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' include/generated/utsversion.h)" > "$out/release"
echo "build.sh: $out ($(cat "$out/release"))"

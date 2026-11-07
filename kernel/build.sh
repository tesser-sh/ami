#!/bin/bash
# Builds the tesser kernel, the one kernel every box runs: Canonical's noble
# linux-aws source at the version fleet/versions pins, with Ubuntu's own
# config and debian/rules, plus the patches next to this script. An EC2 box
# installs its .debs; a fleet microVM and the move loader boot its vmlinux
# (Firecracker can't restore a hibernation image under a bzImage boot), with
# the modules from the same .debs on the guest's disk.
# A hibernation image resumes only under the same build, and two builds of
# this script are never the same build (module signing keys are made per
# build), so every artifact comes from one run of it, and uname -v carries the
# patches' hash and the build's own timestamp.
# usage: build.sh <out dir>
set -euo pipefail
out=$(realpath -m "${1:?out dir}")
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../fleet/versions"
work=$(mktemp -d "${KERNEL_WORK:-/tmp}/kernel.XXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"

url=https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/linux-aws/$ubuntu_kernel
dsc=linux-aws_$ubuntu_kernel.dsc
curl -fsSL --retry 3 -o "$dsc" "$url/$dsc"
echo "$ubuntu_kernel_dsc_sha256  $dsc" | sha256sum -c --quiet
# Launchpad's librarian serves the 230 MB upstream tarball at ~300 KB/s; the
# archive has it as long as noble's release pocket does. dpkg-source checks
# every file against the .dsc.
for f in $(awk '/^Checksums-Sha256:/ { s = 1; next } /^[^ ]/ { s = 0 } s { print $3 }' "$dsc"); do
  case $f in
    *.orig.tar.*) curl -fsSL --retry 3 -o "$f" "http://archive.ubuntu.com/ubuntu/pool/main/l/linux-aws/$f" ;;
    *) curl -fsSL --retry 3 -o "$f" "$url/$f" ;;
  esac
done
dpkg-source -x "$dsc" src > /dev/null
cd src

for p in "$here"/patches/*.patch; do patch -p1 -s < "$p"; done
tag=tesser$(cat "$here"/patches/*.patch | sha256sum | cut -c1-12)
{
  printf 'linux-aws (%s+%s) noble; urgency=medium\n\n  * kernel/patches from github.com/tesser-sh/ami\n\n' "$ubuntu_kernel" "$tag"
  printf ' -- tesser <kernel@tesser.sh>  %s\n\n' "$(dpkg-parsechangelog -l debian.aws/changelog -S Date)"
  cat debian.aws/changelog
} > changelog && mv changelog debian.aws/changelog

rules=(do_tools=false do_zfs=false do_v4l2loopback=false)
export DEB_BUILD_OPTIONS="parallel=$(nproc)"
fakeroot debian/rules clean "${rules[@]}" > /dev/null
debian/rules build-aws "${rules[@]}"
fakeroot debian/rules binary-headers binary-aws "${rules[@]}"

build=debian/build/build-aws
release=$(cat "$build/include/config/kernel.release")
uts=$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$build/include/generated/utsversion.h")
install -d "$out/debs"
cp ../*.deb "$out/debs/"
objcopy --strip-debug "$build/vmlinux" "$out/vmlinux"
install -m 644 "$build/arch/x86/boot/bzImage" "$out/bzImage"
install -m 644 "$build/.config" "$out/config"
echo "$release $uts" > "$out/release"

# The vmlinux is the one in the image .deb: the same build id, the same banner.
deb=$(ls "$out"/debs/linux-image-unsigned-"$release"_*.deb)
dpkg-deb --fsys-tarfile "$deb" | tar -xO "./boot/vmlinuz-$release" > "$work/vmlinuz"
cmp -s "$work/vmlinuz" "$out/bzImage" || { echo "build.sh: bzImage is not the .deb's vmlinuz" >&2; exit 1; }
scripts/extract-vmlinux "$work/vmlinuz" > "$work/vmlinux.deb"
buildid() { readelf -n "$1" | sed -n 's/^ *Build ID: //p'; }
[[ -n $(buildid "$out/vmlinux") && $(buildid "$out/vmlinux") == $(buildid "$work/vmlinux.deb") ]] || { echo "build.sh: vmlinux build id differs from the .deb's" >&2; exit 1; }
grep -qaF "$uts" "$out/vmlinux" || { echo "build.sh: vmlinux banner is not $uts" >&2; exit 1; }
buildid "$out/vmlinux" > "$out/build-id"
echo "build.sh: $out ($(cat "$out/release"), build id $(cat "$out/build-id"))"

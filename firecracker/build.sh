#!/bin/bash
# Builds the Firecracker release fleet hosts run: upstream's source at the tag
# and commit fleet/versions pins, plus the patches next to this script, built
# the way upstream cuts its releases, by upstream's tools/release.sh in the
# dev container that tag's tools/devtool names (pinned here by digest): static
# musl, against that container's static libseccomp. The tarball has the shape
# of upstream's: release-<tag>-x86_64/ with <bin>-<tag>-x86_64 and SHA256SUMS.
# The build is reproducible: no patches builds upstream's binaries byte for
# byte, and a rebuild of the same inputs makes the same tarball.
# usage: build.sh <out dir>
set -euo pipefail
out=$(realpath -m "${1:?out dir}")
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../fleet/versions"
devctr_tag=v93
devctr=public.ecr.aws/firecracker/fcuvm:$devctr_tag@sha256:36d81dd62f79c2f3ae5f97429d4c1504999539daa27c4797c993efc799702720
work=$(mktemp -d "${FIRECRACKER_WORK:-/tmp}/firecracker.XXXX")
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$firecracker" https://github.com/firecracker-microvm/firecracker.git "$work/src"
[[ $(git -C "$work/src" rev-parse HEAD) == "$firecracker_commit" ]] || { echo "build.sh: $firecracker is not $firecracker_commit" >&2; exit 1; }
grep -qxF "DEVCTR_IMAGE_TAG=\${DEVCTR_IMAGE_TAG:-$devctr_tag}" "$work/src/tools/devtool" || { echo "build.sh: $firecracker builds in another dev container than $devctr_tag" >&2; exit 1; }
shopt -s nullglob
for p in "$here"/patches/*.patch; do patch -d "$work/src" -p1 -s < "$p"; done

docker run --rm -v "$work/src:/firecracker" -w /firecracker "$devctr" \
  bash -c "./tools/release.sh --libc musl --profile release --make-release && chown -R $(id -u):$(id -g) ."

release=release-$firecracker-x86_64
install -d "$out"
tar -C "$work/src" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$(git -C "$work/src" log -1 --format=%ct)" -cf - "$release" |
  gzip -n > "$out/firecracker-$firecracker-x86_64.tgz"
echo "build.sh: $out/firecracker-$firecracker-x86_64.tgz"

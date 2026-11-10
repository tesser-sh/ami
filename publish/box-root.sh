#!/bin/bash
# Cuts a published box AMI's root partition out of its EBS snapshot, as hosts
# need it to land an EC2 box's root as a copy of the AMI plus what the box
# changed since (tesser sends only the blocks dm-era saw written).
# Fails unless the partition is the one the image's grub boots and its
# /etc/tesser/base names the AMI.
# usage: box-root.sh <region> <ami id> <out dir>   (writes root.ext4.zst, box-root.json)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
region=${1:?region} ami=${2:?ami id} out=${3:?out dir}
mkdir -p "$out"
work=$(mktemp -d "${WORK:-/tmp}/box-root.XXXX")
trap 'rm -rf "$work"' EXIT

read -r name snapshot < <(aws ec2 describe-images --region "$region" --image-ids "$ami" \
  --query 'Images[0].[Name, BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.SnapshotId | [0]]' --output text)
echo "box-root: $ami is $name, root snapshot $snapshot"
start=$(date +%s)
python3 "$here/snapshot-read.py" "$region" "$snapshot" "$work/disk.raw"
echo "box-root: read $snapshot in $(( $(date +%s) - start )) s"

root=
while read -r pstart psize puuid; do
  [ "$psize" -gt $((2 * 1024 * 1024)) ] || continue
  dd if="$work/disk.raw" of="$work/part.ext4" bs=1M skip=$((pstart * 512)) count=$((psize * 512)) iflag=skip_bytes,count_bytes conv=sparse status=none
  base=$(debugfs -R "cat /etc/tesser/base" "$work/part.ext4" 2> /dev/null || true)
  grub=$(debugfs -R "cat /etc/default/grub.d/95-tesser.cfg" "$work/part.ext4" 2> /dev/null || true)
  if [ "$base" = "ami $name" ] && [[ $grub == *"tesser.root=PARTUUID=${puuid,,}"* ]]; then
    root=$work/part.ext4
    echo "box-root: root is the partition at sector $pstart ($((psize * 512)) bytes), PARTUUID ${puuid,,}"
    break
  fi
  rm -f "$work/part.ext4"
done < <(sfdisk --json "$work/disk.raw" | jq -r '.partitiontable.partitions[] | "\(.start) \(.size) \(.uuid)"')
[ -n "$root" ] || { echo "box-root: no partition of $snapshot is the root grub boots with /etc/tesser/base = ami $name" >&2; exit 1; }
e2fsck -fn "$root" > /dev/null

zstd -T0 -3 -q -o "$out/root.ext4.zst" "$root"
jq -n --arg id "$name" --arg root "$(sha256sum "$out/root.ext4.zst" | cut -d' ' -f1)" --argjson bytes "$(stat -c %s "$root")" '{id: $id, root: $root, bytes: $bytes}' > "$out/box-root.json"
cat "$out/box-root.json"

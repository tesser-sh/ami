#!/bin/bash
# Runs last, as root: strip what belongs to the build instance so every box
# starts clean (the same files EC2 Image Builder's cleanup removes).
set -euo pipefail

cloud-init clean --logs
rm -f /etc/sudoers.d/90-cloud-init-users /etc/hostname
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
rm -rf /tmp/tesser
# Every box from this image counts its changed blocks from here.
if dmsetup status hera > /dev/null 2>&1; then
  dmsetup message hera 0 checkpoint
  echo "since $(dmsetup status hera | awk '{ print $6 }')" > /var/lib/tesser/era
fi

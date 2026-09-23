#!/bin/bash
# Runs last, as root: strip what belongs to the build instance so every box
# starts clean (the same files EC2 Image Builder's cleanup removes).
set -euo pipefail

cloud-init clean --logs
rm -f /etc/sudoers.d/90-cloud-init-users /etc/hostname
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
rm -rf /tmp/tesser

#!/bin/bash
# Runs as root after the build instance reboots into the host image's kernel.
# The build instance is no metal host, so nothing here needs /dev/kvm.
set -euo pipefail

kernels=(/boot/vmlinuz-*)
[[ ${kernels[*]} == "/boot/vmlinuz-$(uname -r)" ]] || { echo "booted $(uname -r), image has ${kernels[*]}" >&2; exit 1; }
echo "kernel $(uname -r)"

firecracker --version | head -1
jailer --version | head -1
snapshot-editor --version | head -1
for tool in jq xfs_io nft wg conntrack zstd; do command -v "$tool" > /dev/null || { echo "no $tool" >&2; exit 1; }; done

[[ $(cat /sys/kernel/mm/transparent_hugepage/enabled) == *"[always]"* ]] || { echo "THP is not always" >&2; exit 1; }
[[ $(cat /sys/kernel/mm/ksm/run) == 0 ]] || { echo "KSM is on" >&2; exit 1; }
[[ -z $(swapon --noheadings) ]] || { echo "swap is on" >&2; exit 1; }
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || { echo "ip_forward is off" >&2; exit 1; }
[[ $(systemctl is-enabled tesser-host-boot.service) == enabled ]]
systemd-analyze verify /etc/systemd/system/tesser-host-boot.service /etc/systemd/system/tesser-hostd.service
grep -qx 'allow_userdata: false' /etc/cloud/cloud.cfg.d/99-tesser.cfg

#!/bin/bash
# Runs once, as root, on the build instance of the fleet host image: what a
# bare-metal host needs to run boxes as Firecracker microVMs. hostd is not in
# it: tesser-host-boot fetches the build the cell names, on every launch.
set -euo pipefail
files=${TESSER_FILES:?}

export DEBIAN_FRONTEND=noninteractive
printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99tesser

# A host never patches itself: a new image replaces it.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
systemctl stop apt-daily.service apt-daily-upgrade.service
systemctl mask apt-daily.service apt-daily-upgrade.service
apt-get purge -y -o DPkg::Lock::Timeout=600 unattended-upgrades ec2-hibinit-agent
install -d /etc/needrestart/conf.d
echo '$nrconf{restart} = "l";' > /etc/needrestart/conf.d/tesser.conf

apt-get update
apt-get install -y curl jq xfsprogs nftables iproute2 zstd wireguard-tools conntrack

# The same kernel track as the box image. A memory snapshot restores only on
# the KVM it was taken on (major.minor), so this is what keeps sleeping boxes
# warm across host images.
kernel=linux-aws-lts-24.04
apt-get install -y "$kernel"
abi=$(dpkg-query -W -f='${Depends}' "linux-image-${kernel#linux-}" | grep -oP 'linux-image-\K[0-9][^ ,]*')
old=$(dpkg-query -W -f='${db:Status-Abbrev}${Package}\n' 'linux-*' | sed -n 's/^ii *//p' |
  grep -E '^linux-(image-|headers-|tools-|modules-)?aws$|[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | grep -vF "${abi%-aws}" || true)
[[ -z $old ]] || apt-get purge -y $old
apt-get autoremove --purge -y

bash "$files/fleet/install-firecracker.sh" /usr/local/bin

# Boxes' memory is theirs alone: no page merging across tenants, and no swap
# under a guest whose memory is a snapshot file. Huge pages back guest memory.
install -m 644 "$files/fleet/host/tesser-host.tmpfiles" /etc/tmpfiles.d/tesser-host.conf
install -m 644 "$files/fleet/host/99-tesser-host.conf" /etc/sysctl.d/99-tesser-host.conf
systemctl mask swap.target

install -m 644 "$files/config/99-tesser.cfg" /etc/cloud/cloud.cfg.d/99-tesser.cfg
install -m 755 "$files/fleet/host/tesser-host-boot" /usr/local/sbin/tesser-host-boot
install -m 644 "$files/fleet/host/tesser-host-boot.service" /etc/systemd/system/tesser-host-boot.service
install -m 644 "$files/fleet/host/tesser-hostd.service" /etc/systemd/system/tesser-hostd.service
systemctl enable tesser-host-boot.service

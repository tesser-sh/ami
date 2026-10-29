#!/bin/bash
# Runs once, as root, on the build instance. Everything the image has on top
# of stock Ubuntu comes from this script and the files next to it.
set -euo pipefail
files=${TESSER_FILES:?}

export DEBIAN_FRONTEND=noninteractive
printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99tesser

# A box must never patch itself mid-build: no unattended upgrades, and
# needrestart never bounces tesser-boxd or docker after an apt run.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
systemctl stop apt-daily.service apt-daily-upgrade.service
systemctl mask apt-daily.service apt-daily-upgrade.service
apt-get purge -y -o DPkg::Lock::Timeout=600 unattended-upgrades
install -d /etc/needrestart/conf.d
echo '$nrconf{restart} = "l";' > /etc/needrestart/conf.d/tesser.conf

apt-get update
apt-get install -y ca-certificates curl rsync unzip nftables nbd-client docker.io docker-compose-v2 docker-buildx build-essential pkg-config libssl-dev software-properties-common systemd-zram-generator
add-apt-repository -y ppa:git-core/ppa
apt-get install -y git

# The kernel track every box boots, and the one place to change it. Canonical's
# noble image rolls to the newest HWE kernel (7.0 now), and MongoDB 8 refuses
# to start on 6.19 through 7.0.13 (SERVER-121912). noble has no 6.18 for aws
# and 6.17 no longer gets fixes, so boxes run the 24.04 LTS kernel, which
# stays on 6.8 and is patched until 2029. Every other kernel goes, so grub
# boots this one; smoke.sh fails the build if a box would boot anything else.
kernel=linux-aws-lts-24.04
apt-get install -y "$kernel"
abi=$(dpkg-query -W -f='${Depends}' "linux-image-${kernel#linux-}" | grep -oP 'linux-image-\K[0-9][^ ,]*')
old=$(dpkg-query -W -f='${db:Status-Abbrev}${Package}\n' 'linux-*' | sed -n 's/^ii *//p' |
  grep -E '^linux-(image-|headers-|tools-|modules-)?aws$|[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | grep -vF "${abi%-aws}" || true)
[[ -z $old ]] || apt-get purge -y $old
apt-get autoremove --purge -y

# node 22 and 24 through fnm, 24 the default, on every PATH.
export FNM_DIR=/usr/local/fnm
curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/fnm --skip-shell
/usr/local/fnm/fnm install 22
/usr/local/fnm/fnm install 24
/usr/local/fnm/fnm default 24
for b in node npm npx corepack; do ln -sf /usr/local/fnm/aliases/default/bin/$b /usr/local/bin/$b; done
PATH=/usr/local/bin:$PATH /usr/local/bin/corepack enable --install-directory /usr/local/bin
sed -i 's|^PATH="|PATH="/usr/local/fnm/aliases/default/bin:|' /etc/environment
printf '%s\n' 'export FNM_DIR=/usr/local/fnm' 'export PATH=/usr/local/fnm:$PATH' 'eval "$(fnm env --use-on-cd --shell bash)"' > /etc/profile.d/fnm.sh
chown -R ubuntu:ubuntu /usr/local/fnm

# The only thing that decides whether a downloaded boxd may run.
install -m 755 "$files/verify/verify.mjs" /usr/local/bin/tesser-verify-boxd

# bun through a shim that runs the version the repo pins, installing it on
# first use; the newest release for a repo that pins none.
latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/oven-sh/bun/releases/latest)
latest=${latest##*/bun-v}
[[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
install -d /usr/local/bun
echo "$latest" > /usr/local/bun/default
install -m 755 "$files/shim/bun" /usr/local/bin/bun
ln -sf bun /usr/local/bin/bunx
(cd / && /usr/local/bin/bun --version)
chown -R ubuntu:ubuntu /usr/local/bun
sed -i 's|^PATH="|PATH="/home/ubuntu/.bun/bin:|' /etc/environment
printf '%s\n' 'export PATH=$HOME/.bun/bin:$PATH' > /etc/profile.d/bun.sh

usermod -aG docker ubuntu
systemctl enable docker
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tesser-ubuntu
chmod 440 /etc/sudoers.d/tesser-ubuntu
# No login banner: pam_motd runs update-motd's scripts on every new ssh session.
sed -i '/^session\s\+optional\s\+pam_motd\.so/s/^/#/' /etc/pam.d/sshd

install -m 644 "$files/config/99-tesser.conf" /etc/sysctl.d/99-tesser.conf
# Swap in compressed memory: a spike on top of a running stack slows down
# instead of getting OOM-killed.
install -m 644 "$files/config/zram-generator.conf" /etc/systemd/zram-generator.conf
# User-data is config for tesser-boot, never a script cloud-init runs.
install -m 644 "$files/config/99-tesser.cfg" /etc/cloud/cloud.cfg.d/99-tesser.cfg
install -m 644 "$files/boot/tesser-boxd.service" /etc/systemd/system/tesser-boxd.service
install -m 644 "$files/boot/tesser-boot.service" /etc/systemd/system/tesser-boot.service
install -m 755 "$files/boot/tesser-boot" /usr/local/sbin/tesser-boot
systemctl enable tesser-boot.service

# Hibernation: tesser's handler replaces Ubuntu's for EC2's sleep button, and
# Ubuntu's resume hook (a swapoff that pages the whole image back in from EBS
# 4 KB at a time) never runs.
install -m 755 "$files/hibernate/tesser-hibernate" /usr/local/sbin/tesser-hibernate
install -D -m 755 "$files/hibernate/pagecache" /usr/local/lib/tesser/pagecache
install -m 644 "$files/hibernate/tesser-sleep" /etc/acpi/events/tesser-sleep
dpkg-divert --rename --divert /etc/acpi/hibinit-sleep.disabled --add /etc/acpi/events/hibinit-sleep
dpkg-divert --rename --divert /usr/lib/ec2-hibinit-agent/system-sleep.disabled --add /lib/systemd/system-sleep/hibinit-agent
install -D -m 644 "$files/config/logind.conf" /etc/systemd/logind.conf.d/tesser.conf

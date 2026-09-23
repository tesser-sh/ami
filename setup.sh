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
apt-get install -y ca-certificates curl rsync unzip nftables docker.io docker-compose-v2 build-essential pkg-config libssl-dev software-properties-common
add-apt-repository -y ppa:git-core/ppa
apt-get install -y git

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

export BUN_INSTALL=/usr/local/bun
curl -fsSL https://bun.sh/install | bash
ln -sf /usr/local/bun/bin/bun /usr/local/bin/bun
ln -sf /usr/local/bun/bin/bun /usr/local/bin/bunx
chown -R ubuntu:ubuntu /usr/local/bun
sed -i 's|^PATH="|PATH="/home/ubuntu/.bun/bin:|' /etc/environment
printf '%s\n' 'export PATH=$HOME/.bun/bin:$PATH' > /etc/profile.d/bun.sh

usermod -aG docker ubuntu
systemctl enable docker
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tesser-ubuntu
chmod 440 /etc/sudoers.d/tesser-ubuntu

install -m 644 "$files/config/99-tesser.conf" /etc/sysctl.d/99-tesser.conf
# User-data is config for tesser-boot, never a script cloud-init runs.
install -m 644 "$files/config/99-tesser.cfg" /etc/cloud/cloud.cfg.d/99-tesser.cfg
install -m 644 "$files/boot/tesser-boxd.service" /etc/systemd/system/tesser-boxd.service
install -m 644 "$files/boot/tesser-boot.service" /etc/systemd/system/tesser-boot.service
install -m 755 "$files/boot/tesser-boot" /usr/local/sbin/tesser-boot
systemctl enable tesser-boot.service

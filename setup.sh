#!/bin/bash
# Runs once, as root, on the build instance. Everything the image has on top
# of stock Ubuntu comes from this script and the files next to it.
set -euo pipefail
files=${TESSER_FILES:?}
# ec2: the box AMI. firecracker: the root disk of a fleet microVM, which boots
# the tesser kernel's vmlinux and sleeps by memory snapshot, not by hibernation.
target=${TESSER_TARGET:-ec2}
[[ $target == ec2 || $target == firecracker ]] || { echo "setup.sh: unknown target $target" >&2; exit 1; }

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
apt-get install -y ca-certificates curl rsync unzip cpio zstd busybox-static thin-provisioning-tools kexec-tools nftables nbd-client docker.io docker-compose-v2 docker-buildx build-essential pkg-config libssl-dev software-properties-common systemd-zram-generator
add-apt-repository -y ppa:git-core/ppa
apt-get install -y git

# The tesser kernel (kernel/build.sh), the one every box runs: Canonical's
# 24.04 LTS linux-aws (6.8, patched until 2029) rebuilt with our patches, from
# the .debs this build was handed. MongoDB 8 refuses to start on 6.19 through
# 7.0.13 (SERVER-121912), so not the newest HWE kernel Canonical's image boots.
# Every other kernel goes, so grub boots this one; smoke.sh fails the build if
# a box would boot anything else. Held, because Canonical's own build of the
# same version has the same package names and isn't the same build.
debs=("$files"/kernel-out/debs/linux-{image-unsigned,modules,modules-extra}-[0-9]*.deb)
apt-get install -y "${debs[@]}"
ours=$(dpkg-deb -f "${debs[0]}" Package)
ours=${ours#linux-image-unsigned-}
old=$(dpkg-query -W -f='${db:Status-Abbrev}${Package}\n' 'linux-*' | sed -n 's/^ii *//p' |
  grep -E '^linux-(image-|headers-|tools-|modules-)?aws$|[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | grep -vF -- "-$ours" || true)
[[ -z $old ]] || apt-get purge -y $old
apt-mark hold "linux-image-unsigned-$ours" "linux-modules-$ours" "linux-modules-extra-$ours"
apt-get autoremove --purge -y
rm -f /etc/apt/apt.conf.d/99update-notifier /etc/apt/apt.conf.d/20packagekit
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
rm -f /var/lib/man-db/auto-update

# node 22 and 24 through fnm, 24 the default, on every PATH.
export FNM_DIR=/usr/local/fnm
curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/fnm --skip-shell
/usr/local/fnm/fnm install 22
/usr/local/fnm/fnm install 24
/usr/local/fnm/fnm default 24
for b in node npm npx corepack; do ln -sf /usr/local/fnm/aliases/default/bin/$b /usr/local/bin/$b; done
PATH=/usr/local/bin:$PATH /usr/local/bin/corepack enable --install-directory /usr/local/bin
sed -i 's|^PATH="\(.*/usr/local/bin\)|PATH="\1:/usr/local/fnm/aliases/default/bin|' /etc/environment
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

# uv for python and mise for ruby, on every PATH. mise never compiles a ruby.
curl -fsSL https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh
curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh
install -d /etc/mise
printf '%s\n' '[settings]' 'ruby.compile = false' 'idiomatic_version_file_enable_tools = ["ruby"]' 'trusted_config_paths = ["/home/ubuntu"]' > /etc/mise/config.toml
sed -i 's|^PATH="|PATH="/home/ubuntu/.local/share/mise/shims:|' /etc/environment
printf '%s\n' 'export PATH=$HOME/.local/share/mise/shims:$PATH' > /etc/profile.d/mise.sh

usermod -aG docker ubuntu
systemctl enable docker
# Docker Hub pulls try Google's mirror first: every box behind one address
# shares one anonymous Docker Hub quota.
install -D -m 644 "$files/config/docker-daemon.json" /etc/docker/daemon.json
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

if [[ $target == ec2 ]]; then
  # The root filesystem stays on p1 of the boot disk, under dm-era (its init
  # is boot/initrd/init), with the era metadata on a partition cut from the end
  # of /boot. The init finds p1 by the PARTUUID every box from this image
  # shares, grows it, and resizes the filesystem, so cloud-init doesn't.
  root=$(findmnt -no SOURCE /)
  bootpart=$(findmnt -no SOURCE /boot)
  disk=/dev/$(lsblk -no PKNAME "$bootpart")
  bootsys=/sys/class/block/${bootpart#/dev/}
  start=$(cat "$bootsys/start") size=$(cat "$bootsys/size")
  # fwupd (started by apt) holds /boot read-only in its own mount namespace.
  systemctl stop fwupd.service
  umount /boot/efi /boot
  e2fsck -fy "$bootpart" || (($? <= 1))
  resize2fs "$bootpart" 512M
  echo 'size=512MiB' | sfdisk -q --no-reread --no-tell-kernel -N "$(cat "$bootsys/partition")" "$disk"
  echo "start=$((start + 1048576)), size=$((size - 1048576)), name=tesser-era" | sfdisk -q --no-reread --no-tell-kernel --append "$disk"
  partx -u "$disk"
  partx -a "$disk" 2> /dev/null || true
  udevadm settle
  era=$(blkid -t PARTLABEL=tesser-era -o device)
  dd if=/dev/zero of="$era" bs=1M count=16 conv=fsync
  mount /boot
  mount /boot/efi
  sed -i 's|^\S\+\(\s\+/\s\)|/dev/mapper/hroot\1|' /etc/fstab
  install -m 644 "$files/config/99-tesser-box.cfg" /etc/cloud/cloud.cfg.d/99-tesser-box.cfg
  echo 'KERNEL=="dm-[0-9]*", ATTR{dm/name}=="hroot", SYMLINK+="mapper/hroot"' > /etc/udev/rules.d/99-hroot.rules

  initrd=$(mktemp -d)
  mkdir -p "$initrd"/{bin,dev,proc,sys,run,newroot,lib/modules}
  install -m 755 "$files/boot/initrd/init" "$initrd/init"
  cp /usr/bin/busybox "$initrd/bin/busybox"
  # dm-era and what it needs, in load order, decompressed: busybox insmod can't
  # read .ko.zst.
  modprobe -S "$ours" --show-depends dm-era | awk '$1 == "insmod" { print $2 }' | while read -r ko; do
    name=$(basename "$ko" .zst)
    zstd -dqf "$ko" -o "$initrd/lib/modules/$name"
    echo "$name" >> "$initrd/lib/modules/order"
  done
  grep -qx dm-era.ko "$initrd/lib/modules/order"
  for applet in sh mount sleep cat seq head grep basename dirname readlink dd tr date mkdir blockdev insmod switch_root poweroff; do
    ln -s busybox "$initrd/bin/$applet"
  done
  for tool in blkid sfdisk dmsetup debugfs resize2fs; do
    path=$(command -v "$tool")
    cp "$path" "$initrd/bin/"
    ldd "$path" | grep -oE '/[^ ]+' | while read -r lib; do install -D "$lib" "$initrd$lib"; done
  done
  (cd "$initrd" && find . | cpio -o -H newc --quiet) > /boot/tesser-initrd.img
  rm -rf "$initrd"

  # Box command line: Firecracker's CPU and timer quirks hidden from the start
  # (a box must resume where they differ), and virtio-mmio placeholders at the
  # slots a move target's root, swap, home and NIC appear on (tesser's
  # MOVE_SLOTS: Firecracker numbers them by attach order from IRQ 5 and
  # 0xc0001000). IRQ 5 (level-triggered on Nitro, edge in Firecracker), 8 (rtc0)
  # and 9 (acpi) are dummy disks the box never names. No framebuffer console,
  # and kernel messages on the serial console only: after a move the boot
  # framebuffer is no longer backed, and one fbcon redraw into it (simpledrm's
  # memcpy_toio) holds a CPU for ~21 s in the middle of the move.
  install -m 755 "$files/boot/09_tesser" /etc/grub.d/09_tesser
  chmod -x /etc/grub.d/10_linux /etc/grub.d/10_linux_zfs /etc/grub.d/20_linux_xen /etc/grub.d/30_os-prober
  rm -f /etc/default/grub.d/40-force-partuuid.cfg
  grep -q 'console=tty1 ' /etc/default/grub.d/50-cloudimg-settings.cfg
  sed -i 's/console=tty1 //' /etc/default/grub.d/50-cloudimg-settings.cfg
  mmio=" virtio_mmio.device=4K@0xc0002000:6 virtio_mmio.device=4K@0xc0003000:7 virtio_mmio.device=4K@0xc0006000:10 virtio_mmio.device=4K@0xc0007000:11"
  echo "GRUB_CMDLINE_LINUX=\"root=/dev/mapper/hroot panic=-1 efi=noruntime lapic=notscdeadline idle=halt nmi_watchdog=0 clearcpuid=aperfmperf,monitor initcall_blacklist=simpledrm_platform_driver_init$mmio tesser.root=PARTUUID=$(blkid -s PARTUUID -o value "$root")\"" > /etc/default/grub.d/95-tesser.cfg
  update-grub

  # What breaks when a box's disks and NIC go away and come back elsewhere:
  # cloud-init's hotplug hook (99-tesser-box.cfg turns it off), LVM scanning
  # the move's virtio and nbd disks, and multipathd, which has no module to load.
  sed -i '0,/^devices {/s//devices {\n\tglobal_filter = [ "r|^\/dev\/vd.*|", "r|^\/dev\/nbd.*|" ]/' /etc/lvm/lvm.conf
  systemctl mask multipathd.service multipathd.socket
  # A box that lands on another instance keeps the netplan of the one it left,
  # which matches the old NIC's MAC; any ENA gets DHCP from this one instead.
  install -D -m 644 "$files/config/90-tesser-ena.network" /etc/systemd/network/90-tesser-ena.network
  install -d /etc/tesser
  echo "ami ${TESSER_BASE:?}" > /etc/tesser/base

  # Hibernation: tesser's handler replaces Ubuntu's for EC2's sleep button, and
  # Ubuntu's resume hook (a swapoff that pages the whole image back in from EBS
  # 4 KB at a time) never runs.
  install -m 755 "$files/hibernate/tesser-hibernate" /usr/local/sbin/tesser-hibernate
  install -D -m 755 "$files/hibernate/pagecache" /usr/local/lib/tesser/pagecache
  install -m 644 "$files/hibernate/tesser-sleep" /etc/acpi/events/tesser-sleep
  dpkg-divert --rename --divert /etc/acpi/hibinit-sleep.disabled --add /etc/acpi/events/hibinit-sleep
  dpkg-divert --rename --divert /usr/lib/ec2-hibinit-agent/system-sleep.disabled --add /lib/systemd/system-sleep/hibinit-agent
  install -D -m 644 "$files/config/logind.conf" /etc/systemd/logind.conf.d/tesser.conf
  # The init finds the swap file itself; hibinit-agent's grub line can't name
  # a dm device.
  sed -i 's/^grub-update = True/grub-update = False/' /etc/hibinit-config.cfg
else
  # A microVM: its host snapshots it, starts it from a per-size template and
  # gives it an identity over vsock, and fakes EC2's metadata with
  # Firecracker's, so tesser-boot runs as it does on EC2.
  guest=$files/fleet/guest
  install -m 755 "$guest/tesser-hostkeys" /usr/local/sbin/tesser-hostkeys
  install -m 755 "$guest/tesser-resumed" /usr/local/sbin/tesser-resumed
  apt-get install -y musl-tools
  musl-gcc -Os -static -s -o /usr/local/sbin/tesser-vouch "$guest/tesser-vouch.c"
  for unit in ssh-hostkeys.service tesser-template.service tesser-vsock.socket tesser-vsock@.service; do
    install -m 644 "$guest/$unit" "/etc/systemd/system/$unit"
  done
  install -D -m 644 "$guest/tesser-boot-fleet.conf" /etc/systemd/system/tesser-boot.service.d/fleet.conf
  install -D -m 644 "$guest/resolved.conf" /etc/systemd/resolved.conf.d/10-tesser.conf
  systemctl enable ssh-hostkeys.service tesser-template.service tesser-vsock.socket
  # dockerd starts on its socket: a box's home stops it before it mounts.
  systemctl disable docker.service containerd.service
  systemctl enable docker.socket
  # A box that moves to EC2 is reached through AWS's SSM agent, which Ubuntu's
  # cloud image lacks and the EC2 AMI ships as a snap. It starts only with an
  # ENA NIC: a resumed microVM's systemd still believes it runs in Firecracker.
  source <(grep "^ssm_agent" "$files/fleet/versions")
  install -D -m 644 "$guest/amazon-ssm-agent-ec2.conf" /etc/systemd/system/amazon-ssm-agent.service.d/ec2.conf
  curl -fsSL -o /tmp/amazon-ssm-agent.deb "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/$ssm_agent/debian_amd64/amazon-ssm-agent.deb"
  echo "$ssm_agent_sha256  /tmp/amazon-ssm-agent.deb" | sha256sum -c --quiet
  dpkg -i /tmp/amazon-ssm-agent.deb
  rm /tmp/amazon-ssm-agent.deb
  systemctl enable amazon-ssm-agent.service
  systemctl mask systemd-networkd-wait-online.service serial-getty@ttyS0.service multipathd.service multipathd.socket \
    snapd.service snapd.socket snapd.seeded.service lxd-installer.socket
  install -d /etc/tesser
  touch /etc/tesser/snapshots
fi

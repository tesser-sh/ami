#!/bin/bash
# Builds the root disk every fleet microVM boots, the twin of the box AMI:
# Ubuntu noble's cloud image, then setup.sh with TESSER_TARGET=firecracker run
# inside a build microVM on the kernel the boxes boot, then stripped of what
# belongs to the build. Then it runs smoke.sh on a copy and boots the result
# as a template would, and fails unless smoke.sh passes and the guest settles
# and answers its host on vsock.
# Runs as root with /dev/kvm and firecracker on PATH.
# usage: guest-image.sh <kernel/build.sh out dir> <out root.ext4>
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
kernel=${1:?kernel out dir}
vmlinux=$kernel/vmlinux
out=${2:?out root.ext4}
work=$(mktemp -d "${WORK:-/tmp}/guest-image.XXXX")
mnt=$work/mnt
tap=fct0
loop=""
cleanup() {
  mountpoint -q "$work/src" && umount "$work/src"
  mountpoint -q "$mnt" && umount "$mnt"
  [ -z "$loop" ] || losetup -d "$loop" 2>/dev/null || true
  ip link del "$tap" 2>/dev/null || true
  nft delete table ip tesser_build 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$mnt" "$work/src"

source "$repo/fleet/versions"
curl -fsSL -o "$work/noble.img" "https://cloud-images.ubuntu.com/releases/noble/release-$noble/ubuntu-24.04-server-cloudimg-amd64.img"
echo "$noble_sha256  $work/noble.img" | sha256sum -c --quiet
echo "guest-image: base noble release-$noble $noble_sha256"
qemu-img convert -O raw "$work/noble.img" "$work/noble.raw"
# By offset, not losetup -P: a kernel without GPT support (Blacksmith's
# runners) scans the protective MBR and makes p1 the whole disk.
read -r start sectors < <(partx -g -o START,SECTORS -n 1 "$work/noble.raw")
loop=$(losetup -f --show -r -o $((start * 512)) --sizelimit $((sectors * 512)) "$work/noble.raw")
truncate -s 40G "$work/root.ext4"
mkfs.ext4 -F -q -L rootfs "$work/root.ext4"
mount -o ro "$loop" "$work/src"
mount -o loop "$work/root.ext4" "$mnt"
cp -a "$work/src/." "$mnt/"
umount "$work/src"
losetup -d "$loop"
loop=""

# What cloud-init and the EC2 AMI would have done: the disk, the user, no
# netplan (tesser-ip sets the address the kernel command line names), no
# cloud-init at all.
# The root is hroot, a dm-linear over the root disk that hostd's command line
# makes, so a move can suspend and remap it like an EC2 box's.
echo '/dev/mapper/hroot / ext4 defaults,noatime 0 1' > "$mnt/etc/fstab"
echo 'KERNEL=="dm-[0-9]*", ATTR{dm/name}=="hroot", SYMLINK+="mapper/hroot"' > "$mnt/etc/udev/rules.d/99-hroot.rules"
touch "$mnt/etc/cloud/cloud-init.disabled"
chroot "$mnt" useradd -m -s /bin/bash -G sudo,adm ubuntu
rm -f "$mnt"/etc/netplan/*.yaml
echo tesser-box > "$mnt/etc/hostname"

mkdir -p "$mnt/root/ami"
cp -a "$repo/setup.sh" "$repo/boot" "$repo/config" "$repo/shim" "$repo/verify" "$repo/fleet" "$mnt/root/ami/"
install -d "$mnt/root/ami/kernel-out"
cp -a "$kernel/debs" "$mnt/root/ami/kernel-out/"
install -m 644 /dev/stdin "$mnt/etc/systemd/system/tesser-build.service" <<'EOF'
[Unit]
After=network-online.target systemd-resolved.service
Wants=network-online.target
[Service]
Type=oneshot
Environment=TESSER_FILES=/root/ami TESSER_TARGET=firecracker
ExecStart=/bin/bash -c 'bash -x /root/ami/setup.sh > /root/build.log 2>&1 && apt-get clean && touch /root/build.ok; sync; systemctl reboot -f'
TimeoutStartSec=3600
[Install]
WantedBy=multi-user.target
EOF
chroot "$mnt" systemctl enable tesser-build.service
install -D -m 644 "$repo/fleet/guest/resolved.conf" "$mnt/etc/systemd/resolved.conf.d/10-tesser.conf"
install -m 755 "$repo/fleet/guest/tesser-ip" "$mnt/usr/local/sbin/tesser-ip"
install -m 644 "$repo/fleet/guest/tesser-ip.service" "$mnt/etc/systemd/system/tesser-ip.service"
chroot "$mnt" systemctl enable tesser-ip.service
install -D -m 644 "$repo/fleet/guest/dirty.conf" "$mnt/etc/sysctl.d/60-tesser-dirty.conf"
umount "$mnt"

ip tuntap add "$tap" mode tap
ip addr add 10.199.0.1/30 dev "$tap"
ip link set "$tap" up
ext=$(ip -o route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
sysctl -qw net.ipv4.ip_forward=1
nft -f - <<EOF
table ip tesser_build {
  chain postrouting { type nat hook postrouting priority srcnat; ip saddr 10.199.0.0/30 oifname "$ext" masquerade; }
  chain forward { type filter hook forward priority filter; iifname "$tap" accept; oifname "$tap" ct state established,related accept; }
}
EOF
# Docker's FORWARD policy, where the builder runs docker, drops the rest.
if command -v iptables > /dev/null; then
  iptables -I FORWARD 1 -i "$tap" -j ACCEPT
  iptables -I FORWARD 1 -o "$tap" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
boot() {
  cat > "$work/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"$vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off dm-mod.create=\\"hroot,,,rw,0 $(( $(stat -c %s "$work/root.ext4") / 512 )) linear /dev/vda 0\\" root=/dev/dm-0 rw $1"},
 "drives":[{"drive_id":"root","path_on_host":"$work/root.ext4","is_root_device":false,"is_read_only":false}],
 "machine-config":{"vcpu_count":$(( $(nproc) > 32 ? 32 : $(nproc) )),"mem_size_mib":8192},
 "network-interfaces":[{"iface_id":"eth0","guest_mac":"06:00:0a:c7:00:02","host_dev_name":"$tap"}],
 "vsock":{"guest_cid":3,"uds_path":"$work/v.sock"}}
EOF
  rm -f "$work/v.sock"
  firecracker --no-api --config-file "$work/vm.json" > "$work/console.log" 2>&1 &
  fc=$!
}
boot "ip=10.199.0.2::10.199.0.1:255.255.255.252::eth0:off"
timeout 3600 tail --pid="$fc" -f /dev/null || kill "$fc" 2>/dev/null || true
wait "$fc" 2>/dev/null || true

mount -o loop "$work/root.ext4" "$mnt"
if [ ! -f "$mnt/root/build.ok" ]; then
  tail -60 "$mnt/root/build.log" >&2 || tail -60 "$work/console.log" >&2
  echo "guest-image: setup.sh failed" >&2
  exit 1
fi
chroot "$mnt" systemctl disable tesser-build.service
rm -rf "$mnt/etc/systemd/system/tesser-build.service" "$mnt/root/build.log" "$mnt/root/build.ok" "$mnt/root/ami"
rm -f "$mnt"/etc/ssh/ssh_host_* "$mnt/var/lib/dbus/machine-id" "$mnt/etc/tesser/boxd.json"
: > "$mnt/etc/machine-id"
rm -rf "$mnt"/var/log/journal/* "$mnt/home/ubuntu/.ssh"
umount "$mnt"

# smoke.sh on a copy, with the network, so the image never sees it.
mv "$work/root.ext4" "$work/built.ext4"
cp --reflink=auto --sparse=always "$work/built.ext4" "$work/root.ext4"
mount -o loop "$work/root.ext4" "$mnt"
install -m 755 "$repo/smoke.sh" "$mnt/root/smoke.sh"
install -m 644 /dev/stdin "$mnt/etc/systemd/system/tesser-smoke.service" <<'EOF'
[Unit]
After=network-online.target systemd-resolved.service
Wants=network-online.target
[Service]
Type=oneshot
Environment=TESSER_TARGET=firecracker
ExecStart=/bin/bash -c '/root/smoke.sh > /root/smoke.log 2>&1 && touch /root/smoke.ok; sync; systemctl reboot -f'
TimeoutStartSec=1800
[Install]
WantedBy=multi-user.target
EOF
chroot "$mnt" systemctl enable tesser-smoke.service
umount "$mnt"
boot "ip=10.199.0.2::10.199.0.1:255.255.255.252::eth0:off systemd.mask=tesser-boot.service"
timeout 1800 tail --pid="$fc" -f /dev/null || kill "$fc" 2>/dev/null || true
wait "$fc" 2>/dev/null || true
mount -o loop "$work/root.ext4" "$mnt"
cat "$mnt/root/smoke.log" || tail -60 "$work/console.log"
[ -f "$mnt/root/smoke.ok" ] || { echo "guest-image: smoke.sh failed" >&2; exit 1; }
umount "$mnt"

# Booted as a template, with no network: hostd's own first step on a host.
cp --reflink=auto --sparse=always "$work/built.ext4" "$work/root.ext4"
boot "ip=10.255.255.254::10.128.0.1:255.128.0.0::eth0:off tesser.template"
answer=
for _ in $(seq 120); do
  answer=$(python3 - "$work/v.sock" <<'PY' 2>/dev/null || true
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(90)
s.connect(sys.argv[1])
s.sendall(b"CONNECT 1024\n")
f = s.makefile("rb")
if not f.readline().startswith(b"OK"):
    sys.exit(1)
s.sendall(b"ready\n")
print(f.readline().decode().strip())
PY
)
  [ "$answer" = ok ] && break
  sleep 1
done
kill "$fc" 2>/dev/null || true
[ "$answer" = ok ] || { tail -60 "$work/console.log" >&2; echo "guest-image: the image never settled as a template" >&2; exit 1; }
cp --sparse=always "$work/built.ext4" "$out"
echo "guest-image: $out"

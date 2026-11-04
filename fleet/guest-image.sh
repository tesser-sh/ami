#!/bin/bash
# Builds the root disk every fleet microVM boots, the twin of the box AMI:
# Ubuntu noble's cloud image, then setup.sh with TESSER_TARGET=firecracker run
# inside a build microVM on the kernel the boxes boot, then stripped of what
# belongs to the build. Then it boots the result as a template would and
# fails unless the guest settles and answers its host on vsock.
# Runs as root with /dev/kvm and firecracker on PATH.
# usage: guest-image.sh <vmlinux> <out root.ext4>
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
kernel=${1:?vmlinux}
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

images=https://cloud-images.ubuntu.com/noble/current
curl -fsSL -o "$work/noble.img" "$images/noble-server-cloudimg-amd64.img"
want=$(curl -fsSL "$images/SHA256SUMS" | awk '$2 == "*noble-server-cloudimg-amd64.img" {print $1}')
[ -n "$want" ] || { echo "guest-image: no published checksum for the cloud image" >&2; exit 1; }
echo "$want  $work/noble.img" | sha256sum -c --quiet
echo "guest-image: base noble-server-cloudimg-amd64.img $want"
qemu-img convert -O raw "$work/noble.img" "$work/noble.raw"
loop=$(losetup -fP --show "$work/noble.raw")
truncate -s 40G "$work/root.ext4"
mkfs.ext4 -F -q -L rootfs "$work/root.ext4"
mount -o ro "${loop}p1" "$work/src"
mount -o loop "$work/root.ext4" "$mnt"
cp -a "$work/src/." "$mnt/"
umount "$work/src"
losetup -d "$loop"
loop=""

# What cloud-init and the EC2 AMI would have done: the disk, the user, no
# netplan (the kernel command line sets the address), no cloud-init at all.
echo 'LABEL=rootfs / ext4 defaults,noatime 0 1' > "$mnt/etc/fstab"
touch "$mnt/etc/cloud/cloud-init.disabled"
chroot "$mnt" useradd -m -s /bin/bash -G sudo,adm ubuntu
rm -f "$mnt"/etc/netplan/*.yaml
echo tesser-box > "$mnt/etc/hostname"

mkdir -p "$mnt/root/ami"
cp -a "$repo/setup.sh" "$repo/boot" "$repo/config" "$repo/shim" "$repo/verify" "$repo/fleet" "$mnt/root/ami/"
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
{"boot-source":{"kernel_image_path":"$kernel","boot_args":"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw $1"},
 "drives":[{"drive_id":"root","path_on_host":"$work/root.ext4","is_root_device":true,"is_read_only":false}],
 "machine-config":{"vcpu_count":$(nproc),"mem_size_mib":8192},
 "network-interfaces":[{"iface_id":"eth0","guest_mac":"06:00:0a:c7:00:02","host_dev_name":"$tap"}],
 "vsock":{"guest_cid":3,"uds_path":"$work/v.sock"}}
EOF
  rm -f "$work/v.sock"
  firecracker --no-api --config-file "$work/vm.json" > "$work/console.log" 2>&1 &
  fc=$!
}
boot "ip=10.199.0.2::10.199.0.1:255.255.255.252::eth0:off"
timeout 3600 tail --pid="$fc" -f /dev/null || kill "$fc" 2>/dev/null || true

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

# Booted as a template, with no network: hostd's own first step on a host.
cp --reflink=auto --sparse=always "$work/root.ext4" "$work/smoke.ext4"
mv "$work/root.ext4" "$work/built.ext4"
mv "$work/smoke.ext4" "$work/root.ext4"
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

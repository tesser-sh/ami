#!/bin/bash
# Builds the kernel every fleet microVM boots: Firecracker's guest config for
# its pinned release, plus what a box needs built in (docker, nbd + dm-thin for
# the home disk, zram). Everything is built in; there are no modules.
# usage: kernel.sh <out vmlinux>
set -euo pipefail
out=${1:?out vmlinux}
source "$(dirname "$0")/versions"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/linux.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v${kernel%%.*}.x/linux-$kernel.tar.xz"
echo "$kernel_sha256  $work/linux.tar.xz" | sha256sum -c --quiet
curl -fsSL -o "$work/config" "https://raw.githubusercontent.com/firecracker-microvm/firecracker/$firecracker/resources/guest_configs/microvm-kernel-ci-x86_64-${kernel%.*}.config"
echo "$kernel_config_sha256  $work/config" | sha256sum -c --quiet
tar xJf "$work/linux.tar.xz" -C "$work"
cd "$work/linux-$kernel"
cp "$work/config" .config
for o in BLK_DEV_NBD OVERLAY_FS BRIDGE BRIDGE_NETFILTER VETH VXLAN NETFILTER NETFILTER_ADVANCED \
  NF_TABLES NF_TABLES_INET NF_TABLES_IPV4 NF_TABLES_IPV6 NFT_NAT NFT_MASQ NFT_CT NFT_COMPAT NFT_REJECT NFT_FIB_INET NFT_FIB_IPV4 \
  NF_CONNTRACK NF_NAT IP_NF_IPTABLES IP_NF_FILTER IP_NF_NAT IP_NF_TARGET_MASQUERADE IP_NF_MANGLE IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_NAT \
  NETFILTER_XTABLES NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_MULTIPORT NETFILTER_XT_MATCH_COMMENT \
  NETFILTER_XT_MARK NETFILTER_XT_TARGET_MASQUERADE IP_VS CGROUPS CGROUP_BPF CGROUP_DEVICE CGROUP_FREEZER CGROUP_PIDS CGROUP_SCHED MEMCG \
  BLK_CGROUP CPUSETS NAMESPACES USER_NS PID_NS NET_NS IPC_NS UTS_NS SECCOMP SECCOMP_FILTER KEYS POSIX_MQUEUE BLK_DEV_DM \
  DM_THIN_PROVISIONING DM_SNAPSHOT DM_BUFIO DM_PERSISTENT_DATA MD BTRFS_FS XFS_FS EXT4_FS FUSE_FS ZRAM ZSMALLOC CRYPTO_LZ4 CRYPTO_ZSTD \
  SWAP TUN DUMMY MACVLAN IPVLAN INET_DIAG UNIX_DIAG PACKET_DIAG NETLINK_DIAG BPF_SYSCALL VIRTIO_BALLOON VIRTIO_VSOCKETS VSOCKETS \
  IKCONFIG IKCONFIG_PROC SQUASHFS AUTOFS_FS FANOTIFY INOTIFY_USER USERFAULTFD TRANSPARENT_HUGEPAGE CHECKPOINT_RESTORE \
  IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES NET_SCHED NET_CLS_CGROUP CGROUP_NET_PRIO NET_SCH_FQ_CODEL; do
  ./scripts/config --enable "$o"
done
make olddefconfig > /dev/null
for o in BLK_DEV_NBD DM_THIN_PROVISIONING OVERLAY_FS BRIDGE NF_TABLES VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_VSOCKETS USER_NS ZRAM; do
  grep -q "^CONFIG_$o=y" .config || { echo "kernel.sh: CONFIG_$o is not built in" >&2; exit 1; }
done
make -j"$(nproc)" vmlinux > /dev/null
install -D -m 644 vmlinux "$out"
echo "kernel.sh: $out ($kernel)"

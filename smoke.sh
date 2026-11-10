#!/bin/bash
# Runs as root on the image's own kernel: on the box AMI's build instance after
# it reboots, and in a microVM on a copy of the fleet guest's root disk. What
# boxes run most must work on it, or the build fails. Everything pulled or
# installed here is deleted again.
set -euo pipefail
target=${TESSER_TARGET:-ec2}

if [[ $target == ec2 ]]; then
  kernels=(/boot/vmlinuz-*)
  [[ ${kernels[*]} == "/boot/vmlinuz-$(uname -r)" ]] || { echo "booted $(uname -r), image has ${kernels[*]}" >&2; exit 1; }
  [[ $(findmnt -no SOURCE /) == /dev/mapper/hroot && $(dmsetup table hera) == *" era "* && $(dmsetup deps -o devname hroot) == *"(hera)"* ]] || { echo "/ is not on dm-era" >&2; exit 1; }
  [[ $(cat /proc/cmdline) == *console=ttyS0* && $(cat /proc/cmdline) != *console=tty1* && ! -s /proc/fb ]] || { echo "a box has no framebuffer and logs to the serial console only: $(cat /proc/fb) $(cat /proc/cmdline)" >&2; exit 1; }
else
  [[ $(cat "/sys/dev/block/$(findmnt -no MAJ:MIN / | tr -d " ")/dm/name") == hroot ]] || { echo "/ is not on hroot" >&2; exit 1; }
fi
echo "kernel $(uname -r) $(uname -v)"
[[ $(cat /sys/block/zram0/comp_algorithm) == *"[zstd]"* ]] || { echo "zram is not on zstd" >&2; exit 1; }
# SNAPSHOT_INPLACE (kernel/patches/0004): a frozen process's anonymous memory
# is read in place and io_uring's pinned buffers are not, marking twice gives
# the same answer, unfreezing drops every reference, and the memory is intact
# afterwards. In the microVM it also makes an image and finds the process's
# pages in it as they are.
inplace=$(mktemp -d)
cat > "$inplace/check.c" << 'INPLACE'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/io_uring.h>
#include <linux/suspend_ioctls.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SNAPSHOT_INPLACE
#define SNAPSHOT_INPLACE _IOR(SNAPSHOT_IOC_MAGIC, 21, __kernel_loff_t)
#endif

#define MIB (1LL << 20)
#define HOG (512 * MIB)
#define PINNED (128 * MIB)
#define PAGE 4096

static void fail(const char *m) {
  fprintf(stderr, "inplace-check: %s\n", m);
  exit(1);
}

static long long meminfo(const char *key) {
  char b[8192];
  int f = open("/proc/meminfo", O_RDONLY);
  ssize_t n = f < 0 ? -1 : read(f, b, sizeof b - 1);
  if (f >= 0)
    close(f);
  b[n > 0 ? n : 0] = 0;
  char *p = strstr(b, key);
  if (!p)
    fail("no such /proc/meminfo line");
  return strtoll(p + strlen(key), 0, 10) << 10;
}

#define HOG_MAGIC 0x686f672070616765ULL

static long long unmapped_anon(void) {
  return meminfo("Active(anon):") + meminfo("Inactive(anon):") - meminfo("AnonPages:") - meminfo("Shmem:") - meminfo("SwapCached:");
}

static uint64_t word(size_t i, int pinned) {
  size_t page = i / (PAGE / 8), at = i % (PAGE / 8);
  if (at == 0)
    return pinned ? ~HOG_MAGIC : HOG_MAGIC;
  if (at == 1)
    return page;
  return (i * 0x9e3779b97f4a7c15ULL) ^ 0x5bd1e995;
}

static void wake(int s) {
  (void)s;
}

static pid_t child(int pinned, int ready) {
  pid_t p = fork();
  if (p)
    return p;
  signal(SIGUSR2, wake);
  sigset_t usr2, old;
  sigemptyset(&usr2);
  sigaddset(&usr2, SIGUSR2);
  sigprocmask(SIG_BLOCK, &usr2, &old);
  size_t len = pinned ? PINNED : HOG;
  uint64_t *m = mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (m == MAP_FAILED)
    _exit(2);
  for (size_t i = 0; i < len / 8; i++)
    m[i] = word(i, pinned);
  int ring = -1;
  if (pinned) {
    struct io_uring_params pr;
    memset(&pr, 0, sizeof pr);
    ring = syscall(__NR_io_uring_setup, 8, &pr);
    if (ring < 0)
      _exit(3);
    struct iovec v = { m, len };
    if (syscall(__NR_io_uring_register, ring, IORING_REGISTER_BUFFERS, &v, 1))
      _exit(4);
  }
  if (write(ready, "x", 1) != 1)
    _exit(5);
  sigsuspend(&old);
  for (size_t i = 0; i < len / 8; i++)
    if (m[i] != word(i, pinned))
      _exit(6);
  if (pinned && (syscall(__NR_io_uring_register, ring, IORING_UNREGISTER_BUFFERS, 0, 0) || close(ring)))
    _exit(7);
  _exit(0);
}

static long long marked(int fd) {
  loff_t n = 0;
  if (ioctl(fd, SNAPSHOT_INPLACE, &n))
    fail("SNAPSHOT_INPLACE failed");
  return n;
}

static long long hog_pages_in_image(int fd) {
  static uint64_t page[PAGE / 8];
  long long found = 0;
  for (;;) {
    ssize_t r = read(fd, page, PAGE);
    if (r == 0)
      return found;
    if (r != PAGE)
      fail("reading the image failed");
    if (page[0] != HOG_MAGIC || page[1] >= HOG / PAGE)
      continue;
    size_t i = page[1] * (PAGE / 8);
    int same = 1;
    for (int j = 2; j < PAGE / 8 && same; j++)
      same = page[j] == word(i + j, 0);
    found += same;
  }
}

int main(int argc, char **argv) {
  int image = argc > 1 && !strcmp(argv[1], "--image");
  int fd = open("/dev/snapshot", O_RDONLY);
  if (fd < 0)
    fail("open /dev/snapshot");
  loff_t n = 0;
  if (ioctl(fd, SNAPSHOT_INPLACE, &n) == 0 || errno != EPERM)
    fail("SNAPSHOT_INPLACE before SNAPSHOT_FREEZE is not EPERM (is kernel/patches/0004 in?)");
  if (ioctl(fd, SNAPSHOT_FREEZE))
    fail("SNAPSHOT_FREEZE");
  long long base = marked(fd);
  ioctl(fd, SNAPSHOT_UNFREEZE);
  long long loose0 = unmapped_anon();

  int pp[2];
  if (pipe(pp))
    fail("pipe");
  pid_t hog = child(0, pp[1]), pin = child(1, pp[1]);
  char c;
  if (read(pp[0], &c, 1) != 1 || read(pp[0], &c, 1) != 1)
    fail("children did not start");
  if (ioctl(fd, SNAPSHOT_FREEZE))
    fail("SNAPSHOT_FREEZE");
  long long first = marked(fd), again = marked(fd), found = -1;
  if (image) {
    int in_suspend = 0;
    if (ioctl(fd, SNAPSHOT_CREATE_IMAGE, &in_suspend) || !in_suspend)
      fail("SNAPSHOT_CREATE_IMAGE failed");
    found = hog_pages_in_image(fd);
    ioctl(fd, SNAPSHOT_FREE);
  }
  ioctl(fd, SNAPSHOT_UNFREEZE);
  close(fd);
  long long grew = first - base;
  printf("in place: %lld MiB before, %lld MiB with a %lld MiB process and %lld MiB pinned by io_uring", base / MIB, first / MIB, HOG / MIB, PINNED / MIB);
  if (image)
    printf(", %lld of its %lld pages in the image", found, HOG / PAGE);
  printf("\n");
  if (again != first)
    fail("marking twice gives a different answer");
  if (grew < HOG - 16 * MIB)
    fail("a frozen process's memory is not read in place");
  if (grew > HOG + PINNED / 2)
    fail("io_uring's pinned buffers are read in place");
  if (image && found != HOG / PAGE)
    fail("the image does not hold the frozen process's memory as it is");

  kill(hog, SIGUSR2);
  kill(pin, SIGUSR2);
  int st;
  for (int i = 0; i < 2; i++)
    if (wait(&st) < 0 || !WIFEXITED(st) || WEXITSTATUS(st))
      fail("memory changed across the freeze");
  if (unmapped_anon() > loose0 + HOG / 2)
    fail("pages leaked: the references were not dropped");
  printf("SNAPSHOT_INPLACE: ok\n");
  return 0;
}
INPLACE
gcc -O2 -o "$inplace/check" "$inplace/check.c"
"$inplace/check" $([[ $target == firecracker ]] && echo --image)
rm -rf "$inplace"

systemctl start docker
docker buildx version
uv --version
[[ $(sudo -u ubuntu -H mise settings get ruby.compile) == false ]]
for v in 22 24; do
  [[ $(FNM_DIR=/usr/local/fnm /usr/local/fnm/fnm exec --using "$v" node -p 'process.versions.node.split(".")[0]') == "$v" ]] || { echo "no node $v" >&2; exit 1; }
done
[[ $(cd / && bun -e 'console.log(6 * 7)') == 42 ]] || { echo "bun does not run" >&2; exit 1; }
uvtmp=$(mktemp -d)
UV_CACHE_DIR=$uvtmp uv run -q --no-project --python /usr/bin/python3 --with six python3 -c 'import six'
rm -rf "$uvtmp"
echo "node 22 24, bun, uv: ok"

[[ $(docker info -f '{{.Driver}}') == overlay* ]] || { echo "docker is not on overlayfs" >&2; exit 1; }
busybox=public.ecr.aws/docker/library/busybox:latest
docker pull -q "$busybox" > /dev/null
[[ $(docker run --rm --memory 64m "$busybox" cat /sys/fs/cgroup/memory.max) == 67108864 ]] || { echo "no memory cgroup limit" >&2; exit 1; }
docker run --rm "$busybox" wget -q -T 20 -O /dev/null http://checkip.amazonaws.com
docker run -d --name smoke-web -p 18080:80 "$busybox" sh -c 'echo smoke > /www && httpd -f -p 80 -h /' > /dev/null
ip=$(ip -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
ok=0
for _ in $(seq 20); do
  [[ $(curl -fsS -m 2 "http://$ip:18080/www" 2>/dev/null) == smoke ]] && { ok=1; break; }
  sleep 0.5
done
docker rm -f smoke-web > /dev/null
((ok)) || { echo "published port on $ip does not answer" >&2; exit 1; }
printf 'FROM %s\nRUN wget -q -T 20 -O /dev/null http://checkip.amazonaws.com && echo built > /built\n' "$busybox" |
  docker buildx build -q --load -t smoke-build - > /dev/null
[[ $(docker run --rm smoke-build cat /built) == built ]] || { echo "buildx build failed" >&2; exit 1; }
echo "docker overlayfs, memory cgroup, bridge egress, published port, buildx: ok"

# name, image, readiness command run inside the container
checks=(
  "mongo|public.ecr.aws/docker/library/mongo:8|mongosh --quiet --eval 'quit(db.runCommand({ping: 1}).ok ? 0 : 1)'"
  "postgres|public.ecr.aws/docker/library/postgres:17|pg_isready -U postgres"
  "redis|public.ecr.aws/docker/library/redis:7|redis-cli ping"
)
failed=0
for check in "${checks[@]}"; do
  IFS='|' read -r name image ready <<< "$check"
  docker pull -q "$image" > /dev/null
  docker run -d --name "smoke-$name" -e POSTGRES_PASSWORD=smoke "$image" > /dev/null
  ok=0
  for _ in $(seq 60); do
    [[ $(docker inspect -f '{{.State.Running}}' "smoke-$name") == true ]] || break
    if docker exec "smoke-$name" sh -c "$ready" > /dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  if ((ok)); then
    echo "$name: ready"
  else
    echo "$name: did not start" >&2
    docker logs --tail 50 "smoke-$name" >&2 || true
    failed=1
  fi
  docker rm -f "smoke-$name" > /dev/null
done

docker system prune -af --volumes > /dev/null
docker buildx prune -af > /dev/null
exit "$failed"

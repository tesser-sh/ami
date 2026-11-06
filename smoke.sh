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
fi
echo "kernel $(uname -r) $(uname -v)"
[[ $(cat /sys/block/zram0/comp_algorithm) == *"[zstd]"* ]] || { echo "zram is not on zstd" >&2; exit 1; }

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

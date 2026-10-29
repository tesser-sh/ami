#!/bin/bash
# Runs as root after the build instance reboots into the image's kernel: the
# containers boxes run most must start on it, or the build fails. Every image
# pulled here is deleted again.
set -euo pipefail

kernels=(/boot/vmlinuz-*)
[[ ${kernels[*]} == "/boot/vmlinuz-$(uname -r)" ]] || { echo "booted $(uname -r), image has ${kernels[*]}" >&2; exit 1; }
echo "kernel $(uname -r)"

systemctl start docker
docker buildx version

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
exit "$failed"

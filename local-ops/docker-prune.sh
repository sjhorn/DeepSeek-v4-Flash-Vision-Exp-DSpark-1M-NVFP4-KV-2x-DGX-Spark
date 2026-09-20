#!/usr/bin/env bash
# Tier 1+2 docker prune: stopped containers, build cache, dangling images, and every
# tagged image EXCEPT repo vllm-dspark-runtime (keeps dspark-nvfp4-stage-c + mia-raf-pr1*).
# Dry-run by default; pass --delete to act.
set -uo pipefail
DELETE=0; [ "${1:-}" = "--delete" ] && DELETE=1
KEEP_REPO="vllm-dspark-runtime"
run() { if [ "$DELETE" = 1 ]; then "$@"; else echo "    (dry-run) $*"; fi; }

echo "=== $(hostname) BEFORE ==="; docker system df 2>/dev/null | sed 's/^/  /'

echo "=== stopped containers ==="
docker ps -a --filter status=exited --filter status=created --format "  {{.Names}} ({{.Image}}, {{.Status}})" 2>/dev/null
run docker container prune -f >/dev/null 2>&1

echo "=== images to remove (keeping repo $KEEP_REPO) ==="
docker images --format "{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}" 2>/dev/null | while IFS='|' read -r id name size; do
  case "$name" in "$KEEP_REPO"*) echo "  KEEP   $size  $name"; continue;; esac
  case "$name" in "<none>:<none>") continue;; esac
  echo "  remove $size  $name"
  [ "$DELETE" = 1 ] && docker rmi -f "$id" >/dev/null 2>&1
done

echo "=== dangling images + build cache ==="
run docker image prune -f >/dev/null 2>&1
run docker builder prune -af >/dev/null 2>&1

echo "=== $(hostname) AFTER ==="; docker system df 2>/dev/null | sed 's/^/  /'
df -h / | tail -1 | awk '{print "  disk: "$3" used, "$4" free ("$5")"}'

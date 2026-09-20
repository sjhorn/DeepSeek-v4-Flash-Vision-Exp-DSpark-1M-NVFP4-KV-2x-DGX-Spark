#!/usr/bin/env bash
# Deploy the bind-mounted Anthropic serving patch + docker-compose.dspark.yml
# to the head, then restart the cluster. Use for ANY change to
# patches/anthropic_serving_inline_system.py (Patches 8-13 all live in it).
#
# Follows CLAUDE.md's manual restart checklist exactly: the watchdog fires
# after 3 failed polls (~180s) while a cold boot takes 250-600s, so a running
# watchdog tears the cluster down mid-boot. It must be stopped FIRST, with the
# bracket-class pattern -- the plain pattern matches this script's own SSH.
#
#   bash local-ops/deploy-serving-patch.sh            # dry run: show what would change
#   bash local-ops/deploy-serving-patch.sh --apply    # copy, restart, verify
#
# One restart. Interrupts every session on the cluster, so pick the window.
set -uo pipefail
HEAD=shorn@spark-45ea
REPO_REMOTE=/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== files that would be copied to the head"
for f in patches/anthropic_serving_inline_system.py docker-compose.dspark.yml; do
  L=$(md5 -q "$REPO/$f")
  R=$(ssh "$HEAD" "md5sum $REPO_REMOTE/$f | cut -d' ' -f1")
  [ "$L" = "$R" ] && echo "  same     $f" || echo "  DIFFERS  $f  (local $L / head $R)"
done

if [ "$APPLY" != "1" ]; then
  echo
  echo "dry run. Re-run with --apply to copy and restart."
  exit 0
fi

echo "=== copying"
scp "$REPO/patches/anthropic_serving_inline_system.py" "$HEAD:$REPO_REMOTE/patches/"
scp "$REPO/docker-compose.dspark.yml" "$HEAD:$REPO_REMOTE/"
# The start script syncs patches/*.py and the compose to the worker itself.

echo "=== stopping watchdog, then the cluster (CLAUDE.md restart checklist)"
ssh "$HEAD" "pkill -f '[w]atchdog-dspark.sh'; cd $REPO_REMOTE && ./stop-deepseek-v4-flash-dspark.sh"

echo "=== starting detached, with bootmon for loop detection"
ssh "$HEAD" "cd $REPO_REMOTE && setsid nohup ./start-deepseek-v4-flash-dspark.sh > /tmp/start.log 2>&1 < /dev/null & \
             setsid nohup ./local-ops/bootmon.sh > /dev/null 2>&1 < /dev/null &"

echo "=== waiting for HTTP 200 on /v1/models (cold boot is 250-600s)"
for i in $(seq 1 120); do
  if ssh "$HEAD" "curl -fsS --max-time 5 http://127.0.0.1:8888/v1/models >/dev/null 2>&1"; then
    echo "  up after ~$((i*10))s"; break
  fi
  sleep 10
done

echo "=== verification"
C=$(ssh "$HEAD" "docker ps --format '{{.Names}}' | grep vllm-dspark | head -1")
echo "container: $C"
ssh "$HEAD" "cd $REPO_REMOTE && ./scripts/check-patch4.sh $C" || echo "  (check-patch4 reported a problem)"
ssh "$HEAD" "docker logs $C 2>&1 | grep -c PREFIX_WATCH" | \
  xargs -I{} echo "PREFIX_WATCH lines emitted so far: {}"
echo "--- serving-patch flags as the container sees them"
ssh "$HEAD" "docker exec $C sh -c 'env | grep -E \"STICKY_TOOLS|PREFIX_WATCH|STRIP_LEAKED_COT|CLASSIFIER_NOTHINK\"' | sort"
ssh "$HEAD" "docker logs $C 2>&1 | grep 'non-default args' | tail -1"

echo "=== restart the watchdog LAST, only after the API answers"
ssh "$HEAD" "cd $REPO_REMOTE && setsid ./watchdog-dspark.sh >> watchdog.log 2>&1 < /dev/null & sleep 1; pgrep -f '[w]atchdog-dspark.sh'"
echo "done"

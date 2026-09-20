#!/usr/bin/env bash
# kv-mech-tests.sh — stage the patched KV files into a container and run
# kv-mech-tests.py against the real vLLM classes. Touches /tmp only; never the
# node's repo checkout, and never the running engine's imported modules.
#
#   HOST=spark-45ea bash local-ops/kv-mech-tests.sh
set -euo pipefail
HOST="${HOST:-spark-45ea}"
USER_AT="${USER_AT:-shorn}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="${CONTAINER:-$(ssh "${USER_AT}@${HOST}" "docker ps --format '{{.Names}}' | grep vllm-dspark | head -1")}"
[ -n "$CONTAINER" ] || { echo "no vllm container on $HOST" >&2; exit 1; }

ssh "${USER_AT}@${HOST}" "mkdir -p /tmp/kvtest"
for f in patch6-single_type_kv_cache_manager.py patch7-block_pool-dedupe.py patch8-kv_cache_utils.py; do
  ssh "${USER_AT}@${HOST}" "cat > /tmp/kvtest/$f" < "$ROOT/patches/$f"
done
ssh "${USER_AT}@${HOST}" "cat > /tmp/kvtest/kv-mech-tests.py" < "$ROOT/local-ops/kv-mech-tests.py"
ssh "${USER_AT}@${HOST}" "docker cp /tmp/kvtest ${CONTAINER}:/tmp/ >/dev/null && docker exec ${CONTAINER} python3 /tmp/kvtest/kv-mech-tests.py"

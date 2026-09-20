#!/usr/bin/env bash
# Apply the ds4-prefix-cache-fixes patch chain to a base image and commit
# the result as a new tag. Runs against the LOCAL docker daemon — no ssh,
# no cluster coupling. Safe to run alongside a live server: the throwaway
# container is created without --gpus, so it allocates no GPU memory.
#
# The chain (patches/01..04, in order) takes the plain
#   aidendle94/sparkrun-vllm-ds4-gb10:production-3.7
# image to the dedupe+boundfix state used in the retention benchmarks.
#
# Usage:
#   ./image/apply-patches.sh [BASE_TAG] [NEW_TAG]
#   BASE_TAG default: aidendle94/sparkrun-vllm-ds4-gb10:production-3.7
#   NEW_TAG  default: aidendle94/sparkrun-vllm-ds4-gb10:production-3.7-reffix-schedfix-dedupe-boundfix
#
# Multi-node: the patched tag only exists on THIS host afterwards —
#   docker save "$NEW" | ssh <other-node> docker load
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-aidendle94/sparkrun-vllm-ds4-gb10:production-3.7}"
NEW="${2:-aidendle94/sparkrun-vllm-ds4-gb10:production-3.7-reffix-schedfix-dedupe-boundfix}"
VLLM=/opt/venv/lib/python3.12/site-packages/vllm
CTN=ds4patchbuild

echo "[ds4-patch] base=$BASE new=$NEW"

# 1. Throwaway container (no --gpus -> no GPU alloc, safe alongside a live server)
docker rm -f "$CTN" >/dev/null 2>&1 || true
docker run -d --name "$CTN" --entrypoint sleep "$BASE" infinity >/dev/null

cleanup() { docker rm -f "$CTN" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 2. Copy the patch scripts in
for p in 01-reffix 02-schedfix 03-dedupe 04-boundfix; do
  docker cp "$SCRIPT_DIR/patches/$p.py" "$CTN:/tmp/$p.py"
done

# 3. Apply the chain in order (each patch is idempotent, asserts its anchors)
for p in 01-reffix 02-schedfix 03-dedupe 04-boundfix; do
  echo "[ds4-patch] applying $p"
  docker exec "$CTN" env VLLM_PYTHON_DIR="$VLLM" python3 "/tmp/$p.py"
done

# 4. Validate: the patched modules import cleanly
docker exec "$CTN" python3 -c '
import vllm.v1.core.block_pool
import vllm.v1.core.single_type_kv_cache_manager
import vllm.v1.core.kv_cache_coordinator
import vllm.v1.core.sched.scheduler
import vllm.tokenizers.deepseek_v4_encoding
print("[ds4-patch] import OK")
'

# 5. Commit the patched tree as a new tag
docker commit "$CTN" "$NEW" >/dev/null
echo "[ds4-patch] done: $NEW"
echo "[ds4-patch] multi-node: docker save '$NEW' | ssh <other-node> docker load"

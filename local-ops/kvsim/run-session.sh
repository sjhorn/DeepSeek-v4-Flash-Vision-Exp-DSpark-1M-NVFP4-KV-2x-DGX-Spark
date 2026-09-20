#!/usr/bin/env bash
# sim-session.py in a throwaway container. `run-session.sh patch6` mounts Patch 6.
set -uo pipefail
HEAD_HOST="${HEAD_HOST:-shorn@spark-45ea}"
IMG="${IMG:-vllm-dspark-runtime:dspark-nvfp4-stage-c}"
REPO="${REMOTE_REPO:-/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}"
SITE=/opt/env/lib/python3.12/site-packages/vllm/v1/core
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M=""
[ "${1:-}" = "patch6" ] && M="-v $REPO/patches/patch6-single_type_kv_cache_manager.py:$SITE/single_type_kv_cache_manager.py:ro"
ssh "$HEAD_HOST" "docker run --rm -i $M -e VLLM_SWA_RECYCLE_SKIPPED_BLOCKS=${RECYCLE:-1} -e VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION=${FRACTION:-0.50} --entrypoint python3 $IMG -u -" \
  < "$HERE/sim-session.py" 2>&1 | grep -v "Triton\|cpp_extension\|importing.py"

#!/usr/bin/env bash
# Run local-ops/kvsim/sim.py in a throwaway container from the serving image.
#
#   local-ops/kvsim/run.sh                 # stock image file (control)
#   local-ops/kvsim/run.sh patch6          # with patches/patch6-... bind-mounted
#   RECYCLE=0 local-ops/kvsim/run.sh patch6
#   FRACTION=0.30 local-ops/kvsim/run.sh patch6
#
# No GPU, no engine, no weights; --rm and :ro. It cannot disturb the cluster.
set -uo pipefail
HEAD="${HEAD:-shorn@spark-45ea}"
IMG="${IMG:-vllm-dspark-runtime:dspark-nvfp4-stage-c}"
REPO="${REMOTE_REPO:-/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}"
SITE=/opt/env/lib/python3.12/site-packages/vllm/v1/core
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOUNT=("")
[ "${1:-}" = "patch6" ] && MOUNT=(-v "$REPO/patches/patch6-single_type_kv_cache_manager.py:$SITE/single_type_kv_cache_manager.py:ro")

ENVS=(-e "VLLM_SWA_RECYCLE_SKIPPED_BLOCKS=${RECYCLE:-1}"
      -e "VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION=${FRACTION:-0.50}")
[ -n "${SIM_N:-}" ]         && ENVS+=(-e "SIM_N=$SIM_N")
[ -n "${SIM_USE_EAGLE:-}" ] && ENVS+=(-e "SIM_USE_EAGLE=$SIM_USE_EAGLE")

ssh "$HEAD" "docker run --rm -i ${MOUNT[*]} ${ENVS[*]} --entrypoint python3 $IMG -u -" \
  < "$HERE/sim.py" 2>&1 | grep -v "Triton\|cpp_extension\|importing.py\|\.\.\. D="

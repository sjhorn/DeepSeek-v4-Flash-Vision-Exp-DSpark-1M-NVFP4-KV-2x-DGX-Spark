#!/bin/bash
# Phase 2 watcher: capture the raw malformed tool arguments when they recur.
#
#   setsid nohup local-ops/patch10-watch.sh > /dev/null 2>&1 < /dev/null &
#
# Follows the container log for Patch 10 warnings and appends each hit, with a
# timestamp, to local-ops/patch10-hits.log. The `model=` field in the hit is the
# discriminator: thinking-enabled aliases only => reasoning is leaking into
# tool arguments; -nothink present too => the deepseek_v4 tool parser.
REPO="${REPO:-/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}"
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
OUT="$REPO/local-ops/patch10-hits.log"
echo "# watcher started $(date -Is)" >> "$OUT"
docker logs -f --since 1m "$C" 2>&1 \
  | grep --line-buffered -E "PATCH10 malformed tool arguments|Error in create_messages" \
  | while IFS= read -r line; do
      printf '%s  %s\n' "$(date -Is)" "$line" >> "$OUT"
    done

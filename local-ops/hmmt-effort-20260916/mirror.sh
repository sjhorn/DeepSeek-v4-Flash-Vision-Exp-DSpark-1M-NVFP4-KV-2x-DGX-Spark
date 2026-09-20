#!/bin/bash
# Mirror the detached HMMT eval out of /tmp (reboot-volatile) into the repo.
D=/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/local-ops/hmmt-effort-20260916
while true; do
  cp -f /tmp/hmmt_eval24.log  "$D/" 2>/dev/null
  cp -f /tmp/hmmt_eval24.json "$D/" 2>/dev/null
  if ! pgrep -f "python3 /tmp/hmmt_eval24.py" > /dev/null; then
    sleep 3
    cp -f /tmp/hmmt_eval24.log "$D/" 2>/dev/null
    cp -f /tmp/hmmt_eval24.json "$D/" 2>/dev/null
    echo "eval finished at $(date -Is), final copy done" >> "$D/mirror.log"
    exit 0
  fi
  sleep 60
done

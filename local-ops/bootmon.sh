#!/bin/bash
# Boot-loop monitor for a cluster restart. Run it detached, right after
# ./start-deepseek-v4-flash-dspark.sh:
#
#   setsid nohup local-ops/bootmon.sh > /dev/null 2>&1 < /dev/null &
#
# A startup loop shows up as one of three things, all sampled here:
#   1. RestartCount climbing on either node (docker restarting a dying container)
#   2. the container's StartedAt resetting (something recreated it -- e.g. the
#      watchdog firing at ~180s into a 250-600s boot; stop it before restarting)
#   3. the log phase going backwards to "Loading weights" after passing it
#
# Exits on the first HTTP 200 from /v1/models, or after ~25 minutes.
# Writes a TSV to local-ops/bootmon/ and a one-line verdict at the end.
set -u
REPO="${REPO:-/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}"
WORKER="${WORKER:-192.168.0.101}"
API="${API:-http://127.0.0.1:8888/v1/models}"
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
D="$REPO/local-ops/bootmon"; mkdir -p "$D"
OUT="$D/boot-$(date +%Y%m%d-%H%M%S).tsv"

printf 'ts\thead_restarts\thead_started\twrk_restarts\tapi\tphase\tflag\n' > "$OUT"
prev_phase=""; prev_restarts=""; prev_started=""; flags=0

for _ in $(seq 1 100); do
  hr=$(docker inspect -f '{{.RestartCount}}' "$C" 2>/dev/null | tr -d '\n'); hr=${hr:-NA}
  hs=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null | cut -c12-19 | tr -d '\n'); hs=${hs:-NA}
  wr=$(ssh -o ConnectTimeout=5 "$WORKER" "docker inspect -f '{{.RestartCount}}' $C" 2>/dev/null | tr -d '\n'); wr=${wr:-NA}
  # %{http_code} alone: curl prints 000 on failure, so no shell fallback is
  # needed -- appending one produced the "000down" artefact in the first run.
  api=$(curl -fsS -o /dev/null -w '%{http_code}' -m 5 "$API" 2>/dev/null)
  [ -z "$api" ] && api=000
  # Underscores keep the phase in ONE column so `column -t` stays aligned.
  phase=$(docker logs --tail 80 "$C" 2>&1 | grep -oE \
      "Loading weights took|Model loading took|torch.compile took|Initial profiling|Profiling CUDA graph|Capturing CUDA graph|GPU KV cache size|Application startup complete" \
      | tail -1 | tr ' ' '_')
  [ -z "$phase" ] && phase="(none)"

  flag=""
  [ -n "$prev_restarts" ] && [ "$prev_restarts" != NA ] && [ "$hr" != NA ] && \
    [ "$hr" != "$prev_restarts" ] && flag="RESTART_COUNT"
  [ -n "$prev_started" ] && [ "$prev_started" != NA ] && [ "$hs" != NA ] && \
    [ "$hs" != "$prev_started" ] && flag="${flag:+$flag,}CONTAINER_RECREATED"
  [ "$phase" = "Loading_weights_took" ] && [ -n "$prev_phase" ] && \
    [ "$prev_phase" != "Loading_weights_took" ] && [ "$prev_phase" != "(none)" ] && \
    flag="${flag:+$flag,}PHASE_RESTARTED"
  [ -n "$flag" ] && flags=$((flags + 1))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%H:%M:%S)" "$hr" "$hs" "$wr" "$api" "$phase" "$flag" >> "$OUT"
  prev_phase="$phase"; prev_restarts="$hr"; prev_started="$hs"

  if [ "$api" = 200 ]; then
    printf '# API up at %s after %s samples; loop flags: %s\n' \
      "$(date +%H:%M:%S)" "$(( $(wc -l < "$OUT") - 1 ))" "$flags" >> "$OUT"
    exit 0
  fi
  sleep 15
done
printf '# TIMED OUT without a 200; loop flags: %s\n' "$flags" >> "$OUT"
exit 1

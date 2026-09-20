#!/usr/bin/env bash
# Abort the KV pressure test at the FIRST sign of GPU/host memory exhaustion,
# before the box wedges. Trips on: NVRM NV_ERR_NO_MEMORY, kernel OOM-kill,
# low host available memory, or KV cache above a hard ceiling.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${OOMGUARD_LOG:-$HERE/oomguard.log}"
ABORT=/tmp/ABORT_TEST
MIN_AVAIL_GB=${MIN_AVAIL_GB:-12}
KV_CEILING=${KV_CEILING:-95}
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
rm -f $ABORT
: > $LOG
base=$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c "NV_ERR_NO_MEMORY")
echo "[$(date +%H:%M:%S)] guard armed: NVRM baseline=$base, min_avail=${MIN_AVAIL_GB}G, kv_ceiling=${KV_CEILING}%" | tee -a $LOG

trip() {
  echo "[$(date +%H:%M:%S)] *** TRIPPED: $1 ***" | tee -a $LOG
  touch $ABORT
  pkill -f kvpressure.py 2>/dev/null
  # drop the load immediately so the engine can recover
  pkill -f "curl .*v1/chat/completions" 2>/dev/null
  echo "[$(date +%H:%M:%S)] test killed; load dropped" | tee -a $LOG
  exit 1
}

while true; do
  now=$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c "NV_ERR_NO_MEMORY")
  [ "$now" -gt "$base" ] && trip "NVRM NV_ERR_NO_MEMORY (count $base -> $now)"
  journalctl -k -b 0 --since "-30s" --no-pager 2>/dev/null | grep -qiE "oom-kill|Out of memory: Killed" && trip "kernel OOM-killer fired"
  avail=$(free -g | awk '/^Mem:/{print $7}')
  [ "${avail:-99}" -lt "$MIN_AVAIL_GB" ] && trip "host available memory ${avail}G < ${MIN_AVAIL_GB}G"
  wavail=$(ssh -o ConnectTimeout=5 192.168.0.101 "free -g | awk '/^Mem:/{print \$7}'" 2>/dev/null)
  [ -n "$wavail" ] && [ "$wavail" -lt "$MIN_AVAIL_GB" ] && trip "WORKER available memory ${wavail}G < ${MIN_AVAIL_GB}G"
  kv=$(docker logs --tail 25 $C 2>&1 | grep -oE "GPU KV cache usage: [0-9.]+%" | tail -1 | grep -oE "[0-9.]+")
  if [ -n "$kv" ]; then
    over=$(awk -v a="$kv" -v b="$KV_CEILING" 'BEGIN{print (a>b)?1:0}')
    [ "$over" = "1" ] && trip "KV cache ${kv}% > ${KV_CEILING}%"
  fi
  echo "[$(date +%H:%M:%S)] ok: nvrm=$now avail=${avail}G worker=${wavail}G kv=${kv:-n/a}%" >> $LOG
  sleep 3
done

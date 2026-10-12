#!/usr/bin/env bash
# MEASURE WHETHER THE START SCRIPT'S CACHE RECLAIM IS WHAT MAKES THE BOOT WALK
# SLOW. Runs ON THE HEAD. One boot per run.
#
# WHY NOT JUST `DROP_CACHES_ON_START=0`. That was the obvious test and it
# conflates two things the reclaim does in one window:
#
#   * during the WEIGHT LOAD it frees page cache for ~400 GB of safetensors,
#     which is why it was added -- MemAvailable sits at ~1.4% on this box and
#     earlyoom's real gate is SWAP, so losing that headroom risks the
#     swap-thrash livelock that needs a hard reset rather than a restart;
#   * during the MANIFEST WALK it drops the dentry and inode caches every 2
#     seconds, which is exactly what 923,119 `stat` calls depend on.
#
# The reclaim loop stops only when the API answers, and the API cannot answer
# until the walk finishes, so the stock knob cannot separate them: off means
# off for the weight load too. This runs its OWN reclaim loop instead, with the
# same 2s cadence on both nodes, and stops it at the boundary -- so the weight
# load keeps the protection it was given and the walk gets a warm cache.
#
# THE BOUNDARY IS A REAL LOG LINE, not a sleep:
#
#   core.py:302  init engine (profile, create kv cache, warmup model) took N s
#
# which vLLM logs immediately before the engine core builds the connector, and
# therefore our manager, and therefore the walk. Read off the 2026-10-12 boot:
# 17:44:26 init engine, 17:51:05 manifest restored -- the walk is everything
# between.
#
# THE PREDICTION GOES IN BEFORE THE RUN, because three times today a warm
# measurement was extrapolated onto a cold boot and the boot refuted it. The
# conservative prior is NO saving: the 400 GB weight read evicts the dentry
# cache on its own, at which point the reclaim was never the binding
# constraint. See docs/engine-kv.md.
set -u

C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
WORKER=${KVBW_WORKER:-spark-da08}
OUT=${KVBW_OUT:-$HOME/kvdiag/bootwalk-$(date -u +%m%d-%H%M)}
BOUNDARY='init engine (profile, create kv cache, warmup model) took'
WALKDONE='keys restored'
RECLAIM=${KVBW_RECLAIM:-boundary}   # boundary | off | always

mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

mem(){ # one sampler line per node, the swap figure first because it is the gate
  local h=$1 f=$2
  if [ "$h" = "local" ]; then
    awk '/^SwapFree|^MemAvailable|^Cached:/{printf "%s=%s ", $1, $2}' /proc/meminfo
  else
    ssh -o BatchMode=yes "$h" "awk '/^SwapFree|^MemAvailable|^Cached:/{printf \"%s=%s \", \$1, \$2}' /proc/meminfo" 2>/dev/null
  fi
  echo
}

sample(){ # a timestamped memory line for both nodes, appended
  printf '%s head: %s' "$(date -u +%H:%M:%S)" "$(mem local)" >> "$OUT/mem.log"
  printf '%s wrkr: %s' "$(date -u +%H:%M:%S)" "$(mem "$WORKER")" >> "$OUT/mem.log"
}

say "=== kvbootwalk, reclaim mode: $RECLAIM, output $OUT"
say "baselines BEFORE the down:"
say "  head: $(mem local)"
say "  wrkr: $(mem "$WORKER")"
for h in local "$WORKER"; do
  if [ "$h" = "local" ]; then n=$(journalctl -k 2>/dev/null | grep -c Xid)
  else n=$(ssh -o BatchMode=yes "$h" 'journalctl -k 2>/dev/null | grep -c Xid'); fi
  say "  Xid total ($h): $n"
done

# --- the down, on BOTH nodes --------------------------------------------
# The start script's `up -d` is a no-op on a running container with an
# unchanged spec, so a head-only restart leaves the worker's rank-1 process
# alive and rank 0 hangs in NCCL init FOREVER -- indistinguishable from weights
# still loading. Both, always.
# BOTH compose files, because this cluster is running the Vision-Exp overlay
# and the project's service is defined across the pair. `down` identifies the
# project by directory either way, so passing the overlay when it is not in use
# is harmless -- while omitting it when it IS leaves compose reasoning about a
# service definition that does not match what is running.
CF="-f docker-compose.dspark.yml"
[ -f docker-compose.vision-exp.yml ] && CF="$CF -f docker-compose.vision-exp.yml"
say "down on both nodes ($CF)"
docker compose $CF down >>"$OUT/down.log" 2>&1 || true
ssh -o BatchMode=yes "$WORKER" "cd ~/DeepSeek*; docker compose $CF down" >>"$OUT/down.log" 2>&1 || true
for h in local "$WORKER"; do
  if [ "$h" = "local" ]; then n=$(docker ps -q | wc -l)
  else n=$(ssh -o BatchMode=yes "$h" 'docker ps -q | wc -l'); fi
  say "  containers still up on $h: $n"
  [ "$n" = "0" ] || { say "REFUSING: a container survived the down on $h. A"
    say "  head-only restart hangs rank 0 in NCCL init forever."; exit 1; }
done

# --- our own reclaim loop, if asked for ---------------------------------
RPID=""
if [ "$RECLAIM" != "off" ]; then
  if sudo -n sysctl -qw vm.drop_caches=3 2>/dev/null; then
    (
      while :; do
        sync; sudo -n sysctl -qw vm.drop_caches=3 2>/dev/null || true
        ssh -o BatchMode=yes "$WORKER" "sync; sudo -n sysctl -qw vm.drop_caches=3" >/dev/null 2>&1 || true
        sleep 2
      done
    ) & RPID=$!
    say "our reclaim loop started, pid $RPID (stops at: $RECLAIM)"
  else
    say "WARNING: no passwordless sudo for drop_caches -- reclaim NOT running, so"
    say "         this run measures a DIFFERENT thing from the baseline boots."
  fi
fi

# --- start, with the stock reclaim OFF so ours is the only one ----------
say "starting the engine (DROP_CACHES_ON_START=0; ours is the only reclaim)"
T0=$(date +%s)
DROP_CACHES_ON_START=0 ./start-deepseek-v4-flash-dspark.sh >>"$OUT/start.log" 2>&1 &
SPID=$!

# --- watch for the boundary, then stop the reclaim ----------------------
# Kill by PID, never `pkill -f`: that matches this script's own command line
# and has killed an ssh session here twice.
BOUND_AT=""
WALK_AT=""
while :; do
  sleep 2
  sample
  LOG=$(docker logs "$C" 2>&1 | tail -400 || true)
  if [ -z "$BOUND_AT" ] && printf '%s' "$LOG" | grep -qF "$BOUNDARY"; then
    BOUND_AT=$(date +%s)
    say "BOUNDARY reached at +$((BOUND_AT-T0))s -- weights are in, the walk is next"
    if [ -n "$RPID" ] && [ "$RECLAIM" = "boundary" ]; then
      kill "$RPID" 2>/dev/null && say "reclaim loop $RPID STOPPED; the walk now runs on a warm cache"
      wait "$RPID" 2>/dev/null || true
      RPID=""
    fi
    say "  head at boundary: $(mem local)"
    say "  wrkr at boundary: $(mem "$WORKER")"
  fi
  if printf '%s' "$LOG" | grep -qF "$WALKDONE"; then
    WALK_AT=$(date +%s)
    say "WALK DONE at +$((WALK_AT-T0))s"
    printf '%s' "$LOG" | grep -F "$WALKDONE" | tail -1 | tee -a "$OUT/run.log"
    break
  fi
  if [ $(( $(date +%s) - T0 )) -gt 1800 ]; then
    say "GIVING UP after 1800s -- the walk line never appeared. NOT a measurement."
    break
  fi
done

[ -n "$RPID" ] && { kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; }
say "waiting for the start script to finish (API ready)"
wait $SPID 2>/dev/null || true
T1=$(date +%s)
say "=== totals"
say "  down -> walk done : $((WALK_AT-T0))s"
[ -n "$BOUND_AT" ] && say "  the WALK itself   : $((WALK_AT-BOUND_AT))s   <-- the number this run exists for"
say "  down -> API ready : $((T1-T0))s"
say "  head after: $(mem local)"
say "  wrkr after: $(mem "$WORKER")"
say "evidence in $OUT"

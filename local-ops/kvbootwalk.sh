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

# *** THIS SCRIPT IS DESTRUCTIVE FROM ITS FIRST PHASE: IT `down`s BOTH NODES.
# *** TWO GUARDS, BECAUSE IT COST TWO BOOTS ON 2026-10-12 IN TEN MINUTES. ***
#
# Both failures were the same mistake wearing different clothes: the file was
# made to execute from a machine that is not the head, while a boot was in
# flight. Once by `source`-ing it to get at one pure function for a self-test,
# once by "just running it" to check a guard. Each time the `down` reached the
# WORKER, removed rank 1, and left rank 0 hanging in NCCL init forever -- the
# documented head-only-restart trap, arriving from a test instead of a human.
#
# GUARD 1: it must be the HEAD. This is the one that would have stopped both.
# A tool whose first act is to tear down a two-node engine has no business
# running anywhere it cannot also start one.
HEAD_HOST=${KVBW_HEAD:-spark-45ea}
if [ "$(hostname -s 2>/dev/null)" != "$HEAD_HOST" ]; then
  echo "kvbootwalk: REFUSING -- this runs ON THE HEAD ($HEAD_HOST) and this is" >&2
  echo "  $(hostname -s 2>/dev/null || echo unknown). Its FIRST phase is a" >&2
  echo "  \`down\` on BOTH nodes; from anywhere else that removes rank 1 and" >&2
  echo "  hangs rank 0 in NCCL init forever. ssh to the head and run it there." >&2
  exit 1
fi

# GUARD 2: it must not be SOURCED. `(return 0)` succeeds only in a sourced
# file, and the subshell is what keeps the `return` from quietly ending the
# file -- which the first version did, refusing SILENTLY, so the caller saw
# nothing and believed the function had loaded.
if (return 0 2>/dev/null); then
  echo "kvbootwalk: REFUSING -- do not source this, it \`down\`s both nodes." >&2
  echo "  To test a function from here, EXTRACT its definition and eval that." >&2
  return 1
fi

C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
WORKER=${KVBW_WORKER:-spark-da08}
OUT=${KVBW_OUT:-$HOME/kvdiag/bootwalk-$(date -u +%m%d-%H%M)}
BOUNDARY='init engine (profile, create kv cache, warmup model) took'
WALKDONE='keys restored'
RECLAIM=${KVBW_RECLAIM:-boundary}   # boundary | off | always

# *** THE VALUE IS THE WHOLE EXPERIMENT, which is why it is a knob now. ***
# 1 frees the PAGE CACHE, 2 frees DENTRIES AND INODES, 3 does both. The first
# run of this script used 3, matching the start script's own loop, and measured
# the walk at 182.1s against 394.4s -- 212s bought, and PAID FOR in 4.38 GB of
# the head's swap headroom, which does not come back. The arithmetic that
# explains it: 923,119 files x ~1 KB of dentry+inode is ~0.95 GB, and it FITS
# inside the 2.02 GB `Cached` measured at the boundary -- so the structure the
# walk depends on is small, survives the 400 GB weight read, and the walk
# builds it itself. Dropping it every 2 seconds was destroying what the walk
# had just read. So the configuration this argues for is DROP=1: keep
# reclaiming page cache (the swap protection, which is what the start script's
# loop is FOR) and stop dropping the dentries the walk lives on.
DROP=${KVBW_DROP:-3}                # 1 page cache | 2 dentries+inodes | 3 both
case "$DROP" in 1|2|3) ;; *)
  echo "kvbootwalk: REFUSING -- KVBW_DROP must be 1, 2 or 3 (got '$DROP')." >&2
  exit 1 ;;
esac

mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

mem(){ # one sampler line per node, the swap figure first because it is the gate
  # *** `local h=$1 f=$2` WAS THE BUG, AND `set -u` MADE IT TOTAL. *** There is
  # no second argument, so every call failed with "$2: unbound variable" -- the
  # baselines printed EMPTY and mem.log stayed at zero lines, which is this
  # repo's own "an unreadable log must report absence, not write an empty file"
  # trap arriving as a shell slip. The boot itself was unaffected (the boundary
  # and walk timing do not call this), and the swap half of the first run was
  # recovered by an external sampler, because NEVER EDIT A SHELL SCRIPT THAT IS
  # EXECUTING: bash reads lazily by byte offset and an insert ends the run at a
  # premature EOF with exit 0.
  local h=$1
  if [ "$h" = "local" ]; then
    awk '/^SwapFree|^MemAvailable|^Cached:/{printf "%s=%s ", $1, $2}' /proc/meminfo
  else
    ssh -o BatchMode=yes "$h" "awk '/^SwapFree|^MemAvailable|^Cached:/{printf \"%s=%s \", \$1, \$2}' /proc/meminfo" 2>/dev/null
  fi
  echo
}

memck(){ # mem() or a named absence -- a blank reading must not read as 0
  local v
  v=$(mem "$1")
  case "$v" in
    *SwapFree*) printf '%s' "$v" ;;
    *) printf 'UNREADABLE (no SwapFree line from %s)' "$1" ;;
  esac
}

sample(){ # a timestamped memory line for both nodes, appended
  # The `\n` is not cosmetic: without it every sample lands on ONE line, so
  # `wc -l` reports 0 and the file reads as empty while holding the whole run.
  # `mem()` ends without a newline by design, so the newline belongs here.
  printf '%s head: %s\n' "$(date -u +%H:%M:%S)" "$(mem local)" >> "$OUT/mem.log"
  printf '%s wrkr: %s\n' "$(date -u +%H:%M:%S)" "$(mem "$WORKER")" >> "$OUT/mem.log"
}

say "=== kvbootwalk, reclaim mode: $RECLAIM, output $OUT"
say "baselines BEFORE the down:"
say "  head: $(memck local)"
say "  wrkr: $(memck "$WORKER")"
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
# *** `wc -l` PADS ITS OUTPUT, so `[ "$n" = "0" ]` compared against a string
# *** of spaces and a zero, and the guard refused on a perfectly clean down.
# `$(( ))` forces the arithmetic comparison this always wanted.
for h in local "$WORKER"; do
  if [ "$h" = "local" ]; then n=$(docker ps -q | wc -l)
  else n=$(ssh -o BatchMode=yes "$h" 'docker ps -q | wc -l'); fi
  n=$(( n + 0 ))
  say "  containers still up on $h: $n"
  [ "$n" -eq 0 ] || { say "REFUSING: a container survived the down on $h. A"
    say "  head-only restart hangs rank 0 in NCCL init forever."; exit 1; }
done

# --- our own reclaim loop, if asked for ---------------------------------
RPID=""
if [ "$RECLAIM" != "off" ]; then
  if sudo -n sysctl -qw vm.drop_caches=$DROP 2>/dev/null; then
    (
      while :; do
        sync; sudo -n sysctl -qw vm.drop_caches=$DROP 2>/dev/null || true
        ssh -o BatchMode=yes "$WORKER" "sync; sudo -n sysctl -qw vm.drop_caches=${DROP}" >/dev/null 2>&1 || true
        sleep 2
      done
    ) & RPID=$!
    say "our reclaim loop started, pid $RPID (drop_caches=$DROP, stops at: $RECLAIM)"
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
    say "  head at boundary: $(memck local)"
    say "  wrkr at boundary: $(memck "$WORKER")"
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
say "  head after: $(memck local)"
say "  wrkr after: $(memck "$WORKER")"
say "evidence in $OUT"

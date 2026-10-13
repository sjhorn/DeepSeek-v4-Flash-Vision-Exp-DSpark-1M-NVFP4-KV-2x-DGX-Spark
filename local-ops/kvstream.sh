#!/usr/bin/env bash
# Keep rare engine-side evidence across a restart. Two streams.
#
# *** `docker logs` DIES WITH THE CONTAINER. *** Both crashes on 2026-10-09 had
# their Python context captured only because somebody happened to be watching:
# the kernel's Xid lines persist in journalctl, the traceback does not. And the
# numpy-scalar producer has fired three times in a day, each time in a window
# nobody was tailing. So: stream to a file, append across boots, never query
# after the fact.
#
#   STREAM=faults   bash kvstream.sh start     # deaths, stalls, GPU faults
#   STREAM=producer bash kvstream.sh start     # the numpy-scalar producer
#   STREAM=faults   bash kvstream.sh status|stop
#
# *** THE PROCESS TAG MUST APPEAR NOWHERE IN THIS FILE'S NAME OR ARGUMENTS. ***
# A first version used `pgrep -f "[p]roducer-stream"`, which matched
# "kvproducer-stream.sh" itself -- the check found its own invocation, said
# "already streaming" and started nothing. A second version built the pattern
# with `${TAG#k}` and produced "[k]vmgr-vmgr-fault-tap", a pattern that can
# never match: it reported "FAILED to start" while both processes were running,
# and left the idempotence guard unable to see a duplicate. Both were checks
# that lied. The tag is a literal now, and `status` reports the FILE as well as
# the process, because one fact beside another is the only thing that caught
# either bug.
set -u

C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
STREAM=${STREAM:-producer}

case "$STREAM" in
producer)
  TAG=kvtap-numpy
  OUT=${OUT:-$HOME/kvdiag/producer}
  # Narrow on purpose: these four lines are the producer hunt and nothing else.
  PAT='numpy scalar PRODUCER|coerced a numpy scalar|producer scan EXHAUSTED|producer walk raised'
  DROP=''
  ;;
faults)
  TAG=kvtap-faults
  OUT=${OUT:-$HOME/kvdiag/faults}
  # *** ANCHORED ON SEVERITY, not on keywords. *** A keyword list caught a
  # routine INFO line that merely MENTIONED refused_bounds, which would have
  # buried the real thing in noise. ERROR/WARNING plus the specific fatal
  # shapes we have actually seen, and `Xid ` because the kernel prefix carries
  # no level.
  PAT='ERROR|WARNING|Xid |died unexpectedly|EngineDeadError|unspecified launch|terminate called|checkTimeout|Traceback \(most recent'
  # *** EXCLUDE BY SOURCE, NOT BY LOWERING SEVERITY. *** Anchoring on
  # ERROR/WARNING caught routine Triton JIT-compilation warnings at every boot,
  # and twenty lines of known-benign noise per restart is how the one line that
  # matters gets skipped. The fix is to name the routine SOURCE -- narrowing
  # the severity instead would have dropped the real WARNINGs (the stall
  # watchdog and the drop refusal are both WARNING).
  DROP='jit_monitor.py'
  ;;
*)
  echo "unknown STREAM=$STREAM (want producer or faults)" >&2; exit 2;;
esac

LOG="$OUT/$STREAM.log"
mkdir -p "$OUT"

running() { pgrep -f "[k]vtap-${STREAM}" >/dev/null 2>&1; }

# *** THE CLUSTER-WIDE FORMS, AND WHY THEY EXIST AT ALL. ***
#
# This script has always been correct: `running()` has the `-f` that an
# `exec -a` tag needs, the bracket pattern cannot match itself, and `status`
# prints the FILE beside the process because two earlier versions lied by
# reporting only one. None of that stopped the capture being dead through
# three restarts, and the reason is ERGONOMIC rather than a defect here:
# asking the right question properly cost FOUR ssh invocations with the right
# env var set each time, while a wrong one-liner -- `pgrep -af kvtap-` -- looks
# like a single command. So the wrong instinct was cheaper than the right tool,
# and it won repeatedly, including once by the author of the rule against it
# (that ad-hoc pattern matched its OWN command line and reported two streams
# where none were armed).
#
# `all-start` and `all-check` make the correct question the cheap one: both
# streams on both nodes in one call. **`all-check` EXITS NON-ZERO** when any of
# the four is down, so a caller can gate on it instead of reading prose -- a
# gate that prints its verdict instead of exiting on it is not a gate.
WORKER=${KVSTREAM_WORKER:-spark-da08}
REPO=${KVSTREAM_REPO:-$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}

# One node, both streams. `local` runs here; anything else goes over ssh.
_both_on() {
  local host="$1" verb="$2"
  if [ "$host" = local ]; then
    for s in faults producer; do
      echo "  [$(hostname -s) $s]"
      STREAM="$s" bash "$0" "$verb" 2>&1 | sed 's/^/  /'
    done
  else
    for s in faults producer; do
      echo "  [$host $s]"
      ssh -o BatchMode=yes "$host" \
        "cd '$REPO' && STREAM=$s bash local-ops/kvstream.sh $verb" 2>&1 | sed 's/^/  /'
    done
  fi
}

# Is EACH stream armed on one node? Answers per stream, never as a total --
# break-verification caught the total version passing with one stream dead,
# because each stream contributes TWO matches (the `bash -c` wrapper and the
# `exec -a`'d `docker logs`), so "4 processes" and "2 streams, one of them
# doubled" are indistinguishable from a count alone. A guard that cannot fail
# reads as coverage.
#
# Prints one line per stream: "<stream> <n>", with n = -1 for UNREADABLE.
# Arithmetic, and NOT `pgrep -c || echo 0`: `pgrep -c` exits 1 on an empty
# count, so that idiom yields "0\n0" and the empty case -- the one being tested
# for -- can never compare equal to 0.
_armed_on() {
  local host="$1" s n
  for s in faults producer; do
    if [ "$host" = local ]; then
      n=$(pgrep -f "[k]vtap-$s" 2>/dev/null | wc -l)
    else
      n=$(ssh -o BatchMode=yes "$host" "pgrep -f '[k]vtap-$s' 2>/dev/null | wc -l" 2>/dev/null)
    fi
    case "$n" in ''|*[!0-9[:space:]]*) echo "$s -1" ;; *) echo "$s $(( n + 0 ))" ;; esac
  done
}


case "${1:-start}" in
start)
  if running; then
    echo "  already streaming (pid $(pgrep -f "[k]vtap-${STREAM}" | tr '\n' ' '))"
  else
    if [ -n "${DROP:-}" ]; then
      nohup bash -c "exec -a kvtap-${STREAM} docker logs -f --since 0 '$C' 2>&1 \
        | grep --line-buffered -E '$PAT' \
        | grep --line-buffered -vE '$DROP' >> '$LOG'" >/dev/null 2>&1 &
    else
      nohup bash -c "exec -a kvtap-${STREAM} docker logs -f --since 0 '$C' 2>&1 \
        | grep --line-buffered -E '$PAT' >> '$LOG'" >/dev/null 2>&1 &
    fi
    sleep 2
    running && echo "  started" || echo "  FAILED to start"
  fi
  ;;
status) running && echo "  streaming" || echo "  NOT streaming" ;;
stop)   pkill -f "[k]vtap-${STREAM}" && echo "  stopped" || echo "  was not running" ;;
all-start)
  # *** CALL THIS AT THE END OF ANYTHING THAT RESTARTS THE ENGINE. *** The
  # capture dies with the container, so the tool that spends the boot is the
  # tool that must restore it; leaving it to memory has failed every time.
  echo "=== arming all four streams (both nodes)"
  _both_on local  start
  _both_on "$WORKER" start
  exec bash "$0" all-check
  ;;
all-check)
  echo "=== capture state, both nodes (each of faults+producer must be armed)"
  T=0
  for h in local "$WORKER"; do
    label=$([ "$h" = local ] && hostname -s || echo "$h")
    while read -r st n; do
      if [ "$n" -lt 0 ]; then
        echo "  $label $st: UNREADABLE -- not zero, and not a pass"; T=1
      elif [ "$n" -ge 1 ]; then
        echo "  $label $st: armed ($n proc)"
      else
        echo "  $label $st: *** NOT ARMED ***"; T=1
      fi
    done <<< "$(_armed_on "$h")"
  done
  [ "$T" -eq 0 ] && echo "CAPTURE ARMED: all four streams" \
                 || echo "*** CAPTURE INCOMPLETE -- evidence will be lost ***"
  exit $T
  ;;
*)      echo "usage: STREAM=producer|faults $0 start|status|stop   |   $0 all-start|all-check" >&2; exit 2;;
esac

# The EFFECT, beside the process state. Reporting only one of them is how both
# earlier versions of this script managed to lie.
case "${1:-start}" in all-start|all-check) exit 0 ;; esac

if [ -f "$LOG" ]; then
  echo "  file: $LOG  $(wc -c < "$LOG") bytes, $(wc -l < "$LOG") lines"
  tail -2 "$LOG" | cut -c1-150 | sed 's/^/    /'
else
  echo "  no file yet (nothing matching has been logged since the stream began)"
fi

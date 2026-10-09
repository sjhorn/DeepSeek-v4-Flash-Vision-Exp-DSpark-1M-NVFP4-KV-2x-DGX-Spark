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
*)      echo "usage: STREAM=producer|faults $0 start|status|stop" >&2; exit 2;;
esac

# The EFFECT, beside the process state. Reporting only one of them is how both
# earlier versions of this script managed to lie.
if [ -f "$LOG" ]; then
  echo "  file: $LOG  $(wc -c < "$LOG") bytes, $(wc -l < "$LOG") lines"
  tail -2 "$LOG" | cut -c1-150 | sed 's/^/    /'
else
  echo "  no file yet (nothing matching has been logged since the stream began)"
fi

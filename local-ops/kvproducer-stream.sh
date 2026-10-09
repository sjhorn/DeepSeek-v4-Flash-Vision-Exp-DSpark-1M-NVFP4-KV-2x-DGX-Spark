#!/usr/bin/env bash
# Keep the numpy-producer evidence across a restart.
#
# *** `docker logs` IS DESTROYED BY A RESTART, and the producer is now a
# *** WAITING GAME. *** Three occurrences in a day of heavy testing, the last
# one coerced losslessly and logged -- but if it fires tonight and somebody
# restarts tomorrow, the line is gone and the hunt starts over. That is this
# repo's CAPTURE BEFORE YOU RECOVER rule applied to a rare event nobody is
# sitting and watching for: STREAM the log to a file, do not query it after.
#
# Filtered rather than raw, because the whole log is large and only four
# patterns matter. Appends, so it accumulates across boots.
#
# *** THE BRACKET PATTERN IS LOAD-BEARING, AND MY FIRST ONE WAS DEFEATED BY
# *** THIS SCRIPT'S OWN FILENAME. *** `pgrep -f "[k]vmgr-numpy-tap"` cannot
# match the literal string "[k]vmgr-numpy-tap" -- but it DOES match
# "kvproducer-stream.sh", which contains "producer-stream" as a substring. So
# the idempotence check found its own invocation, reported "already streaming",
# and started nothing. A check that lies is worse than no check, and the tell
# was the companion line: "already streaming" beside "no file yet".
#
# The tag is therefore a string that appears NOWHERE in this file's name or
# arguments, set with `exec -a` so it is the streamer's whole argv[0].
set -u
C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
OUT=${OUT:-$HOME/kvdiag/producer}
PAT='numpy scalar PRODUCER|coerced a numpy scalar|producer scan EXHAUSTED|producer walk raised'

mkdir -p "$OUT"

case "${1:-start}" in
start)
  if pgrep -f "[k]vmgr-numpy-tap" >/dev/null 2>&1; then
    echo "  already streaming (pid $(pgrep -f '[k]vmgr-numpy-tap' | tr '\n' ' '))"
  else
    nohup bash -c "exec -a kvmgr-numpy-tap docker logs -f --since 0 '$C' 2>&1 \
      | grep --line-buffered -E '$PAT' >> '$OUT/producer.log'" >/dev/null 2>&1 &
    sleep 2
    pgrep -f "[k]vmgr-numpy-tap" >/dev/null 2>&1 \
      && echo "  started" || echo "  FAILED to start"
  fi
  ;;
status)
  pgrep -f "[k]vmgr-numpy-tap" >/dev/null 2>&1 \
    && echo "  streaming" || echo "  NOT streaming"
  ;;
stop)
  pkill -f "[k]vmgr-numpy-tap" && echo "  stopped" || echo "  was not running"
  ;;
esac

if [ -f "$OUT/producer.log" ]; then
  echo "  file: $OUT/producer.log  $(wc -c < "$OUT/producer.log") bytes"
  echo "  PRODUCER lines captured: $(grep -c 'numpy scalar PRODUCER' "$OUT/producer.log" || true)"
  echo "  coercions captured:      $(grep -c 'coerced a numpy scalar' "$OUT/producer.log" || true)"
  tail -2 "$OUT/producer.log" | cut -c1-200
else
  echo "  no file yet (nothing has fired since the stream started)"
fi

#!/usr/bin/env bash
# Phase 1: run the whole baseline matrix, one cell at a time.
#
#   nohup bash local-ops/toolsearch-matrix-run.sh > local-ops/toolsearch-matrix/run.log 2>&1 &
#
# Sequential on purpose: /metrics counters are global, so overlapping cells
# would blend into each other's cache deltas and every number would be a lie.
# Each cell gets its own port so a socket in TIME_WAIT cannot stall the next.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"

run() {  # cell tool_search workload port
  PORT="$4" bash "$REPO/local-ops/toolsearch-matrix.sh" "$1" "$2" "$D/$3" claude-sonnet-5
  echo "--- cooling down 20s so the next cell starts on a quiet engine"
  sleep 20
}

date
run ts-true-a   true   workload-a.txt 8911
run ts-true-b   true   workload-b.txt 8912
run ts-false-a  false  workload-a.txt 8913
run ts-false-b  false  workload-b.txt 8914
run ts-auto-a   unset  workload-a.txt 8915
run ts-auto-b   unset  workload-b.txt 8916
date
echo "=== matrix complete"
python3 "$REPO/local-ops/matrix-report.py" "$D"/ts-*.jsonl

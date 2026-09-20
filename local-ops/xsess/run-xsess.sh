#!/usr/bin/env bash
# R1 step 2, live: two REAL back-to-back Claude Code sessions with different
# opening prompts, to see whether session B's turn 0 starts warm off session A.
#
# Sequential by construction -- the /metrics counters are global, so two
# sessions at once would blend into each other's deltas.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/xsess-settings.json
# swift-lsp flaps and is the one known head-mover; this is a Python/shell repo.
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"

run() {  # cell workload port
  echo "=== $(date '+%H:%M:%S') starting cell $1"
  EXTRA_ARGS="--settings $S" PORT="$3" \
    bash "$REPO/local-ops/toolsearch-matrix.sh" "$1" false "$D/$2" claude-sonnet-5
  echo "=== $(date '+%H:%M:%S') cell $1 done; cooling 20s"
  sleep 20
}

date
run xsess-a workload-a.txt 8941
run xsess-b workload-b.txt 8942
date
echo "=== both cells complete"
python3 "$REPO/local-ops/matrix-report.py" "$D"/xsess-a.jsonl "$D"/xsess-b.jsonl

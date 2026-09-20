#!/usr/bin/env bash
# Is a single re-touch of the head between the sessions what makes session B hit?
#
# n=3 cold-head reps all gave B turn 0 = 0.0%. The ONE run where B hit 99.7%
# (gap-b) is the only one where the head was probed between A and B. That makes
# the probe the independent variable, so test it as one: identical protocol to
# clean-reps.sh, with exactly ONE probe of the head inserted after A ends.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/xsess-settings.json
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"

cleanup() { rm -f "$REPO"/xsess-scratch-*.md; }
trap cleanup EXIT

echo "rep probe $(date +%s)" > "$REPO/xsess-scratch-probe-$(date +%s).md"

echo "=== $(date '+%H:%M:%S') cell probea (cold head)"
EXTRA_ARGS="--settings $S" PORT=8991 \
  bash "$REPO/local-ops/toolsearch-matrix.sh" probea false "$D/workload-a.txt" claude-sonnet-5

echo "=== $(date '+%H:%M:%S') ONE probe of A's head"
python3 "$REPO/local-ops/xsess/gap-probe.py" \
  --capture "$D/probea.jsonl" --seconds 1 --every 1 \
  --out "$REPO/local-ops/xsess/probe-arm.json"

echo "=== $(date '+%H:%M:%S') cell probeb"
EXTRA_ARGS="--settings $S" PORT=8992 \
  bash "$REPO/local-ops/toolsearch-matrix.sh" probeb false "$D/workload-b.txt" claude-sonnet-5

echo "=== $(date '+%H:%M:%S') done"
python3 "$REPO/local-ops/matrix-report.py" "$D"/probea.jsonl "$D"/probeb.jsonl 2>&1 | grep -E "jsonl |^    0 |^    1 "

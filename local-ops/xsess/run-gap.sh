#!/usr/bin/env bash
# Re-run the two live sessions, but POLL A's head throughout the gap between
# them. Probes run only in the gap, so no session's own delta is contaminated.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/xsess-settings.json
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"

echo "=== $(date '+%H:%M:%S') cell gap-a"
EXTRA_ARGS="--settings $S" PORT=8961 \
  bash "$REPO/local-ops/toolsearch-matrix.sh" gap-a false "$D/workload-a.txt" claude-sonnet-5

echo "=== $(date '+%H:%M:%S') session A done -- polling the head through the gap"
python3 "$REPO/local-ops/xsess/gap-probe.py" \
  --capture "$D/gap-a.jsonl" --seconds 45 --every 6 \
  --out "$REPO/local-ops/xsess/gap.json"

echo "=== $(date '+%H:%M:%S') cell gap-b"
EXTRA_ARGS="--settings $S" PORT=8962 \
  bash "$REPO/local-ops/toolsearch-matrix.sh" gap-b false "$D/workload-b.txt" claude-sonnet-5

echo "=== $(date '+%H:%M:%S') done"
python3 "$REPO/local-ops/matrix-report.py" "$D"/gap-a.jsonl "$D"/gap-b.jsonl

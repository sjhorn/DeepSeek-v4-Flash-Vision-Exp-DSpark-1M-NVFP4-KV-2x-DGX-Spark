#!/usr/bin/env bash
# Phase 1, follow-up: the same cells with the swift-lsp plugin disabled.
#
# The baseline matrix found ONE head move per session in both tool-search
# modes, and in both it is the same event: the swift-lsp plugin attaching a few
# seconds in. With ENABLE_TOOL_SEARCH=false it shows up as the tools array
# going 23 -> 24; with =true the array stays at 9 but the deferred-tool NAME
# LIST inside msg[0].user goes 10 -> 11. Same cause, same cost -- everything
# behind it re-prefills.
#
# The plugin is Swift tooling in a Python/shell repo, so disabling it costs
# nothing here. These cells test whether removing it leaves a head that never
# moves, which is the outcome the whole plan is after.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/nolsp-settings.json
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"

run() {  # cell tool_search workload port
  EXTRA_ARGS="--settings $S" PORT="$4" \
    bash "$REPO/local-ops/toolsearch-matrix.sh" "$1" "$2" "$D/$3" claude-sonnet-5
  echo "--- cooling down 20s"
  sleep 20
}

date
run nolsp-true-a   true   workload-a.txt 8931
run nolsp-true-b   true   workload-b.txt 8932
run nolsp-false-a  false  workload-a.txt 8933
run nolsp-false-b  false  workload-b.txt 8934
date
echo "=== no-LSP cells complete"
python3 "$REPO/local-ops/matrix-report.py" "$D"/nolsp-*.jsonl

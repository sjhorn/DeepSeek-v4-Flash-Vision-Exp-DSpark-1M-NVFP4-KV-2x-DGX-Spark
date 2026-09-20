#!/usr/bin/env bash
# Natural cross-session reuse, measured cleanly, n reps.
#
# The gap run was contaminated: my own probes had cached the head before session
# A ran (gap-a turn 0 read 99.8%, which a genuinely first session cannot). So
# each rep here starts from a head NOBODY has seen: a uniquely-named scratch
# file at the repo root changes `gitStatus`, which Claude Code injects into the
# prompt head, so the head differs from every previous rep and from any probe.
#
# NO probing between A and B -- the whole point is to leave the cluster alone
# and see what a real second session gets.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/xsess-settings.json
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"
REPS="${1:-2}"

cleanup() { rm -f "$REPO"/xsess-scratch-*.md; }
trap cleanup EXIT

for r in $(seq 1 "$REPS"); do
  # unique repo-root file -> unique gitStatus -> head no one has cached
  echo "rep $r $(date +%s)" > "$REPO/xsess-scratch-$r-$(date +%s).md"
  echo "=== $(date '+%H:%M:%S') rep $r: cell rep${r}a"
  EXTRA_ARGS="--settings $S" PORT=$((8970+r*2)) \
    bash "$REPO/local-ops/toolsearch-matrix.sh" "rep${r}a" false "$D/workload-a.txt" claude-sonnet-5
  echo "=== $(date '+%H:%M:%S') rep $r: cell rep${r}b (no probing in between)"
  EXTRA_ARGS="--settings $S" PORT=$((8971+r*2)) \
    bash "$REPO/local-ops/toolsearch-matrix.sh" "rep${r}b" false "$D/workload-b.txt" claude-sonnet-5
done

echo "=== $(date '+%H:%M:%S') all reps done"
python3 "$REPO/local-ops/matrix-report.py" "$D"/rep*a.jsonl "$D"/rep*b.jsonl 2>&1 | tail -60

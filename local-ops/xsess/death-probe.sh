#!/usr/bin/env bash
# WHEN does a real session's head die?
#
# A head cached by a synthetic probe survives 5+ minutes (99.7% throughout a
# 777K-token burst). A head cached by a REAL session is already gone 22s after
# the session ends -- the "gap" and "probe-arm" probes both took ~22s, i.e. a
# full cold prefill, and only then became reusable.
#
# One probe per run is all the information available: the first probe re-caches
# the head, so every later probe hits regardless. DELAY sets when that single
# probe fires. Read the SECONDS, not the hit% -- ~0.7s means it was alive,
# ~22s+ means it was already gone (and the hit% is usually blended anyway).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
S=/tmp/xsess-settings.json
printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$S"
DELAY="${1:-2}"
# A trivial single-turn workload isolates "multi-turn" from "real session":
# if a one-prompt, no-tool session's head is ALSO dead 2s later, multi-turn is
# not the trigger.
WORKLOAD="${2:-$D/workload-a.txt}"
TAG="${3:-death${DELAY}}"

cleanup() { rm -f "$REPO"/xsess-scratch-*.md; }
trap cleanup EXIT
echo "death $DELAY $(date +%s)" > "$REPO/xsess-scratch-$TAG-$(date +%s).md"

echo "=== $(date '+%H:%M:%S') session A (cold head)"
EXTRA_ARGS="--settings $S" PORT=8995 \
  bash "$REPO/local-ops/toolsearch-matrix.sh" "$TAG" false "$WORKLOAD" claude-sonnet-5
echo "=== $(date '+%H:%M:%S') session ended; waiting ${DELAY}s then ONE probe"
sleep "$DELAY"
python3 "$REPO/local-ops/xsess/gap-probe.py" \
  --capture "$D/$TAG.jsonl" --seconds 1 --every 1 \
  --out "$REPO/local-ops/xsess/$TAG.json"
echo "=== $(date '+%H:%M:%S') done  (read the SECONDS: ~0.7s alive, ~22s dead)"

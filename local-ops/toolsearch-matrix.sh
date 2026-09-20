#!/usr/bin/env bash
# Phase 1 driver: run ONE matrix cell -- a headless Claude Code session routed
# through prompt-tap.py, with the tap measuring each turn's prefix-cache hit
# ratio live from the engine's /metrics counters.
#
#   ./local-ops/toolsearch-matrix.sh <cell-name> <true|false|unset> <workload.txt> [model]
#
# Everything lands in local-ops/toolsearch-matrix/<cell-name>.{jsonl,tap.log,session.log}.
# Report on it with local-ops/matrix-report.py.
#
# One cell at a time, deliberately: the /metrics counters are global, so two
# concurrent sessions would blend into each other's deltas.
#
# The tap terminates TLS towards the proxy itself (it reuses the same profile
# the launcher uses), so Claude Code talks plain HTTP to 127.0.0.1 and needs
# only the endpoint and the auth token.
set -uo pipefail

CELL="${1:?cell name}"
TOOLSEARCH="${2:?true|false|unset}"
WORKLOAD="${3:?path to workload file}"
MODEL="${4:-claude-sonnet-5}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$REPO/local-ops/toolsearch-matrix"
PORT="${PORT:-8901}"
BASE="${DSPARK_BASE_URL:-http://127.0.0.1:8888}"
PROFILE="${VLLM_PROFILE:-$HOME/.config/vllm-proxy/claude-latest-local.json}"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$CELL.jsonl"

curl -fsS --max-time 10 "$BASE/v1/models" >/dev/null || {
  echo "cannot reach $BASE -- open the SSH tunnel first:" >&2
  echo "  ssh -f -N -L 8888:127.0.0.1:8888 shorn@spark-45ea" >&2
  exit 1
}

echo "=== cell $CELL   tool_search=$TOOLSEARCH   model=$MODEL"
VLLM_PROFILE="$PROFILE" python3 "$REPO/local-ops/prompt-tap.py" \
    --port "$PORT" --out "$OUTDIR/$CELL.jsonl" --metrics-url "$BASE" \
    > "$OUTDIR/$CELL.tap.log" 2>&1 &
TAP=$!
trap 'kill $TAP 2>/dev/null' EXIT
sleep 2
kill -0 $TAP 2>/dev/null || { echo "tap failed to start:"; cat "$OUTDIR/$CELL.tap.log"; exit 1; }

# Same token the launcher passes; it never leaves this machine -- the tap
# forwards to the proxy over the existing mTLS path.
TOKEN="$(VLLM_PROFILE="$PROFILE" python3 -c 'import json,os;print(json.load(open(os.environ["VLLM_PROFILE"]))["apiKey"])')"

ENVV=(
  ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
  ANTHROPIC_AUTH_TOKEN="$TOKEN"
  API_TIMEOUT_MS="${API_TIMEOUT_MS:-1800000}"
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  DISABLE_TELEMETRY=1 DISABLE_INSTALLATION_CHECKS=1 DISABLE_AUTOUPDATER=1
  ENABLE_CLAUDEAI_MCP_SERVERS=false
)
# "unset" is its own cell: Claude Code's default (auto) is a third behaviour,
# not a synonym for either explicit value.
[ "$TOOLSEARCH" = "unset" ] || ENVV+=(ENABLE_TOOL_SEARCH="$TOOLSEARCH")

# EXTRA_ARGS lets a cell change client-side behaviour without a second driver.
# Used for the no-LSP cells: the swift-lsp plugin attaches a few seconds into
# every session, and its arrival is the single head move both tool-search modes
# suffer -- as the tools array (search off) or as the deferred-tool list inside
# msg[0].user (search on).
cd "$REPO"
START=$(date +%s)
env "${ENVV[@]}" claude -p --model "$MODEL" \
    --permission-mode bypassPermissions --output-format json \
    ${EXTRA_ARGS:-} \
    "$(cat "$WORKLOAD")" > "$OUTDIR/$CELL.session.log" 2>&1
RC=$?
echo "claude exited rc=$RC after $(( $(date +%s) - START ))s"

sleep 1
kill $TAP 2>/dev/null; trap - EXIT
echo "captured $(wc -l < "$OUTDIR/$CELL.jsonl" 2>/dev/null || echo 0) requests -> $OUTDIR/$CELL.jsonl"

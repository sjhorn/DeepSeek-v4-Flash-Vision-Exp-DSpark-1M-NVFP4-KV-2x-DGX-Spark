#!/usr/bin/env bash
# Phase 2 failure-mode probes. Each subcommand drives ONE real Claude Code
# session through prompt-tap.py and leaves a capture for matrix-report.py.
#
#   bash local-ops/phase2-probes.sh resume    [true|false|unset]   # T2.2
#   bash local-ops/phase2-probes.sh subagent  [true|false|unset]   # T2.3
#   bash local-ops/phase2-probes.sh mcp       [true|false|unset]   # T2.4
#   bash local-ops/phase2-probes.sh tier      [true|false|unset]   # Phase 1 tier switch
#
# Sequential only -- the /metrics counters the tap reads are global.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$REPO/local-ops/toolsearch-matrix"
PROFILE="${VLLM_PROFILE:-$HOME/.config/vllm-proxy/claude-latest-local.json}"
BASE="${DSPARK_BASE_URL:-http://127.0.0.1:8888}"
CMD="${1:?resume|subagent|mcp|tier}"
TS="${2:-unset}"
PORT="${PORT:-8921}"
mkdir -p "$D"

TOKEN="$(VLLM_PROFILE="$PROFILE" python3 -c 'import json,os;print(json.load(open(os.environ["VLLM_PROFILE"]))["apiKey"])')"

start_tap() {  # outfile
  python3 "$REPO/local-ops/prompt-tap.py" --port "$PORT" --out "$1" \
      --metrics-url "$BASE" > "$1.tap.log" 2>&1 &
  TAP=$!
  trap 'kill $TAP 2>/dev/null' EXIT
  sleep 2
}
stop_tap() { sleep 1; kill $TAP 2>/dev/null; trap - EXIT; }

cc() {  # runs claude with the tap as its endpoint; all args passed through
  env ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
      ANTHROPIC_AUTH_TOKEN="$TOKEN" \
      API_TIMEOUT_MS="${API_TIMEOUT_MS:-1800000}" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 \
      DISABLE_INSTALLATION_CHECKS=1 DISABLE_AUTOUPDATER=1 \
      ENABLE_CLAUDEAI_MCP_SERVERS="${MCP:-false}" \
      ${TS_ENV:+ENABLE_TOOL_SEARCH="$TS_ENV"} \
      claude ${SETTINGS:+--settings "$SETTINGS"} "$@"
}
# Phase 1 ended with the swift-lsp plugin disabled as part of the candidate
# config: its mid-session attach was the ONLY head move once tool search was
# off. Probe the config we intend to run, not the one we are leaving.
: "${SETTINGS:=/tmp/nolsp-settings.json}"
[ -r "$SETTINGS" ] || printf '{"enabledPlugins": {"swift-lsp@claude-plugins-official": false}}\n' > "$SETTINGS"
[ "$TS" = "unset" ] || TS_ENV="$TS"
: "${TS_ENV:=}"

cd "$REPO"

case "$CMD" in

# ── T2.2 resume + compaction ────────────────────────────────────────
# Upstream #27048 reports the prefix being invalidated on resume. Three legs
# in ONE capture so the seams are visible as consecutive turns: build context,
# resume it, then force a compaction. A resume that re-sends a byte-identical
# head shows as strict-prefix; anything else shows as a divergence with the
# part named.
resume)
  OUT="$D/p2-resume-$TS.jsonl"; rm -f "$OUT"; start_tap "$OUT"
  echo "=== leg 1: build context"
  SID="$(cc -p --model claude-sonnet-5 --permission-mode bypassPermissions \
       --output-format json \
       "Read CLAUDE.md in full, then read STATUS.md in full, then read local-ops/prefix-diff.py in full. One tool call per step. Then say DONE." \
       | python3 -c 'import json,sys;print(json.load(sys.stdin).get("session_id",""))')"
  echo "session_id=$SID"
  [ -n "$SID" ] || { echo "no session id -- cannot resume"; stop_tap; exit 1; }
  echo "=== leg 2: resume (the seam upstream #27048 is about)"
  cc -p --resume "$SID" --model claude-sonnet-5 --permission-mode bypassPermissions \
     --output-format json \
     "Now read local-ops/prompt-tap.py in full, then say DONE." > "$OUT.leg2.log" 2>&1
  echo "=== leg 3: force a compaction, then one more turn"
  cc -p --resume "$SID" --model claude-sonnet-5 --permission-mode bypassPermissions \
     "/compact" > "$OUT.leg3.log" 2>&1
  cc -p --resume "$SID" --model claude-sonnet-5 --permission-mode bypassPermissions \
     "Read local-ops/cache-probe.py in full, then say DONE." > "$OUT.leg4.log" 2>&1
  stop_tap
  ;;

# ── T2.3 subagents ──────────────────────────────────────────────────
# The Agent tool spawns a child session. Two questions: does the child perturb
# the PARENT's prefix (it should not -- separate conversation), and does the
# pair thrash a KV pool that only fits two 1M sessions.
subagent)
  OUT="$D/p2-subagent-$TS.jsonl"; rm -f "$OUT"; start_tap "$OUT"
  cc -p --model claude-sonnet-5 --permission-mode bypassPermissions \
     --output-format json \
     "Read CLAUDE.md in full. Then use the Agent tool (subagent_type Explore) to find every file under local-ops/ that reads the /metrics endpoint. Then read STATUS.md in full and summarise both results in five lines." \
     > "$OUT.session.log" 2>&1
  stop_tap
  ;;

# ── T2.4 MCP ────────────────────────────────────────────────────────
# MCP tool lists are the documented trigger for claude-code#92033. We run with
# ENABLE_CLAUDEAI_MCP_SERVERS=false normally; this is the "if we ever want it"
# measurement, not a recommendation.
mcp)
  OUT="$D/p2-mcp-$TS.jsonl"; rm -f "$OUT"; start_tap "$OUT"
  MCP=true cc -p --model claude-sonnet-5 --permission-mode bypassPermissions \
     --output-format json \
     "Read CLAUDE.md in full, then read STATUS.md in full, then read local-ops/prefix-diff.py in full. One tool call per step. Then say DONE." \
     > "$OUT.session.log" 2>&1
  stop_tap
  ;;

# ── Phase 1 tier switch ─────────────────────────────────────────────
# NOT a candidate mode: it quantifies what the effort prefix at message index 0
# costs when a session changes tier. sonnet (thinking low, +0 prefix) then opus
# (thinking high, +79) rewrites the prompt HEAD, so the whole conversation
# behind it re-prefills. The number decides whether mixing tiers in one session
# has to be avoided outright.
tier)
  OUT="$D/p2-tier-$TS.jsonl"; rm -f "$OUT"; start_tap "$OUT"
  SID="$(cc -p --model claude-sonnet-5 --permission-mode bypassPermissions \
       --output-format json \
       "Read CLAUDE.md in full, then read STATUS.md in full. One tool call per step. Then say DONE." \
       | python3 -c 'import json,sys;print(json.load(sys.stdin).get("session_id",""))')"
  echo "session_id=$SID"
  [ -n "$SID" ] || { echo "no session id"; stop_tap; exit 1; }
  echo "=== same tier (control)"
  cc -p --resume "$SID" --model claude-sonnet-5 --permission-mode bypassPermissions \
     "Read local-ops/prefix-diff.py in full, then say DONE." > "$OUT.same.log" 2>&1
  echo "=== switch to claude-opus-5 (thinking high, +79 prefix at index 0)"
  cc -p --resume "$SID" --model claude-opus-5 --permission-mode bypassPermissions \
     "Read local-ops/prompt-tap.py in full, then say DONE." > "$OUT.switch.log" 2>&1
  stop_tap
  ;;

*) echo "unknown probe: $CMD" >&2; exit 2 ;;
esac

echo "captured $(wc -l < "$OUT" 2>/dev/null || echo 0) requests -> $OUT"
python3 "$REPO/local-ops/matrix-report.py" "$OUT"

#!/usr/bin/env bash
# Re-enable the disk tier and walk the byte budget DOWN to a target.
#
# *** A BUDGET SET FAR BELOW WHAT IS HELD EVICTS THE DIFFERENCE IN ONE CALL. ***
# `_enforce_budget` computes `need = held + incoming - budget` and hands the
# whole thing to `choose_victims`, so going straight from 400 GB held to a
# 300 GB budget asks for ~100 GB -- roughly 140,000 keys -- in a single
# metadata message, unlinked on the worker's TRANSFER path. That is the largest
# eviction burst the system can produce, and it would land on the same path a
# suspected use-after-free lives on. Same destination, no cliff: start at or
# above what is held, then step down.
#
# Every step is a HOT knob, so this costs no restart. The engine must already
# be serving -- a real completion, never /v1/models, which the API server
# answers without touching the engine core.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
TARGET="${1:-300}"
STEP="${2:-20}"          # GB per step
SETTLE="${3:-45}"        # seconds between steps

engine(){ curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }

knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
rk=[(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]
print('  knob %-20s ok=%s ranks=%s' % ('$1', d.get('ok'), rk))"; }

state(){ curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {})
print('  held %.1f GB / budget %s GB  over=%s  present=%s  evicted=%s' % (
    (d.get('bytes_held') or 0)/1e9, d.get('budget_gb'), d.get('over_budget'),
    d.get('present'), d.get('evicted')))"; }

echo "=== engine must be SERVING first ==="
[ "$(engine)" = "200" ] || { echo "  engine is not answering a completion -- refusing"; exit 1; }
echo "  completion 200"

echo "=== the pending-blocks fix must be LIVE, or this is the old code ==="
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
n=$(docker logs --since 30m "$C" 2>&1 | grep -c "pending-blocks provider installed")
echo "  provider-installed log lines: $n"
[ "$n" -gt 0 ] || echo "  *** WARNING: the fix is NOT active. patch6 is imported at boot, so this"
[ "$n" -gt 0 ] || echo "      means the restart did not pick it up. Proceeding is a choice, not a default."

echo "=== start the budget AT or ABOVE what is held, so nothing bursts ==="
held=$(curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys,math
print(int(math.ceil(((json.load(sys.stdin).get('disk') or {}).get('bytes_held') or 0)/1e9)))")
start=$(( held + 10 ))
echo "  held ${held} GB -> starting budget ${start} GB"
knob disk_budget_gb "$start"
knob disk_restore 1
knob disk_store_paused 0
state

echo "=== stepping down to ${TARGET} GB in ${STEP} GB steps ==="
cur=$start
while [ "$cur" -gt "$TARGET" ]; do
  cur=$(( cur - STEP )); [ "$cur" -lt "$TARGET" ] && cur=$TARGET
  knob disk_budget_gb "$cur"
  # *** THE POKE MUST STORE SOMETHING NEW, OR THE STEP DOES NOTHING. ***
  # Eviction is DEMAND-DRIVEN: _enforce_budget runs only from prepare_store,
  # for the bytes a store is making room for. The first version of this used a
  # FIXED prompt, so after step one its blocks were already present -- nothing
  # incoming, no enforcement -- and the knobs were accepted while
  # `evicted` stayed None and `present` never moved. Measured: budget walked
  # 411 -> 371 with `over=True` and not one key evicted, which would have left
  # the whole 100 GB gap to go in a single burst on the first REAL request.
  # The stepping was theatre.
  #
  # So: a unique nonce per step, and enough tokens to produce group-0 blocks
  # (256 tokens each) worth storing. Note the eviction size is set by the GAP,
  # not by this prompt -- `need = held + incoming - budget` -- so a small store
  # is enough to trigger a full step's worth of eviction.
  nonce="budget-step-${cur}-$(date +%s)"
  body=$(python3 - "$nonce" <<'PYBODY'
import json, sys
n = sys.argv[1]
filler = ("the quick brown fox jumps over the lazy dog " * 120)[:4000]
json.dump({"model": "claude-opus-5", "max_tokens": 4,
           "messages": [{"role": "user", "content": n + " " + filler}]},
          sys.stdout)
PYBODY
)
  curl -s -o /dev/null -m 120 -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$body"
  sleep "$SETTLE"
  state
  if [ "$(engine)" != "200" ]; then
    echo "  *** ENGINE STOPPED ANSWERING at budget ${cur} GB -- stopping here, nothing restarted"
    exit 1
  fi
done
echo "=== settled ==="
state
echo "KVENABLE-DONE"

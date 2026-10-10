#!/usr/bin/env bash
# Xid 13 on the LOAD path: separate "big job" from "blocks a big prefill just freed".
#
# The faulting run (2026-10-09 18:49) did a 78K cold prefill and THEN restored a
# 327-key prefix, so two things changed at once and the fault attributes to
# neither. Multi-round is already refuted: 83 keys through a 4-slot pool (~21
# rounds) was clean.
#
# THIS RUN: restore the SAME 327-key prefix with NO large prefill before it.
#   faults  -> the preceding prefill is exonerated; it is the load job itself
#              (key count / bytes in one pass), and that is bisectable by size.
#   clean   -> the load job is exonerated; the interaction with freshly-freed
#              blocks is the suspect, which is a different and nastier fix.
#
# Either answer halves the search, which is the point of running it before
# reading more code -- the last two hypotheses were both closed by measurement
# and one of them was mine and wrong.
#
# CAPTURES BEFORE IT STARTS and never recovers. The handler LEDGER is captured
# either side, because a bounded ledger of index RANGES is the one thing an
# asynchronous fault destroys.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-100000}"
WARM="${2:-dropguard-live}"
D=~/kvdiag/load13-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('  knob %-20s ok=%s ranks=%s' % ('$1', d.get('ok'), [(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]))"; }
idx(){ curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}); i=d.get('index') or d
print('present=%s lookup=%s hit=%s' % (i.get('present'), i.get('lookup'), i.get('hit')))" 2>/dev/null || echo unreadable; }
# *** THE LEDGER SHAPE, READ OFF A REAL REPLY RATHER THAN GUESSED. ***
# My first parser looked for a "groups" map with bid_min/bid_max and printed
# NOTHING, twice, on a run whose whole purpose was to capture index ranges --
# an instrument failing silently on the one measurement it existed for. The
# real shape is:
#   {"transfers": N, "block_id_range": [lo,hi], "slot_range": [lo,hi],
#    "recent": [[kind, group, n, bid_min, bid_max, slot_min, slot_max], ...]}
# or, before anything moves, {"transfers": 0, "why": "...ABSENCE, not 0"}.
ledger(){ python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print('  ledger: unreadable (%s)' % e); raise SystemExit
if 'ranks' not in d: print('  ledger: no ranks key -- wrong port, or the engine is gone'); raise SystemExit
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        l = h.get('ledger')
        if not isinstance(l, dict): continue
        if not l.get('transfers'):
            print('  r%s %-16s %s' % (r.get('rank'), h.get('cls'), l.get('why') or 'no transfers'))
            continue
        print('  r%s %-16s transfers=%s bid=%s slot=%s' % (
            r.get('rank'), h.get('cls'), l.get('transfers'),
            l.get('block_id_range'), l.get('slot_range')))
        for e in (l.get('recent') or [])[-4:]:
            print('        last: %s' % (e,))
" "$1"
}

xid(){ journalctl -k -b 2>/dev/null | grep "Xid (" | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l; }
xidw(){ ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep 'Xid (' | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l"; }

fetchw(){ curl -s -m 20 "$API/kv/workers" > "$1" 2>/dev/null || true; }

( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
( ssh -o BatchMode=yes spark-da08 "docker logs -f --since 1s $C" > "$D/worker-stream.log" 2>&1 ) & WLOG=$!
trap 'kill $LOG $WLOG 2>/dev/null' EXIT
sleep 2

[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }
say "=== NO large prefill before this. Largest prior request this process: ~20K. ==="
knob disk_store_paused 1
knob disk_restore 1
H0=$(xid); W0=$(xidw)
say "Xid events before: head=$H0 worker=$W0"
say "index before: $(idx)"
say "ledger before:"; fetchw "$D/workers-before.json"; ledger "$D/workers-before.json"

python3 - "$TOK" "$WARM" > /tmp/load13.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY

# *** POLL THE LEDGER DURING THE RESTORE. *** It lives in the WORKER's memory,
# so the fault that destroys the worker destroys the very record kept to survive
# an asynchronous fault -- workers-after.json came back 99 bytes of error last
# run. Keep the newest successful snapshot on the HOST instead, so the last
# index ranges before the fault are readable afterwards.
( while true; do
    curl -s -m 5 "$API/kv/workers" > "$D/workers-poll.tmp" 2>/dev/null \
      && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'ranks' in d else 1)" "$D/workers-poll.tmp" 2>/dev/null \
      && mv "$D/workers-poll.tmp" "$D/workers-last.json"
    sleep 1
  done ) & POLL=$!
trap 'kill $LOG $WLOG $POLL 2>/dev/null' EXIT

say "=== THE RESTORE, as the only large request in this process ==="
t=$(date +%s)
body=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/load13.json)
say "wall=$(( $(date +%s) - t ))s  prompt_tokens=$(echo "$body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','NONE -- the request FAILED'))
except Exception: print('NONE -- no JSON, the request FAILED')" 2>/dev/null)"
say "index after: $(idx)"
kill $POLL 2>/dev/null
say "ledger after (live, may be unreadable if the engine died):"
fetchw "$D/workers-after.json"; ledger "$D/workers-after.json"
say "ledger LAST GOOD POLL before the fault (this is the one that matters):"
ledger "$D/workers-last.json"
H=$(xid); W=$(xidw); A=$(alive)
say "Xid head=$H(+$((H-H0)))  worker=$W(+$((W-W0)))  engine=$A"
sleep 3
docker logs --since 30m "$C" > "$D/engine.log" 2>&1
ssh -o BatchMode=yes spark-da08 "docker logs --since 30m $C" > "$D/worker.log" 2>&1
journalctl -k --since "-30m" > "$D/kernel-head.log" 2>&1
ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-30m\"" > "$D/kernel-worker.log" 2>&1
if [ "$H" != "$H0" ] || [ "$W" != "$W0" ] || [ "$A" != "200" ]; then
  say "VERDICT: FAULTED with no large prefill before it -- the prefill is EXONERATED,"
  say "         the load job itself is the suspect, and key count is bisectable."
else
  say "VERDICT: CLEAN -- the load job alone is not sufficient. The interaction with"
  say "         blocks a large prefill just freed becomes the suspect."
fi
say "evidence: $D"
echo "LOAD13-DONE"

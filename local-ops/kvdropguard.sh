#!/usr/bin/env bash
# Prove the worker-side drop guard FIRES, and then that it CLEARS.
#
# *** A GUARD THAT CANNOT FIRE READS EXACTLY LIKE A GUARD WITH NOTHING TO
# *** REFUSE, and that is how the 2026-10-09 17:51 crash got through: the
# scheduler-side guard was live, said nothing, and the drop proceeded while the
# worker held two store jobs. Every drop I ran afterwards drained first, so the
# guard was never exercised -- a clean result from a path that never ran.
#
# So this does the opposite of the safe procedure ON PURPOSE: it starts a large
# store and calls the drop WHILE the worker is demonstrably busy. The pass
# condition is a 409 naming the rank and its counts. If it returns 200, the
# guard is decorative and the next 100K cycle will kill a worker.
#
# Then it waits for the transfers to drain and drops again, because a guard
# that refuses forever is just as broken as one that never refuses -- it would
# disable the lever the restore tests depend on.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
TOK="${1:-100000}"
NONCE="${2:-dropguard-$(date +%s)}"
say(){ echo "  $*"; }
engine(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
# The WORKER-side counts -- the quantity the guard added. Reported from
# /kv/workers, which was already serving them before anything asked.
wbusy(){ curl -s -m 15 "$STATS/kv/workers" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unreadable'); raise SystemExit
tot=0; parts=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        for f in ('jobs_open','writes_open','reads_open'):
            v=h.get(f)
            if isinstance(v,int) and not isinstance(v,bool) and v:
                tot+=v; parts.append('r%s.%s.%s=%d'%(r.get('rank'),h.get('cls','?'),f,v))
print('%d %s'%(tot,' '.join(parts) if parts else 'idle'))" 2>/dev/null || echo "unreadable"; }

[ "$(engine)" = "200" ] || { say "engine not serving; refusing to test"; exit 1; }
knob disk_store_paused 0; knob disk_restore 1
knob disk_budget_gb 1000; knob gpu_cache_drop_allowed 1

python3 - "$TOK" "$NONCE" > /tmp/dropguard-body.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY

say "=== a large store, in the BACKGROUND, so the drop can race it ==="
curl -s -o /dev/null -m 1800 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' --data @/tmp/dropguard-body.json &
BG=$!

say "=== wait until the WORKER is demonstrably busy ==="
seen=0
for i in $(seq 1 300); do
  w=$(wbusy); n=${w%% *}
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -gt 0 ]; then say "worker busy after ${i}s: $w"; seen=1; break; fi
  sleep 1
done
# ABSENT IS NOT ZERO: if the window never opened this run proves nothing about
# the guard, and must say so rather than report the refusal that follows.
if [ "$seen" = "0" ]; then
  say "*** THE WORKER WAS NEVER OBSERVED BUSY -- this run tests NOTHING. ***"
  say "    Raise TOK, or check /kv/workers is reporting handlers at all."
  wait $BG 2>/dev/null; exit 2
fi

say "=== THE DROP, while a DMA is live. A 200 here is a FAILED TEST. ==="
body=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache")
code=$(echo "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('refused') or ('PERMITTED' if d.get('ok') else 'other'))" 2>/dev/null || echo parse-error)
say "drop verdict: $code"
echo "$body" | python3 -m json.tool 2>/dev/null | head -22 | sed 's/^/      /'
case "$code" in
  worker_transfers_outstanding) say "PASS: the guard FIRED and named the rank" ;;
  PERMITTED) say "*** FAIL: the drop was PERMITTED with the worker busy -- the guard is decorative ***" ;;
  *) say "*** FAIL: unexpected verdict '$code' ***" ;;
esac

say "=== now let it drain, and confirm the guard CLEARS ==="
wait $BG 2>/dev/null
for i in $(seq 1 180); do
  w=$(wbusy); n=${w%% *}
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" = "0" ] && break
  sleep 2
done
say "worker now: $(wbusy)"
body2=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache")
ok2=$(echo "$body2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('PERMITTED' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo parse-error)
say "drop verdict when idle: $ok2  (PERMITTED is the pass -- a guard that never clears disables the lever)"
say "engine: $(engine)"
echo "DROPGUARD-DONE"

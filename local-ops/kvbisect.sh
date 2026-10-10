#!/usr/bin/env bash
# BISECT THE LOAD BATCH SIZE AT WHICH THE COPY FAULTS -- with no restarts.
#
# Experiment 1 answered the shared-vs-size question in the direction I did not
# expect: with the load on its OWN separate pool of 256 the Xid 13 fault
# RETURNED on the first restore (worker Xid 7 -> 8, VllmWorker-1 died), and the
# store was PAUSED throughout. So sharing is NOT the cause and no concurrent
# store is needed; the variable is the number of blocks handed to upstream's
# batch copy in ONE transfer_async.
#
# Everything measured so far fits that:
#     42 keys / 256 pool  ->  42 per round   clean   (the 37x run)
#     83 keys /   4 pool  ->  <=4 per round  clean
#    327 keys /  64 pool  ->  64 per round   clean
#    327 keys / 256 pool  -> ~256 per round  FAULT
#
# `staging_load_slots` is HOT and the allocation is 256, so the live limit can
# be walked down without a boot. Each arm: set the limit, poke so the reconcile
# lands on a scheduler step, drain, drop (ASSERTED), restore, check Xid.
#
# STOPS AT THE FIRST CLEAN VALUE below a faulting one, which is the threshold.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
WARM="${1:-dropguard-live}"
shift || true
ARMS="${*:-256 128 96 64}"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
drop(){ curl -s -m 60 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo unreachable; }
tot(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print(-1); raise SystemExit
t=0
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        for f in ('jobs_open','writes_open','reads_open'):
            x=h.get(f)
            if isinstance(x,int) and not isinstance(x,bool): t+=x
print(t)" 2>/dev/null || echo -1; }
# The LIVE load pool size, read back -- the knob is not evidence the pool moved.
lpool(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskLoadHandler':
            st=h.get('staging')
            o.append('r%s size=%s cap=%s' % (r.get('rank'),
                     (st or {}).get('size','?'), (st or {}).get('capacity','?')))
print(' | '.join(o) or 'no load handler')" 2>/dev/null || echo unreadable; }
xh(){ journalctl -k -b 2>/dev/null | grep "Xid (" | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*: ([0-9]+).*/\1|\2/' | sort -u | wc -l; }
xw(){ ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep 'Xid (' | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*: ([0-9]+).*/\1|\2/' | sort -u | wc -l" 2>/dev/null || echo -1; }
python3 - "$WARM" > /tmp/bisect-warm.json <<'PY'
import json, sys
n, nonce = 100000, sys.argv[1]
w = "alpha beta gamma delta epsilon zeta eta theta "
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + (w * ((n // 8) + 2))[:n * 4]}]},
          sys.stdout)
PY

[ "$(alive)" = "200" ] || { say "engine not serving -- aborting"; exit 1; }
# Store PAUSED: experiment 1 proved the fault needs no store, and leaving it off
# removes a variable and avoids the pump/fence stall entirely.
knob disk_store_paused 1
H0=$(xh); W0=$(xw)
say "Xid events before: head=$H0 worker=$W0"

for n in $ARMS; do
  say "=== ARM staging_load_slots=$n ==="
  [ "$(alive)" = "200" ] || { say "    engine not serving -- STOPPING (a corpse, not a result)"; break; }
  knob staging_load_slots "$n"
  knob disk_restore 1
  knob gpu_cache_drop_allowed 1
  # The reconcile runs in _collect, once per scheduler step, so poke it or the
  # arm measures the OLD pool size -- this project's documented idle-knob trap.
  curl -s -o /dev/null -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"pool poke"}]}'
  say "    live load pool: $(lpool)"
  for i in $(seq 1 60); do [ "$(tot)" = "0" ] && break; sleep 2; done
  dv=$(drop)
  if [ "$dv" != "ok" ]; then say "    DROP=$dv -- skipping this arm, it would measure a GPU hit"; continue; fi
  curl -s -o /dev/null -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
  t=$(date +%s)
  body=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/bisect-warm.json)
  wall=$(( $(date +%s) - t ))
  tok=$(echo "$body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
  H=$(xh); W=$(xw); A=$(alive)
  say "    restore wall=${wall}s tokens=$tok  Xid head=$H(+$((H-H0))) worker=$W(+$((W-W0)))  engine=$A"
  if [ "$H" != "$H0" ] || [ "$W" != "$W0" ] || [ "$A" != "200" ]; then
    say "    *** FAULTED at $n -- stopping, NOT recovering. Threshold is above the next clean value. ***"
    echo "BISECT-DONE faulted_at=$n"; exit 0
  fi
  say "    clean at $n"
  knob disk_restore 0
done
knob disk_restore 0
knob disk_store_paused 1
say "all arms clean: $ARMS"
echo "BISECT-DONE"

#!/usr/bin/env bash
# Is the LOAD path's MULTI-ROUND case the thing that has never worked?
#
# THE HYPOTHESIS, and why it is worth one experiment rather than more reading:
# the 37x restore on 2026-10-08 had `lookup 43, hit 42` -- 42 keys against a
# 256-slot staging pool, so it completed in ONE round. The 2026-10-09 restore
# that faulted the worker with Xid 13 had `lookup 328, hit 327`, which exceeds
# the pool and therefore chunks over rounds. So the multi-round LOAD may simply
# never have run successfully, which is the same shape as the `view[:] = buf`
# bug: the one direction that had never executed.
#
# THE DESIGN: hold the prefix CONSTANT and vary only `staging_slots`, which is
# hot (reconcile_pool applies it per scheduler step). Same keys, same bytes,
# same files -- only the number of rounds differs. That is the difference the
# hypothesis is about, and nothing else moves.
#
#   arm A: staging_slots=256 -> a small prefix fits in one round
#   arm B: staging_slots=4   -> the SAME prefix needs many rounds
#
# A pass in A and a fault in B isolates multi-round load. A fault in BOTH means
# the round count is innocent and the load path is broken generally, which is
# also worth knowing and is a different fix.
#
# Store path stays PAUSED throughout: a read measured beside a write is a
# measurement about the pool (574.9s vs 3.3s), and a paused store cannot queue a
# job that needs the scheduler step the fence removes.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
TOK="${1:-20000}"
WARM="${2:-droploop-a}"
say(){ echo "  $*"; }
xid(){ journalctl -k -b 2>/dev/null | grep "Xid (" | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l; }
xidw(){ ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep 'Xid (' | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('  knob %-20s ok=%s ranks=%s' % ('$1', d.get('ok'), [(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]))"; }
idx(){ curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}); i=d.get('index') or d
print('lookup=%s hit=%s' % (i.get('lookup'), i.get('hit')))" 2>/dev/null || echo "unreadable"; }
pool(){ curl -s -m 15 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
out=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        st=h.get('staging')
        if isinstance(st,dict): out.append('r%s.%s size=%s cap=%s'%(r.get('rank'),h.get('cls'),st.get('size'),st.get('capacity')))
print(' | '.join(out) or 'no staging reported')" 2>/dev/null || echo unreadable; }

[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }
python3 - "$TOK" "$WARM" > /tmp/loadrounds.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY

knob disk_store_paused 1
knob staging_write_floor 0      # let the LOAD take the whole pool
H0=$(xid); W0=$(xidw)
say "Xid events before: head=$H0 worker=$W0"

arm(){ # $1=label $2=slots
  say "=== ARM $1: staging_slots=$2 ==="
  knob staging_slots "$2"
  knob disk_restore 1
  # A hot pool resize lands on the next SCHEDULER STEP, not on the knob call --
  # so poke the engine once, or the arm runs against the OLD pool size and the
  # whole experiment is about nothing. This repo's "hot knob on an IDLE engine
  # shows the OLD derived figure", applied to the thing under test.
  curl -s -o /dev/null -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"pool poke"}]}'
  say "    pool now: $(pool)"
  say "    index before: $(idx)"
  t=$(date +%s)
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 1200 -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' --data @/tmp/loadrounds.json)
  say "    restore: http=$code wall=$(( $(date +%s) - t ))s"
  say "    index after:  $(idx)"
  H=$(xid); W=$(xidw); A=$(alive)
  say "    Xid head=$H(+$((H-H0))) worker=$W(+$((W-W0)))  engine=$A"
  if [ "$H" != "$H0" ] || [ "$W" != "$W0" ] || [ "$A" != "200" ]; then
    say "    *** ARM $1 FAULTED -- stopping here, NOT recovering ***"
    return 1
  fi
  say "    ARM $1 clean"
  knob disk_restore 0
  return 0
}

if arm "A (one round)" 256; then
  # The GPU now holds the prefix, so arm B would hit the GPU cache and never
  # reach an external lookup. The drop is guarded now, so this is safe -- and if
  # it REFUSES, say so, because then arm B tests nothing.
  knob gpu_cache_drop_allowed 1
  dv=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys; d=json.load(sys.stdin); print('ok' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo parse-error)
  say "=== drop between arms: $dv ==="
  [ "$dv" = "ok" ] || say "*** the drop did not take -- arm B will hit the GPU cache and test NOTHING ***"
  curl -s -o /dev/null -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
  arm "B (many rounds)" 4 || true
fi
say "final: engine=$(alive)  pool=$(pool)"
echo "LOADROUNDS-DONE"

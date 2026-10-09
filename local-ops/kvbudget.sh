#!/usr/bin/env bash
# PHASE 5, verified on the box: does a budget below what is held actually evict,
# do the WORKERS unlink, and does the disk shrink?
#
# Verified by EFFECT, not by the knob reading back -- a knob that reads back and
# changes nothing is this repo's signature failure.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
knob(){ curl -s -m 20 -X POST "$API/kv/knob" -H 'Content-Type: application/json' -d "{\"name\":\"$1\",\"value\":$2}" -o /dev/null; }
kv(){ curl -s -m 25 "$STATS/kv" | python3 -c "
import json,sys
d=json.load(sys.stdin)['disk']
print('  present=%s held_gb=%.1f budget_gb=%s enforced=%s over=%s evicted=%s evicted_gb=%.1f'
      % (d.get('present'), (d.get('bytes_held') or 0)/1e9, d.get('budget_gb'),
         d.get('budget_enforced'), d.get('over_budget'), d.get('evicted') or 0,
         (d.get('evicted_bytes') or 0)/1e9))"; }
wk(){ curl -s -m 25 "$API/kv/workers" | python3 -c "
import json,sys
for r in json.load(sys.stdin)['ranks']:
    for h in r.get('handlers',[]):
        if h.get('cls')=='DiskStoreHandler':
            print('  rank %s deleted=%s delete_errors=%s files=%s'
                  % (r['rank'], h.get('deleted'), h.get('delete_errors'), h.get('files')))"; }
req(){ python3 - "$1" <<'PY'
import json, sys, time
t = int(sys.argv[1])
u = " budget-%d alpha bravo charlie delta echo foxtrot golf hotel india juliet." % time.time()
need = int(t * 3.27)
json.dump({"model":"claude-opus-5","max_tokens":4,"temperature":0,
           "messages":[{"role":"user","content":(u*(need//len(u)+1))[:need]}]},
          open("/tmp/budget-req.json","w"))
PY
  curl -s -m 600 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    --data-binary @/tmp/budget-req.json -o /dev/null -w "  request HTTP=%{http_code} %{time_total}s\n"; }

knob disk_store_paused false; knob disk_restore true
echo "=== A) no budget: must be UNBOUNDED, nothing evicted ==="
knob disk_budget_gb 0
req 20000
sleep 15
kv; wk
du_before=$(du -sb ~/kvoffload 2>/dev/null | cut -f1)
echo "  disk: $(numfmt --to=iec $du_before 2>/dev/null || echo $du_before)"

echo "=== B) budget BELOW what is held: eviction must fire ==="
held=$(curl -s -m 25 "$STATS/kv" | python3 -c "
import json,sys; print(int((json.load(sys.stdin)['disk'].get('bytes_held') or 0)/1e9))")
target=$(( held > 60 ? held - 50 : 1 ))
echo "  held ${held} GB -> setting budget ${target} GB"
knob disk_budget_gb "$target"
req 20000
sleep 25
kv; wk
du_after=$(du -sb ~/kvoffload 2>/dev/null | cut -f1)
echo "  disk: $(numfmt --to=iec $du_after 2>/dev/null || echo $du_after)  (was $(numfmt --to=iec $du_before 2>/dev/null || echo $du_before))"
# *** REPORT THE NUMBER, DO NOT ASSERT THE CONCLUSION. *** The first version
# printed "a DECREASE is the proof" beside a +1.1 GB INCREASE, because the label
# was fixed and only the number varied. A diagnostic that states its own verdict
# regardless of the measurement is worse than no label.
python3 -c "
b,a=$du_before,$du_after
d=(a-b)/1e9
print('  disk change: %+.1f GB -- %s' % (
    d, 'SHRANK, which is the proof eviction reached the files'
       if d < -0.5 else
    'GREW: stores outpaced eviction, or nothing was evicted'
       if d > 0.5 else 'flat'))"

echo "=== C) a restore must still work after eviction ==="
curl -s -m 300 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  --data-binary @/tmp/budget-req.json -o /dev/null -w "  repeat HTTP=%{http_code} %{time_total}s\n"
echo "  engine=$(curl -s -o /dev/null -w %{http_code} -m 30 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}')"
knob disk_budget_gb 0
echo "  (budget back to unbounded)"
echo BUDGET-DONE

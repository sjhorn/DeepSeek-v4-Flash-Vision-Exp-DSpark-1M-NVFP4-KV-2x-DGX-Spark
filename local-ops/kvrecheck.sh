#!/usr/bin/env bash
# Re-verify the restore with the pre-copy skip live, and MEASURE what it avoided.
#
# Two questions, kept separate:
#   1. how many GPU->staging copies did the skip prevent? (skipped_before_copy)
#   2. does the 327-key restore still fault?
#
# (1) is the one that says the mitigation does real work. (2) is a RATE, and N
# clean attempts bound it rather than proving zero -- the lesson this project
# has paid for twice today, where two clean single runs were nearly reported as
# a fix and the first 100K cycle then faulted immediately.
#
# NOTE ON disk_store_paused: it is set here, and it is KNOWN NOT TO STOP STORE
# JOBS (measured 2026-10-10: set and read back True on both ranks with a store
# outstanding anyway). So this is not a write-path-off measurement, and must not
# be reported as one. It is set because it reduces new stores, not because it
# eliminates them.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-100000}"
WARM="${2:-dropguard-live}"
N="${3:-3}"
D=~/kvdiag/recheck-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
idx(){ curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}); i=d.get('index') or d
print('lookup=%s hit=%s' % (i.get('lookup'), i.get('hit')))" 2>/dev/null || echo unreadable; }
# The counter the fix added. /kv/workers is on the CONTROL PLANE (:8888), not
# :9199, whose "not found" has no ranks key and would render as zero.
skipped(){ curl -s -m 15 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
out=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskStoreHandler':
            out.append('r%s skipped_before_copy=%s files=%s bytes=%s' % (
              r.get('rank'), h.get('skipped_before_copy', 'ABSENT'),
              h.get('files'), h.get('bytes')))
print(' | '.join(out) or 'no store handler')" 2>/dev/null || echo unreadable; }
xid(){ journalctl -k -b 2>/dev/null | grep "Xid (" | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l; }
xidw(){ ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep 'Xid (' | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l"; }

( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }
knob disk_store_paused 1
knob disk_restore 1
python3 - "$TOK" "$WARM" > /tmp/recheck.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY
H0=$(xid); W0=$(xidw)
say "Xid events before: head=$H0 worker=$W0"
say "store counters before: $(skipped)"

FAULT=0
for i in $(seq 1 "$N"); do
  t=$(date +%s)
  body=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/recheck.json)
  tok=$(echo "$body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
  H=$(xid); W=$(xidw); A=$(alive)
  say "attempt $i/$N: wall=$(( $(date +%s) - t ))s tokens=$tok  $(idx)  Xid head=$H(+$((H-H0))) worker=$W(+$((W-W0)))  engine=$A"
  say "    $(skipped)"
  if [ "$H" != "$H0" ] || [ "$W" != "$W0" ] || [ "$A" != "200" ]; then
    say "    *** FAULTED on attempt $i -- capturing, NOT recovering ***"; FAULT=$i; break
  fi
  # Drop between attempts or the GPU cache answers and no restore is exercised.
  knob gpu_cache_drop_allowed 1
  dv=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys; d=json.load(sys.stdin); print('ok' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo parse-error)
  [ "$dv" = "ok" ] || say "    drop between attempts: $dv -- the NEXT attempt may hit the GPU cache and test nothing"
  curl -s -o /dev/null -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
done
sleep 3
docker logs --since 40m "$C" > "$D/engine.log" 2>&1
ssh -o BatchMode=yes spark-da08 "docker logs --since 40m $C" > "$D/worker.log" 2>&1
journalctl -k --since "-40m" > "$D/kernel-head.log" 2>&1
ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-40m\"" > "$D/kernel-worker.log" 2>&1
if [ "$FAULT" = "0" ]; then
  say "RESULT: $N/$N attempts clean. That BOUNDS the rate; it does not prove zero."
else
  say "RESULT: faulted on attempt $FAULT of $N -- the structural overlap remains."
fi
say "evidence: $D"
echo "RECHECK-DONE"

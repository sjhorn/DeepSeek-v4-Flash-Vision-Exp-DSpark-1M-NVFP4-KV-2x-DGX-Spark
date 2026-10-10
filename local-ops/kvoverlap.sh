#!/usr/bin/env bash
# Restore a stored prefix WHILE a new prefix is being stored -- the condition
# the staging split exists to make safe.
#
# *** WHY THIS RUN AND NOT THE LAST ONE. *** kvrecheck.sh got 3/3 clean on the
# 327-key restore, which is the first time it has completed at all -- but its
# own output said `files=0 bytes=0` on both ranks, so NO STORE RAN. The Xid 13
# hazard needs a concurrent GPU->staging write, and the faulting runs had one
# ("store path busy -- 1 job(s) outstanding" on both ranks at the fault). So a
# clean run with no store in flight does not test the split; it tests the easy
# case, and reporting it as proof would be the vacuous pass this project keeps
# paying for.
#
# So: a FRESH nonce (nothing on disk, so every block is a genuine new store,
# and the pre-copy skip cannot remove them) sent concurrently with the stored
# prefix's restore. Both directions busy on their own pinned allocations, which
# is precisely what the shared buffer could not survive.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-100000}"
WARM="${2:-dropguard-live}"
N="${3:-3}"
D=~/kvdiag/overlap-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
hw(){ curl -s -m 15 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        o.append('r%s.%s jobs=%s w=%s rd=%s skip=%s files=%s' % (
          r.get('rank'), h.get('cls','?')[4:9], h.get('jobs_open'),
          h.get('writes_open'), h.get('reads_open'),
          h.get('skipped_before_copy'), h.get('files')))
print(' | '.join(o))" 2>/dev/null || echo unreadable; }
xid(){ journalctl -k -b 2>/dev/null | grep "Xid (" | sed -E 's/.*Xid \(PCI:[^)]*\): ([0-9]+).*/\1/' | wc -l; }
xidw(){ ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo 0; }

( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }
# *** THE STORE PATH IS ON, DELIBERATELY. *** Every other restore measurement
# here paused it; this one must not, because the overlap IS the test. (And
# disk_store_paused is known not to stop store jobs anyway -- measured
# 2026-10-10 -- so "paused" was never the write-off state it was read as.)
knob disk_store_paused 0
knob disk_restore 1
knob gpu_cache_drop_allowed 1

mk(){ python3 - "$TOK" "$1" ; }
python3 - "$TOK" "$WARM" > /tmp/ov-warm.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY
H0=$(xid); W0=$(xidw)
say "Xid LINES before: head=$H0 worker=$W0"
say "handlers before: $(hw)"

FAULT=0
for i in $(seq 1 "$N"); do
  NONCE="overlap-$(date +%s)-$i"
  python3 - "$TOK" "$NONCE" > /tmp/ov-new.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("delta epsilon zeta eta theta iota kappa lambda " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY
  say "=== round $i/$N: a FRESH prefix storing, concurrent with the restore ==="
  curl -s -o /dev/null -m 1800 -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' --data @/tmp/ov-new.json &
  NEWPID=$!
  # Wait until the STORE is demonstrably busy, then fire the restore into it.
  busy=0
  for _ in $(seq 1 240); do
    w=$(hw)
    case "$w" in *"Store jobs=0 w=0"*) ;; *"Store jobs="*) busy=1; break ;; esac
    sleep 1
  done
  say "    overlap: $(hw)"
  [ "$busy" = "1" ] || say "    *** NO STORE OBSERVED BUSY -- this round tests nothing about the overlap ***"
  t=$(date +%s)
  body=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/ov-warm.json)
  tok=$(echo "$body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
  wait $NEWPID 2>/dev/null
  H=$(xid); W=$(xidw); A=$(alive)
  say "    restore: wall=$(( $(date +%s) - t ))s tokens=$tok  Xid head=$H(+$((H-H0))) worker=$W(+$((W-W0)))  engine=$A"
  say "    handlers: $(hw)"
  if [ "$H" != "$H0" ] || [ "$W" != "$W0" ] || [ "$A" != "200" ]; then
    say "    *** FAULTED on round $i -- capturing, NOT recovering ***"; FAULT=$i; break
  fi
  dv=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys; d=json.load(sys.stdin); print('ok' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo parse-error)
  say "    drop between rounds: $dv"
  curl -s -o /dev/null -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
done
sleep 3
docker logs --since 40m "$C" > "$D/engine.log" 2>&1
ssh -o BatchMode=yes spark-da08 "docker logs --since 40m $C" > "$D/worker.log" 2>&1
journalctl -k --since "-40m" > "$D/kernel-head.log" 2>&1
ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-40m\"" > "$D/kernel-worker.log" 2>&1
if [ "$FAULT" = "0" ]; then
  say "RESULT: $N/$N rounds clean WITH A STORE IN FLIGHT -- the condition that faulted before."
  say "        That bounds the rate; it does not prove zero."
else
  say "RESULT: faulted on round $FAULT of $N -- the split is NOT sufficient."
fi
say "evidence: $D"
echo "OVERLAP-DONE"

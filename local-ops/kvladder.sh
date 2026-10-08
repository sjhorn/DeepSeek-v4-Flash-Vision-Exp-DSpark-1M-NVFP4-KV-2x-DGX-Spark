#!/usr/bin/env bash
# THE RESTORE LADDER, re-run with the wait()-ate-the-completions fix live.
#
# The question is NOT whether restore works -- that was proven. It is whether a
# prefix is now fully restorable after ONE pass instead of fourteen. Before the
# fix the restorable prefix grew a fixed +13,312 tokens a pass, because each
# pass indexed only the jobs that happened to complete outside a wait().
#
# A FRESH NONCE IS REQUIRED. The manifest is persisted (103,917 keys survived
# the restart), so the old prompt's keys are already indexed and a "cold" pass
# on it would not be cold.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-180000}"
NONCE="kvladder-$(date +%s)"

inflight() { curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d",(r+w)}'; }
hits()  { curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_hits_total\{/{print $2; exit}'; }
d2g()   { curl -s -m 10 "$API/metrics" | awk '/transfer_type="DSPARK_DISK_to_GPU"/{print $2; exit}'; }
g2d()   { curl -s -m 10 "$API/metrics" | awk '/transfer_type="GPU_to_DSPARK_DISK"/{print $2; exit}'; }
kv()    { curl -s -m 20 "$STATS/kv"; }

knob() { curl -s -m 20 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
         -d "{\"name\":\"$1\",\"value\":$2}" -o /dev/null; }

echo "=== RESTORE LADDER: ${TOK} tokens, nonce=$NONCE ==="
knob disk_restore true; knob disk_store_paused false
echo "  store ON, restore ON"

python3 - "$TOK" "$NONCE" <<'PY'
import json, sys
t, n = int(sys.argv[1]), sys.argv[2]
unit = (f" {n} alpha bravo charlie delta echo foxtrot golf hotel india juliet "
        "kilo lima mike november oscar papa quebec romeo sierra tango.")
need = int(t * 3.27)
json.dump({"model":"claude-opus-5","max_tokens":8,"temperature":0,"stream":False,
           "messages":[{"role":"user","content":(unit*(need//len(unit)+1))[:need]}]},
          open("/tmp/ladder-req.json","w"))
PY

drop() {
  local n=1
  for i in $(seq 1 60); do n=$(inflight); [ "$n" = "0" ] && break; sleep 5; done
  [ "$n" = "0" ] || { echo "    NOT DROPPING: $n in flight"; return 1; }
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" -o /dev/null
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' -o /dev/null
  sleep 3
  local line
  line=$(docker logs --since 90s "$C" 2>&1 | grep -o "released [0-9]*/[0-9]* manager(s), pool free blocks [0-9]* -> [0-9]*, reset [A-Z]*" | tail -1)
  echo "    drop: ${line:-NO LOG LINE}"
  case "$line" in *"reset OK"*) return 0;; *) return 1;; esac
}

pass() {
  local label="$1" h0 h1 r0 r1 w0 w1 b a t0 t1
  b=$(kv); h0=$(hits); r0=$(d2g); w0=$(g2d)
  t0=$(date +%s%N)
  curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
       --data-binary @/tmp/ladder-req.json > /tmp/ladder-$label.json
  t1=$(date +%s%N)
  sleep 20   # let the stores settle so `stored` is not undercounted
  a=$(kv); h1=$(hits); r1=$(d2g); w1=$(g2d)
  echo "$b" > /tmp/l-b.json; echo "$a" > /tmp/l-a.json
  python3 - "$label" "$t0" "$t1" "$h0" "$h1" "$r0" "$r1" "$w0" "$w1" <<'PY'
import json, sys
label, t0, t1, h0, h1, r0, r1, w0, w1 = sys.argv[1:10]
f = lambda x: float(x) if x not in ("", None) else 0.0
b = json.load(open('/tmp/l-b.json'))['disk']
a = json.load(open('/tmp/l-a.json'))['disk']
try:
    d = json.load(open('/tmp/ladder-%s.json' % label)); u = d['usage']
    pt = u.get('prompt_tokens') or 0
except Exception as e:
    print("  %-10s FAILED -- %s" % (label, str(e)[:60])); raise SystemExit(0)
sb = (b.get('sched') or {}); sa = (a.get('sched') or {})
print("  %-10s wall=%7.1fs  tok=%9s  restored=%9s (%.1f%%)  disk->gpu=%9s  gpu->disk=%9s"
      % (label, (int(t1)-int(t0))/1e9, '{:,}'.format(pt),
         '{:,.0f}'.format(f(h1)-f(h0)), 100*(f(h1)-f(h0))/pt if pt else 0,
         '{:,.0f}B'.format(f(r1)-f(r0)), '{:,.0f}B'.format(f(w1)-f(w0))))
print("             keys indexed +%-7s  jobs created %+d  left open %+d  reports %+d"
      % ('{:,}'.format((a.get('stored') or 0)-(b.get('stored') or 0)),
         (sa.get('job_counter') or 0)-(sb.get('job_counter') or 0),
         (sa.get('jobs_open') or 0)-(sb.get('jobs_open') or 0),
         ((sa.get('arrival') or {}).get('job_ids_seen') or 0)
         - ((sb.get('arrival') or {}).get('job_ids_seen') or 0)))
PY
}

echo "--- A) COLD ---";      pass cold
echo "--- B) drop ---";      drop || echo "    (drop failed; the next pass is not a restore test)"
echo "--- C) RESTORE 1 ---"; pass restore1
echo "--- D) drop ---";      drop || true
echo "--- E) RESTORE 2 ---"; pass restore2

echo "=== final ==="
kv | python3 -c "
import json,sys; d=json.load(sys.stdin); s=d['disk'].get('sched',{})
print('  index %s keys | jobs_open %s | blocks fenced %s' % (d['disk']['present'], s.get('jobs_open'), s.get('blocks_with_pending_jobs')))
print('  arrival:', s.get('arrival'))"
curl -s -m 10 "$API/metrics" | awk '/^vllm:num_preemptions_total\{/{print "  preempt", $2; exit}'
knob disk_store_paused true
echo "  (store paused again; restore left ON)"
echo LADDER-DONE

#!/usr/bin/env bash
# STORE AND RESTORE TOGETHER AT 700K -- the condition real traffic actually has.
#
# *** EVERY 700K MEASUREMENT SO FAR HAD THE STORE PATH PAUSED. *** That was the
# right way to measure a read (a read measured beside a live write is a
# measurement about contention), and it means 16s/12s describes a condition a
# real conversation never sees: a live turn restores its prefix WHILE storing
# the new blocks.
#
# So: fresh boot, store ON, drive heavy storing with a FRESH 700K nonce, wait
# until the store handler is demonstrably busy, THEN fire the stored 700K prompt
# so the restore lands into real contention. The restore must be an early
# request against an empty GPU cache, which is why this needs its own boot and
# no drop.
#
# This is the heaviest thing here: ~1.4M tokens of KV against a 3.38M pool, and
# ~45 GB/rank of writes in flight, exercising load_ops_max, load_inflight_max
# and the staging split at once.
#
# READ IT AS:
#   completes fast      -> the 16s/12s result survives real traffic
#   completes slowly    -> usable, but concurrent storing costs the prize, which
#                          is the argument for store admission control
#   faults              -> 16s/12s is a laboratory number and the honest cap
#                          stays at 176K
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
WARM_BODY=/tmp/kvscale-body.json      # the SAME body the 12s run restored
D=~/kvdiag/both-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 300 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
m(){ curl -s -m 30 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
busy(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print(-1); raise SystemExit
t=0
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskStoreHandler':
            for f in ('jobs_open','writes_open'):
                x=h.get(f)
                if isinstance(x,int) and not isinstance(x,bool): t+=x
print(t)" 2>/dev/null || echo -1; }
hb(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        o.append('r%s.%s files=%s sat=%s' % (r.get('rank'), h.get('cls','?')[4:9],
                                             h.get('files'), h.get('saturations')))
print(' | '.join(o))" 2>/dev/null || echo unreadable; }
# BOTH nodes -- a head-only Xid probe reported "no faults" about a run that
# killed a worker on the other node.
xid(){ local h w
  h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (" || echo 0)
  w=$(ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo -1)
  echo "head=$h worker=$w"; }

[ -s "$WARM_BODY" ] || { say "the stored body is missing -- run kvscale.sh build first"; exit 1; }
say "warm body: $(wc -c < "$WARM_BODY") bytes sha $(sha256sum "$WARM_BODY" | cut -c1-16)"
python3 - > /tmp/both-fresh.json <<'PY'
import json, time
w = "mu nu xi omicron pi rho sigma tau "
nonce = "both-fresh-%d" % int(time.time())
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + (w * 110000)[:3580000]}]},
          open("/dev/stdout", "w"))
PY
say "fresh body: $(wc -c < /tmp/both-fresh.json) bytes (a nonce nothing can have stored)"

( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
( while true; do printf '%s ' "$(date +%H:%M:%S)"
    awk '/^MemAvailable:|^SwapFree:/{sub(/:$/,"",$1); printf "%s=%s ", $1, $2}' /proc/meminfo
    echo; sleep 5; done ) > "$D/mem.txt" 2>&1 & MEM=$!
trap 'kill $LOG $MEM 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }

# The winning configuration, plus the STORE ON -- that is the whole variable.
knob load_ops_max 2048
knob load_inflight_max 1
knob disk_restore 1
knob disk_store_paused 0
knob gpu_cache_drop_allowed 0
knob disk_budget_gb 1000
X0=$(xid)
say "Xid before: $X0"
say "handlers:   $(hb)"

say "=== fire the FRESH 700K to drive heavy storing ==="
curl -s -o /dev/null -m 2400 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' --data @/tmp/both-fresh.json & FRESH=$!
ok=0
for i in $(seq 1 300); do b=$(busy); [ "$b" != "0" ] && [ "$b" != "-1" ] && { ok=$b; break; }; sleep 1; done
say "store busy confirmed: $ok units  ($(hb))"
[ "$ok" != "0" ] || say "*** STORE NEVER BUSY -- this run tests NOTHING about contention ***"

say "=== NOW the restore, into real contention ==="
H0=$(m external_prefix_cache_hits_total); t=$(date +%s)
resp=$(curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @"$WARM_BODY")
WALL=$(( $(date +%s) - t ))
TOK=$(echo "$resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
H1=$(m external_prefix_cache_hits_total)
say ""
say "  RESTORE UNDER A LIVE 700K STORE: wall=${WALL}s tokens=$TOK"
say "  external hits: $H0 -> $H1"
say "  reference: same restore with the store PAUSED = 12s and 16s"
wait $FRESH 2>/dev/null
say "  after:      $(hb)"
say "  preemptions: $(m num_preemptions_total)"
say "  Xid: $X0 -> $(xid)"
say "  engine: $(alive)"
say "  MemAvailable min: $(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/mem.txt") kB"
sleep 3
docker logs --since 60m "$C" > "$D/engine.log" 2>&1
knob disk_store_paused 1
knob disk_restore 0
say "evidence: $D"
echo "KVBOTH-DONE wall=${WALL}s tokens=$TOK"

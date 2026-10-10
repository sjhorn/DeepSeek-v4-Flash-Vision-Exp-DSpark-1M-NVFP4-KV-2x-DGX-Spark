#!/usr/bin/env bash
# WHICH KNOB IS LOAD-BEARING: load_ops_max or load_inflight_max?
#
# The safe operating point is ops_max=2048 + inflight_max=1, and the 700K prize
# (26s under a live store, 12s quiet) was measured there. What is NOT known is
# which of the two bounds is doing the work -- the Xid 13 evidence conflates
# them, because "861 keys unbounded" meant both big batches AND many in flight.
#
# THE ARITHMETIC MAKES THIS SEPARABLE. refs_per_group peaks at 62, so
# ops_max=2048 caps ONE submission at ~33 blocks / 2,048 copy descriptors --
# far under the faulting bracket of (13,888, 15,872] descriptors per call.
# inflight_max bounds CONCURRENT submissions instead. So holding ops_max at
# 2048 and raising inflight asks exactly one question:
#
#   survives -> the per-CALL batch is the limit; inflight is free, and raising
#               it is the available speed-up on an already-good number
#   faults   -> concurrency matters on its own, the safe point stays at 1, and
#               the fault surface is genuinely two-variable
#
# QUIET ON PURPOSE: the store stays PAUSED, because this file's own rule is that
# a read path measured beside a live write measures the pool, not the read.
# One variable per run.
#
# ABORTS ON THE FIRST FAULT. A worker kill costs a 6-minute recovery and needs
# `down` on BOTH nodes, so there is no value in walking into a second one.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
BODY=/tmp/kvscale-body.json
D=~/kvdiag/inflight-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
m(){ curl -s -m 30 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 300 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
# BOTH nodes. A head-only probe once reported "no new faults" about a run that
# killed a worker on the other node.
xid(){ local h w
  h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (" || echo 0)
  w=$(ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo -1)
  echo "$h/$w"; }
inflight(){ curl -s -m 30 "$STATS/live" 2>/dev/null | python3 -I -c "
import json,sys
try: print(int(json.load(sys.stdin).get('count') or 0))
except Exception: print(-1)" 2>/dev/null || echo -1; }
jobs_open(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
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
loadsat(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskLoadHandler':
            o.append('r%s sat=%s inflight_max=%s ops_max=%s' % (r.get('rank'),
                h.get('saturations'), h.get('inflight_max'), h.get('ops_max')))
print(' | '.join(o) or 'none')" 2>/dev/null || echo unreadable; }
drop(){
  local n j line
  for i in $(seq 1 60); do n=$(inflight); [ "$n" = "0" ] && break; sleep 5; done
  [ "$n" = "0" ] || { say "REFUSING to drop: $n request(s) in flight"; return 1; }
  for i in $(seq 1 60); do j=$(jobs_open); [ "$j" = "0" ] && break; sleep 5; done
  [ "$j" = "0" ] || { say "REFUSING to drop: transfers not drained (jobs=$j; -1 is UNREADABLE, not zero)"; return 1; }
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" >/dev/null
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' -o /dev/null
  sleep 3
  line=$(docker logs --since 90s "$C" 2>&1 \
    | grep -o "reset [A-Z]*" | tail -1)
  case "$line" in *"reset OK"*) return 0 ;; *) say "the drop did NOT reset (${line:-no log line})"; return 1 ;; esac
}

[ -s "$BODY" ] || { say "the 700K body is missing -- run kvscale.sh build first"; exit 1; }
( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }

knob disk_store_paused 1        # ONE VARIABLE. The read path, alone.
knob disk_restore 1
knob load_ops_max 2048          # held FIXED across every arm -- that is the point
knob gpu_cache_drop_allowed 1
X0=$(xid)
say "=== ops_max held at 2048; sweeping inflight_max. Xid before: $X0 (head/worker) ==="
printf "  %-10s %-7s %-10s %-12s %s\n" arm wall tokens hits Xid

for IM in 1 2 4; do
  knob load_inflight_max "$IM"
  drop || { say "inflight=$IM: NO DROP -- skipping (a GPU hit would be a fake fast wall)"; continue; }
  H0=$(m external_prefix_cache_hits_total); t=$(date +%s)
  resp=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' --data @"$BODY")
  W=$(( $(date +%s) - t ))
  TOK=$(echo "$resp" | python3 -I -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
  H1=$(m external_prefix_cache_hits_total)
  X=$(xid)
  printf "  %-10s %-7s %-10s %-12s %s\n" "inflight=$IM" "${W}s" "$TOK" "$(python3 -I -c "
try: print(int(float('$H1')-float('$H0')))
except Exception: print('?')")" "$X"
  say "             $(loadsat)"
  if [ "$X" != "$X0" ]; then
    say "*** NEW Xid AT inflight=$IM ($X0 -> $X) -- ABORTING THE SWEEP."
    say "    So concurrency IS load-bearing independently of the batch size,"
    say "    and the safe operating point stays at inflight_max=1."
    knob load_inflight_max 1; knob disk_restore 0; knob gpu_cache_drop_allowed 0
    say "engine: $(alive)"; exit 9
  fi
  [ "$TOK" = "FAILED" ] && { say "*** the request FAILED at inflight=$IM -- aborting"; break; }
done

# back to the known-good point whatever happened
knob load_inflight_max 1
knob disk_restore 0
knob gpu_cache_drop_allowed 0
say "=== done. Xid: $X0 -> $(xid)   engine: $(alive) ==="
say "evidence: $D"
echo "KVINFLIGHT-DONE"

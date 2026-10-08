#!/usr/bin/env bash
# HUNT THE Xid. Methodical, and it STOPS on the first fault so the evidence
# survives -- the two faults so far were found hours later with the state gone.
#
# Known: Xid 32 at 08:57 (slots=32) and Xid 13 at 17:38 (slots up to 256), on a
# boot where the offload went live, after three weeks with none. So the suspect
# is the offload path, not the pool size, and the factors worth separating are
# TRANSFER VOLUME and CONCURRENCY.
#
# Arms, each a fixed token budget so volume is comparable:
#   A  1 client  x large   -- volume, no concurrency
#   B  5 clients x small   -- concurrency, same total volume
#   C  5 clients x large   -- both
# Every arm logs Xid count, our refusal counter, the ledger ranges and the fence
# before and after. A refusal firing would mean OUR indices were the cause.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
knob(){ curl -s -m 20 -X POST "$API/kv/knob" -H 'Content-Type: application/json' -d "{\"name\":\"$1\",\"value\":$2}" -o /dev/null; }
api(){ curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/v1/models"; }
xid(){ journalctl -k 2>/dev/null | grep -icE "Xid" || echo 0; }
inflight(){ curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d",(r+w)}'; }

probe(){ # $1 label  $2 nclients  $3 tokens-each
  local lab="$1" n="$2" tok="$3"
  for i in $(seq 1 "$n"); do
    python3 - "$tok" "xid-$lab-$i-$(date +%s%N)" "$i" <<'PY'
import json, sys
t, nonce, i = int(sys.argv[1]), sys.argv[2], sys.argv[3]
unit = (f" {nonce} alpha bravo charlie delta echo foxtrot golf hotel india "
        "juliet kilo lima mike november oscar papa quebec romeo sierra tango.")
need = int(t * 3.27)
json.dump({"model":"claude-opus-5","max_tokens":8,"temperature":0,
           "messages":[{"role":"user","content":(unit*(need//len(unit)+1))[:need]}]},
          open("/tmp/xid-req-%s.json" % i, "w"))
PY
  done
  for i in $(seq 1 120); do [ "$(inflight)" = "0" ] && break; sleep 5; done
  local x0 t0
  x0=$(xid); t0=$(date +%s%N)
  for i in $(seq 1 "$n"); do
    ( curl -s -m 2400 -X POST "$API/v1/chat/completions" \
        -H 'Content-Type: application/json' --data-binary @/tmp/xid-req-$i.json \
        -o /tmp/xid-resp-$i.json -w "%{http_code} %{time_total}\n" > /tmp/xid-t-$i.txt ) &
  done
  wait
  local t1; t1=$(date +%s%N)
  sleep 25
  local x1; x1=$(xid)
  echo "  --- $lab: ${n} client(s) x ${tok} tok ---"
  python3 - "$lab" "$t0" "$t1" "$n" <<'PY'
import glob, json, sys
lab,t0,t1,n = sys.argv[1:5]
codes, times, toks = [], [], 0
for fn in sorted(glob.glob('/tmp/xid-t-*.txt')):
    try:
        c, t = open(fn).read().split(); codes.append(c); times.append(float(t))
    except Exception: pass
for fn in sorted(glob.glob('/tmp/xid-resp-*.json')):
    try: toks += json.load(open(fn))['usage']['prompt_tokens']
    except Exception: pass
print("      wall=%.1fs  http=%s  slowest=%.1fs  tokens=%s"
      % ((int(t1)-int(t0))/1e9, ",".join(sorted(set(codes))) or "none",
         max(times) if times else 0, '{:,}'.format(toks)))
PY
  curl -s -m 25 "$API/kv/workers" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('      /kv/workers unreachable'); raise SystemExit
for r in d.get('ranks',[]):
    for h in r.get('handlers',[]):
        if h.get('cls')=='DiskStoreHandler':
            l=h.get('ledger') or {}
            print('      r%s refused_bounds=%s errors=%s transfers=%s bid_range=%s slot_range=%s gpu_rows=%s staging_rows=%s'
                  % (r['rank'], h.get('refused_bounds'), h.get('errors'),
                     l.get('transfers'), l.get('block_id_range'),
                     l.get('slot_range'), h.get('gpu_rows'), h.get('staging_rows')))" 2>/dev/null
  curl -s -m 20 "$STATS/kv" 2>/dev/null | python3 -c "
import json,sys
try: s=json.load(sys.stdin)['disk'].get('sched',{})
except Exception: print('      /kv unreachable'); raise SystemExit
print('      fence: jobs_open=%s blocks=%s   reports=%s' % (s.get('jobs_open'),
      s.get('blocks_with_pending_jobs'), (s.get('arrival') or {}).get('job_ids_seen')))" 2>/dev/null
  echo "      api=$(api)   Xid lines $x0 -> $x1"
  if [ "$x1" != "$x0" ] || [ "$(api)" != "200" ]; then
    echo "  *** FAULT DETECTED in $lab -- capturing and STOPPING ***"
    journalctl -k --since "-10min" 2>/dev/null | grep -iE "Xid" | tail -8 | sed 's/^/      /'
    /tmp/kvdiag.sh capture "xidhunt-$lab" 2>&1 | tail -2
    return 1
  fi
  return 0
}

echo "=== Xid hunt. store ON, restore ON, slots=256 ==="
knob disk_store_paused false; knob disk_restore true; knob staging_slots 256
echo "  Xid before: $(xid)   api=$(api)"
# Arms are selectable, so a re-run after a fix does not have to repeat an arm
# that already passed -- arm A (volume, no concurrency) ran clean in 144.1s with
# the fence fully drained, so re-running it costs 2.5 minutes and proves nothing.
ARMS="${ARMS:-A B C}"
case " $ARMS " in *" A "*) probe "A-volume-1x200k"  1 200000 || exit 1 ;; esac
case " $ARMS " in *" B "*) probe "B-conc-5x40k"     5 40000  || exit 1 ;; esac
case " $ARMS " in *" C "*) probe "C-both-5x200k"    5 200000 || exit 1 ;; esac
echo "=== no fault reproduced in three arms ==="
echo XIDHUNT-DONE

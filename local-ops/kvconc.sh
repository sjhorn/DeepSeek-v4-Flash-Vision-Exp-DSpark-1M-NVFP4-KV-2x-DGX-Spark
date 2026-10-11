#!/usr/bin/env bash
# STORE AND RESTORE CONCURRENTLY, SMALLEST FIRST -- the variable the ladder could
# not reach.
#
# WHY THE LADDER WAS NOT ENOUGH. kvladder arm B ran 15 restores with the store
# "live" and reported 15/15 clean -- and the store wrote ONE FILE in the whole
# arm. Restoring an already-stored prefix has nothing new to write, and 8
# generated tokens do not fill a 256-token group-0 block, so the condition under
# test barely existed. A clean result from a test whose condition never occurred
# is not evidence, which is this repo's own rule about asking what makes the
# number non-zero before reading a zero as success.
#
# So: a FRESH prefix (never stored, so the store must really work) laid down
# WHILE a WARM prefix (already on disk) is restored. Both at the same size, and
# small first -- a 50K cold prefill is ~30s against 430-795s for 700K, so the
# small rungs buy many repeats for the price of one big one.
#
# IT REFUSES TO REPORT A RUNG WHERE THE STORE WAS NEVER BUSY. That is the exact
# failure kvboth.sh had: it printed an 11s wall for a run whose store wrote
# nothing, which reads as a contention result to anyone skimming.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
SRC=/tmp/kvscale-body.json
RUNGS="${RUNGS:-25000 50000 100000 200000}"
REPEATS="${REPEATS:-3}"
CPT=5.111
D=~/kvdiag/conc-$(date +%m%d-%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
m(){ curl -s -m 30 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
xid(){ local h w
  h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (")
  w=$(ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo -1)
  echo "$h/$w"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 120 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' 2>/dev/null; }
sbusy(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
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
sfiles(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskStoreHandler':
            print(h.get('files')); raise SystemExit
print(-1)" 2>/dev/null || echo -1; }
allidle(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
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
drop(){
  local n line
  for i in $(seq 1 60); do n=$(allidle); [ "$n" = "0" ] && break; sleep 5; done
  [ "$n" = "0" ] || { say "    REFUSING to drop: outstanding=$n"; return 1; }
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" >/dev/null
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' -o /dev/null
  sleep 2
  line=$(docker logs --since 45s "$C" 2>&1 | grep -oE "reset [A-Z]+" | tail -1)
  case "$line" in *"reset OK"*) return 0 ;; *) return 1 ;; esac
}

[ -s "$SRC" ] || { say "missing $SRC"; exit 1; }
( docker logs -f --since 1s "$C" > "$D/engine.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }
knob disk_store_paused 0
knob disk_restore 1
knob gpu_cache_drop_allowed 1
X0=$(xid)
say "=== CONCURRENT store + restore. Xid before: $X0 ==="
say "    rungs: $RUNGS   repeats: $REPEATS"
printf "    %-8s %-4s %-9s %-7s %-10s %-8s %s\n" rung try store-busy wall off-disk s-files Xid
FAULTED=0
for TOK in $RUNGS; do
  CH=$(python3 -I -c "print(int($TOK * $CPT))")
  # the WARM body: a truncation of the known-stored prefix
  python3 -I - "$SRC" "$CH" > "$D/warm-$TOK.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["messages"][0]["content"] = d["messages"][0]["content"][:int(sys.argv[2])]
d["max_tokens"] = 8
json.dump(d, open("/dev/stdout", "w"))
PY
  for TRY in $(seq 1 "$REPEATS"); do
    # the FRESH body: same filler so the token count matches by construction
    # (the chars-per-token ratio is a property of the VOCABULARY, and assuming
    # otherwise once produced a 1,048,569-token prompt and an HTTP 400)
    python3 -I - "$SRC" "$CH" "$TOK-$TRY-$(date +%s)" > "$D/fresh-$TOK-$TRY.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
body = d["messages"][0]["content"].split(" ", 1)[1][:int(sys.argv[2])]
d["messages"][0]["content"] = "conc-%s %s" % (sys.argv[3], body)
d["max_tokens"] = 8
json.dump(d, open("/dev/stdout", "w"))
PY
    drop || { say "    rung $TOK try $TRY: no drop -- skipped"; continue; }
    F0=$(sfiles)
    # fire the FRESH prefill: this is what makes the store do real work
    ( curl -s -o "$D/fresh-resp.json" -w '%{http_code}' -m 1800 -X POST \
        "$API/v1/chat/completions" -H 'Content-Type: application/json' \
        --data @"$D/fresh-$TOK-$TRY.json" > "$D/fresh-code" ) &
    FP=$!
    BUSY=0
    for i in $(seq 1 240); do
      b=$(sbusy); [ "$b" != "0" ] && [ "$b" != "-1" ] && { BUSY=$b; break; }
      if [ -s "$D/fresh-code" ]; then
        c=$(cat "$D/fresh-code")
        [ "$c" != "200" ] && { say "    rung $TOK try $TRY: fresh request http=$c -- aborting rung"; break; }
      fi
      sleep 1
    done
    if [ "$BUSY" = "0" ]; then
      say "    rung $TOK try $TRY: *** STORE NEVER BUSY -- this try measures NOTHING, not reported ***"
      wait $FP 2>/dev/null; continue
    fi
    H0=$(m external_prefix_cache_hits_total); t=$(date +%s)
    code=$(curl -s -o "$D/warm-resp.json" -w '%{http_code}' -m 1800 -X POST \
      "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @"$D/warm-$TOK.json")
    W=$(( $(date +%s) - t ))
    H1=$(m external_prefix_cache_hits_total)
    OFF=$(python3 -I -c "
try: print(int(float('$H1')-float('$H0')))
except Exception: print('?')")
    X=$(xid); F1=$(sfiles)
    printf "    %-8s %-4s %-9s %-7s %-10s %-8s %s%s\n" "$TOK" "$TRY" "$BUSY" "${W}s" "$OFF" \
      "$((F1 - F0))" "$X" "$([ "$X" != "$X0" ] && echo '  *** NEW FAULT ***')$([ "$code" != "200" ] && echo "  http=$code")"
    wait $FP 2>/dev/null
    if [ "$X" != "$X0" ] || [ "$code" != "200" ]; then
      FAULTED=1
      say ""
      say "    *** FAULTED: rung $TOK try $TRY (http=$code, Xid $X0 -> $X) ***"
      say "    --- THE LEDGER ---"
      grep -E "LEDGER DUMP|ledger " "$D/engine.log" 2>/dev/null | tail -34 | sed 's/^/      /'
      say "    --- kernel ---"
      journalctl -k -b 2>/dev/null | grep "Xid (" | tail -2 | sed 's/^/      /'
      break 2
    fi
  done
done
knob gpu_cache_drop_allowed 0
knob disk_store_paused 1
say ""
[ "$FAULTED" = "0" ] && say "=== CLEAN at every rung with the store DEMONSTRABLY busy ==="
say "    engine: $(alive)   Xid: $X0 -> $(xid)"
say "evidence: $D"
echo "KVCONC-DONE faulted=$FAULTED"

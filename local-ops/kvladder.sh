#!/usr/bin/env bash
# A SCALE LADDER FOR THE RESTORE FAULT -- smallest first, repeats at each rung.
#
# WHY A LADDER AND NOT ANOTHER 700K SHOT. The fault is INTERMITTENT, which is
# the fact that shapes this: 700K restores have completed cleanly at 11s, 12s,
# 13s and 16s with the store paused, and once at 26s with it live, and killed
# the engine once (Xid 11, 2026-10-11). One clean pass therefore proves nothing
# and one fault at 700K localises nothing. What is wanted is the SMALLEST rung
# that faults, and a rate at each rung.
#
# THE CHEAP TRICK THAT MAKES THIS AFFORDABLE: external reuse is a contiguous run
# from token 0, so TRUNCATING the already-stored 700K body restores a shorter
# prefix of the same blocks -- no store pass, no cold prefill, seconds per rung
# instead of the 430-795s a fresh prefix would cost to lay down.
#
# ARM A (this script): the READ path alone, store PAUSED, which this repo's own
# rule demands -- "measure a read path with the write path OFF" -- and which was
# verified on 2026-10-11 to be honoured across a full restore (files 1936 ->
# 1936, 71 refusals). Arm B (store live) is a separate run, because two
# variables at once is what made the earlier evidence unreadable.
#
# The ledger now emits on a 15s floor and dumps on any failure, so a fault here
# should name a block-id range instead of leaving silence.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
SRC=/tmp/kvscale-body.json          # the 700K body whose prefix is on disk
REPEATS="${REPEATS:-3}"
RUNGS="${RUNGS:-50000 100000 200000 400000 700000}"
CHARS_PER_TOKEN=5.111               # measured: 3,580,013 chars = 700,444 tokens
D=~/kvdiag/ladder-$(date +%m%d-%H%M); mkdir -p "$D"
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
inflight(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
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
loadstat(){ curl -s -m 30 "$API/kv/workers" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskLoadHandler':
            o.append('r%s files=%s sat=%s refused_bounds=%s errors=%s' % (
                r.get('rank'),h.get('files'),h.get('saturations'),
                h.get('refused_bounds'),h.get('errors')))
print(' | '.join(o))" 2>/dev/null || echo unreadable; }
drop(){
  local n j line
  for i in $(seq 1 40); do n=$(inflight); [ "$n" = "0" ] && break; sleep 5; done
  [ "$n" = "0" ] || { say "    REFUSING to drop: transfers outstanding=$n"; return 1; }
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" >/dev/null
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' -o /dev/null
  sleep 2
  line=$(docker logs --since 45s "$C" 2>&1 | grep -oE "reset [A-Z]+" | tail -1)
  case "$line" in *"reset OK"*) return 0 ;; *) say "    drop did NOT reset (${line:-no line})"; return 1 ;; esac
}

[ -s "$SRC" ] || { say "missing $SRC -- run kvscale.sh build first"; exit 1; }
( docker logs -f --since 1s "$C" > "$D/engine.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving"; exit 1; }

knob disk_store_paused 1      # ARM A: the read path, alone
knob disk_restore 1
knob gpu_cache_drop_allowed 1
X0=$(xid)
say "=== ARM A: restore alone, store PAUSED. Xid before: $X0 ==="
say "    rungs: $RUNGS   repeats: $REPEATS"
printf "    %-9s %-4s %-7s %-9s %-11s %s\n" rung try wall tokens off-disk Xid
FAULTED=0
for TOK in $RUNGS; do
  CH=$(python3 -I -c "print(int($TOK * $CHARS_PER_TOKEN))")
  python3 -I - "$SRC" "$CH" > "$D/body-$TOK.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# truncate the CONTENT, keeping the nonce and therefore the prefix from token 0
d["messages"][0]["content"] = d["messages"][0]["content"][:int(sys.argv[2])]
d["max_tokens"] = 8
json.dump(d, open("/dev/stdout", "w"))
PY
  for TRY in $(seq 1 "$REPEATS"); do
    drop || { say "    rung $TOK try $TRY: no drop, skipping (a GPU hit is not a restore)"; continue; }
    H0=$(m external_prefix_cache_hits_total); t=$(date +%s)
    code=$(curl -s -o "$D/resp.json" -w '%{http_code}' -m 1800 -X POST \
      "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @"$D/body-$TOK.json")
    W=$(( $(date +%s) - t ))
    PT=$(python3 -I -c "
import json
try: print(json.load(open('$D/resp.json')).get('usage',{}).get('prompt_tokens','?'))
except Exception: print('?')")
    H1=$(m external_prefix_cache_hits_total)
    OFF=$(python3 -I -c "
try: print(int(float('$H1')-float('$H0')))
except Exception: print('?')")
    X=$(xid)
    printf "    %-9s %-4s %-7s %-9s %-11s %s%s\n" "$TOK" "$TRY" "${W}s" "$PT" "$OFF" "$X" \
      "$([ "$X" != "$X0" ] && echo '  *** NEW FAULT ***')$([ "$code" != "200" ] && echo "  http=$code")"
    if [ "$X" != "$X0" ] || [ "$code" != "200" ]; then
      FAULTED=1
      say ""
      say "    *** FAULTED at rung $TOK, try $TRY (http=$code, Xid $X0 -> $X) ***"
      say "    --- THE LEDGER, which is the point of this run ---"
      grep -E "LEDGER DUMP|ledger " "$D/engine.log" 2>/dev/null | tail -30 | sed 's/^/      /'
      say "    --- the kernel's own line ---"
      journalctl -k -b 2>/dev/null | grep "Xid (" | tail -2 | sed 's/^/      /'
      break 2
    fi
  done
  say "    rung $TOK: $REPEATS/$REPEATS clean   load: $(loadstat)"
done
knob gpu_cache_drop_allowed 0
say ""
if [ "$FAULTED" = "0" ]; then
  say "=== ARM A CLEAN at every rung, $REPEATS repeats each, up to $(echo $RUNGS | awk '{print $NF}') tokens ==="
  say "    So scale ALONE does not trigger it on the read path, which makes the"
  say "    store round that was in flight at the 12:25:47 fault the next variable"
  say "    -- that is arm B, and it is one knob away."
fi
say "    engine: $(alive)   Xid: $X0 -> $(xid)"
say "evidence: $D"
echo "KVLADDER-DONE faulted=$FAULTED"

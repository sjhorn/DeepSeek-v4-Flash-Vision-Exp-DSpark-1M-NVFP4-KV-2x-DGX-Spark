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
knobval(){ curl -s -m 30 "$API/kv" | python3 -I -c "
import json,sys
k=(json.load(sys.stdin).get('knobs') or {}).get('$1')
print('unreadable' if k is None else k.get('value'))" 2>/dev/null || echo unreadable; }
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
# *** DERIVE THE FRESH BODY FROM THE WARM ONE -- same filler bytes, nonce
# *** swapped. My first version wrote its own filler,
# "mu nu xi omicron pi rho sigma tau " against the warm body's
# "alpha beta gamma delta epsilon zeta eta theta ". Same 3.58 MB, but the
# shorter words tokenise denser -- 3.41 chars/token against 5.11 -- so the
# "700K" fresh prompt was 1,048,569 tokens and the engine refused it with
# HTTP 400 for exceeding max_model_len. That is the chars-per-token error
# from the first scale run arriving a second time: I corrected the ratio for
# ONE vocabulary and then assumed the byte count carried to another.
# Swapping only the nonce makes the two bodies the same token count BY
# CONSTRUCTION, with no ratio to get wrong -- and block 0 still differs, so
# nothing of the fresh prompt can be on disk.
python3 - "$WARM_BODY" > /tmp/both-fresh.json <<'PYBODY'
import json, sys, time
d = json.load(open(sys.argv[1]))
c = d["messages"][0]["content"]
d["messages"][0]["content"] = "both-fresh-%d %s" % (int(time.time()), c.split(" ", 1)[1])
d["max_tokens"] = 8
json.dump(d, open("/dev/stdout", "w"))
PYBODY
say "fresh body: $(wc -c < /tmp/both-fresh.json) bytes (same filler, new nonce)"
# a byte-size sanity check: the two must match within the nonce's length, or
# the derivation silently did something else
FW=$(wc -c < "$WARM_BODY"); FF=$(wc -c < /tmp/both-fresh.json)
DIFF=$(( FW > FF ? FW - FF : FF - FW ))
[ "$DIFF" -lt 64 ] || { say "*** fresh body differs from warm by $DIFF bytes -- derivation is wrong"; exit 1; }

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
    | grep -o "released [0-9]*/[0-9]* manager(s), pool free blocks [0-9]* -> [0-9]*, reset [A-Z]*" | tail -1)
  say "drop: ${line:-NO LOG LINE FOUND}"
  case "$line" in *"reset OK"*) return 0 ;; *) say "*** the drop did NOT reset -- the next pass is NOT a restore test"; return 1 ;; esac
}

# *** THE GPU MUST HAVE FORGOTTEN THE WARM PREFIX. *** The run before this one
# restored all 2,758 files into GPU memory, so without a drop the warm prompt
# is a GPU hit: fast wall, zero disk reads, and a number that looks like a
# brilliant contention result while measuring nothing.
say "=== drop the GPU prefix cache (the disk index is untouched) ==="
knob gpu_cache_drop_allowed 1
drop || { say "*** NO DROP -- aborting rather than measuring a GPU hit"; knob gpu_cache_drop_allowed 0; exit 4; }
# straight back off: nothing in the concurrent phase below may drop a cache
# while transfers are in flight, which is the 2026-10-09 worker kill.
knob gpu_cache_drop_allowed 0

say "=== fire the FRESH 700K to drive heavy storing ==="
# *** READ ITS STATUS. *** This was `-o /dev/null` with no %{http_code}, so
# the HTTP 400 above was silent: the busy-wait simply timed out, and the run
# went on to measure a restore against a completely idle store while believing
# it had a 700K prefill in flight. A request whose status nobody reads is not a
# request you may claim anything about.
rm -f /tmp/both-fresh-code
( code=$(curl -s -o "$D/fresh-resp.json" -w '%{http_code}' -m 2400 \
    -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' --data @/tmp/both-fresh.json)
  echo "$code" > /tmp/both-fresh-code ) & FRESH=$!
# fail fast on a rejection rather than waiting out the 300s busy loop
for _ in $(seq 1 15); do
  [ -s /tmp/both-fresh-code ] || { sleep 1; continue; }
  fc=$(cat /tmp/both-fresh-code)
  [ "$fc" = "200" ] && break
  say "*** THE FRESH REQUEST WAS REFUSED: http=$fc"
  say "    There is no store load to contend with, so this run can measure"
  say "    nothing. Reason the engine gave:"
  head -c 400 "$D/fresh-resp.json" | sed 's/^/      /'; echo
  exit 2
done
ok=0
for i in $(seq 1 300); do b=$(busy); [ "$b" != "0" ] && [ "$b" != "-1" ] && { ok=$b; break; }; sleep 1; done
say "store busy confirmed: $ok units  ($(hb))"
# Refusing to measure beats measuring the wrong thing: the previous run
# printed this warning and then reported an 11s wall anyway, which reads as a
# contention result to anyone skimming.
if [ "$ok" = "0" ] || [ "$ok" = "-1" ]; then
  say "*** STORE NEVER BUSY (busy=$ok) -- ABORTING."
  say "    fresh request status: $(cat /tmp/both-fresh-code 2>/dev/null || echo 'still running')"
  say "    store paused knob:    $(knobval disk_store_paused)"
  say "    policy store live:    $(curl -s -m 30 "$API/kv" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("policy",{}).get("disk_store_live","unreadable"))' 2>/dev/null || echo unreadable)"
  say "    worker store files:   $(hb)"
  exit 3
fi

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

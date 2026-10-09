#!/usr/bin/env bash
# Reproduce Xid 32 with the fault made ATTRIBUTABLE, then stop.
#
# *** TWO EVENTS, BOTH ~4s AFTER A gpu_cache_epoch BUMP, ON DIFFERENT RANKS. ***
# 2026-10-09 11:50 (worker) and 17:07 (head). Reading the code exhausted what
# it could say: the load path's slot lifecycle is correct (slots return only in
# get_finished, after the inner copy completes), check_bounds precedes every
# submit, the load path chunks symmetrically with the store, and upstream
# records NO block ids for a load job -- so there is nothing our pending-blocks
# guard could have read, which is also why it never fired.
#
# So: reproduce it with CUDA_LAUNCH_BLOCKING=1, which reports the failure AT
# the offending launch instead of at the next synchronisation. That is the
# difference between a traceback naming the kernel and one naming whatever ran
# next -- and both previous tracebacks named the latter.
#
# *** CAPTURES AND STOPS. Never recovers. *** Two crashes today were diagnosed
# only because somebody happened to be watching; recovery is a separate,
# explicit command, run after a human has looked.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-60000}"
NONCE="${2:-xid32-$(date +%s)}"
# drain (safe, the operating procedure) | nodrain (the crash condition)
MODE="${3:-drain}"
D=~/kvdiag/xid32-$MODE-$(date +%H%M)

say(){ echo "  $*"; }
engine(){ curl -s -o /dev/null -w '%{http_code}' -m 120 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('  knob %-26s ok=%s ranks=%s' % ('$1', d.get('ok'),
      [(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]))"; }
inflight(){ curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d", (r+w)}'; }
jobs_open(){ curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}).get('sched') or {}
print(-1 if not d.get('available') else int(d.get('jobs_open') or 0)+int(d.get('blocks_with_pending_jobs') or 0))" 2>/dev/null || echo -1; }

mkdir -p "$D"
say "=== MODE=$MODE  TOK=$TOK  NONCE=$NONCE ==="

# *** NOTHING HAS EVER MEASURED MEMORY AT A FAULT, and the log looks like it
# *** does. offload.py:153 prints "watch MemAvailable and SwapFree" when the
# O_DIRECT shim installs, and that advice line is the ONLY thing in the whole
# engine log containing either word -- so grepping the two crash captures for
# them returns a hit, from the sentence telling somebody to go and look.
# Nothing went and looked. I read that hit as evidence and it was my own prose.
#
# It matters because the memory hypothesis is the only one that fits all six
# GPU faults: Xid 32 on BOTH nodes with different channels and different intr
# fields, plus three Xid 13s with "Data deaddead" and no drop anywhere near
# them. NVIDIA attributes Xid 32 to driver error or SYSTEM MEMORY CORRUPTION,
# and on a GB10 the GPU and the CPU share physical RAM -- so dropping O_DIRECT
# (page cache now in the write path), a 256-slot pinned staging buffer and a
# 1000 GB budget are all claims on the same pool, on a box measured at 1.49%
# MemAvailable with NO OOM net on either node.
#
# A sample every 2s into a file that survives the container, so the question is
# answerable from the evidence rather than re-run.
( while true; do
    printf '%s ' "$(date +%H:%M:%S)"
    # sub() strips the colon: /proc/meminfo keys are "MemAvailable:", so
    # emitting $1 verbatim gives "MemAvailable:=123" and the summary's
    # /^MemAvailable=/ can never match -- it would print ABSENT for every run,
    # reporting absence for a measurement that WAS taken. My synthetic fixture
    # wrote the key without the colon, so it could not express the real format.
    awk '/^MemAvailable:|^SwapFree:|^Cached:|^Dirty:|^Writeback:/{sub(/:$/,"",$1); printf "%s=%s ", $1, $2}' /proc/meminfo
    echo
    sleep 2
  done ) > "$D/meminfo.log" 2>&1 &
MEMPID=$!
trap 'kill $MEMPID 2>/dev/null' EXIT
# *** STREAM FROM BEFORE THE EXPERIMENT. *** `docker logs` after the fact is
# how two tracebacks were nearly lost today.
nohup docker logs -f --since 0 "$C" > "$D/engine-stream.log" 2>&1 &
STREAM_PID=$!
trap 'kill $STREAM_PID 2>/dev/null' EXIT

say "=== engine must be SERVING (a real completion, not /v1/models) ==="
[ "$(engine)" = "200" ] || { say "not serving -- refusing"; exit 1; }
say "completion 200"

say "=== is CUDA_LAUNCH_BLOCKING actually in the container? ==="
blk=$(docker exec -i "$C" sh -c 'echo "${CUDA_LAUNCH_BLOCKING:-unset}"' 2>/dev/null)
say "CUDA_LAUNCH_BLOCKING=$blk"
[ "$blk" = "1" ] || say "*** WARNING: not set -- the fault will be ASYNCHRONOUS and this run buys little"

say "=== arm the tier AND the drop gate (deliberately, this is the dangerous lever) ==="
knob disk_store_paused 0
knob disk_restore 1
knob disk_budget_gb 1000
knob gpu_cache_drop_allowed 1

say "=== store a prefix of ~$TOK tokens, nonce=$NONCE ==="
python3 - "$TOK" "$NONCE" > /tmp/xid32-body.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]},
          sys.stdout)
PY
t0=$(date +%s)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 1800 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' --data @/tmp/xid32-body.json)
say "cold pass: http=$code in $(( $(date +%s) - t0 ))s"

# MODE is the whole experiment. The first run of this script drained BOTH
# requests and transfers before dropping, and it did not reproduce -- but it
# also had CUDA_LAUNCH_BLOCKING=1 set and the pending-blocks fix live, so three
# variables moved at once and the clean result attributed to none of them.
#
# "nodrain" is the condition the two real crashes actually had: the drop lands
# while stores are still in flight. That matters because the drop frees GPU
# blocks and resets the prefix cache, and an in-flight transfer holds block ids
# the drop cannot see -- upstream records NO block ids for a load job at all,
# which is exactly why the in-flight guard (a store-only dict) can never fire
# for one.
#
# A drain is the safe operating procedure. This mode exists to break it on
# purpose, with the log already streaming.
if [ "$MODE" = "nodrain" ]; then
  say "=== NOT DRAINING, deliberately -- what is in flight at the drop ==="
  say "inflight=$(inflight)  jobs_open=$(jobs_open)   <- the overlap window"
else
  say "=== drain requests AND transfers before the drop ==="
  for i in $(seq 1 60); do n=$(inflight); [ "$n" = "0" ] && break; sleep 5; done
  for i in $(seq 1 60); do j=$(jobs_open); [ "$j" = "0" ] && break; sleep 5; done
  say "inflight=$(inflight)  jobs_open=$(jobs_open)"
fi

say "=== THE DROP (the lever that crashed it twice) ==="
curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" -o /dev/null
curl -s -o /dev/null -m 300 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
sleep 3
docker logs --since 1m "$C" 2>&1 | grep -E "prefix cache drop|drop REFUSED" | tail -1 | cut -c1-200 | sed 's/^/    /'

say "=== THE RESTORE -- same prefix, GPU cache empty, disk index intact ==="
t1=$(date +%s)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 1800 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' --data @/tmp/xid32-body.json)
say "restore pass: http=$code in $(( $(date +%s) - t1 ))s"

say "=== CAPTURE, whatever happened. Nothing is restarted. ==="
sleep 3
docker logs --since 30m "$C" > "$D/engine.log" 2>&1
ssh -o BatchMode=yes spark-da08 "docker logs --since 30m $C" > "$D/worker.log" 2>&1
journalctl -k --since "-30m" > "$D/kernel-head.log" 2>&1
ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-30m\"" > "$D/kernel-worker.log" 2>&1
say "evidence in $D"
say "Xid head=$(grep -c 'Xid' "$D/kernel-head.log")  worker=$(grep -c 'Xid' "$D/kernel-worker.log")"
say "engine now: $(engine)"
say "memory over the run (MemAvailable kB): min=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/meminfo.log")  SwapFree min=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^SwapFree=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/meminfo.log")"
say "meminfo samples: $(wc -l < "$D/meminfo.log")"
echo "XID32-DONE"

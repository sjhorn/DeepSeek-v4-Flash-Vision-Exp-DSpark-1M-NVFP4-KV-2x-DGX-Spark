#!/usr/bin/env bash
# Drop + restore, N times, to get a REPRODUCTION RATE for the Xid 32 fault.
#
# *** TWO SINGLE RUNS PROVED NOTHING AND I NEARLY REPORTED THEM AS A FIX. ***
# Both crashes dropped with `reset OK` and faulted ~4s later, and two clean
# single cycles since then say only that the rate is below 1-in-1 -- which was
# never in question. Two faults across roughly a dozen historical drops is a
# rate of order 15%, so a single clean cycle is the expected outcome of a
# broken system and carries almost no information. A rate needs repetition.
#
# The head traceback names gpu_model_runner.py:3803 synchronize_input_prep,
# which is the ASYNC SCHEDULING input-prep sync point, and this engine runs
# async_scheduling=True. A step prepared against the pre-reset block state is
# the kind of thing that surfaces exactly there, asynchronously, seconds later.
# This harness exists to make that testable by giving it something to fail on.
#
# STOPS AT THE FIRST FAULT and captures. Never recovers: recovery is a separate
# explicit command, after a human has read the evidence.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
TOK="${1:-20000}"
CYCLES="${2:-8}"
NONCE="${3:-droploop-$(date +%s)}"
D=~/kvdiag/droploop-$(date +%H%M)
mkdir -p "$D"

say(){ echo "  $*"; }
engine(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
inflight(){ curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d", (r+w)}'; }
jobs_open(){ curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}).get('sched') or {}
print(-1 if not d.get('available') else int(d.get('jobs_open') or 0)+int(d.get('blocks_with_pending_jobs') or 0))" 2>/dev/null || echo -1; }
# Count Xid EVENTS, not lines: one event logs 1-4 lines depending on the code,
# so a line count reads as several faults where there was one.
xid(){ journalctl -k --since "-6h" 2>/dev/null | grep "Xid (" \
  | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l; }
xid_remote(){ ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-6h\" 2>/dev/null | grep 'Xid (' \
  | sed -E 's/^(\w+ [0-9]+ [0-9:]+).*Xid \(PCI:[^)]*\): ([0-9]+).*/\1|\2/' | sort -u | wc -l"; }

# *** THE SCHEDULER-SIDE COUNT IS THE WRONG QUANTITY TO DRAIN ON, which is
# *** what let cycle 1 at 100K kill the head on 2026-10-09 17:51.
# `jobs_open` above reads /kv (the scheduler's `cs._jobs`). Measured during the
# guard verification: with that at 0, each rank still held
# DiskStoreHandler.jobs_open=1 and writes_open=5 -- five store rounds whose file
# writes were unfinished, so their staging slots were still held and the GPU
# copies behind them were live. Draining the scheduler and dropping is exactly
# the sequence that faulted.
#
# /kv/workers is on the CONTROL PLANE (:8888). Querying :9199 answers
# {"error":"not found"}, whose missing "ranks" key renders as zero ranks and
# therefore as "both workers idle" -- so this reports unreadable rather than 0.
wbusy(){ curl -s -m 15 "$API/kv/workers" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
if 'ranks' not in d: print(-1); raise SystemExit
rs=d.get('ranks') or []
if not rs: print(-1); raise SystemExit
tot=0
for r in rs:
    hs=r.get('handlers')
    if hs is None: print(-1); raise SystemExit
    for h in hs:
        for f in ('jobs_open','writes_open','reads_open'):
            v=h.get(f)
            if isinstance(v,int) and not isinstance(v,bool): tot+=v
print(tot)" 2>/dev/null || echo -1; }

# Stream from BEFORE the experiment: `docker logs` after the fact destroyed two
# tracebacks today.
( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) &
LOGPID=$!
( while true; do printf '%s ' "$(date +%H:%M:%S)"
    awk '/^MemAvailable:|^SwapFree:|^Cached:|^Dirty:|^Writeback:/{sub(/:$/,"",$1); printf "%s=%s ", $1, $2}' /proc/meminfo
    echo; sleep 2; done ) > "$D/meminfo.log" 2>&1 &
MEMPID=$!
trap 'kill $LOGPID $MEMPID 2>/dev/null' EXIT

say "=== TOK=$TOK CYCLES=$CYCLES NONCE=$NONCE -> $D ==="
[ "$(engine)" = "200" ] || { say "engine not serving; refusing to start"; exit 1; }
knob disk_store_paused 0; knob disk_restore 1
knob disk_budget_gb 1000; knob gpu_cache_drop_allowed 1

python3 - "$TOK" "$NONCE" > /tmp/droploop-body.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY

X0=$(xid); W0=$(xid_remote)
say "Xid events before: head=$X0 worker=$W0"
say "cold pass: http=$(curl -s -o /dev/null -w '%{http_code}' -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/droploop-body.json)"

FAULTED=0
for c in $(seq 1 "$CYCLES"); do
  for i in $(seq 1 60); do [ "$(inflight)" = "0" ] && break; sleep 2; done
  for i in $(seq 1 60); do j=$(jobs_open); [ "$j" = "0" ] && break; sleep 2; done
  # Drain the WORKERS too, and report if it never reaches zero rather than
  # falling through and dropping anyway -- a loop that proceeds on timeout is
  # how the 17:51 drop happened with a guard sitting right there.
  wok=0
  for i in $(seq 1 120); do w=$(wbusy); [ "$w" = "0" ] && { wok=1; break; }; sleep 2; done
  [ "$wok" = "1" ] || say "cycle $c: WORKERS NEVER DRAINED (last=$(wbusy)) -- the drop should now REFUSE"
  dv=$(curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('refused') or ('ok' if d.get('ok') else 'other'))" 2>/dev/null || echo parse-error)
  [ "$dv" = "ok" ] || say "cycle $c: drop REFUSED ($dv) -- the guard is doing its job; this cycle tests no restore"
  # gpu_cache_epoch is acted on at the edge in new_step_starts(), so a bump on
  # an idle engine does NOTHING until some request produces a scheduler step.
  # This tiny request is that step, not a smoke test.
  curl -s -o /dev/null -m 300 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'
  t1=$(date +%s)
  rc=$(curl -s -o /dev/null -w '%{http_code}' -m 1800 -X POST "$API/v1/chat/completions" \
    -H 'Content-Type: application/json' --data @/tmp/droploop-body.json)
  X=$(xid); W=$(xid_remote); E=$(engine)
  mem=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/meminfo.log")
  say "cycle $c/$CYCLES: restore=$rc in $(( $(date +%s) - t1 ))s  engine=$E  Xid head=$X(+$((X-X0))) worker=$W(+$((W-W0)))  MemAvail min=${mem}kB"
  if [ "$X" != "$X0" ] || [ "$W" != "$W0" ] || [ "$E" != "200" ]; then
    say "*** FAULT ON CYCLE $c -- capturing and stopping, NOT recovering ***"; FAULTED=$c; break
  fi
done

sleep 3
docker logs --since 60m "$C" > "$D/engine.log" 2>&1
ssh -o BatchMode=yes spark-da08 "docker logs --since 60m $C" > "$D/worker.log" 2>&1
journalctl -k --since "-60m" > "$D/kernel-head.log" 2>&1
ssh -o BatchMode=yes spark-da08 "journalctl -k --since \"-60m\"" > "$D/kernel-worker.log" 2>&1
say "evidence in $D"
if [ "$FAULTED" = "0" ]; then
  say "RESULT: $CYCLES/$CYCLES cycles clean. That bounds the rate; it does not prove zero."
else
  say "RESULT: FAULTED on cycle $FAULTED of $CYCLES."
fi
say "memory: MemAvailable min=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/meminfo.log")kB  SwapFree min=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^SwapFree=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/meminfo.log")kB"
echo "DROPLOOP-DONE"

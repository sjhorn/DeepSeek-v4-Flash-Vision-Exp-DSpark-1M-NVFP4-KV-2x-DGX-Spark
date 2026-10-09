#!/usr/bin/env bash
# kvnumpy.sh -- make the numpy-scalar producer NAME ITSELF.
#
# *** THE BUG IT HUNTS. *** `vllm/v1/serial_utils.py`'s enc_hook handles
# np.ndarray but NOT numpy SCALARS, so one numpy integer in EngineCoreOutputs
# raises inside process_output_sockets. That kills the THREAD, not the engine:
# requests complete, the core goes idle on an empty input queue, clients hang
# for ever and nothing logs an error. I read it as a memory ceiling for an
# evening. kvmgr's shim coerces it losslessly, so it is no longer fatal -- but
# the PRODUCER is still unidentified and should be fixed at source.
#
# *** WHAT MAKES IT HARD IS THE RATE, NOT THE DETECTION. *** Two occurrences in
# a whole evening (value=1, then value=39 -- a varying small count), and two
# deliberate reproduction attempts produced none. So this does not wait for the
# coercion: kvmgr now SCANS the object being encoded, sampled across the
# process's life, and names the field path before any coercion happens. This
# script's job is to generate the traffic that scan needs to see.
#
# THE TRAFFIC MATTERS, because the suspected path is the STORE side:
# page_size_bytes -> Chunk.nbytes -> plan_nbytes -> TransferResult.transfer_size
# -> KVConnectorStats -> the output socket. So the disk tier must be ARMED, and
# a mix of prompt sizes and concurrency is more likely to move whichever count
# is the offender than one shape repeated.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
ROUNDS="${1:-6}"

say(){ echo "  $*"; }
engine(){ curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }

# *** THE TIER MUST BE ON OR THE SUSPECTED PATH NEVER RUNS. *** kvdiag's
# `recover` deliberately writes the flags file SAFE (store paused, restore off),
# so a post-restart run starts with the store path disabled. Arming is hot, and
# the per-rank answer is read rather than assumed -- a worker-side knob set by
# editing the file reaches rank 0 only.
arm(){
  for kv in disk_store_paused=0 disk_restore=1 disk_budget_gb=400; do
    curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${kv%%=*}\",\"value\":\"${kv#*=}\"}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
rk=[(r.get('rank'), r.get('now'), r.get('ok')) for r in d.get('ranks',[])]
print('  knob %-20s ok=%s ranks=%s' % ('${kv%%=*}', d.get('ok'), rk))"
  done
}

found(){ docker logs --since 60m "$C" 2>&1 | grep -c "numpy scalar PRODUCER" || true; }

say "=== engine check (a REAL completion, not /v1/models) ==="
say "completion = $(engine)"
say "=== arming the disk tier, hot, both ranks ==="
arm
say "=== traffic: $ROUNDS rounds of mixed shapes and concurrency ==="
# Varied sizes and widths. The scan samples at most once every 5s, so the run
# needs to last minutes rather than seconds -- a burst that finishes inside one
# sampling interval gets one look at one object.
for r in $(seq 1 "$ROUNDS"); do
  for n in 1 2 3; do
    toks=$(( 2000 * r * n ))
    python3 - "$toks" "$r-$n" > /tmp/kvnumpy-body-$n.json <<'PY'
import json, sys
n = int(sys.argv[1]); tag = sys.argv[2]
# A nonce per round so nothing is answered purely from the GPU cache, and the
# store path therefore has work to do.
body = {"model": "claude-opus-5", "max_tokens": 8,
        "messages": [{"role": "user",
                      "content": "ref %s " % tag + ("alpha beta gamma delta " * (n // 4 + 1))[:n*4]}]}
json.dump(body, open("/dev/stdout", "w"))
PY
    curl -s -o /dev/null -m 300 -X POST "$API/v1/chat/completions" \
      -H 'Content-Type: application/json' --data @/tmp/kvnumpy-body-$n.json &
  done
  wait
  f=$(found)
  say "round $r: $(curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys; d=json.load(sys.stdin).get('disk') or {}
print('present=%s stored=%s lookup=%s hit=%s'%(d.get('present'),d.get('stored'),d.get('lookup'),d.get('hit')))")  PRODUCER lines=$f"
  if [ "$f" != "0" ]; then
    say "*** THE PRODUCER NAMED ITSELF ***"
    docker logs --since 60m "$C" 2>&1 | grep -A1 "numpy scalar PRODUCER" | head -10
    break
  fi
done

say "=== final ==="
say "PRODUCER lines in the log: $(found)"
docker logs --since 60m "$C" 2>&1 | grep -E "coerced a numpy scalar|numpy scalar PRODUCER" | head -5
say "DONE"

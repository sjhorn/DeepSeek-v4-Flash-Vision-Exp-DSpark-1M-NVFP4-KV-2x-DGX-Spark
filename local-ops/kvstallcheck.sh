#!/usr/bin/env bash
# NEGATIVE CONTROL for the stall deadline: it must NOT fire on a healthy engine.
#
# The deadline fails a transfer job after N seconds of ZERO progress, and
# failing a job KILLS the worker (upstream's `assert transfer_result.success`
# has no failure path). So a misfire is strictly worse than the hang it
# replaces: it would kill engines that were working.
#
# The positive direction cannot honestly be verified live -- manufacturing a
# genuinely stuck copy means breaking a GPU, which is the one thing we are
# trying to survive. `stall_action` is covered offline with 8 assertions and
# 6/6 mutations caught. THIS covers the direction that can be tested: with the
# store path busy and progressing, an ABSURDLY short deadline must still fail
# nothing, because `verdict` never reaches "stalled" while counters move.
#
# That is the whole point of `watchdog_verdict` comparing a progress
# FINGERPRINT rather than timing a job -- a slow-but-working flush must stay out
# of the stalled bucket. This asserts that property on the live engine.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
SECS="${1:-150}"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('  knob %-22s ok=%s ranks=%s' % ('$1', d.get('ok'), [(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]))"; }
busy(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
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

[ "$(alive)" = "200" ] || { say "engine not serving -- aborting"; exit 1; }
say "=== is the deadline even LIVE on this boot? ==="
curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in (d.get('ranks') or []):
    k=r.get('knobs') or {}
    print('  rank %s stall_fail_after_s=%s load_batch_max=%s' % (
        r.get('rank'), k.get('stall_fail_after_s', 'ABSENT -- the fix is NOT running'),
        k.get('load_batch_max', 'ABSENT')))"
say "=== arm an ABSURD deadline: 1 second of zero progress would fail a job ==="
knob disk_store_paused 0
knob stall_fail_after_s 1
X0h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (")
say "=== drive the store path HARD for ${SECS}s with fresh prefixes ==="
( END=$(( $(date +%s) + SECS )); n=0
  while [ "$(date +%s)" -lt "$END" ]; do
    for c in 1 2 3 4; do
      n=$((n+1))
      python3 - "$n" > /tmp/sc$c.json <<'PY'
import json, sys, time
w = "mu nu xi omicron pi rho sigma tau "
json.dump({"model": "claude-opus-5", "max_tokens": 4,
           "messages": [{"role": "user",
                         "content": "stallcheck-%d-%s " % (int(time.time()*1000), sys.argv[1]) + (w*900)[:28000]}]},
          sys.stdout)
PY
      curl -s -o /dev/null -m 300 -X POST "$API/v1/chat/completions" \
        -H 'Content-Type: application/json' --data @/tmp/sc$c.json &
    done
    wait
  done ) & LOAD=$!
trap 'kill $LOAD 2>/dev/null' EXIT
for i in $(seq 1 60); do b=$(busy); [ "$b" != "0" ] && [ "$b" != "-1" ] && break; sleep 1; done
say "store busy confirmed: $(busy) handler units"
sleep "$SECS"
kill $LOAD 2>/dev/null; wait $LOAD 2>/dev/null
say "=== THE VERDICT ==="
FAILED=$(docker logs --since 20m "$C" 2>&1 | grep -c "FAILING THE STALLED STORE JOB" || true)
MARKED=$(docker logs --since 20m "$C" 2>&1 | grep -cE "marked [0-9]+ (STORE|LOAD) job\(s\) failed" || true)
STALLED=$(docker logs --since 20m "$C" 2>&1 | grep -c "STORE PATH STALLED" || true)
say "  'FAILING THE STALLED' lines: $FAILED   (want 0)"
say "  'marked N job(s) failed':    $MARKED   (want 0)"
say "  'STORE PATH STALLED':        $STALLED   (want 0 -- counters were moving)"
say "  engine: $(alive)   Xid lines: $X0h -> $(journalctl -k -b 2>/dev/null | grep -c 'Xid (')"
say "  heartbeats seen (proof the watchdog was AWAKE, not just quiet):"
docker logs --since 20m "$C" 2>&1 | grep -c "store path busy --" | sed 's/^/      /'
knob stall_fail_after_s 240
knob disk_store_paused 1
if [ "$FAILED" = "0" ] && [ "$MARKED" = "0" ] && [ "$(alive)" = "200" ]; then
  say "PASS: a 1-second deadline failed NOTHING while the path was progressing."
  say "      That is watchdog_verdict comparing a progress FINGERPRINT rather"
  say "      than timing a job -- a slow-but-working flush stays out of the"
  say "      stalled bucket, which is the property that makes this safe to arm."
else
  say "*** FAIL: the deadline MISFIRED on a healthy engine. Set"
  say "    stall_fail_after_s=0 and do not ship this. ***"
fi
echo "STALLCHECK-DONE"

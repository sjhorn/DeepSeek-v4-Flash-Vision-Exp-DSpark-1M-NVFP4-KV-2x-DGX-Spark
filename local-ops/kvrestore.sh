#!/usr/bin/env bash
# Restore AT SCALE, with no restart.
#
# The lever that makes this possible is gpu_cache_epoch: block_pool.reset_prefix_cache()
# is the POOL's reset, not the connector's, so the GPU forgets and the disk remembers.
# The sequencing is the part that bit us: the drop is acted on in new_step_starts(), so
# the engine must be IDLE when the epoch is bumped (otherwise live requests still hold
# block refs and patch7's `num_used_blocks != 1` gate REFUSES) and must then be given
# one tiny request to produce the scheduler step that performs it.
#
# Never restarts anything.
set -u
API=http://127.0.0.1:8888
# *** /kv IS NOT ONE VIEW. *** The control plane is attached to the engine's own
# app, so GET /kv on :8888 is answered by the API SERVER process -- which holds no
# manager, so `disk` comes back null there. The index lives in the ENGINE CORE,
# and :9199 is the only listener inside it. Knob POSTs are fine on :8888 because
# those fan out over collective_rpc; READS of state must use STATS.
STATS=http://127.0.0.1:9199
TOK="${1:-200000}"
NONCE="${2:-kvscale-fixed-v1}"
OUT=/tmp/kvrestore-out
mkdir -p "$OUT"

api()  { curl -s -o /dev/null -w '%{http_code}' -m 10 "$API/v1/models"; }
# *** NO TRAILING SPACE AFTER THE METRIC NAME. *** Every vLLM series carries a
# label block, so the name is followed by `{engine="0",...}` and not by a space:
# /^vllm:num_requests_running /  matches NOTHING, silently, and an empty
# inflight() then makes `[ "$n" = "0" ]` false forever -- drain() spins its full
# deadline and drop() refuses to fire, so the "restore" pass runs against a GPU
# that still holds the prefix and a GPU hit gets reported as a disk restore.
inflight() { curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d", (r+w)}'; }
hits() { curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_hits_total\{/{print $2; exit}'; }
queries() { curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_queries_total\{/{print $2; exit}'; }
d2g()  { curl -s -m 10 "$API/metrics" | awk '/transfer_type="DSPARK_DISK_to_GPU"/{print $2; exit}'; }
g2d()  { curl -s -m 10 "$API/metrics" | awk '/transfer_type="GPU_to_DSPARK_DISK"/{print $2; exit}'; }
preempt() { curl -s -m 10 "$API/metrics" | awk '/^vllm:num_preemptions_total\{/{print $2; exit}'; }
kvd()  { curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('disk',{})
print(' '.join('%s=%s'%(k,d.get(k)) for k in ('present','lookup','hit','stored','skipped_present','manifest_writes')))"; }
swap() { awk '/SwapFree/{printf "%.2fGB", $2/1048576}' /proc/meminfo; }

knob() { curl -s -m 20 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
          -d "{\"name\":\"$1\",\"value\":$2}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rk=[(r.get('rank'),r.get('now')) for r in d.get('ranks',[])]
print('    knob %s -> api_server=%s ranks=%s'%('$1', d.get('api_server',{}).get('now'), rk))"; }

build() {
  python3 - "$TOK" "$NONCE" <<'PY'
import json, sys
t, n = int(sys.argv[1]), sys.argv[2]
unit = (f" {n} alpha bravo charlie delta echo foxtrot golf hotel india juliet "
        "kilo lima mike november oscar papa quebec romeo sierra tango.")
need = int(t * 3.27)
text = (unit * (need // len(unit) + 1))[:need]
json.dump({"model":"claude-opus-5","max_tokens":8,"temperature":0,"stream":False,
           "messages":[{"role":"user","content":text}]}, open("/tmp/kvscale-req.json","w"))
PY
}

# One pass. $1 = label. Prints a CSV line to $OUT/table.
pass() {
  local label="$1" h0 h1 r0 r1 t0 t1 wall
  h0=$(hits); r0=$(d2g); local w0=$(g2d)
  t0=$(date +%s%N)
  curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
       --data-binary @/tmp/kvscale-req.json > "$OUT/resp-$label.json" 2>&1
  t1=$(date +%s%N)
  h1=$(hits); r1=$(d2g); local w1=$(g2d)
  wall=$(python3 -c "print('%.1f'%(($t1-$t0)/1e9))")
  python3 - "$label" "$wall" "$h0" "$h1" "$r0" "$r1" "$w0" "$w1" <<'PY' | tee -a "$OUT/table"
import json, sys
label, wall, h0, h1, r0, r1, w0, w1 = sys.argv[1:9]
f = lambda x: float(x) if x not in ("", None) else 0.0
try:
    d = json.load(open('/tmp/kvrestore-out/resp-%s.json' % label)); u = d['usage']
    pt = u.get('prompt_tokens') or 0
    cached = (u.get('prompt_tokens_details') or {}).get('cached_tokens')
    txt = (d['choices'][0]['message'].get('content') or '')[:24].replace('\n', ' ')
except Exception as e:
    print('  %-12s FAILED after %ss -- %s' % (label, wall, str(e)[:70])); raise SystemExit(0)
print('  %-12s wall=%7ss  tok=%9s  cached=%-9s  HITS +%-8s  disk->gpu +%-9s  gpu->disk +%-9s  reply=%r'
      % (label, wall, '{:,}'.format(pt), cached,
         '{:,.0f}'.format(f(h1) - f(h0)),
         '{:,.0f}B'.format(f(r1) - f(r0)),
         '{:,.0f}B'.format(f(w1) - f(w0)), txt))
PY
}

drain() {
  # Stores are asynchronous and the FENCE is what makes them visible, so a drop
  # issued before they settle would both refuse and destroy the thing under test.
  local prev="" cur="" stable=0
  for i in $(seq 1 240); do
    cur=$(curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('disk',{}).get('stored'))" 2>/dev/null)
    [ "$cur" = "$prev" ] && stable=$((stable+1)) || stable=0
    [ "$stable" -ge 4 ] && [ "$(inflight)" = "0" ] && { echo "    stores settled at stored=$cur"; return 0; }
    prev="$cur"; sleep 5
  done
  echo "    WARNING: stores never settled (stored=$cur) -- not dropping"; return 1
}

drop() {
  # The engine MUST be idle, or live block refs make patch7 refuse.
  local n
  for i in $(seq 1 60); do n=$(inflight); [ "$n" = "0" ] && break; sleep 5; done
  [ "$n" = "0" ] || { echo "    REFUSING to drop: $n request(s) in flight"; return 1; }
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" >/dev/null
  # one tiny request IS the scheduler step that performs the drop
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' \
    -o /dev/null
  sleep 3
  local line
  line=$(docker logs --since 90s deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1 2>&1 \
         | grep -o "released [0-9]*/[0-9]* manager(s), pool free blocks [0-9]* -> [0-9]*, reset [A-Z]*" | tail -1)
  echo "    drop: ${line:-NO LOG LINE FOUND}"
  case "$line" in *"reset OK"*) return 0 ;; *) echo "    *** the drop did NOT reset -- the next pass is NOT a restore test"; return 1 ;; esac
}

echo "=== RESTORE AT SCALE: ${TOK} tokens, nonce=$NONCE ==="
echo "  api=$(api)  inflight=$(inflight)  swapfree=$(swap)  preempt=$(preempt)"
echo "  disk: $(kvd)"
: > "$OUT/table"

echo "--- enabling restore (hot, both ranks) ---"
knob disk_restore true
knob disk_store_paused false

build
echo "--- A) COLD: nothing of this prompt is on disk or in the GPU ---"
pass cold
drain

echo "--- B) drop the GPU cache, keep the disk ---"
drop || echo "  (continuing so the numbers are still recorded, but B is not a clean restore)"
echo "  disk: $(kvd)"

echo "--- C) RESTORE #1: same prompt, GPU empty, disk holds it ---"
pass restore1
drain
drop >/dev/null 2>&1 && echo "    second drop ok"

echo "--- D) RESTORE #2: convergence check at scale ---"
pass restore2

echo "=== final ==="
echo "  api=$(api)  preempt=$(preempt)  swapfree=$(swap)"
echo "  disk: $(kvd)"
# *** THIS LINE READ $API AND THE FILE'S OWN HEADER SAYS NOT TO. *** GET /kv on
# :8888 is answered by the API SERVER process, which holds no manager, so
# `groups` comes back EMPTY and ['groups'][0] raised IndexError -- after "DONE",
# so every run of this harness ended with a traceback where its conclusion
# should be. The state lives in the engine core; $STATS is the only listener in
# it. And report an absent figure rather than raising on it: a summary that
# crashes is a summary nobody reads.
curl -s -m 10 "$STATS/kv" | python3 -c "
import json, sys
try:
    gs = json.load(sys.stdin).get('groups') or []
except Exception as exc:
    print('  group0: unreadable (%s)' % exc); raise SystemExit
if not gs:
    print('  group0: no groups in the response -- wrong listener, or the '
          'manager is not installed'); raise SystemExit
g = gs[0]
print('  group0: restore_hits=%s restore_blocks=%s restore_refused=%s'
      % (g.get('restore_hits'), g.get('restore_blocks'), g.get('restore_refused')))"
echo "DONE"

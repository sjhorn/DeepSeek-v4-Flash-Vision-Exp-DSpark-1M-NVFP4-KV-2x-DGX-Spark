#!/usr/bin/env bash
# Does the restorable prefix converge to the WHOLE prompt, or plateau at a fraction?
# Measured so far: 0 -> 26,624 -> 39,936 tokens, i.e. increments of +26,624 then
# +13,312. Three points cannot tell "converging to full" from "plateauing", and the
# difference decides whether the disk tier is worth leaving on. So: drop, re-send,
# repeat, and watch the external-hit delta per pass.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
inflight() { curl -s -m 10 "$API/metrics" | awk '/^vllm:num_requests_running\{/{r=$2} /^vllm:num_requests_waiting\{/{w=$2} END{printf "%d",(r+w)}'; }
hits() { curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_hits_total\{/{print $2; exit}'; }
present() { curl -s -m 10 "$STATS/kv" | python3 -c "
import json,sys; print(json.load(sys.stdin)['disk'].get('present'))"; }

drop() {
  for i in $(seq 1 60); do [ "$(inflight)" = "0" ] && break; sleep 5; done
  curl -s -m 30 -X POST "$API/kv/drop_gpu_cache" >/dev/null
  curl -s -m 60 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"hi"}]}' -o /dev/null
  sleep 3
  docker logs --since 60s "$C" 2>&1 | grep -o "reset [A-Z]*" | tail -1
}

for n in 3 4 5 6; do
  v=$(drop)
  [ "$v" = "reset OK" ] || { echo "  pass$n: drop said '$v' -- ABORTING, this would measure the GPU"; exit 1; }
  h0=$(hits); p0=$(present); t0=$(date +%s%N)
  curl -s -m 1200 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
       --data-binary @/tmp/kvscale-req.json > /tmp/conv-$n.json
  t1=$(date +%s%N); h1=$(hits); p1=$(present)
  python3 - "$n" "$t0" "$t1" "$h0" "$h1" "$p0" "$p1" <<'PY'
import sys
n, t0, t1, h0, h1, p0, p1 = sys.argv[1:8]
d = float(h1) - float(h0)
print('  pass%s  wall=%6.1fs  restored=%9s tok (%4.1f%% of 179,622)  index present %s -> %s'
      % (n, (int(t1)-int(t0))/1e9, '{:,.0f}'.format(d), 100*d/179622, p0, p1))
PY
  # let the stores settle so the next drop is clean
  sleep 20
done
echo CONVERGE-DONE

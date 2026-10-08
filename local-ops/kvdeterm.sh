#!/usr/bin/env bash
# Is the output divergence NON-DETERMINISM or WRONG KV?
# The discriminator: run the same prompt repeatedly with the GPU cache WARM and
# the disk never touched. If the reply varies with no restore in the path at all,
# divergence is the engine's known argmax instability and says nothing about KV.
set -u
API=http://127.0.0.1:8888
for i in 1 2 3; do
  h0=$(curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_hits_total\{/{print $2; exit}')
  t0=$(date +%s%N)
  curl -s -m 600 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
       --data-binary @/tmp/kvscale-req.json > "/tmp/det-$i.json"
  t1=$(date +%s%N)
  h1=$(curl -s -m 10 "$API/metrics" | awk '/^vllm:external_prefix_cache_hits_total\{/{print $2; exit}')
  python3 - "$i" "$t0" "$t1" "$h0" "$h1" <<'PY'
import json, sys
i, t0, t1, h0, h1 = sys.argv[1:6]
d = json.load(open('/tmp/det-%s.json' % i)); u = d['usage']
c = (u.get('prompt_tokens_details') or {}).get('cached_tokens')
print('  warm#%s wall=%.1fs  cached=%s  extHITS+%d  reply=%r'
      % (i, (int(t1)-int(t0))/1e9, c, float(h1)-float(h0),
         (d['choices'][0]['message'].get('content') or '')[:40]))
PY
done

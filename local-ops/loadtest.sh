#!/usr/bin/env bash
# Concurrent load test: saturate max_num_seqs and watch KV pressure.
N=${1:-12}; MAXTOK=${2:-600}
API=http://127.0.0.1:8888/v1/chat/completions
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1

TOPICS=("the history of steam engines" "how photosynthesis works" "the fall of the Western Roman Empire"
        "how TCP congestion control works" "the geology of volcanic islands" "the development of the printing press"
        "how vaccines train the immune system" "the history of cartography" "how semiconductors are manufactured"
        "the ecology of coral reefs" "the origins of jazz" "how hydroelectric dams work")

echo "### firing $N concurrent requests, max_tokens=$MAXTOK"
start=$(date +%s)
for i in $(seq 0 $((N-1))); do
  t="${TOPICS[$((i % 12))]}"
  curl -s -m 300 $API -H "content-type: application/json" \
    -d "{\"model\":\"deepseek-v4-flash-dspark\",\"max_tokens\":$MAXTOK,\"temperature\":0.7,\"messages\":[{\"role\":\"user\",\"content\":\"Write a thorough, detailed essay about $t. Include background, key developments, and technical specifics.\"}]}" \
    -o /tmp/lt_$i.json -w "req$i http=%{http_code} time=%{time_total}s\n" >> /tmp/lt_results.txt 2>&1 &
done

# sample scheduler state while they run
echo "### sampling scheduler state"
for s in $(seq 1 40); do
  line=$(docker logs --tail 40 $C 2>&1 | grep -oE "Running: [0-9]+ reqs, Waiting: [0-9]+ reqs.*GPU KV cache usage: [0-9.]+%" | tail -1)
  [ -n "$line" ] && echo "  [$(date +%H:%M:%S)] $line"
  jobs -r > /dev/null 2>&1 || true
  if [ "$(jobs -r | wc -l)" -eq 0 ]; then break; fi
  sleep 3
done
wait
end=$(date +%s)
echo "### all requests done in $((end-start))s"

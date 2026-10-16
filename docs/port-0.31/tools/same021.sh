# the gate's tests, unchanged, against production 0.21 on :8888
B=http://127.0.0.1:8888; C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
G=/var/tmp/garble_synth; R=~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
echo "== smoke"; cd $R && CHAT_URL=$B/v1/chat/completions timeout 600 ./smoke-deepseek-v4-flash-dspark.sh 2>&1 | tail -1
echo "== single stream (400 tokens, temperature 0) x2"
for i in 1 2; do curl -s $B/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"deepseek-v4-flash-dspark","messages":[{"role":"user","content":"Write a 300-word explanation of how a hash table handles collisions."}],"max_tokens":400,"temperature":0}' -o /tmp/s$i.json -w "%{time_total}s " ; python3 -c "import json;print(json.load(open('/tmp/s$i.json'))['usage']['completion_tokens'],'tokens')"; done
docker logs --since 1m $C 2>&1 | grep -E "SpecDecoding metrics" | tail -1 | grep -oE "Mean acceptance length: [0-9.]+|Per-position acceptance rate: [0-9., ]+"
echo "== concurrency 2,4,6"; timeout 1500 python3 $R/benchmarks/keys-concurrency/bench_concurrent.py $B 2,4,6 2>&1 | tail -4
echo "== hermes synth cold N=10"; cd $G && URL=$B/v1 N=10 REQ=$G/hermes.jsonl OUT=$G/hermes-full-021.jsonl timeout 1500 python3 -I $G/hermes_full.py 2>&1 | tail -11
echo "== needle 60K N=5"; URL=$B/v1 N=5 TOKENS=60000 timeout 1500 python3 garble_synth.py needle 2>&1 | tail -6
echo "== anthropic"; API=$B python3 $G/anthcheck.py 2>&1 | tail -12
echo "== KV capacity (one request, usage %)"; bash $G/kvmeasure.sh $B $C
echo "== needle ~377K N=1"; URL=$B/v1 N=1 TOKENS=520000 SEED=11 timeout 1700 python3 garble_synth.py needle 2>&1 | tail -2
echo "== done $(date -u +%H:%M:%S)"

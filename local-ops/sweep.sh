#!/usr/bin/env bash
# Sweep max_num_seqs x max_cudagraph_capture_size; record KV pool, graph memory, throughput.
cd /home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SWEEP_OUT:-$HERE/sweep_results.tsv}"
[ -f "$OUT" ] || printf "seqs\tcap_cfg\tkv_tokens\tconcurrency\tgraph_gib\tcap_max\tn_caps\tboot_s\ttput_toks\n" > $OUT

run_one() {
  local SEQS=$1 CAPCFG=$2
  echo "=================== seqs=$SEQS cap=$CAPCFG ==================="
  sed -i "s/^MAX_NUM_SEQS=.*/MAX_NUM_SEQS=$SEQS/" .env.dspark
  sed -i "/^COMPILATION_CONFIG=/d" .env.dspark
  if [ "$CAPCFG" != "default" ]; then
    echo "COMPILATION_CONFIG='{\"max_cudagraph_capture_size\":$CAPCFG}'" >> .env.dspark
  fi
  ./stop-deepseek-v4-flash-dspark.sh >/dev/null 2>&1
  local t0=$(date +%s)
  nohup ./start-deepseek-v4-flash-dspark.sh > /tmp/sweep_start.log 2>&1 &
  # wait for ready (max 12 min)
  local ready=0
  for i in $(seq 1 144); do
    if curl -fsS -m 5 http://127.0.0.1:8888/v1/models >/dev/null 2>&1; then ready=1; break; fi
    if [ "$i" -gt 18 ]; then
      docker ps --format '{{.Names}}' | grep -q vllm-dspark || { echo "  container gone at i=$i"; break; }
    fi
    sleep 5
  done
  local boot=$(( $(date +%s) - t0 ))
  if [ "$ready" != "1" ]; then
    printf "%s\t%s\tFAILED\t-\t-\t-\t-\t%s\t-\n" "$SEQS" "$CAPCFG" "$boot" >> $OUT
    echo "  BOOT FAILED"; return 1
  fi

  local kv conc graph capmax ncaps
  kv=$(docker logs $C 2>&1 | grep -oE "GPU KV cache size: [0-9,]+" | tail -1 | grep -oE "[0-9,]+" | tr -d ,)
  conc=$(docker logs $C 2>&1 | grep -oE "Maximum concurrency for [0-9,]+ tokens per request: [0-9.]+x" | tail -1 | grep -oE "[0-9.]+x$")
  graph=$(docker logs $C 2>&1 | grep -oE "Graph capturing finished in [0-9]+ secs, took [0-9.]+ GiB" | tail -1 | grep -oE "[0-9.]+ GiB" | grep -oE "[0-9.]+")
  capmax=$(docker logs $C 2>&1 | grep -oE "'max_cudagraph_capture_size': [0-9]+" | tail -1 | grep -oE "[0-9]+")
  ncaps=$(docker logs $C 2>&1 | grep -oE "'cudagraph_capture_sizes': \[[0-9, ]+\]" | tail -1 | grep -oE "[0-9]+" | wc -l)

  # short-request throughput probe: 12 concurrent small requests
  for i in $(seq 1 12); do
    curl -s -m 240 http://127.0.0.1:8888/v1/chat/completions -H "content-type: application/json" \
      -d "{\"model\":\"deepseek-v4-flash-dspark\",\"max_tokens\":400,\"temperature\":0.7,\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed essay about topic number $i in science.\"}]}" \
      -o /dev/null >/dev/null 2>&1 &
  done
  wait
  local tput=$(docker logs --since 6m $C 2>&1 | grep -oE "Avg generation throughput: [0-9.]+ tokens/s" | grep -oE "[0-9.]+" | sort -n | tail -1)

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$SEQS" "$CAPCFG" "${kv:-?}" "${conc:-?}" "${graph:-?}" "${capmax:-?}" "${ncaps:-?}" "$boot" "${tput:-?}" >> $OUT
  echo "  kv=$kv conc=$conc graph=${graph}GiB capmax=$capmax ncaps=$ncaps boot=${boot}s tput=$tput"
}

for spec in "$@"; do
  run_one "${spec%%:*}" "${spec##*:}"
done
echo; echo "=== RESULTS ==="; column -t $OUT

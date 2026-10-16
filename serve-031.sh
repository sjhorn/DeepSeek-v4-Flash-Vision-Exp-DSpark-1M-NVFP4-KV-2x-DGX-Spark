#!/usr/bin/env bash
# Serve vLLM 0.31 (docker-compose.dspark-031.yml) on both nodes, from the head.
#   ./serve-031.sh          restart: BOTH down (and confirmed down), then worker, then head
#   ./serve-031.sh down     both down
# Settings: production's .env.dspark, then ~/dspark031.env on each node (port,
# max_model_len, KV_TRANSFER_CONFIG_031 for kvmgr 0.5.0).
#
# REFUSES unless ~/.engine-hold exists (engine-supervisor watches production's
# container, not this one: without the hold a reboot would start 0.21 beside
# 0.31) and no production container exists on either node. Back to 0.21:
#   ./serve-031.sh down && ./start-deepseek-v4-flash-dspark.sh && rm ~/.engine-hold
set -euo pipefail
E=$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark
W=192.168.0.101
C=dspark031-vllm-dspark031-1
P=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
F="-f docker-compose.dspark-031.yml"
U="env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1"
WK="$U NODE_RANK=1 HEADLESS=1 HF_CACHE=$HOME/.cache/huggingface VLLM_HOST_IP=$W docker compose --env-file $E --env-file $HOME/dspark031.env $F"
HD="$U NODE_RANK=0 HEADLESS= docker compose --env-file $E --env-file $HOME/dspark031.env $F"

[ -f ~/.engine-hold ] || { echo "refusing: no ~/.engine-hold (touch it first)"; exit 1; }
for h in local $W; do
  n=$( [ $h = local ] && docker ps -aq -f name="^${P}$" | wc -l || ssh $h "docker ps -aq -f name='^${P}$' | wc -l")
  [ "$n" = 0 ] || { echo "refusing: production container exists on $h (stop it first)"; exit 1; }
done

echo "down: head, worker"
(cd ~/dspark031 && $HD down >/dev/null 2>&1 || true)
ssh $W "cd ~/dspark031 && $WK down >/dev/null 2>&1 || true"
for h in local $W; do
  n=$( [ $h = local ] && docker ps -aq -f name="^${C}$" | wc -l || ssh $h "docker ps -aq -f name='^${C}$' | wc -l")
  [ "$n" = 0 ] || { echo "ABORT: $C still exists on $h"; exit 1; }
done
echo "both down"
[ "${1:-}" = down ] && exit 0

echo "up: worker"; ssh $W "cd ~/dspark031 && $WK up -d 2>&1 | tail -1"
echo "up: head";   (cd ~/dspark031 && $HD up -d 2>&1 | tail -1)
PORT=$(grep -E '^VLLM_PORT_031=' ~/dspark031.env | cut -d= -f2); PORT=${PORT:-18888}
T=$(date -u +%Y-%m-%dT%H:%M:%S); drop=1; t0=$(date +%s)
while ! curl -fsS --max-time 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1; do
  for h in local $W; do
    st=$( [ $h = local ] && docker inspect -f '{{.State.Status}}' $C 2>&1 || ssh $h "docker inspect -f '{{.State.Status}}' $C" 2>&1)
    [ "$st" = running ] || { echo "FAILED: $C on $h is $st"; exit 1; }
  done
  # reclaim page cache until graph capture, as the production start script does
  if [ $drop = 1 ]; then
    if docker logs --since $T $C 2>&1 | grep -c "Graph capturing finished" | grep -qv '^0$'; then drop=0
    else sync; sudo -n sysctl -qw vm.drop_caches=3 || true; ssh $W "sync; sudo -n sysctl -qw vm.drop_caches=3" >/dev/null 2>&1 || true; fi
  fi
  sleep 5
done
echo "HEALTHY on :$PORT after $(( $(date +%s) - t0 ))s"
docker logs $C 2>&1 | grep -E "GPU KV cache size|kvmgr: file_mapper base" | cut -c1-200

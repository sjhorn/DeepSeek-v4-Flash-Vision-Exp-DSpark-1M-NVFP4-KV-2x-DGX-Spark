#!/usr/bin/env bash
# Serve vLLM 0.32 (docker-compose.dspark-032.yml) on both nodes, from the head.
#   ./serve-032.sh          restart: BOTH down (and confirmed down), then worker, then head
#   ./serve-032.sh down     both down
# Settings: production's .env.dspark, then ~/dspark032.env on each node (port,
# max_model_len, KV_TRANSFER_CONFIG_032 for kvmgr 0.6.0).
#
# REFUSES unless ~/.engine-hold exists, and while another engine's container
# (0.21's, or 0.31's dspark031-vllm-dspark031-1) exists on either node. A person always holds before a restart. The one caller
# without a hold is engine-supervisor on lane 0.32 (ENGINE_LANE=0.32) doing a
# crash recovery: it passes ENGINE_SUPERVISOR=1 and never touches the hold
# (decided 2026-10-18). Back to 0.21: set the supervisor's lane back
# (~/.config/engine-supervisor.env), then
#   ./serve-032.sh down && ./start-deepseek-v4-flash-dspark.sh && rm ~/.engine-hold
set -euo pipefail
E=$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark
W=192.168.0.101
C=dspark032-vllm-dspark032-1
P=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
# every OTHER engine's container: none may exist while this one starts or stops
OTHERS="$P dspark031-vllm-dspark031-1"
F="-f docker-compose.dspark-032.yml"
U="env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1"
WK="$U NODE_RANK=1 HEADLESS=1 HF_CACHE=$HOME/.cache/huggingface VLLM_HOST_IP=$W docker compose --env-file $E --env-file $HOME/dspark032.env $F"
HD="$U NODE_RANK=0 HEADLESS= docker compose --env-file $E --env-file $HOME/dspark032.env $F"

[ -f ~/.engine-hold ] || [ "${ENGINE_SUPERVISOR:-}" = 1 ] || { echo "refusing: no ~/.engine-hold (touch it first)"; exit 1; }
for o in $OTHERS; do for h in local $W; do
  n=$( [ $h = local ] && docker ps -aq -f name="^${o}$" | wc -l || ssh $h "docker ps -aq -f name='^${o}$' | wc -l")
  [ "$n" = 0 ] || { echo "refusing: another engine's container $o exists on $h (stop it first)"; exit 1; }
done; done

echo "down: head, worker"
(cd ~/dspark032 && $HD down >/dev/null 2>&1 || true)
ssh $W "cd ~/dspark032 && $WK down >/dev/null 2>&1 || true"
for h in local $W; do
  n=$( [ $h = local ] && docker ps -aq -f name="^${C}$" | wc -l || ssh $h "docker ps -aq -f name='^${C}$' | wc -l")
  [ "$n" = 0 ] || { echo "ABORT: $C still exists on $h"; exit 1; }
done
echo "both down"
[ "${1:-}" = down ] && exit 0

echo "up: worker"; ssh $W "cd ~/dspark032 && $WK up -d 2>&1 | tail -1"
echo "up: head";   (cd ~/dspark032 && $HD up -d 2>&1 | tail -1)
PORT=$(grep -E '^VLLM_PORT_032=' ~/dspark032.env | cut -d= -f2); PORT=${PORT:-18888}
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

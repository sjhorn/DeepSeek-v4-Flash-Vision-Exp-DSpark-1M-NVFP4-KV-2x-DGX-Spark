#!/usr/bin/env bash
# vLLM 0.31 CPU (Apple container) serving Qwen3-0.6B with the whole patches-031
# set mounted over the image: anthropic protocol+serving, detokenizer, plugin.
#   apiserve.sh up | down
set -u
D=~/dev/spark/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/patches-031
SITE=/opt/venv/lib/python3.12/site-packages
case "${1:-up}" in
up)
  container system status >/dev/null 2>&1 || container system start >/dev/null
  container delete apitest >/dev/null 2>&1 || true
  container run -d --name apitest --cpus 8 --memory 16G --shm-size 4G -p 8000:8000 \
    -v "$D/anthropic_protocol.py:$SITE/vllm/entrypoints/anthropic/protocol.py:ro" \
    -v "$D/anthropic_serving.py:$SITE/vllm/entrypoints/anthropic/serving.py:ro" \
    -v "$D/detokenizer.py:$SITE/vllm/v1/engine/detokenizer.py:ro" \
    -v "$D/dspark031_plugin:/opt/dspark031:ro" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
    -e PYTHONPATH=/opt/dspark031 -e VLLM_LOGGING_LEVEL=DEBUG -e VLLM_CPU_KVCACHE_SPACE=4 \
    -e PREFIX_WATCH=1 -e CLASSIFIER_NOTHINK=1 -e TOOL_ARGS_STRICT=0 \
    vllm/vllm-openai-cpu:v0.31.0-arm64 Qwen/Qwen3-0.6B --host 0.0.0.0 --port 8000 \
    --max-model-len 8192 --enable-prefix-caching \
    --served-model-name Qwen3-0.6B claude-haiku-4-5 claude-sonnet-5 claude-opus-5 x-think-max \
    --reasoning-parser qwen3 --tool-call-parser hermes --enable-auto-tool-choice >/dev/null
  echo started ;;
down) container stop apitest >/dev/null 2>&1; container delete apitest >/dev/null 2>&1
  container system stop >/dev/null 2>&1; echo "stopped apitest and the container service" ;;
esac

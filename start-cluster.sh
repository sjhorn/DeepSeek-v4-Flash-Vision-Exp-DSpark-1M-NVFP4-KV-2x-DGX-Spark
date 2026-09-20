#!/usr/bin/env bash
# Wrapper around start-deepseek-v4-flash-dspark.sh that also:
#   1. Applies GPU clock pinning on both nodes
#   2. Starts the watchdog
#
# Usage: ./start-cluster.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"

GPU_CLOCK_MIN="${GPU_CLOCK_MIN:-300}"
GPU_CLOCK_MAX="${GPU_CLOCK_MAX:-2200}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE}"

echo "Applying GPU clock lock (${GPU_CLOCK_MIN}-${GPU_CLOCK_MAX} MHz) on head..."
sudo nvidia-smi -pm 1
sudo nvidia-smi -lgc "$GPU_CLOCK_MIN","$GPU_CLOCK_MAX"

echo "Applying GPU clock lock (${GPU_CLOCK_MIN}-${GPU_CLOCK_MAX} MHz) on worker (${WORKER_HOST})..."
ssh "$WORKER_HOST" "sudo nvidia-smi -pm 1 && sudo nvidia-smi -lgc $GPU_CLOCK_MIN,$GPU_CLOCK_MAX"

echo "Starting DSpark cluster..."
"$SCRIPT_DIR/start-deepseek-v4-flash-dspark.sh"

echo "Starting watchdog..."
# Kill any existing watchdog
pkill -f "watchdog-dspark.sh" 2>/dev/null || true
nohup "$SCRIPT_DIR/watchdog-dspark.sh" >> "$SCRIPT_DIR/watchdog.log" 2>&1 &
echo "Watchdog started (PID $!, log: $SCRIPT_DIR/watchdog.log)"

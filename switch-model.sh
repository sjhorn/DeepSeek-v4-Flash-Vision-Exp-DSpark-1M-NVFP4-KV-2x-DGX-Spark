#!/usr/bin/env bash
# switch-model.sh — switch between text-0731 and vision-exp deployments.
#
# Usage:
#   ./switch-model.sh text      # rollback to DeepSeek-V4-Flash-0731 (text only)
#   ./switch-model.sh vision    # switch to DeepSeek-V4-Flash-Vision-Exp
#   ./switch-model.sh status    # show which config is active
#
# This swaps .env.dspark only -- it does NOT restart. Restart with ./start-cluster.sh
# (or start-deepseek-v4-flash-dspark.sh), which now detects the active model and
# overlays docker-compose.vision-exp.yml by itself, syncs it to the worker, and
# preflights the four staged port files in ~/vision-stage on BOTH nodes.
set -euo pipefail
cd "$(dirname "$0")"

ENV_TEXT=".env.dspark.text-0731"
ENV_VISION=".env.dspark.vision-exp"
ENV_ACTIVE=".env.dspark"

case "${1:-status}" in
  text)
    [ -f "$ENV_TEXT" ] || { echo "❌ $ENV_TEXT not found — cannot rollback"; exit 1; }
    cp "$ENV_TEXT" "$ENV_ACTIVE"
    echo "✅ Switched to text-0731 config"
    echo "   Restart with: ./start-cluster.sh"
    ;;
  vision)
    [ -f "$ENV_VISION" ] || { echo "❌ $ENV_VISION not found"; exit 1; }
    cp "$ENV_VISION" "$ENV_ACTIVE"
    echo "✅ Switched to vision-exp config"
    echo "   Restart with: ./start-cluster.sh    (vision overlay is applied automatically)"
    echo "   Override the auto-detection with COMPOSE_VISION=0 / COMPOSE_VISION=1 if needed."
    ;;
  status)
    if [ ! -f "$ENV_ACTIVE" ]; then
      echo "⚠️  No .env.dspark — not configured"
    elif grep -q 'Vision-Exp' "$ENV_ACTIVE" 2>/dev/null; then
      echo "🔭 Active: vision-exp (DeepSeek-V4-Flash-Vision-Exp)"
      for f in ds4v_model.py ds4v_vision.py ds4v_mm.py ds4v_registry.py; do
        [ -f "$HOME/vision-stage/$f" ] || echo "   ⚠️  missing ~/vision-stage/$f on this node"
      done
    else
      echo "📝 Active: text-0731 (DeepSeek-V4-Flash-0731)"
    fi
    ;;
  *)
    echo "Usage: $0 {text|vision|status}"
    exit 1
    ;;
esac

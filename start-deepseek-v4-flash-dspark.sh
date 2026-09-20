#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.dspark.yml}"
VISION_COMPOSE_FILE="${VISION_COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.vision-exp.yml}"
VISION_STAGE_DIR="${VISION_STAGE_DIR:-$HOME/vision-stage}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-100}"
# Boot sentinel: exists for the life of this script, mtime refreshed while we
# wait. watchdog-dspark.sh skips polling (and resets its failure count) while it
# is present and fresh, so a boot this script is driving cannot be torn down by
# a watchdog that did not start it. See "Boot sentinel" below.
BOOT_SENTINEL="${BOOT_SENTINEL:-/tmp/dspark-booting}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy .env.dspark.example to .env.dspark and edit node-specific values." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Derive the health-check URLs AFTER sourcing, so VLLM_PORT actually reaches them.
# Setting these before the source pinned them to 8888 regardless of VLLM_PORT, so a
# non-default port started the server correctly and then timed out waiting on 8888.
# An explicit API_URL/CHAT_URL from the environment still wins.
API_URL="${API_URL:-http://127.0.0.1:${VLLM_PORT:-8888}/v1/models}"
CHAT_URL="${CHAT_URL:-http://127.0.0.1:${VLLM_PORT:-8888}/v1/chat/completions}"

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE}"
: "${MASTER_ADDR:?MASTER_ADDR must be set in $ENV_FILE}"
: "${NCCL_IB_HCA:?NCCL_IB_HCA must be set in $ENV_FILE}"
: "${NCCL_SOCKET_IFNAME:?NCCL_SOCKET_IFNAME must be set in $ENV_FILE}"
: "${VLLM_HOST_IP:?VLLM_HOST_IP must be set to the head node fabric IP in $ENV_FILE}"
: "${WORKER_VLLM_HOST_IP:?WORKER_VLLM_HOST_IP must be set to the worker node fabric IP in $ENV_FILE}"

# Worker paths are needed by the vision preflight below, not just at sync time.
WORKER_DIR="${WORKER_SCRIPT_DIR:-${WORKER_DIR:-$SCRIPT_DIR}}"
WORKER_HF_CACHE="${WORKER_HF_CACHE:-${HF_CACHE:-}}"

# Vision-Exp needs a compose overlay (bind-mounts the four ported files) on TOP of the
# base compose. Selecting it by hand is the failure this block removes: switch-model.sh
# swaps in the vision .env, and a plain start would then boot with HF_OVERRIDES naming a
# multimodal class the unpatched registry does not have.
# Auto-detected from the active env; force with COMPOSE_VISION=1 / disable with 0.
if [ -z "${COMPOSE_VISION:-}" ]; then
  case "${DSPARK_MODEL:-}${HF_OVERRIDES:-}" in
    *Vision-Exp*|*DeepseekV4V*) COMPOSE_VISION=1 ;;
    *)                          COMPOSE_VISION=0 ;;
  esac
fi

COMPOSE_ARGS=(-f "$COMPOSE_FILE")
REMOTE_COMPOSE_FILES="-f docker-compose.dspark.yml"
VISION_STAGE_FILES="ds4v_model.py ds4v_vision.py ds4v_mm.py ds4v_registry.py"

if [ "$COMPOSE_VISION" = "1" ]; then
  [ -f "$VISION_COMPOSE_FILE" ] || {
    echo "COMPOSE_VISION=1 but $VISION_COMPOSE_FILE is missing." >&2; exit 1; }
  COMPOSE_ARGS+=(-f "$VISION_COMPOSE_FILE")
  REMOTE_COMPOSE_FILES="$REMOTE_COMPOSE_FILES -f docker-compose.vision-exp.yml"
  echo "Vision-Exp mode: overlaying $(basename "$VISION_COMPOSE_FILE")"

  # The overlay bind-mounts four files from $VISION_STAGE_DIR on EACH node. A file that
  # exists only on the head yields a half-patched cluster that fails deep in model load,
  # so check both sides up front and say exactly how to fix it.
  stage_missing=""
  for f in $VISION_STAGE_FILES; do
    [ -f "$VISION_STAGE_DIR/$f" ] || stage_missing="$stage_missing $f"
  done
  [ -z "$stage_missing" ] || {
    echo "Missing in $VISION_STAGE_DIR on this node:$stage_missing" >&2
    echo "Regenerate with: ./vision-exp/build-ds4v-files.sh \"$DSPARK_VLLM_IMAGE\" \"$VISION_STAGE_DIR\"" >&2
    exit 1; }

  worker_missing="$(ssh "$WORKER_HOST" "for f in $VISION_STAGE_FILES; do \
    [ -f '$VISION_STAGE_DIR'/\$f ] || printf ' %s' \$f; done" || true)"
  [ -z "$worker_missing" ] || {
    echo "Missing in $VISION_STAGE_DIR on worker ${WORKER_HOST}:$worker_missing" >&2
    echo "Regenerate THERE (files are derived from that node's image):" >&2
    echo "  ssh $WORKER_HOST 'cd $WORKER_DIR && ./vision-exp/build-ds4v-files.sh \"$DSPARK_VLLM_IMAGE\" \"$VISION_STAGE_DIR\"'" >&2
    exit 1; }
  echo "Vision stage files present on both nodes."
fi

cd "$SCRIPT_DIR"

# DSpark source patches ship inside the runtime image (recipe/overlay/), not
# as runtime bind-mounts. Launching an image that predates the current overlay
# would run stale proposer code, so verify and rebuild first.
# Skip with SKIP_OVERLAY_CHECK=1 (e.g. offline, or a deliberate old image).
if [ "${SKIP_OVERLAY_CHECK:-0}" != "1" ]; then
  IMG="${DSPARK_VLLM_IMAGE:-vllm-dspark-runtime:dspark-nvfp4-stage-c}"
  OVERLAY_DOCKERFILE="$SCRIPT_DIR/recipe/Dockerfile.dspark-runtime-overlay"
  STALE=0
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "Runtime image $IMG not present; building it."
    STALE=1
  else
    IMAGE_SUMS="$(docker run --rm --entrypoint bash "$IMG" -c \
      "sha256sum $(awk '$1 == "COPY" { printf "%s ", $3 }' "$OVERLAY_DOCKERFILE")" 2>/dev/null || true)"
    while read -r src dst; do
      want="$(sha256sum "$SCRIPT_DIR/recipe/overlay/$src" | awk '{ print $1 }')"
      have="$(printf '%s\n' "$IMAGE_SUMS" | awk -v f="$dst" '$2 == f { print $1 }')"
      if [ "$want" != "$have" ]; then
        echo "Runtime image $IMG is stale against recipe/overlay/$src; rebuilding."
        STALE=1
        break
      fi
    done < <(awk '$1 == "COPY" { print $2, $3 }' "$OVERLAY_DOCKERFILE")
  fi
  if [ "$STALE" = "1" ]; then
    "$SCRIPT_DIR/build-dspark-vllm-runtime.sh"
  fi
fi

REMOTE_WORKER_DIR="$(printf '%q' "$WORKER_DIR")"
REMOTE_COMPOSE="cd $REMOTE_WORKER_DIR && env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS COMPOSE_DISABLE_ENV_FILE=1"

echo "Syncing DSpark deployment files to ${WORKER_HOST}:${WORKER_DIR}"
ssh "$WORKER_HOST" "mkdir -p $REMOTE_WORKER_DIR"
scp "$COMPOSE_FILE" "${WORKER_HOST}:${REMOTE_WORKER_DIR}/docker-compose.dspark.yml"
scp "$ENV_FILE" "${WORKER_HOST}:${REMOTE_WORKER_DIR}/.env.dspark"

# The compose file bind-mounts these from the repo dir on EVERY node, but only the two
# files above were ever synced -- so a patch edited on the head silently ran unpatched
# on the worker.
if compgen -G "$SCRIPT_DIR/patches/anthropic_*.py" >/dev/null; then
  ssh "$WORKER_HOST" "mkdir -p $REMOTE_WORKER_DIR/patches"
  # sync ALL bind-mounted patches (anthropic_*, patch6 kv-cache-manager, patch7 dedupe, ...)
  scp "$SCRIPT_DIR"/patches/*.py "${WORKER_HOST}:${REMOTE_WORKER_DIR}/patches/"
  # THE SAME TRAP ONE LEVEL DEEPER. patches/*.py does not match a directory, and
  # the prefill collector ships as a DIRECTORY -- a module plus a .dist-info,
  # because the engine finds it through the vllm.stat_logger_plugins entry-point
  # group rather than by import. Without this the worker starts with compose
  # bind-mounts pointing at paths that do not exist, Docker helpfully creates
  # empty DIRECTORIES for them inside site-packages, and one of those is an
  # empty .dist-info that importlib.metadata then has to walk.
  if [ -d "$SCRIPT_DIR/patches/prefill_plugin" ]; then
    scp -r "$SCRIPT_DIR/patches/prefill_plugin" "${WORKER_HOST}:${REMOTE_WORKER_DIR}/patches/"
  fi
fi
if [ "$COMPOSE_VISION" = "1" ]; then
  scp "$VISION_COMPOSE_FILE" "${WORKER_HOST}:${REMOTE_WORKER_DIR}/docker-compose.vision-exp.yml"
fi

# --- Boot sentinel (local extension, not upstream) --------------------------
# WHY. The watchdog cannot tell "the engine is dead" from "the engine is not up
# yet": both are a failing /v1/models. Raising FAIL_THRESHOLD 3 -> 8 on
# 2026-09-19 bought ~480s, but a cold boot is 250-600s, so the windows still
# overlap -- and on 2026-09-20 a 407s boot reached 7 of 8, one 60s poll from the
# watchdog issuing `stop` into a live weight load. That is exactly the failure
# that boot-looped the cluster for two hours on 2026-09-19.
#
# This closes the overlap instead of widening it: while this file exists and is
# fresh, the watchdog skips its poll AND resets its failure count. The mtime is
# refreshed on every wait iteration below, so a legitimately slow boot never
# ages out -- the staleness limit is a no-progress timeout, not a boot cap. If
# this script dies, the trap removes it; if it is SIGKILLed, the watchdog
# ignores a sentinel older than its own limit (default 900s), so the blind spot
# is bounded either way.
#
# Created here, AFTER every preflight and before the first compose call, so a
# preflight failure never leaves the watchdog blinded.
: > "$BOOT_SENTINEL" 2>/dev/null \
  && echo "Boot sentinel: $BOOT_SENTINEL (watchdog will hold off while this boots)" \
  || echo "Boot sentinel: could not create $BOOT_SENTINEL -- stop the watchdog by hand." >&2

# ONE EXIT trap for both cleanups: bash keeps only the last `trap ... EXIT`, so
# the page-cache reclaim's kill had to move in here rather than install its own.
cleanup_on_exit() {
  [ -n "${DROP_PID:-}" ] && kill "$DROP_PID" 2>/dev/null
  rm -f "$BOOT_SENTINEL" 2>/dev/null
  return 0
}
trap cleanup_on_exit EXIT

echo "Starting DSpark worker on ${WORKER_HOST}..."
ssh "$WORKER_HOST" "$REMOTE_COMPOSE NODE_RANK=1 HEADLESS=1 HF_CACHE='$WORKER_HF_CACHE' VLLM_HOST_IP='$WORKER_VLLM_HOST_IP' docker compose --env-file .env.dspark $REMOTE_COMPOSE_FILES up -d"

echo "Starting DSpark head..."
COMPOSE_DISABLE_ENV_FILE=1 NODE_RANK=0 HEADLESS= docker compose --env-file "$ENV_FILE" "${COMPOSE_ARGS[@]}" up -d

# --- Startup page-cache reclaim (local extension, not upstream) -------------
# On DGX Spark the CPU, GPU, model weights and KV cache share one memory pool.
# Reading the safetensors shards during model load fills the page cache, and
# vLLM profiles free memory *after* that load to size the KV pool. Dropping the
# cache repeatedly across the load window reduces memory pressure at startup and
# shortens boot. Bounded on purpose: it stops the moment the API answers, and
# never runs while the engine is serving (during serving only ~1.5 GiB is
# reclaimable and the repeated full-cache walks are pure overhead).
# Set DROP_CACHES_ON_START=0 to disable. Requires passwordless sudo for
# `sysctl -w vm.drop_caches=3` on both nodes; skipped with a warning if absent.
DROP_CACHES_ON_START="${DROP_CACHES_ON_START:-1}"
DROP_PID=""
if [ "$DROP_CACHES_ON_START" = "1" ]; then
  if sudo -n sysctl -qw vm.drop_caches=3 2>/dev/null; then
    echo "Startup cache reclaim: active on both nodes (stops when API is ready)."
    (
      while ! curl -fsS --max-time 2 "$API_URL" >/dev/null 2>&1; do
        sync; sudo -n sysctl -qw vm.drop_caches=3 2>/dev/null || true
        ssh "$WORKER_HOST" "sync; sudo -n sysctl -qw vm.drop_caches=3" >/dev/null 2>&1 || true
        sleep 2
      done
    ) &
    DROP_PID=$!
  else
    echo "Startup cache reclaim: SKIPPED (no passwordless sudo for vm.drop_caches)." >&2
  fi
fi

echo "Waiting for DSpark vLLM API..."
for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  # Keep the sentinel fresh: a boot that is slow but progressing must not look
  # stale to the watchdog. Cleanup is the EXIT trap's job, not this loop's.
  touch "$BOOT_SENTINEL" 2>/dev/null || true
  if curl -fsS --max-time 5 "$API_URL" >/dev/null; then
    [ -n "${DROP_PID:-}" ] && kill "$DROP_PID" 2>/dev/null || true
    echo "DeepSeek V4 Flash DSpark is running: $API_URL"
    COMPOSE_DISABLE_ENV_FILE=1 docker compose --env-file "$ENV_FILE" "${COMPOSE_ARGS[@]}" ps
    ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose --env-file .env.dspark $REMOTE_COMPOSE_FILES ps"
    echo "Running minimal OpenAI-compatible chat request..."
    curl -fsS --max-time 60 "$CHAT_URL" \
      -H "Content-Type: application/json" \
      -d '{"model":"'"${SERVED_MODEL_NAME:-deepseek-v4-flash-dspark}"'","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":8,"temperature":0.0}' >/dev/null
    echo "Minimal chat request succeeded."
    exit 0
  fi
  sleep "$WAIT_SECONDS"
done

echo "Timed out waiting for DSpark API. Recent head logs:" >&2
COMPOSE_DISABLE_ENV_FILE=1 docker compose --env-file "$ENV_FILE" "${COMPOSE_ARGS[@]}" logs --tail=120 vllm-dspark >&2 || true
echo "Recent worker logs:" >&2
ssh "$WORKER_HOST" "$REMOTE_COMPOSE docker compose --env-file .env.dspark $REMOTE_COMPOSE_FILES logs --tail=120 vllm-dspark" >&2 || true
exit 1

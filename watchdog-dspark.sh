#!/usr/bin/env bash
# Watchdog for the DSpark vLLM cluster.
# Polls the API every POLL_INTERVAL seconds. After FAIL_THRESHOLD consecutive
# failures, runs stop + start to restart both nodes (worker-first).
#
# Usage:
#   ./watchdog-dspark.sh              # foreground, logs to stdout
#   nohup ./watchdog-dspark.sh &      # background
#   ./watchdog-dspark.sh 2>&1 | tee -a watchdog.log  # with log file
#
# The watchdog waits RESTART_COOLDOWN seconds after a restart before resuming
# polling, to allow the cluster time to boot (model load + CUDA graph capture).
#
# SINGLETON: a flock on $LOCK_FILE means a second instance exits immediately.
# Start it with `setsid nohup ./watchdog-dspark.sh >> watchdog.log 2>&1 &` and
# check with `pgrep -fx "bash ./watchdog-dspark.sh"` -- note the -x, because a
# plain `pgrep -f watchdog-dspark.sh` also matches the shell you typed it in.
#
# WHY FAIL_THRESHOLD IS 8, NOT 3: a restart here is BLOCKING (stop, then start
# to completion, then cooldown), so a single watchdog never interrupts its own
# boot. The threshold only matters for boots this instance did not start. At 3
# (~180s) it would stop a manual restart mid-load, since a cold boot is
# 250-600s; at 8 (~480s) it waits. It is still good practice to stop the
# watchdog before a manual restart -- see the checklist in CLAUDE.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_URL="${API_URL:-http://127.0.0.1:8888/v1/models}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
# 8 x 60s = ~480s of tolerance. A cold boot takes 250-600s, so the old value of
# 3 (~180s) meant this watchdog would STOP any boot it had not started itself --
# a manual restart, or another instance's. See "why 8, not 3" below.
FAIL_THRESHOLD="${FAIL_THRESHOLD:-8}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-900}"
LOCK_FILE="${LOCK_FILE:-/tmp/dspark-watchdog.lock}"

fail_count=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# --- singleton ---------------------------------------------------------------
# Only ever ONE watchdog. Without this, a second instance's failure timer
# expires INSIDE the first instance's boot and issues `stop` mid-weight-load.
# On 2026-09-19 four instances were running (15:04:18, 15:04:45, 16:04:10,
# 16:04:36) and the cluster boot-looped for two hours: every attempt died around
# weight load, and it came up ~6 minutes after they were all killed.
#
# The lock is held on fd 9 for the life of the process and is released
# automatically when it exits, however it exits -- no stale-PID file to clean up.
exec 9>"$LOCK_FILE" || { echo "cannot open $LOCK_FILE" >&2; exit 1; }
if ! flock -n 9; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] another watchdog already holds $LOCK_FILE -- exiting"
  exit 0
fi

log "Watchdog started: polling $API_URL every ${POLL_INTERVAL}s, restart after ${FAIL_THRESHOLD} consecutive failures"

while true; do
  if curl -fsS --max-time 10 "$API_URL" >/dev/null 2>&1; then
    if [ "$fail_count" -gt 0 ]; then
      log "API recovered (was at $fail_count/$FAIL_THRESHOLD failures)"
    fi
    fail_count=0
  else
    fail_count=$((fail_count + 1))
    log "API check failed ($fail_count/$FAIL_THRESHOLD)"

    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
      log "Threshold reached. Restarting cluster..."
      fail_count=0

      log "Stopping both nodes..."
      set +e
      "$SCRIPT_DIR/stop-deepseek-v4-flash-dspark.sh" 2>&1 | while IFS= read -r line; do log "  stop: $line"; done
      stop_status=${PIPESTATUS[0]}
      set -e
      [ "$stop_status" -eq 0 ] || log "  stop: exited $stop_status (continuing to start anyway)"

      # `set -euo pipefail` is on. Previously this pipeline was NOT guarded, so a
      # failing start script tripped `set -e` and killed the watchdog outright --
      # which made the "will retry after cooldown" branch below unreachable dead
      # code, and silently left the cluster with no supervisor at the exact
      # moment it needed one. Guard it and read the START script's own status
      # from PIPESTATUS[0], not $? (which is the pipeline's).
      log "Starting cluster (worker-first)..."
      set +e
      "$SCRIPT_DIR/start-deepseek-v4-flash-dspark.sh" 2>&1 | while IFS= read -r line; do log "  start: $line"; done
      start_status=${PIPESTATUS[0]}
      set -e

      if [ "$start_status" -eq 0 ]; then
        log "Cluster restarted successfully. Cooling down ${RESTART_COOLDOWN}s before resuming polling."
      else
        log "WARNING: start script exited $start_status. Will retry after cooldown."
      fi

      sleep "$RESTART_COOLDOWN"
      log "Cooldown complete. Resuming polling."
      continue
    fi
  fi

  sleep "$POLL_INTERVAL"
done

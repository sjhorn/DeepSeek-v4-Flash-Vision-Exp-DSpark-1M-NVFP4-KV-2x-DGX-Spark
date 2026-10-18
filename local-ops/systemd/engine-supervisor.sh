#!/usr/bin/env bash
# engine-supervisor.sh -- a COORDINATED restart of both nodes when either engine dies.
#
# CLASS: ACTUATOR -- RESTARTS BOTH NODES, but only on an ABNORMAL EXIT, and it
# is the ONE standing exception to "ask before every restart" (approved
# 2026-10-14, scoped to crash recovery). Humans and Claude still ask, and put
# `touch ~/.engine-hold` around any planned work.
#
# WHY. 2026-10-14 06:21:48: Xid 32 killed the worker's rank. The head then hung
# ten minutes on an NCCL sync with the dead rank and died, and Docker's
# `restart: unless-stopped` brought each node back SEPARATELY. They happened to
# pair up; on 2026-10-10 the same mechanism left rank 0 hanging in NCCL init
# for ever. Clients saw ~20 minutes of hangs and then 500/502/503. Compose now
# says `restart: "no"`, and this does the documented recovery instead -- `down`
# on BOTH nodes, then the start script -- within ~10s of the death, so the
# outage is the boot and nothing more.
#
# HEAD ONLY. Every 10s it reads both containers' state (the worker's over ssh).
#
#   TRIGGER  a container that EXISTS and exited abnormally (exit code not 0 or
#            143, or OOMKilled) or is `dead`, on either node; OR one exited
#            with ANY code while the other is still running (a half pair --
#            vLLM exits 0 when its engine core dies, measured 2026-10-14).
#   REBOOT   containers stopped BY THEIR HOST'S SHUTDOWN -- exited, with FinishedAt
#            at most 10 min before that host's boot time -- are started again
#            the same way (both nodes), so a deliberate reboot brings the engine
#            back. A `docker stop` with no reboot after it stays down. (Decided
#            2026-10-14: compose is `restart: "no"`, so nothing else would.)
#   NOT      a container that is ABSENT (somebody ran `down`): logged, left alone.
#            A state it cannot READ (ssh failed): logged, left alone -- an
#            unreadable worker is not a dead one.
#   HOLD     ~/.engine-hold exists; or an actuator from local-ops/README.md is
#            running; or the start script's boot sentinel is fresh.
#   LIMIT    at most 2 restarts in 6 hours. Then CRITICAL and NO action until
#            the hold file is created and removed (which clears the count).
#   BEFORE   both containers' last 2,000 log lines, inspect, kernel log and the
#            kvmgr ledger tails go to ~/kvdiag/supervisor/<ts>/ -- the `down`
#            removes the containers, and the evidence with them.
#   WEDGE    both containers running but a load open >= 90s (ledger) or kvmgr
#            logged STORE PATH STALLED: capture once per boot with kvwedge.sh,
#            and do NOT restart (NCCL ends a wedge at ~11 min; then the crash
#            path restarts). Added 2026-10-14 after a 14:36 wedge read `ok`.
#   LIVENESS both running but the API down >= 3 min (container past a 15-min
#            boot grace), or a load open >= 3 min: the same two-node restart.
#            Added 2026-10-14 after a dead engine sat in `running` containers.
#   AFTER    kvstream.sh all-start re-arms the four capture streams (READ-ONLY
#            on the engine; NOT kvdiag.sh arm, which turns the store path on).
#
#   journalctl --user -u engine-supervisor
#
# The verdict is the pure function `decide` between the BEGIN/END markers.
# local-ops/systemd/test-engine-supervisor.sh EXTRACTS it to a temp file and
# tests it -- this file is never sourced, because sourcing runs it.
#
# The unit runs a COPY of this file (ExecStartPre): bash reads a script lazily
# by byte offset, and a push that edits a running script makes it exit 0
# having done nothing.
set -u

# WHICH ENGINE. ENGINE_LANE picks the container, the start/stop commands and
# the paths (lane_config, below); the unit's EnvironmentFile sets it. Unset is
# 0.21, exactly as before. The env names that existed before still win.
ENGINE_LANE=${ENGINE_LANE:-0.21}
HOLD=${ENGINE_HOLD:-$HOME/.engine-hold}
STATE=${ENGINE_SUPERVISOR_STATE:-$HOME/.local/state/engine-supervisor}
EVIDENCE=${ENGINE_SUPERVISOR_EVIDENCE:-$HOME/kvdiag/supervisor}
SENTINEL=${BOOT_SENTINEL:-/tmp/dspark-booting}
SENTINEL_MAX_AGE=${SENTINEL_MAX_AGE:-900}
POLL=${POLL:-10}
OK_EVERY=${OK_EVERY:-60}
MAX_RESTARTS=${MAX_RESTARTS:-2}
WINDOW=${WINDOW:-21600}
WEDGE_LOAD_S=${WEDGE_LOAD_S:-90}

# The actuators from local-ops/README.md, plus every script that starts or
# stops the engine. Bracketed so pgrep cannot match its own argv; and no tag
# here appears in THIS script's name, which is how a bracket gets defeated.
ACTUATORS='[k]v(bootconfirm|bootwalk|killmid|selfheal|xid|xid32|droploop|bisect|load13|ladder|scale|both|conc|overlap|small|inflight|restore|recheck|prefix|converge|loadrounds|budget|enable|dropguard|stallcheck|numpy)\.sh|[k]vsweep\.sh +apply|[k]vdiag\.sh +(arm|disarm|probe|soak|recover)|[f]lags-apply\.sh +apply|[s]tart-deepseek-v4-flash-dspark|[s]top-deepseek-v4-flash-dspark|[s]erve-031\.sh|[l]ane-test\.sh|[u]pdate-and-restart\.sh|[s]witch-model\.sh|[w]atchdog-dspark\.sh|[d]eploy-serving-patch\.sh|local-ops/[s]weep\.sh'

# ---- BEGIN decide (pure: no I/O; extracted by the test, never sourced) ----
# lane_config LANE -> "L_<KEY>=<value>" lines, or "unknown <lane>" and status 1.
#   REPO      where the start/stop commands run
#   NAME      the engine container, the same name on both nodes
#   START/STOP  run in REPO (word-split, so no quoting inside)
#   PORT      the API port the liveness probe reads
#   LEDGER    kvmgr's write-ahead ledger directory
#   TAG       the journald tag (compose `logging.options.tag`)
#   WORKER    the worker's address; empty -> WORKER_HOST from REPO/.env.dspark
#   STREAMS, WEDGE  0.21's capture-stream and wedge tools; empty -> skipped
# 0.31 (2026-10-18): kvstream.sh and kvwedge.sh read 0.21's container and
# tier, so the 0.31 lane skips them; capture() still saves the logs, kernel and
# ledger. OPEN: serve-031.sh refuses without ~/.engine-hold, and the supervisor
# acts only WITHOUT one, so on this lane a recovery is refused by serve-031.sh
# (start.out says why; CRITICAL in the journal) until that gate is decided.
lane_config() {
  case "$1" in
    0.21) printf '%s\n' \
      "L_REPO=$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark" \
      "L_NAME=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1" \
      "L_START=./start-deepseek-v4-flash-dspark.sh" \
      "L_STOP=./stop-deepseek-v4-flash-dspark.sh" \
      "L_PORT=8888" "L_LEDGER=$HOME/kvoffload/diag" "L_TAG=dspark-vllm-" \
      "L_WORKER=" "L_STREAMS=local-ops/kvstream.sh" "L_WEDGE=local-ops/kvwedge.sh" ;;
    0.31) printf '%s\n' \
      "L_REPO=$HOME/dspark031" \
      "L_NAME=dspark031-vllm-dspark031-1" \
      "L_START=./serve-031.sh" \
      "L_STOP=./serve-031.sh down" \
      "L_PORT=8888" "L_LEDGER=$HOME/kvoffload-031/diag" "L_TAG=dspark031-vllm-" \
      "L_WORKER=192.168.0.101" "L_STREAMS=" "L_WEDGE=" ;;
    *) echo "unknown $1"; return 1 ;;
  esac
}

# A state is "<status> <exitcode> <oomkilled> <finished_epoch> <host_btime>".
# abnormal STATE -> 0 if it is a crash
abnormal() {
  local st code oom _rest
  read -r st code oom _rest <<< "$1"
  case "$st" in
    dead) return 0 ;;
    exited)
      [ "${oom:-false}" = true ] && return 0
      case "${code:-}" in 0|143) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}

# by_boot STATE -> 0 if the container was stopped by its host's shutdown:
# exited, and finished in the 10 minutes before the host booted. A crash after
# the boot finishes AFTER btime and is abnormal() instead.
by_boot() {
  local st code oom fin bt
  read -r st code oom fin bt <<< "$1"
  [ "$st" = exited ] || return 1
  case "$fin$bt" in *[!0-9]*|"") return 1 ;; esac
  [ "$fin" -gt 0 ] && [ "$fin" -le "$bt" ] && [ $(( bt - fin )) -le 600 ]
}

# decide HEAD WORKER HOLD ACTUATOR BOOTING RECENT LOCKED MAX
#   HEAD, WORKER: "<status> <exitcode> <oomkilled>" | "absent" | "unreadable"
#   HOLD, ACTUATOR, BOOTING, LOCKED: 0|1    RECENT: restarts in the window
# Prints "<verdict> <reason>"; verdict is one of
#   ok | hold | restart | limit | locked | unreadable | absent | other
# (a reboot-stopped engine yields `restart` too: the action is the same)
decide() {
  local head=$1 worker=$2 hold=$3 act=$4 boot=$5 recent=$6 locked=$7 max=$8
  local hs=${head%% *} ws=${worker%% *} crashed=""
  [ "$hold" = 1 ] && { echo "hold hold file present"; return; }
  [ "$act" = 1 ] && { echo "hold an actuator is running"; return; }
  [ "$boot" = 1 ] && { echo "hold a boot is in progress (sentinel fresh)"; return; }
  case "$head" in absent|unreadable) ;; *) abnormal "$head" && crashed="head[$head]";; esac
  case "$worker" in absent|unreadable) ;; *) abnormal "$worker" && crashed="${crashed:+$crashed }worker[$worker]";; esac
  # *** HALF A PAIR IS A DEAD ENGINE, WHATEVER THE EXIT CODE. *** 2026-10-14
  # 12:12 CEST: Xid 32 on the head, and the head container exited with code 0 --
  # vLLM shuts itself down cleanly once its engine core is dead -- so the first
  # version of this read it as a deliberate stop and left the worker running
  # alone. One exited and one running cannot serve, so it restarts both. Two
  # exited cleanly is still a deliberate stop; use ~/.engine-hold to stop one.
  if [ -z "$crashed" ]; then
    [ "$hs" = exited ] && [ "$ws" = running ] && ! by_boot "$head" && crashed="head[$head; worker still running]"
    [ "$ws" = exited ] && [ "$hs" = running ] && ! by_boot "$worker" && crashed="worker[$worker; head still running]"
  fi
  # A reboot stopped one or both, and nothing is missing or unreadable: the
  # same two-node start. Unreadable waits (a node still booting is unreadable).
  if [ -z "$crashed" ] && [ "$hs" != absent ] && [ "$ws" != absent ] \
     && [ "$hs" != unreadable ] && [ "$ws" != unreadable ]; then
    by_boot "$head" && crashed="head[stopped by its reboot]"
    by_boot "$worker" && crashed="${crashed:+$crashed }worker[stopped by its reboot]"
  fi
  # *** A RESTART NEEDS BOTH NODES. *** 2026-10-14 17:41 CEST, the first full
  # reboot: the head came up first, saw its own container `exited 137`, and
  # restarted at once -- while the worker was still booting. `down` "succeeded"
  # (its ssh failed quietly), the start script died on "No route to host", and
  # the doomed attempt still used one of the two restarts in the window. A crash
  # seen while either node is unreadable now WAITS; the next poll decides again.
  if [ -n "$crashed" ] && { [ "$hs" = unreadable ] || [ "$ws" = unreadable ]; }; then
    echo "unreadable $crashed crashed, but a node is unreadable -- waiting for both before restarting"; return
  fi
  if [ -n "$crashed" ]; then
    [ "$locked" = 1 ] && { echo "locked $crashed crashed; locked out after $max restarts -- create and remove the hold file to re-enable"; return; }
    [ "$recent" -ge "$max" ] && { echo "limit $crashed crashed; $recent restarts already in the window"; return; }
    echo "restart $crashed crashed"; return
  fi
  [ "$hs" = unreadable ] || [ "$ws" = unreadable ] && { echo "unreadable head[$head] worker[$worker]"; return; }
  [ "$hs" = running ] && [ "$ws" = running ] && { echo "ok both running"; return; }
  [ "$hs" = absent ] || [ "$ws" = absent ] && { echo "absent head[$head] worker[$worker] -- somebody ran down; left alone"; return; }
  echo "other head[$head] worker[$worker]"
}
# wedge_verdict STALLED OPEN_LOAD_AGE_S CAPTURED HOLD THRESHOLD_S
#   STALLED: 1 if kvmgr logged "STORE PATH STALLED" this boot; OPEN_LOAD_AGE_S: age
#   of the oldest load the ledger shows open ("" = none / unreadable); CAPTURED: 1 if
#   this boot's wedge was already captured. Prints "capture <why>" or "none".
#   Capture only -- it never restarts: NCCL ends a wedge at ~11 min and the crash
#   path takes over. (2026-10-14 14:36: both GPUs stuck on one load, supervisor `ok`.)
wedge_verdict() {
  local stalled=$1 age=$2 captured=$3 hold=$4 thr=$5
  [ "$hold" = 1 ] && { echo "none"; return; }
  [ "$captured" = 1 ] && { echo "none"; return; }
  case "$age" in ""|*[!0-9]*) age=-1 ;; esac
  if [ "$age" -ge "$thr" ]; then echo "capture a load has been open ${age}s"; return; fi
  [ "$stalled" = 1 ] && { echo "capture kvmgr logged STORE PATH STALLED"; return; }
  echo "none"
}
# live_verdict API_DOWN_S CONTAINER_AGE_S OPEN_LOAD_AGE_S HOLD BOOTING  (both containers running)
#   -> "restart <why>" | "none". Pure.
# *** A DEAD ENGINE IN A RUNNING CONTAINER. *** 2026-10-14 17:16 CEST: a
# poll-thread load faulted (Xid 32), the engine core died, and the API stopped
# answering -- but the API process did not exit, both containers read
# `running`, and the supervisor said `ok` until a human restarted it. The 14:36
# wedge was the same blindness. Two signals that do not misfire under load:
#   - /v1/models failing for >= LIVE_API_S while the container is past a boot
#     grace (a slow manual start must not look dead);
#   - a load open >= LIVE_LOAD_S (one copy takes well under a second; the
#     wedge capture already fired at WEDGE_LOAD_S).
# Not a one-token completion: it can queue for minutes behind a long prefill.
live_verdict() {
  local down=$1 age=$2 load=$3 hold=$4 boot=$5
  [ "$hold" = 1 ] || [ "$boot" = 1 ] && { echo none; return; }
  case "$down" in ""|*[!0-9]*) down=0 ;; esac
  case "$age" in ""|*[!0-9]*) age=0 ;; esac
  case "$load" in ""|*[!0-9]*) load=-1 ;; esac
  if [ "$load" -ge "${LIVE_LOAD_S:-180}" ]; then echo "restart a load has been open ${load}s -- the engine is wedged"; return; fi
  if [ "$down" -ge "${LIVE_API_S:-180}" ] && [ "$age" -ge "${BOOT_GRACE_S:-900}" ]; then
    echo "restart the API has not answered for ${down}s with both containers running -- the engine is dead"; return
  fi
  echo none
}
# ---- END decide ----

log()  { echo "<6>$*"; }
warn() { echo "<4>WARNING $*"; }
crit() { echo "<2>CRITICAL $*"; }

if [ "$(hostname -s)" != spark-45ea ]; then
  crit "engine-supervisor runs on the HEAD (spark-45ea) only; this is $(hostname -s). Refusing."
  exit 1
fi

LC=$(lane_config "$ENGINE_LANE") || { crit "ENGINE_LANE=$ENGINE_LANE is not a lane this script knows ($LC). Refusing."; exit 1; }
eval "$LC"
REPO=${DSPARK_REPO:-$L_REPO}
NAME=${ENGINE_CONTAINER:-$L_NAME}
START_CMD=${ENGINE_START:-$L_START}
STOP_CMD=${ENGINE_STOP:-$L_STOP}
API_PORT=${ENGINE_API_PORT:-$L_PORT}
LEDGER_DIR=${LEDGER_DIR:-$L_LEDGER}
TAG=$L_TAG$NAME
STREAMS=$L_STREAMS
WEDGE=$L_WEDGE
WORKER_HOST=${WORKER_HOST:-$L_WORKER}
if [ -z "$WORKER_HOST" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO/.env.dspark" || { crit "cannot read $REPO/.env.dspark"; exit 1; }
  set +a
fi
: "${WORKER_HOST:?WORKER_HOST unset in .env.dspark}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 "$WORKER_HOST")

# The probe, run locally and on the worker. FinishedAt is an RFC 3339 STRING in
# docker's inspect data (`.State.FinishedAt.Unix` is a template error, which the
# first version shipped and which read as `unreadable` -- safe, and useless). docker failing prints `unreadable`;
# a container docker does not list prints `absent`.
PROBE='out=$(docker ps -a --filter "name=^'"$NAME"'$" --format x) || { echo unreadable; exit 0; }
[ -z "$out" ] && { echo absent; exit 0; }
bt=$(awk "/^btime/{print \$2}" /proc/stat)
s=$(docker inspect -f "{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}} {{.State.FinishedAt}}" '"$NAME"' 2>/dev/null) || { echo unreadable; exit 0; }
set -- $s; fin=$(date -d "$4" +%s 2>/dev/null) || fin=x
echo "$1 $2 $3 $fin $bt"'

state_head()   { bash -c "$PROBE"; }
state_worker() { local o; o=$("${SSH[@]}" "bash -c '$PROBE'" 2>/dev/null) || o=""; echo "${o:-unreadable}"; }

mkdir -p "$STATE" "$EVIDENCE"
touch "$STATE/restarts"

recent_restarts() {
  local now; now=$(date +%s)
  awk -v c=$(( now - WINDOW )) '$1>c{n++} END{print n+0}' "$STATE/restarts"
}

booting() {
  [ -e "$SENTINEL" ] || return 1
  local m; m=$(stat -c %Y "$SENTINEL" 2>/dev/null) || return 1
  [ $(( $(date +%s) - m )) -lt "$SENTINEL_MAX_AGE" ]
}

actuator_running() {
  pgrep -f -- "$ACTUATORS" >/dev/null 2>&1
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 0 ;; esac   # pgrep error: assume busy
}

capture() {   # capture DIR -- evidence BEFORE the down removes it
  local d=$1
  docker inspect "$NAME" > "$d/head-inspect.json" 2>&1
  docker logs --tail 2000 "$NAME" > "$d/head.log" 2>&1
  "${SSH[@]}" "docker inspect $NAME" > "$d/worker-inspect.json" 2>&1
  "${SSH[@]}" "docker logs --tail 2000 $NAME" > "$d/worker.log" 2>&1
  # An unreadable log must say so, not leave an empty file that reads as clean.
  journalctl -k --since=-30min --no-pager > "$d/kernel-head.txt" 2>&1 \
    || echo "UNREADABLE: journalctl -k failed on the head" >> "$d/kernel-head.txt"
  "${SSH[@]}" "journalctl -k --since=-30min --no-pager" > "$d/kernel-worker.txt" 2>&1 \
    || echo "UNREADABLE: journalctl -k failed on the worker" >> "$d/kernel-worker.txt"
  # The write-ahead ledger: the open entries for the dead pid name the transfer.
  for f in "$LEDGER_DIR"/ledger-r*.jsonl; do
    [ -e "$f" ] && tail -n 4000 "$f" > "$d/head-$(basename "$f")"
  done
  "${SSH[@]}" "for f in $LEDGER_DIR/ledger-r*.jsonl; do [ -e \$f ] && echo \$f; done" 2>/dev/null |
    while read -r f; do "${SSH[@]}" "tail -n 4000 $f" > "$d/worker-$(basename "$f")" 2>&1; done
}

restart_both() {
  local why=$1 ts d rc
  ts=$(date -u +%Y%m%dT%H%M%SZ); d="$EVIDENCE/$ts"; mkdir -p "$d"
  echo "$why" > "$d/reason"
  date +%s >> "$STATE/restarts"
  crit "RESTARTING BOTH NODES: $why. Evidence -> $d"
  capture "$d"
  log "evidence captured ($(du -sh "$d" | cut -f1)); down on both nodes"
  # shellcheck disable=SC2086  # the commands are word-split on purpose
  (cd "$REPO" && $STOP_CMD) > "$d/stop.out" 2>&1; rc=$?
  log "stop exited $rc"
  # shellcheck disable=SC2086
  (cd "$REPO" && $START_CMD) > "$d/start.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    crit "start script exited $rc -- see $d/start.out. The next poll decides again; the restart is counted."
    return
  fi
  # An exit status is not evidence that work happened: read the effect.
  log "start exited 0; head[$(state_head)] worker[$(state_worker)]"
  if [ -z "$STREAMS" ]; then
    log "no capture streams on lane $ENGINE_LANE"
  else
    bash "$REPO/$STREAMS" all-start > "$d/streams.out" 2>&1 \
      && log "capture streams re-armed" \
      || warn "capture streams NOT fully armed -- see $d/streams.out"
  fi
}

# THE WEDGE PROBES. Both read-only and cheap: the tail of the head's ledger, and
# the head engine's journal since this container started.
# *** ONLY LOADS SUBMITTED SINCE THIS CONTAINER STARTED. *** The first version
# read the ledger's last boot, and right after a restart -- before the new boot
# has written a line -- that is the PREVIOUS boot, whose stuck load then reads
# as "open 1,097s": a false wedge capture after every crash recovery. Found by
# running the probe on the head mid-boot, 2026-10-14.
oldest_open_load_age() {
  local f st; f=$(ls "$LEDGER_DIR"/ledger-r*.jsonl 2>/dev/null | head -1) || return
  [ -n "$f" ] || return
  # `date -d ""` is TODAY'S MIDNIGHT and exits 0 -- so an unreadable StartedAt
  # must stop here, or every load since midnight comes back as "open".
  st=$(docker inspect -f "{{.State.StartedAt}}" "$NAME" 2>/dev/null) || return
  [ -n "$st" ] || return
  st=$(date -d "$st" +%s 2>/dev/null) || return
  tail -n 3000 "$f" | STARTED="$st" python3 -c '
import sys,json,time,os
st=float(os.environ["STARTED"])
L=[]
for l in sys.stdin:
    try:
        r=json.loads(l)
        if r.get("ts",0)>=st: L.append(r)
    except Exception: pass
if not L: sys.exit()
b=L[-1].get("boot"); op={}
for r in L:
    if r.get("boot")!=b or r.get("kind")!="load": continue
    if r.get("ev")=="submit": op[r["inner"]]=r["ts"]
    else: op.pop(r.get("inner"),None)
if op: print(int(time.time()-min(op.values())))' 2>/dev/null
}
stalled_this_boot() {
  local since; since=$(docker inspect -f "{{.State.StartedAt}}" "$NAME" 2>/dev/null | cut -c1-19 | tr T " ")
  [ -n "$since" ] || { echo 0; return; }
  journalctl -a -t "$TAG" --since "$since" --no-pager -o cat 2>/dev/null | grep -q "STORE PATH STALLED" && echo 1 || echo 0
}
boot_id() { docker inspect -f "{{.State.StartedAt}}" "$NAME" 2>/dev/null; }

log "engine-supervisor on $(hostname -s): lane $ENGINE_LANE, container $NAME, start '$START_CMD' in $REPO; worker=$WORKER_HOST every ${POLL}s; hold=$HOLD; limit $MAX_RESTARTS restarts per ${WINDOW}s"
last_verdict=""; last_verdict_full=""; last_ok=0; api_down_since=""
while :; do
  if [ -e "$HOLD" ] && [ -e "$STATE/lockout" ]; then
    rm -f "$STATE/lockout"; : > "$STATE/restarts"
    log "lockout CLEARED by the hold file; restart count reset"
  fi
  h=0; [ -e "$HOLD" ] && h=1
  a=0; actuator_running && a=1
  b=0; booting && b=1
  l=0; [ -e "$STATE/lockout" ] && l=1
  hs=$(state_head); ws=$(state_worker)
  out=$(decide "$hs" "$ws" "$h" "$a" "$b" "$(recent_restarts)" "$l" "$MAX_RESTARTS")
  verdict=${out%% *}; reason=${out#* }
  now=$(date +%s)
  case "$verdict" in
    restart) restart_both "$reason"; last_verdict=""; continue ;;
    limit)   touch "$STATE/lockout"; crit "NOT restarting: $reason. LOCKED OUT -- touch then rm $HOLD to re-enable." ;;
    ok)      if [ "$last_verdict" != ok ] || [ $(( now - last_ok )) -ge "$OK_EVERY" ]; then
               log "ok head[$hs] worker[$ws]"; last_ok=$now
             fi ;;
    *)       [ "$out" != "$last_verdict_full" ] && { [ "$verdict" = locked ] && crit "$out" || warn "$out"; } ;;
  esac
  if [ "$verdict" = ok ]; then
    # liveness: the API, and the oldest open load
    if curl -s -o /dev/null -m 5 -w "%{http_code}" "localhost:$API_PORT/v1/models" 2>/dev/null | grep -q 200; then
      api_down_since=""
    else
      [ -n "$api_down_since" ] || api_down_since=$now
    fi
    down=0; [ -n "$api_down_since" ] && down=$(( now - api_down_since ))
    cstart=$(date -d "$(docker inspect -f "{{.State.StartedAt}}" "$NAME" 2>/dev/null)" +%s 2>/dev/null || echo "$now")
    lv=$(live_verdict "$down" "$(( now - cstart ))" "$(oldest_open_load_age)" "$h" "$b")
    if [ "${lv%% *}" = restart ]; then
      if [ "$l" = 1 ]; then crit "LIVENESS: ${lv#restart } -- but LOCKED OUT; not restarting"
      elif [ "$(recent_restarts)" -ge "$MAX_RESTARTS" ]; then touch "$STATE/lockout"; crit "LIVENESS: ${lv#restart } -- limit reached; LOCKED OUT"
      else
        # evidence first, synchronously: the restart destroys it
        if [ "$(cat "$STATE/wedge-captured" 2>/dev/null)" != "$(boot_id)" ]; then
          boot_id > "$STATE/wedge-captured"
          if [ -n "$WEDGE" ]; then
            warn "LIVENESS: ${lv#restart } -- capturing evidence (kvwedge.sh) before the restart"
            timeout 300 "$REPO/$WEDGE" capture "supervisor liveness: ${lv#restart }" 2>&1 | while IFS= read -r ln; do echo "<6>kvwedge: $ln"; done
          fi
        fi
        restart_both "LIVENESS: ${lv#restart }"; api_down_since=""; last_verdict=""; continue
      fi
    fi
    cap=0; [ "$(cat "$STATE/wedge-captured" 2>/dev/null)" = "$(boot_id)" ] && cap=1
    w=$(wedge_verdict "$(stalled_this_boot)" "$(oldest_open_load_age)" "$cap" "$h" "$WEDGE_LOAD_S")
    if [ "${w%% *}" = capture ]; then
      boot_id > "$STATE/wedge-captured"
      if [ -n "$WEDGE" ]; then
        warn "WEDGE suspected (${w#capture }) with both containers running -- capturing evidence (kvwedge.sh), NOT restarting; NCCL ends a wedge at ~11 min"
        ( "$REPO/$WEDGE" capture "supervisor: ${w#capture }" 2>&1 | while IFS= read -r l; do echo "<6>kvwedge: $l"; done ) &
      else
        warn "WEDGE suspected (${w#capture }) with both containers running -- no wedge tool on lane $ENGINE_LANE; NOT restarting; NCCL ends a wedge at ~11 min"
      fi
    fi
  fi
  last_verdict=$verdict; last_verdict_full=$out
  sleep "$POLL"
done

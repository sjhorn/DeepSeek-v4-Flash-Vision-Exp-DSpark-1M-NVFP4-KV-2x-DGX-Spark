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

REPO=${DSPARK_REPO:-$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}
NAME=${ENGINE_CONTAINER:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
HOLD=${ENGINE_HOLD:-$HOME/.engine-hold}
STATE=${ENGINE_SUPERVISOR_STATE:-$HOME/.local/state/engine-supervisor}
EVIDENCE=${ENGINE_SUPERVISOR_EVIDENCE:-$HOME/kvdiag/supervisor}
SENTINEL=${BOOT_SENTINEL:-/tmp/dspark-booting}
SENTINEL_MAX_AGE=${SENTINEL_MAX_AGE:-900}
POLL=${POLL:-10}
OK_EVERY=${OK_EVERY:-60}
MAX_RESTARTS=${MAX_RESTARTS:-2}
WINDOW=${WINDOW:-21600}
LEDGER_DIR=${LEDGER_DIR:-$HOME/kvoffload/diag}
WEDGE_LOAD_S=${WEDGE_LOAD_S:-90}
TAG=dspark-vllm-$NAME

# The actuators from local-ops/README.md, plus every script that starts or
# stops the engine. Bracketed so pgrep cannot match its own argv; and no tag
# here appears in THIS script's name, which is how a bracket gets defeated.
ACTUATORS='[k]v(bootconfirm|bootwalk|killmid|selfheal|xid|xid32|droploop|bisect|load13|ladder|scale|both|conc|overlap|small|inflight|restore|recheck|prefix|converge|loadrounds|budget|enable|dropguard|stallcheck|numpy)\.sh|[k]vsweep\.sh +apply|[k]vdiag\.sh +(arm|disarm|probe|soak|recover)|[f]lags-apply\.sh +apply|[s]tart-deepseek-v4-flash-dspark|[s]top-deepseek-v4-flash-dspark|[u]pdate-and-restart\.sh|[s]witch-model\.sh|[w]atchdog-dspark\.sh|[d]eploy-serving-patch\.sh|local-ops/[s]weep\.sh'

# ---- BEGIN decide (pure: no I/O; extracted by the test, never sourced) ----
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
# ---- END decide ----

log()  { echo "<6>$*"; }
warn() { echo "<4>WARNING $*"; }
crit() { echo "<2>CRITICAL $*"; }

if [ "$(hostname -s)" != spark-45ea ]; then
  crit "engine-supervisor runs on the HEAD (spark-45ea) only; this is $(hostname -s). Refusing."
  exit 1
fi

set -a
# shellcheck disable=SC1091
. "$REPO/.env.dspark" || { crit "cannot read $REPO/.env.dspark"; exit 1; }
set +a
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
  (cd "$REPO" && ./stop-deepseek-v4-flash-dspark.sh) > "$d/stop.out" 2>&1; rc=$?
  log "stop exited $rc"
  (cd "$REPO" && ./start-deepseek-v4-flash-dspark.sh) > "$d/start.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    crit "start script exited $rc -- see $d/start.out. The next poll decides again; the restart is counted."
    return
  fi
  # An exit status is not evidence that work happened: read the effect.
  log "start exited 0; head[$(state_head)] worker[$(state_worker)]"
  bash "$REPO/local-ops/kvstream.sh" all-start > "$d/streams.out" 2>&1 \
    && log "capture streams re-armed" \
    || warn "capture streams NOT fully armed -- see $d/streams.out"
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

log "engine-supervisor on $(hostname -s): worker=$WORKER_HOST every ${POLL}s; hold=$HOLD; limit $MAX_RESTARTS restarts per ${WINDOW}s"
last_verdict=""; last_verdict_full=""; last_ok=0
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
    cap=0; [ "$(cat "$STATE/wedge-captured" 2>/dev/null)" = "$(boot_id)" ] && cap=1
    w=$(wedge_verdict "$(stalled_this_boot)" "$(oldest_open_load_age)" "$cap" "$h" "$WEDGE_LOAD_S")
    if [ "${w%% *}" = capture ]; then
      boot_id > "$STATE/wedge-captured"
      warn "WEDGE suspected (${w#capture }) with both containers running -- capturing evidence (kvwedge.sh), NOT restarting; NCCL ends a wedge at ~11 min"
      ( "$REPO/local-ops/kvwedge.sh" capture "supervisor: ${w#capture }" 2>&1 | while IFS= read -r l; do echo "<6>kvwedge: $l"; done ) &
    fi
  fi
  last_verdict=$verdict; last_verdict_full=$out
  sleep "$POLL"
done

#!/usr/bin/env bash
# test-engine-supervisor.sh -- the supervisor's verdict, offline, with fakes.
#
#   bash local-ops/systemd/test-engine-supervisor.sh [path/to/engine-supervisor.sh]
#
# EXTRACTS `decide` (between the BEGIN/END markers) into a temp file and
# sources THAT. The supervisor itself is never sourced: sourcing a script runs
# it, and a tool whose job is `down` on both nodes must not be "loaded" to test
# one function -- that is how two boots were lost on 2026-10-12.
#
# The optional argument is for break-verification: point it at a mutated copy
# and this must exit non-zero. Ends in `exit $T`.
set -u
SRC=${1:-$(dirname "$0")/engine-supervisor.sh}
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
awk '/^# ---- BEGIN decide/{on=1} on{print} /^# ---- END decide/{on=0}' "$SRC" > "$TMP"
if ! grep -q '^decide()' "$TMP"; then
  echo "FAIL: no decide() between the markers in $SRC -- nothing was tested"; exit 1
fi
# shellcheck disable=SC1090
. "$TMP"
P=0; T=0
v() { decide "$@" | cut -d' ' -f1; }
is() {  # is NAME WANT HEAD WORKER HOLD ACT BOOT RECENT LOCKED MAX
  local name=$1 want=$2; shift 2
  local got; got=$(v "$@")
  if [ "$got" = "$want" ]; then P=$((P+1)); echo "PASS  $name"
  else T=1; echo "FAIL  $name  got '$got' want '$want'  [$(decide "$@")]"; fi
}
RUN="running 0 false"
# ---- the trigger
is "both running -> ok"                         ok      "$RUN" "$RUN" 0 0 0 0 0 2
is "*** worker exited 1 (the Xid shape) -> restart ***" restart "$RUN" "exited 1 false" 0 0 0 0 0 2
is "head exited 134 (SIGABRT) -> restart"        restart "exited 134 false" "$RUN" 0 0 0 0 0 2
is "exit 137 (SIGKILL) is abnormal -> restart"   restart "$RUN" "exited 137 false" 0 0 0 0 0 2
is "OOMKilled with exit 0 -> restart"            restart "$RUN" "exited 0 true" 0 0 0 0 0 2
is "dead -> restart"                             restart "dead 0 false" "$RUN" 0 0 0 0 0 2
is "both crashed -> ONE restart verdict"         restart "exited 1 false" "exited 1 false" 0 0 0 0 0 2
# ---- not a trigger
is "*** both exited 0 is a deliberate stop -> not restart ***" other "exited 0 false" "exited 0 false" 0 0 0 0 0 2
is "both exited 143 (docker stop) -> not restart" other "exited 143 false" "exited 143 false" 0 0 0 0 0 2
is "*** HEAD exited 0 with the worker running (the 12:12 Xid) -> restart ***" restart "exited 0 false 1791972743 1791218329" "running 0 false -62135596800 1791216240" 0 0 0 0 0 2
is "worker exited 143 with the head running -> restart (half a pair)" restart "$RUN" "exited 143 false" 0 0 0 0 0 2
is "*** worker ABSENT (somebody ran down) -> left alone ***" absent "$RUN" "absent" 0 0 0 0 0 2
is "both absent -> left alone"                   absent  absent absent 0 0 0 0 0 2
is "*** worker UNREADABLE (ssh failed) -> not a crash ***" unreadable "$RUN" unreadable 0 0 0 0 0 2
is "*** head crashed but worker UNREADABLE (still booting) -> wait, not restart ***" unreadable "exited 137 false" unreadable 0 0 0 0 0 2
is "worker crashed but head UNREADABLE -> wait"            unreadable unreadable "exited 1 false" 0 0 0 0 0 2
is "restarting/created -> other, no action"      other   "$RUN" "restarting 0 false" 0 0 0 0 0 2
# ---- holds outrank a crash
is "*** hold file outranks a crash ***"          hold    "$RUN" "exited 1 false" 1 0 0 0 0 2
is "*** a running actuator outranks a crash ***" hold    "$RUN" "exited 1 false" 0 1 0 0 0 2
is "*** a fresh boot sentinel outranks a crash ***" hold "$RUN" "exited 1 false" 0 0 1 0 0 2
# ---- the rate limit
is "one restart already in the window -> still restart" restart "$RUN" "exited 1 false" 0 0 0 1 0 2
is "*** two in the window -> limit, not restart ***" limit "$RUN" "exited 1 false" 0 0 0 2 0 2
is "*** locked out -> locked, not restart, even with 0 recent ***" locked "$RUN" "exited 1 false" 0 0 0 0 1 2
is "locked out but healthy -> ok"                ok      "$RUN" "$RUN" 0 0 0 0 1 2
# ---- a reboot (state = "<status> <code> <oom> <finished_epoch> <host_btime>")
BT=1792000000
BYBOOT="exited 143 false $((BT - 30)) $BT"        # stopped 30s before its host booted
is "*** both stopped by their reboot -> restart (auto-start) ***" restart "$BYBOOT" "$BYBOOT" 0 0 0 0 0 2
is "only the worker rebooted (head still running) -> restart both" restart "$RUN" "$BYBOOT" 0 0 0 0 0 2
is "exit 0 by the reboot counts too"              restart "exited 0 false $((BT - 5)) $BT" "$BYBOOT" 0 0 0 0 0 2
is "*** a docker stop of BOTH with NO reboot after it -> stays down ***" other "exited 143 false $((BT + 3600)) $BT" "exited 143 false $((BT + 3600)) $BT" 0 0 0 0 0 2
is "*** stopped 11 min before the boot -> not by the reboot ***" other "exited 143 false $((BT - 660)) $BT" "exited 143 false $((BT - 660)) $BT" 0 0 0 0 0 2
is "running containers carry a zero-time FinishedAt -> ok" ok "running 0 false -62135596800 $BT" "running 0 false -62135596800 $BT" 0 0 0 0 0 2
is "*** reboot-stopped but the other node still unreadable -> wait ***" unreadable "$BYBOOT" unreadable 0 0 0 0 0 2
is "reboot-stopped but the other ABSENT (somebody ran down) -> left alone" absent "$BYBOOT" absent 0 0 0 0 0 2
is "*** the hold file outranks a reboot start ***"  hold    "$BYBOOT" "$BYBOOT" 1 0 0 0 0 2
is "a reboot start counts toward the limit"        limit   "$BYBOOT" "$BYBOOT" 0 0 0 2 0 2
is "*** RUNNING with a pre-boot FinishedAt (docker keeps the last run's) -> ok, never restarted ***" ok "running 0 false $((BT - 30)) $BT" "running 0 false $((BT - 30)) $BT" 0 0 0 0 0 2
# Short (3-field) and zero-time states must be refused by the guard, not by a
# shell error that happens to evaluate false.
err=$( { decide "exited 143 false" "running 0 false -62135596800 $BT" 0 0 0 0 0 2 >/dev/null; } 2>&1 )
[ -z "$err" ] && { P=$((P+1)); echo "PASS  short and zero-time states raise no shell errors"; } \
              || { T=1; echo "FAIL  decide wrote to stderr: $err"; }
r=$(decide "$RUN" "$BYBOOT" 0 0 0 0 0 2)
case "$r" in *"worker[stopped by its reboot]"*) P=$((P+1)); echo "PASS  a reboot start says so in its reason";;
  *) T=1; echo "FAIL  reboot reason missing: $r";; esac

# ---- wedge detection (capture only)
wv() { wedge_verdict "$@" | cut -d" " -f1; }
iw() { local n=$1 want=$2; shift 2; local g; g=$(wv "$@"); if [ "$g" = "$want" ]; then P=$((P+1)); echo "PASS  $n"; else T=1; echo "FAIL  $n  got $g want $want [$(wedge_verdict "$@")]"; fi; }
iw "*** a load open 201s (the 14:36 wedge) -> capture ***" capture 0 201 0 0 90
iw "kvmgr STALLED line alone -> capture"                    capture 1 ""  0 0 90
iw "a load open 30s is normal -> none"                      none    0 30  0 0 90
iw "no open load, no stall -> none"                         none    0 ""  0 0 90
iw "*** already captured this boot -> none (once per boot) ***" none 1 500 1 0 90
iw "*** hold file -> none ***"                               none    1 500 0 1 90
iw "unreadable age with no stall -> none, not a capture"    none    0 "x" 0 0 90
iw "exactly at the threshold -> capture"                    capture 0 90  0 0 90
err=$( { wedge_verdict 0 "x" 0 0 90; wedge_verdict 0 "" 0 0 90; } 2>&1 >/dev/null )
[ -z "$err" ] && { P=$((P+1)); echo "PASS  unreadable ages are refused by the guard, not by a shell error"; } \
              || { T=1; echo "FAIL  wedge_verdict wrote to stderr: $err"; }

# ---- liveness (both containers running)
lv() { live_verdict "$@" | cut -d" " -f1; }
il() { local n=$1 want=$2; shift 2; local g; g=$(lv "$@"); if [ "$g" = "$want" ]; then P=$((P+1)); echo "PASS  $n"; else T=1; echo "FAIL  $n  got $g want $want [$(live_verdict "$@")]"; fi; }
il "*** API down 200s, container 1h old (the 17:16 state) -> restart ***" restart 200 3600 "" 0 0
il "API down 100s -> not yet"                                   none    100 3600 "" 0 0
il "*** API down 600s but container only 5 min old (still booting) -> none ***" none 600 300 "" 0 0
il "*** a load open 200s (the 14:36 wedge) -> restart ***"      restart 0 3600 200 0 0
il "a load open 60s is normal under load -> none"                none    0 3600 60 0 0
il "*** hold file -> none, whatever the signals ***"             none    900 3600 900 1 0
il "boot sentinel fresh -> none"                                 none    900 3600 900 0 1
il "unreadable ages -> none, not a restart"                      none    x 3600 x 0 0
err=$( { live_verdict x y z 0 0; } 2>&1 >/dev/null ); [ -z "$err" ] && { P=$((P+1)); echo "PASS  live_verdict: unreadable inputs raise no shell errors"; } || { T=1; echo "FAIL  live_verdict stderr: $err"; }

# ---- the crash names the node
r=$(decide "$RUN" "exited 1 false" 0 0 0 0 0 2)
case "$r" in *"worker[exited 1 false]"*) P=$((P+1)); echo "PASS  the reason names the worker and its exit";;
  *) T=1; echo "FAIL  reason does not name the worker: $r";; esac
case "$r" in *head*) T=1; echo "FAIL  reason blames the head too: $r";;
  *) P=$((P+1)); echo "PASS  ...and does not blame the head";; esac
# ---- lanes (lane_config): 0.32 is the only lane since 2026-10-19
lane() { local n=$1 lane=$2 key=$3 want=$4 got; got=$(lane_config "$lane" | sed -n "s/^L_$key=//p")
  if [ "$got" = "$want" ]; then P=$((P+1)); echo "PASS  $n"; else T=1; echo "FAIL  $n  got '$got' want '$want'"; fi; }
lane "*** 0.32 container is dspark032's ***" 0.32 NAME dspark032-vllm-dspark032-1
lane "*** 0.32 starts with serve-032.sh, flagged as the supervisor ***" 0.32 START "env ENGINE_SUPERVISOR=1 ./serve-032.sh"
lane "0.32 stops with serve-032.sh down, flagged" 0.32 STOP "env ENGINE_SUPERVISOR=1 ./serve-032.sh down"
lane "0.32 runs in ~/dspark032"           0.32 REPO "$HOME/dspark032"
lane "*** 0.32 ledger is ~/kvoffload-032 ***" 0.32 LEDGER "$HOME/kvoffload-032/diag"
lane "0.32 journald tag matches its compose" 0.32 TAG dspark032-vllm-
lane "0.32 names its worker"              0.32 WORKER 192.168.0.101
lane "0.32 skips 0.21's wedge tool"       0.32 WEDGE ""
for gone in 0.21 0.31 0.99; do
  if out=$(lane_config $gone); then T=1; echo "FAIL  lane $gone was accepted: $out"
  else P=$((P+1)); echo "PASS  lane $gone is refused ($out)"; fi
done
# the default when no env file sets ENGINE_LANE: production's lane, never a retired one
if grep -qxF 'ENGINE_LANE=${ENGINE_LANE:-0.32}' "$SRC"; then P=$((P+1)); echo "PASS  *** an unset ENGINE_LANE means 0.32 ***"
else T=1; echo "FAIL  *** the ENGINE_LANE default is not 0.32: $(grep -n '^ENGINE_LANE=' "$SRC") ***"; fi
U=$(dirname "$SRC")/engine-supervisor.service
grep -qx 'Environment=ENGINE_LANE=0.32' "$U" && { P=$((P+1)); echo "PASS  the unit defaults to lane 0.32"; } || { T=1; echo "FAIL  the unit's ENGINE_LANE is not 0.32"; }
# ---- lane_load runs NOTHING (2026-10-18: an eval of lane_config EXECUTED serve-031.sh)
D=$(mktemp -d); M="$D/RAN"
for f in serve-032.sh env; do printf '#!/bin/sh\ntouch %s\n' "$M" > "$D/$f"; chmod +x "$D/$f"; done
( cd "$D" && PATH="$D:$PATH" && unset L_START L_STOP && lane_load "$(lane_config 0.32)" && [ -n "$L_START" ] && echo "$L_START" > "$D/start.0.32" )
if [ -e "$M" ]; then T=1; echo "FAIL  *** lane_load EXECUTED a lane's command (decoy ran) ***"
else P=$((P+1)); echo "PASS  *** lane_load runs nothing: the decoy serve-032.sh / env never ran ***"; fi
g=$(cat "$D/start.0.32" 2>/dev/null)
[ "$g" = "env ENGINE_SUPERVISOR=1 ./serve-032.sh" ] && { P=$((P+1)); echo "PASS  lane_load sets L_START verbatim"; } || { T=1; echo "FAIL  lane_load L_START: '$g'"; }
if ( lane_load "PATH=/nowhere" ) >/dev/null 2>&1; then T=1; echo "FAIL  lane_load accepted a non-L_ key"; else P=$((P+1)); echo "PASS  lane_load refuses a non-L_ key"; fi
rm -rf "$D"
if grep -qE '^[[:space:]]*eval[[:space:]]' "$SRC"; then T=1; echo "FAIL  the supervisor has an eval: $(grep -nE '^[[:space:]]*eval[[:space:]]' "$SRC" | head -1)"
else P=$((P+1)); echo "PASS  the supervisor has no eval"; fi

# serve-032.sh's gate: the hold, or the supervisor's flag -- and nothing else.
G=$(grep -E '^\[ -f ~/.engine-hold \]' "$(dirname "$SRC")/../../serve-032.sh")
gate() { local n=$1 hold=$2 flag=$3 want=$4 got d; d=$(mktemp -d)
  [ "$hold" = 1 ] && touch "$d/.engine-hold"
  got=$(HOME=$d ENGINE_SUPERVISOR=$flag bash -c "$G && echo pass" 2>/dev/null | tail -1); rm -rf "$d"
  [ "$got" = pass ] || got=refused
  if [ "$got" = "$want" ]; then P=$((P+1)); echo "PASS  $n"; else T=1; echo "FAIL  $n  got $got want $want"; fi; }
[ -n "$G" ] || { T=1; echo "FAIL  no hold-gate line found in serve-032.sh"; }
gate "serve-032.sh: hold present -> runs"                 1 ""  pass
gate "*** serve-032.sh: no hold, no flag -> refused ***"  0 ""  refused
gate "*** serve-032.sh: no hold, ENGINE_SUPERVISOR=1 -> runs ***" 0 1 pass
gate "serve-032.sh: ENGINE_SUPERVISOR=0 is not the flag"  0 0   refused

echo
echo "$P passed, $T failed-flag"
[ "$T" = 0 ] && echo "SUPERVISOR VERDICTS GREEN" || echo "*** SUPERVISOR VERDICTS RED ***"
exit $T

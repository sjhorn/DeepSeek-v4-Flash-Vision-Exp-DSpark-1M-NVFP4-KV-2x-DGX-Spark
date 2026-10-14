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
is "*** exit 0 is a clean stop -> not restart ***" other "$RUN" "exited 0 false" 0 0 0 0 0 2
is "exit 143 (SIGTERM, docker stop) -> not restart" other "exited 143 false" "$RUN" 0 0 0 0 0 2
is "*** worker ABSENT (somebody ran down) -> left alone ***" absent "$RUN" "absent" 0 0 0 0 0 2
is "both absent -> left alone"                   absent  absent absent 0 0 0 0 0 2
is "*** worker UNREADABLE (ssh failed) -> not a crash ***" unreadable "$RUN" unreadable 0 0 0 0 0 2
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
# ---- the crash names the node
r=$(decide "$RUN" "exited 1 false" 0 0 0 0 0 2)
case "$r" in *"worker[exited 1 false]"*) P=$((P+1)); echo "PASS  the reason names the worker and its exit";;
  *) T=1; echo "FAIL  reason does not name the worker: $r";; esac
case "$r" in *head*) T=1; echo "FAIL  reason blames the head too: $r";;
  *) P=$((P+1)); echo "PASS  ...and does not blame the head";; esac
echo
echo "$P passed, $T failed-flag"
[ "$T" = 0 ] && echo "SUPERVISOR VERDICTS GREEN" || echo "*** SUPERVISOR VERDICTS RED ***"
exit $T

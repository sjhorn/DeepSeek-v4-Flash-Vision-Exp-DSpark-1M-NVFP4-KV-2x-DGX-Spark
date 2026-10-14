#!/usr/bin/env bash
# spark-memwatch.sh -- memory, swap, PSI and OOM-kill to the JOURNAL. Nothing else.
#
# CLASS: READ-ONLY. It reads /proc and writes log lines. It never kills, never
# restarts, never drops a cache -- there is deliberately no OOM killer under
# spark-os (earlyoom is absent, not just untuned), and this does not add one.
#
# WHY. The 2026-10-14 06:21:48 Xid 32 left one memory question we could not
# answer: the image's own /var/log/spark/memory-history.log had MemAvailable
# (a steady 3.8 GB on the worker) but NOT swap, PSI or the OOM-kill counter, so
# "was the worker thrashing at the fault?" had no witness. This is that witness.
#
#   journalctl --user -u spark-memwatch            # the minute lines
#   journalctl --user -u spark-memwatch -p warning # only the transitions
#
# One line a minute, plus a WARNING the moment any of these BEGINS (and an
# info line when it ends), so a long low-memory spell is two lines and not
# two hundred:
#   - /proc/vmstat oom_kill increments            (every increment, always)
#   - PSI memory full avg10 > PSI_FULL_MAX (5%)
#   - MemAvailable < AVAIL_MIN_KB (2 GiB)
#   - SwapFree < SWAP_FREE_MIN_PCT (10%) of SwapTotal
#
# ABSENT IS NOT ZERO: a file this cannot read prints `unreadable`, never 0.
#
# The unit runs a COPY of this file (ExecStartPre), because bash reads a
# script lazily by byte offset and a `git push` that edits a running script
# makes it exit 0 having done nothing.
set -u
INTERVAL=${INTERVAL:-15}
EVERY=${EVERY:-60}
AVAIL_MIN_KB=${AVAIL_MIN_KB:-2097152}
SWAP_FREE_MIN_PCT=${SWAP_FREE_MIN_PCT:-10}
PSI_FULL_MAX=${PSI_FULL_MAX:-5.0}

# systemd reads a <N> prefix as the syslog priority (SyslogLevelPrefix=yes).
info() { echo "<6>$*"; }
warn() { echo "<4>WARNING $*"; }

sample() {
  # prints: avail_kb swap_total_kb swap_free_kb psi_some10 psi_full10 oom_kill
  local a st sf ps pf ok
  read -r a st sf < <(awk '/^MemAvailable:/{a=$2} /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
      END{print (a==""?"x":a), (t==""?"x":t), (f==""?"x":f)}' /proc/meminfo 2>/dev/null) || a=x
  read -r ps pf < <(awk '{for(i=2;i<=NF;i++){split($i,kv,"="); if(kv[1]=="avg10") v[$1]=kv[2]}}
      END{print (v["some"]==""?"x":v["some"]), (v["full"]==""?"x":v["full"])}' \
      /proc/pressure/memory 2>/dev/null) || { ps=x; pf=x; }
  ok=$(awk '$1=="oom_kill"{print $2; f=1} END{if(!f) print "x"}' /proc/vmstat 2>/dev/null) || ok=x
  echo "${a:-x} ${st:-x} ${sf:-x} ${ps:-x} ${pf:-x} ${ok:-x}"
}

gib() { [ "$1" = x ] && echo unreadable || awk -v k="$1" 'BEGIN{printf "%.1fG", k/1048576}'; }

# Conditions as words, so a transition is a set difference.
conditions() {
  local a=$1 st=$2 sf=$3 pf=$5 out=""
  [ "$a" != x ] && [ "$a" -lt "$AVAIL_MIN_KB" ] && out="$out low_avail"
  if [ "$st" != x ] && [ "$sf" != x ] && [ "$st" -gt 0 ]; then
    [ $(( sf * 100 / st )) -lt "$SWAP_FREE_MIN_PCT" ] && out="$out low_swap"
  fi
  [ "$pf" != x ] && awk -v p="$pf" -v m="$PSI_FULL_MAX" 'BEGIN{exit !(p>m)}' && out="$out psi_full"
  echo "${out# }"
}

line() {
  local a=$1 st=$2 sf=$3 ps=$4 pf=$5 ok=$6 pct=unreadable
  if [ "$st" != x ] && [ "$sf" != x ]; then
    [ "$st" -gt 0 ] && pct="$(( sf * 100 / st ))%" || pct="no-swap"
  fi
  echo "avail=$(gib "$a") swap_free=$(gib "$sf")/$(gib "$st")($pct) psi_some10=${ps/x/unreadable} psi_full10=${pf/x/unreadable} oom_kill=${ok/x/unreadable}"
}

info "spark-memwatch on $(hostname -s): every ${INTERVAL}s, a line every ${EVERY}s; warn at avail<$(gib "$AVAIL_MIN_KB"), swap_free<${SWAP_FREE_MIN_PCT}%, psi_full10>${PSI_FULL_MAX}, any oom_kill. Logs only."
prev_ok=""; prev_cond=""; last=0
while :; do
  read -r a st sf ps pf ok <<< "$(sample)"
  now=$(date +%s)
  cur=$(conditions "$a" "$st" "$sf" "$ps" "$pf" "$ok")
  if [ "$ok" != x ] && [ -n "$prev_ok" ] && [ "$prev_ok" != x ] && [ "$ok" -gt "$prev_ok" ]; then
    warn "OOM KILL: oom_kill $prev_ok -> $ok ($(( ok - prev_ok )) new). $(line "$a" "$st" "$sf" "$ps" "$pf" "$ok")"
  fi
  for c in $cur; do
    case " $prev_cond " in *" $c "*) ;; *) warn "$c BEGINS: $(line "$a" "$st" "$sf" "$ps" "$pf" "$ok")";; esac
  done
  for c in $prev_cond; do
    case " $cur " in *" $c "*) ;; *) info "$c ends: $(line "$a" "$st" "$sf" "$ps" "$pf" "$ok")";; esac
  done
  if [ $(( now - last )) -ge "$EVERY" ]; then
    info "$(line "$a" "$st" "$sf" "$ps" "$pf" "$ok") active=[${cur:--}]"
    last=$now
  fi
  prev_ok=$ok; prev_cond=$cur
  sleep "$INTERVAL"
done

#!/usr/bin/env bash
# install-user-units.sh -- link this repo's user systemd units on THIS node and start them.
#
#   ssh spark-45ea ~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/local-ops/install-user-units.sh
#   ssh spark-da08 ~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/local-ops/install-user-units.sh
#
# CLASS: ACTUATOR on the HOST (starts services); touches no container.
#   spark-45ea   spark-memwatch + engine-supervisor
#   spark-da08   spark-memwatch
#   anywhere else: refuses -- the supervisor's first act on a crash is `down`
#   on both nodes, so it has no business being installed where it cannot also
#   start them.
#
# USER units, like sparkstats.service: linger is on and /home is on the host
# disk, so they survive reboots and spark-os image updates with no rebuild.
# Symlinks into ~/.config/systemd/user, so a push updates the unit; each unit
# copies its script at start, so a push never edits a running script. A
# changed SCRIPT takes effect on `systemctl --user restart <unit>`.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/systemd" && pwd)
case "$(hostname -s)" in
  spark-45ea) UNITS="spark-memwatch engine-supervisor" ;;
  spark-da08) UNITS="spark-memwatch" ;;
  *) echo "refusing: $(hostname -s) is neither spark-45ea nor spark-da08" >&2; exit 1 ;;
esac
[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] \
  || { echo "refusing: linger is off for $USER, so these would stop at logout" >&2; exit 1; }
mkdir -p ~/.config/systemd/user
for u in $UNITS; do
  ln -sfn "$HERE/$u.service" ~/.config/systemd/user/$u.service
done
systemctl --user daemon-reload
for u in $UNITS; do
  systemctl --user enable "$u.service" >/dev/null 2>&1 || systemctl --user enable "$u.service"
  systemctl --user restart "$u.service"
done
sleep 3
T=0
for u in $UNITS; do
  # The EFFECT, not the exit status: active, and it has said something.
  st=$(systemctl --user is-active "$u.service" || true)
  n=$(journalctl --user -u "$u.service" --since=-1min --no-pager -q 2>/dev/null | wc -l)
  echo "$(hostname -s) $u: $st, $(( n + 0 )) journal line(s) in the last minute"
  [ "$st" = active ] && [ "$(( n + 0 ))" -ge 1 ] || T=1
done
exit $T

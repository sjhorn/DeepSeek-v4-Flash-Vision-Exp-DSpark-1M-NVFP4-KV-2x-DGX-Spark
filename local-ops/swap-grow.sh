#!/usr/bin/env bash
# swap-grow.sh -- grow the spark-os swap file to 64 GiB, IN PLACE. Run with sudo, once per node.
#
#   sudo ~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/local-ops/swap-grow.sh
#
# CLASS: ACTUATOR on the HOST (swapoff, a 64 GiB file, swapon). Touches no container.
#
# WHY. 16 GiB on both nodes, with 13.8 GiB used on the head and 11.5 GiB on the
# worker on 2026-10-14 -- the head had ~2 GiB of swap left while running.
#
# WHEN. Only with the engine DOWN on this node. With it running, swapoff must
# page 10+ GiB back into 3-4 GiB of MemAvailable, and there is no OOM net under
# spark-os. So this REFUSES if a dspark container exists or swap use exceeds
# 2 GiB; run it in the restart window, after `down` and before the start.
#
# SAME PATH, /run/sparkos/host/swap-64k.img (the 64k-page swap sparkos-swap
# looks for), so sparkos-swap.service picks it up at every boot and
# `kindling-setup install` skips it because it exists: it survives reboots and
# image updates. DGX OS's own 4k swap is not touched.
#
# STATED TRADE-OFF: with no OOM killer, more swap also lengthens a possible
# thrash. spark-watchdog still resets the box if it cannot fork, and
# spark-memwatch (journal) shows swap and PSI on the way there.
set -euo pipefail
SWAP=${SWAP:-/run/sparkos/host/swap-64k.img}
SIZE_G=${SIZE_G:-64}
MAX_USED_KB=$(( 2 * 1024 * 1024 ))

case "$(hostname -s)" in spark-45ea|spark-da08) ;; *)
  echo "refusing: $(hostname -s) is not a Spark" >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo "refusing: run with sudo" >&2; exit 1; }
[ -f "$SWAP" ] || { echo "refusing: $SWAP does not exist -- this grows it, it does not create the setup" >&2; exit 1; }
[ "$(getconf PAGESIZE)" = 65536 ] || { echo "refusing: page size is $(getconf PAGESIZE), not 64k" >&2; exit 1; }

n=$(docker ps -aq --filter name=dspark | wc -l)
if [ "$(( n + 0 ))" -ne 0 ]; then
  echo "refusing: $(( n + 0 )) dspark container(s) exist on this node -- \`down\` the engine first:" >&2
  docker ps -a --filter name=dspark --format '  {{.Names}} {{.Status}}' >&2
  exit 1
fi
used=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t-f}' /proc/meminfo)
if [ "$used" -gt "$MAX_USED_KB" ]; then
  echo "refusing: swap in use is $(( used / 1024 )) MiB (> 2048 MiB); swapoff would page it into RAM" >&2
  exit 1
fi
want=$(( SIZE_G * 1024 * 1024 * 1024 ))
have=$(stat -c %s "$SWAP")
free=$(df -B1 --output=avail "$(dirname "$SWAP")" | tail -1)
if [ "$have" -ge "$want" ]; then
  echo "nothing to do: $SWAP is already $(( have >> 30 )) GiB"; swapon --show; exit 0
fi
if [ "$(( free + have ))" -lt "$(( want + (100 << 30) ))" ]; then
  echo "refusing: $(( free >> 30 )) GiB free; growing to ${SIZE_G} GiB would leave under 100 GiB" >&2; exit 1
fi

echo "before:"; swapon --show
swapoff "$SWAP" 2>/dev/null || true      # sparkos-swap off would do the same, but quietly either way
if swapon --show=NAME --noheadings | grep -qx "$SWAP"; then
  echo "FAILED: $SWAP is still active after swapoff; nothing changed" >&2; exit 1
fi
tmp="$SWAP.new"
rm -f "$tmp"
fallocate -l "${SIZE_G}G" "$tmp"
chmod 600 "$tmp"
mkswap -p 65536 "$tmp" >/dev/null
mv -f "$tmp" "$SWAP"
/usr/local/sbin/sparkos-swap on
echo "after:"; swapon --show
# The EFFECT: the active swap is the new size, not just a file on disk.
got=$(swapon --show=NAME,SIZE --bytes --noheadings | awk -v s="$SWAP" '$1==s{print $2}')
if [ -z "$got" ] || [ "$got" -lt $(( want - (1 << 30) )) ]; then
  echo "FAILED: active size is '${got:-none}', wanted ~${SIZE_G} GiB" >&2; exit 1
fi
echo "OK: $SWAP active at $(( got >> 30 )) GiB on $(hostname -s)"

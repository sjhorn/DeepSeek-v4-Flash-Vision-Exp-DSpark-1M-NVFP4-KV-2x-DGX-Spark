#!/usr/bin/env bash
# From the Mac: install sudoers rules on BOTH nodes, asking for the sudo
# password once per node. Copies the rule(s) and install-sudoers.sh to a
# temporary directory on each node, so it needs no push and never dirties the
# nodes' checkouts.
#
#   bash local-ops/grant-sudoers.sh dspark-dmesg
#   NODES="spark-45ea" bash local-ops/grant-sudoers.sh dspark-dmesg
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES=${NODES:-"spark-45ea spark-da08"}
[ "$#" -gt 0 ] || { echo "usage: $0 dspark-<rule> [...]" >&2; exit 1; }
for name in "$@"; do
  [ -f "$HERE/$name" ] || { echo "missing $HERE/$name" >&2; exit 1; }
done

for h in $NODES; do
  echo "== $h"
  d=$(ssh "$h" mktemp -d)
  scp -q "$HERE/install-sudoers.sh" "${@/#/$HERE/}" "$h:$d/"
  ssh -t "$h" "sudo bash $d/install-sudoers.sh $*; rc=\$?; rm -rf $d; exit \$rc"
done

# What the rules grant, checked without a password.
for h in $NODES; do
  for name in "$@"; do
    case "$name" in
      dspark-dmesg) ssh "$h" 'sudo -n dmesg -T >/dev/null && echo "$(hostname): sudo -n dmesg OK"' ;;
    esac
  done
done

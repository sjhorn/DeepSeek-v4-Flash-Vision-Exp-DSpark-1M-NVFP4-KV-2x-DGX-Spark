#!/usr/bin/env bash
# Install sudoers rules from this directory. Run with sudo, on BOTH nodes.
#
#   sudo ./install-sudoers.sh                    # dspark-dropcaches (as before)
#   sudo ./install-sudoers.sh dspark-dmesg       # one or more named rules
#
# From the Mac, `bash local-ops/grant-sudoers.sh <rule>` does both nodes.
# Each rule is checked with `visudo -cf` BEFORE it is installed, then the whole
# configuration with `visudo -c` after; a rule that fails is removed, so a bad
# file can never lock sudo out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
[ "$#" -gt 0 ] || set -- dspark-dropcaches

for name in "$@"; do
  case "$name" in dspark-*) ;; *) echo "refusing $name: rules are named dspark-*" >&2; exit 1;; esac
  SRC="$HERE/$name"
  DST="/etc/sudoers.d/$name"
  [ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
  visudo -cf "$SRC" >/dev/null || { echo "$name does not parse; not installed" >&2; exit 1; }

  install -m 0440 -o root -g root "$SRC" "$DST"
  echo "installed $DST"

  if visudo -c >/dev/null 2>&1; then
    echo "sudoers validation: OK"
  else
    echo "sudoers validation FAILED - removing to avoid locking out sudo" >&2
    rm -f "$DST"
    visudo -c || true
    exit 1
  fi
done
echo "done on $(hostname)"

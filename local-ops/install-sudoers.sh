#!/usr/bin/env bash
# Install the drop_caches sudoers rule. Run with sudo, on BOTH nodes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/dspark-dropcaches"
DST=/etc/sudoers.d/dspark-dropcaches

[ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

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
echo "done on $(hostname)"

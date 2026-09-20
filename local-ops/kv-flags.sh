#!/usr/bin/env bash
# kv-flags.sh — read or flip the MNT-8 / MNT-9 runtime flags on BOTH nodes.
#
# WHY THIS EXISTS.  Container env vars cannot change on a running engine, so an
# env-gated experiment costs one 250-600s cold boot per arm, with every session
# on the cluster interrupted.  These two mechanisms are gated on a JSON file the
# engine re-reads once a second instead, so the A/B costs ONE restart total.
#
#   bash local-ops/kv-flags.sh                     # show both nodes
#   bash local-ops/kv-flags.sh free_queue_prepend_uncached 1
#   bash local-ops/kv-flags.sh swa_recycle_cached 0   # arm E -- the likely fix
  bash local-ops/kv-flags.sh swa_recycle 0          # arm D -- MNT-6b off entirely
  bash local-ops/kv-flags.sh pin_static_head 1
#   bash local-ops/kv-flags.sh reset               # everything OFF (arm A)
#
# Flags (defaults OFF, which is stock behaviour):
#   free_queue_prepend_uncached   MNT-8, vllm#43447 free-queue ordering
#   pin_static_head               MNT-9, pin the tools+system head at B
#   head_pin_fraction             MNT-9 budget, share of the pool per manager (0.05)
#   head_pin_partial              MNT-9, pin even an incomplete run (default 0 -- a
#                                 partial run cannot serve a hit; this is for
#                                 diagnosis only)
#   swa_recycle                   MNT-6b master switch (default 1 = recycle).
#                                 VLLM_SWA_RECYCLE_SKIPPED_BLOCKS still overrides.
#   swa_recycle_cached            MNT-6c (default 1 = today's behaviour). Set 0 to
#                                 recycle only pages with NO cache entry, so the
#                                 prefix-cache mappings survive decode. This is the
#                                 arm for the 2026-09-20 root cause, CACHE_TEST.md 8.
#
# A flip takes effect on the NEXT request. It does not re-order blocks already
# freed, so give an arm a fresh session, not a running one. An env var of the
# same name (VLLM_<NAME>) always wins over this file -- nothing sets one today.
#
# See CACHE_TEST.md for the arms and what each one is supposed to move.
set -uo pipefail

NODES="${NODES:-spark-45ea spark-da08}"
USER_AT="${USER_AT:-shorn}"
FLAGS=/var/tmp/vllm-kv-flags/flags.json

show() {
  for n in $NODES; do
    printf '%-12s ' "$n"
    ssh "${USER_AT}@${n}" "cat $FLAGS 2>/dev/null || echo '(no flags file)'"
  done
}

case "${1:-}" in
  "" ) show; exit 0 ;;
  reset ) key=""; ;;
  * ) key="$1"; val="${2:-}" ;;
esac

for n in $NODES; do
  if [ -z "$key" ]; then
    ssh "${USER_AT}@${n}" "mkdir -p \$(dirname $FLAGS) && printf '%s\n' '{\"free_queue_prepend_uncached\": 0, \"pin_static_head\": 0}' > $FLAGS"
  else
    [ -n "$val" ] || { echo "usage: $0 <flag> <value> | reset" >&2; exit 2; }
    # Rewrite atomically: a half-written file reads as bad JSON, which the
    # engine treats as "every flag off" -- a silent arm change mid-run.
    ssh "${USER_AT}@${n}" "python3 - <<PY
import json, os, tempfile
p = '$FLAGS'
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    d = json.load(open(p))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
raw = '$val'
try:
    d['$key'] = int(raw)
except ValueError:
    d['$key'] = float(raw)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, 'w') as fh:
    json.dump(d, fh); fh.write('\n')
os.replace(tmp, p)
PY"
  fi
done
echo "--- now:"
show

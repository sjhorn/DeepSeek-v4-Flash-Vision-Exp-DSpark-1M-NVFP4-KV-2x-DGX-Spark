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
#   bash local-ops/kv-flags.sh swa_recycle 0          # arm D -- MNT-6b off entirely
#   bash local-ops/kv-flags.sh pin_static_head 1
#   bash local-ops/kv-flags.sh reset               # the RECOMMENDED state (keeps the fix)
#
# THE TWO LINES ABOVE LOST THEIR '#' ONCE AND FORK-BOMBED THE LAPTOP. They sit
# above `set -uo pipefail`, so they were the FIRST executable statements in the
# file -- which means EVERY invocation ran them, including the no-argument one
# whose entire job is to print the current flags. Each ran
# `bash local-ops/kv-flags.sh swa_recycle 0`, which reached the same line and
# did it again: not an exponential bomb but an infinitely deep chain, one child
# per level, which is why `ps` showed thousands of bash processes each with
# exactly one bash child. It reached the 8000-process per-uid cap in seconds
# and left the machine unable to fork at all -- including unable to fork the
# pkill that would have cleaned it up.
#
# It never reached the ssh below, so no node was touched; the damage was
# entirely local. If you edit this block, keep every example commented.
#
# Flags (defaults OFF, which is stock behaviour -- EXCEPT the two noted below,
# swa_recycle_cached and long_prefill_token_threshold, whose defaults are ours):
#   long_prefill_token_threshold  MNT-10. Max tokens ONE request may take per
#                                 scheduler step. **Omitted from `reset` ON
#                                 PURPOSE**: with no key the engine falls through
#                                 to its BOOT value, which is the state we want.
#                                 *** That boot value is 2048 on the RUNNING
#                                 engine, not the 1024 the compose now names.
#                                 The compose changed after this container
#                                 started and a push is not a restart (verified
#                                 2026-09-21 against the container command line;
#                                 docs/local/CACHE-TEST.md 12.5).  An arm that
#                                 treats "no key" as 1024 is measuring 2048. ***
#                                 Set it only to A/B a different cap, e.g.
#                                 `kv-flags.sh long_prefill_token_threshold 1024`;
#                                 `0` disables the cap and restores the starvation.
#                                 Unlike every other flag here, a corrupt/missing
#                                 flags file falls back to the LAST GOOD value and
#                                 then the boot value -- never to 0. See
#                                 docs/local/status/INCIDENTS.md "Decode collapses
#                                 to ~2 tok/s beside a long prefill".
#   free_queue_prepend_uncached   MNT-8, vllm#43447 free-queue ordering
#   pin_static_head               MNT-9, pin the tools+system head at B
#   head_pin_fraction             MNT-9 budget, share of the pool per manager (0.05)
#   head_pin_partial              MNT-9, pin even an incomplete run (default 0 -- a
#                                 partial run cannot serve a hit; this is for
#                                 diagnosis only)
#   swa_recycle                   MNT-6b master switch (default 1 = recycle).
#                                 VLLM_SWA_RECYCLE_SKIPPED_BLOCKS still overrides.
#   swa_recycle_cached            MNT-6c. **0 is the CONFIRMED FIX. Since the
#                                 2026-09-21 restart the CODE default is 0, so the
#                                 fix survives a cleared /var/tmp and a fresh node,
#                                 and this file is the ESCAPE HATCH (set 1 for the
#                                 old, broken behaviour) rather than the enabler.**
#                                 Note the fail-safe direction also flipped: bad
#                                 JSON reads as "every flag at its default", which
#                                 now KEEPS the fix instead of silently dropping it.
#                                 Recycles only pages with
#                                 NO cache entry, so prefix-cache mappings survive
#                                 decode. Head after a session 0.0%/14.4s -> 99.5%/
#                                 0.5s, 3/3. docs/local/CACHE-TEST.md 9.
#
# A flip takes effect on the NEXT request. It does not re-order blocks already
# freed, so give an arm a fresh session, not a running one. An env var of the
# same name (VLLM_<NAME>) always wins over this file -- nothing sets one today.
#
# See docs/local/CACHE-TEST.md for the arms and what each one is supposed to move.
set -uo pipefail

NODES="${NODES:-spark-45ea spark-da08}"
USER_AT="${USER_AT:-shorn}"
FLAGS=/var/tmp/vllm-kv-flags/flags.json

show() {
  for n in $NODES; do
    printf '%-12s ' "$n"
    ssh -n "${USER_AT}@${n}" "cat $FLAGS 2>/dev/null || echo '(no flags file)'"
  done
}

case "${1:-}" in
  "" ) show; exit 0 ;;
  reset ) key=""; ;;
  * ) key="$1"; val="${2:-}" ;;
esac

for n in $NODES; do
  if [ -z "$key" ]; then
    # RESET = the RECOMMENDED state, not the pre-2026-09-21 one. swa_recycle_cached
    # MUST be listed here: it is the confirmed fix for the prefix being destroyed by
    # multi-turn decode (docs/local/CACHE-TEST.md 9), and an earlier reset that wrote only two
    # keys would have silently restored the bug. To get the OLD behaviour for an
    # A/B, set it explicitly: `kv-flags.sh swa_recycle_cached 1`.
    ssh -n "${USER_AT}@${n}" "mkdir -p \$(dirname $FLAGS) && printf '%s\n' '{\"free_queue_prepend_uncached\": 0, \"pin_static_head\": 0, \"swa_recycle\": 1, \"swa_recycle_cached\": 0}' > $FLAGS"
  else
    [ -n "$val" ] || { echo "usage: $0 <flag> <value> | reset" >&2; exit 2; }
    # Rewrite atomically: a half-written file reads as bad JSON, which the
    # engine treats as "every flag off" -- a silent arm change mid-run.
    ssh -n "${USER_AT}@${n}" "python3 - <<PY
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

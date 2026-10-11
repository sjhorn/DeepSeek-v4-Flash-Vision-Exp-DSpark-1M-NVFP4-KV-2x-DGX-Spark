#!/usr/bin/env bash
# INSTALL local-ops/flags.reference.json AS THE BOOT CONFIGURATION ON BOTH NODES.
#
# WHY THIS EXISTS. /var/tmp/vllm-kv-flags/flags.json is the boot-time default for
# every policy knob, and it is per node and not in git. Measured 2026-10-10: the
# head's file was 12 keys from Oct 10 and the WORKER's was 9 keys from Oct 7, and
# they DISAGREED -- worker `disk_restore: 1` against head `0`, with
# `disk_store_paused` absent on the worker entirely. The boot fan-out saves us
# (both ranks read the head's values; verified live), so the divergence was
# harmless and completely invisible. That is exactly the shape of this project's
# documented stale-worker-file trap, and an unversioned file nobody can diff is
# how it stays invisible.
#
# So: the committed JSON is the source, this installs it identically on both, and
# `verify` diffs the live files against it.
#
# *** THIS SETS BOOT DEFAULTS ONLY. *** A running engine does not re-read the
# file, so applying this changes nothing until the next restart. To change a LIVE
# engine use the control plane (`POST /kv/knob`), which fans out per rank and
# returns each rank's answer -- never hand-edit the file for a worker-side knob.
set -u
REF="$(cd "$(dirname "$0")" && pwd)/flags.reference.json"
DEST=/var/tmp/vllm-kv-flags/flags.json
NODES="spark-45ea spark-da08"
MODE="${1:-verify}"

[ -s "$REF" ] || { echo "missing $REF"; exit 1; }
# strip the _comment keys: they document the committed file, and the plugin would
# log them as unknown knobs on every boot.
python3 -I -c "
import json
d = json.load(open('$REF'))
json.dump({k: v for k, v in d.items() if not k.startswith('_')},
          open('/tmp/flags.apply.json', 'w'), indent=2, sort_keys=True)
" || exit 1
echo "reference (comments stripped):"
sed 's/^/  /' /tmp/flags.apply.json; echo

case "$MODE" in
  verify)
    rc=0
    for n in $NODES; do
      echo "=== $n ==="
      if ! scp -q /tmp/flags.apply.json "$n:/tmp/flags.want.json" 2>/dev/null; then
        echo "  UNREACHABLE -- that is not the same as 'in step'"; rc=1; continue
      fi
      ssh -o BatchMode=yes "$n" "
        [ -s $DEST ] || { echo '  NO FILE AT $DEST'; exit 3; }
        ls -l $DEST | sed 's/^/  /'
        python3 -I -c \"
import json
live = json.load(open('$DEST')); want = json.load(open('/tmp/flags.want.json'))
bad = False
for k in sorted(want):
    l, w = live.get(k, '<absent>'), want[k]
    if l != w:
        print('  DIFFERS %-22s live=%-16s want=%s' % (k, l, w)); bad = True
extra = sorted(set(live) - set(want))
if extra:
    print('  extra, preserved (state, not config): %s' % ', '.join(
        '%s=%s' % (k, live[k]) for k in extra))
print('  IN STEP' if not bad else '  OUT OF STEP')
raise SystemExit(1 if bad else 0)
\"" || rc=1
    done
    exit $rc ;;
  apply)
    for n in $NODES; do
      echo "=== $n ==="
      scp -q /tmp/flags.apply.json "$n:/tmp/flags.want.json" || { echo "  scp FAILED"; exit 1; }
      # keep a timestamped backup, write atomically, restore the 0600 the
      # plugin's own writer uses
      ssh -o BatchMode=yes "$n" "
        mkdir -p \$(dirname $DEST)
        [ -f $DEST ] && cp -p $DEST $DEST.bak.\$(date +%Y%m%d-%H%M%S)
        python3 -I -c \"
import json, os
dest, want = '$DEST', json.load(open('/tmp/flags.want.json'))
try:
    live = json.load(open(dest))
except Exception:
    live = {}
kept = {k: v for k, v in live.items() if k not in want}
if kept:
    print('  preserving: %s' % ', '.join('%s=%s' % kv for kv in sorted(kept.items())))
live.update(want)
tmp = dest + '.tmp'
with open(tmp, 'w') as f:
    json.dump(live, f, indent=2, sort_keys=True)
os.chmod(tmp, 0o600)
os.replace(tmp, dest)
print('  wrote %d knobs' % len(live))
\"
      " || exit 1
    done
    echo "applied. NOTE: boot defaults only -- a running engine is unchanged."
    exec "$0" verify ;;
  *) echo "usage: $0 [verify|apply]"; exit 2 ;;
esac

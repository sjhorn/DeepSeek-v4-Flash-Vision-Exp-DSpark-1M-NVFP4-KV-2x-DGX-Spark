#!/usr/bin/env bash
# kvmgr-flag.sh -- set a kvmgr knob on BOTH nodes and WAIT FOR THE ENGINE TO SAY
# IT TOOK, rather than assuming it did.
#
#   bash local-ops/kvmgr-flag.sh                       # show effective values
#   bash local-ops/kvmgr-flag.sh kvmgr_enabled 1
#   bash local-ops/kvmgr-flag.sh protected_fraction 0.75
#   bash local-ops/kvmgr-flag.sh --no-wait evict_order lru
#
# WHY THIS EXISTS BESIDE kv-flags.sh.  kv-flags.sh writes the file and prints
# it, which answers "what did I write" and NOT "what is the engine using".
# Those differ in two ways that are both silent:
#
#   1. env WINS over the file in _flag(), so a knob also set in .env.dspark
#      cannot be moved from the file at all -- you edit it, nothing changes, and
#      nothing says why.  VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION is set in
#      .env.dspark on both nodes TODAY.
#   2. the file is re-read on a 1s TTL, so a read straight after a write can
#      still report the old value.
#
# So this tails the engine log for the line the manager emits ON CHANGE, and
# fails if it does not arrive.  "Did it take?" is answered, not assumed.
#
# EVERY EXAMPLE ABOVE IS COMMENTED, AND MUST STAY THAT WAY.  kv-flags.sh once
# lost the '#' on two example lines, which sat above `set -uo pipefail` and so
# ran on EVERY invocation -- each re-invoking this script, one child per level,
# to the 8000-process per-uid cap in seconds.  The machine could not fork the
# pkill that would have cleaned it up.

set -uo pipefail

NODES=(spark-45ea spark-da08)
FLAGS_DIR=/var/tmp/vllm-kv-flags
FLAGS=$FLAGS_DIR/flags.json
WAIT=1
TIMEOUT_S=${KVMGR_FLAG_TIMEOUT_S:-30}

while [[ ${1-} == --* ]]; do
  case "$1" in
    --no-wait) WAIT=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

# ---- read-only: what is the engine ACTUALLY using ------------------------
if [[ $# -eq 0 ]]; then
  for n in "${NODES[@]}"; do
    echo "=== $n ==="
    # The engine's own answer first, if the stats port is up: it accounts for
    # env overriding the file, which reading the file cannot.
    ssh -o BatchMode=yes "$n" "
      port=\$(python3 -c \"import json;print(json.load(open('$FLAGS')).get('kvmgr_stats_port',0))\" 2>/dev/null || echo 0)
      if [ \"\$port\" != '0' ] && curl -fsS --max-time 3 \"http://127.0.0.1:\$port/flags\" 2>/dev/null; then
        echo
      else
        echo '(no stats port; showing the FILE, which env may override)'
        cat '$FLAGS' 2>/dev/null || echo '{}  (absent -- defaults, i.e. todays behaviour)'
      fi" 2>&1 | sed 's/^/  /'
  done
  exit 0
fi

if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--no-wait] <flag> <value>" >&2
  exit 2
fi
KEY=$1
VAL=$2

for n in "${NODES[@]}"; do
  echo "=== $n: $KEY -> $VAL ==="

  # Refuse rather than mislead: a knob pinned by env cannot be moved here.
  pinned=$(ssh -o BatchMode=yes "$n" "
    cid=\$(docker ps --filter name=vllm --format '{{.ID}}' | head -1)
    [ -n \"\$cid\" ] && docker exec \"\$cid\" env 2>/dev/null |
      grep -iE '^VLLM_(${KEY}|PROTECTED_PROMPT_BLOCKS_FRACTION)=' || true" 2>/dev/null)
  if [[ -n $pinned ]]; then
    echo "  REFUSING: the container env pins this knob, so the flags file cannot"
    echo "  move it and the edit would do nothing silently:"
    echo "$pinned" | sed 's/^/    /'
    echo "  Remove it from .env.dspark on BOTH nodes (it is gitignored, so this is"
    echo "  an on-box edit, never a push) and restart, or pick another knob."
    continue
  fi

  since=$(ssh -o BatchMode=yes "$n" "date -u +%Y-%m-%dT%H:%M:%S" 2>/dev/null)

  # Merge, never overwrite: the file carries MNT-6b/8/9 flags too, and
  # clobbering swa_recycle_cached restores a bug this stack already paid for.
  # NO sudo. /var/tmp/vllm-kv-flags is owned by the login user and
  # flags.json is 0600 shorn -- the container runs as the same uid, which is
  # why it can read it. kv-flags.sh uses sudo for both, which is unnecessary
  # and, since passwordless sudo stopped being granted, now simply FAILS with
  # "a password is required" under BatchMode. Writing as the owner is both
  # correct and what works.
  ssh -o BatchMode=yes "$n" "
    mkdir -p '$FLAGS_DIR' &&
    python3 - '$FLAGS' '$KEY' '$VAL' <<'PY'
import json, os, sys
path, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as fh:
        cur = json.load(fh)
    if not isinstance(cur, dict):
        cur = {}
except Exception:
    cur = {}
for cast in (int, float):
    try:
        raw = cast(raw); break
    except ValueError:
        continue
cur[key] = raw
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(cur, fh, indent=1, sort_keys=True)
os.chmod(tmp, 0o600)   # keep the mode the engine already reads
os.replace(tmp, path)          # atomic: a half-written file reads as defaults
print('wrote', path, '->', json.dumps(cur, sort_keys=True))
PY" 2>&1 | sed 's/^/  /'

  [[ $WAIT -eq 0 ]] && continue

  # Wait for the engine to SAY it took. The manager logs on change only, so a
  # flip that changed nothing legitimately produces no line -- which is why a
  # timeout reports "no change line" rather than "failed".
  echo "  waiting up to ${TIMEOUT_S}s for the engine to confirm..."
  ssh -o BatchMode=yes "$n" "
    cid=\$(docker ps --filter name=vllm --format '{{.ID}}' | head -1)
    [ -z \"\$cid\" ] && { echo 'no vllm container'; exit 1; }
    timeout ${TIMEOUT_S} docker logs -f --since '${since}' \"\$cid\" 2>&1 |
      grep -m1 -E 'kvmgr: (${KEY} CHANGED|protected cap for KV group|reconciled KV group)'
  " 2>&1 | sed 's/^/    /' ||
    echo "    NO CHANGE LINE in ${TIMEOUT_S}s. Either the value was already in" \
         "force (a no-op logs nothing, by design), the engine has not reached" \
         "this path yet (the cap logs on FIRST USE, not at boot), or kvmgr is" \
         "not loaded at all -- check for 'kvmgr: registered' in the log."
done

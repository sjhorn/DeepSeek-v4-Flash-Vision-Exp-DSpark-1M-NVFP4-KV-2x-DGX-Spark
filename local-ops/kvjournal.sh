#!/usr/bin/env bash
# READ THE PRESENCE JOURNAL'S STATE. Read-only, always. Runs ON THE HEAD.
#
# WHY THIS EXISTS. Nothing in local-ops could see journal state at all -- no
# script read `presence.json.journal` or `.compacting`, so every statement ever
# made about the journal was made by hand-running python inside an ssh quote.
# That is the shape this repo keeps paying for: the 5,175-key orphan window was
# found by hand arithmetic, and a guessed key name in one of those ad-hoc
# readers produced a manufactured zero.
#
# THE JOURNAL IS HEAD-ONLY, and that is not a bug to report. The manager is
# scheduler-side (one process, in the engine core, on the head), so the worker
# has no snapshot, no journal and no index. `state` says so explicitly rather
# than printing an absence that reads like a fault.
#
# PORTS, because this has cost a whole evening: STATE READS GO TO :9199. GET /kv
# on :8888 is answered by the API SERVER process, which holds no manager, so
# `disk` comes back null there -- documented as "no disk spec in force" and
# meaning "wrong process". /kv/workers is the exception and lives on :8888.
set -u

API=http://127.0.0.1:8888      # knobs, /kv/workers -- NOT state
STATS=http://127.0.0.1:9199    # the engine core's own listener -- state reads
DIR=${KVJ_DIR:-$HOME/kvoffload/dspark-kv-v1}
C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
SNAP="$DIR/presence.json"
WORKER=${KVJ_WORKER:-spark-da08}

die(){ echo "kvjournal: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# the files, as bytes and mtimes, plus the two transient names
# ---------------------------------------------------------------------------
# `.compacting` and `.part` are the crash-window names and the ONLY reason this
# tool can be pointed at a rotation in the act. Both are reported as present or
# absent rather than silently skipped, because "no .compacting" is the normal
# state and "a .compacting that has been there for minutes" is a finding.
files(){
  local f
  for f in "$SNAP" "$SNAP.journal" "$SNAP.compacting" "$SNAP.part"; do
    if [ -e "$f" ]; then
      # mtime off stat, never off `ls`: this box is UTC+2 and `ls` prints local
      # time, which has already made a rotated log look hours out of date.
      printf '  %-28s %12s bytes  %s\n' "$(basename "$f")" \
        "$(stat -c %s "$f")" "$(stat -c %y "$f" | cut -d. -f1)"
    else
      printf '  %-28s %12s\n' "$(basename "$f")" "ABSENT"
    fi
  done
  if [ -e "$SNAP.journal" ]; then
    printf '  %-28s %12s records (lines)\n' "journal" "$(wc -l < "$SNAP.journal")"
  fi
  if [ -e "$SNAP.compacting" ]; then
    # *** IN FLIGHT AND LEFT OVER LOOK IDENTICAL, AND THEY WANT OPPOSITE
    # *** READINGS. *** A `.compacting` is created by the rotate and removed
    # only by a SUCCESSFUL snapshot write, so one surviving a kill sits there
    # across the whole next boot -- and calling that "a rotation is in flight"
    # is a reading of the wrong thing, which is the trap this repo keeps
    # paying for. The discriminator is a TIMESTAMP COMPARISON against the
    # container's StartedAt, the same instrument that settled whether a
    # bind-mounted patch was live: a `.compacting` OLDER than the process that
    # would have to be writing it cannot be being written.
    local cl ct st
    cl=$(wc -l < "$SNAP.compacting")
    ct=$(stat -c %Y "$SNAP.compacting")
    st=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)
    if [ -n "$st" ] && st=$(date -d "$st" +%s 2>/dev/null) && [ "$ct" -lt "$st" ]; then
      printf '  %-28s %12s records (lines)  <-- LEFT OVER from a process that died\n' \
        "compacting" "$cl"
      printf '  %-28s %12s\n' "" "mid-rotate: it predates this container, so nothing is writing it."
      printf '  %-28s %12s\n' "" "It is replayed at load and dropped by the next successful snapshot,"
      printf '  %-28s %12s\n' "" "whose rotate will DEFER once (journal_rotate_deferred) and lose nothing."
    else
      printf '  %-28s %12s records (lines)  <-- a rotation may be IN FLIGHT\n' \
        "compacting" "$cl"
    fi
  fi
}

# ---------------------------------------------------------------------------
# the disk index off :9199
# ---------------------------------------------------------------------------
# PRINT WHAT IS MISSING AS `unreadable`, NEVER AS A DEFAULT. A probe pointed at
# the wrong port answers {"error":"not found"}, and `(d.get(x) or 0)` renders
# that as a clean zero -- three separate confident zeros in this project came
# from exactly that. So an absent key says so.
index(){
  curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  index: UNREADABLE -- :9199 returned no JSON (is this the head?)")
    raise SystemExit(0)
dk = d.get("disk", "__absent__")
if dk == "__absent__" or dk is None:
    # None is the manager saying "no disk spec is in force". On :8888 it also
    # means "wrong process", which is why the port is pinned above.
    print("  index: no disk spec in force (disk=null)")
    raise SystemExit(0)
if not isinstance(dk, dict):
    print("  index: UNEXPECTED SHAPE %r" % (type(dk).__name__,))
    raise SystemExit(0)
want = ("present", "bytes_held", "byte_accounting_ok", "over_budget",
        "manifest_loaded", "manifest_pruned", "manifest_writes",
        "manifest_skipped_busy", "stored", "skipped_present", "lookup", "hit",
        "journal_records", "journal_adds", "journal_removes", "journal_clears",
        "journal_torn", "journal_appends", "journal_rotations",
        "journal_compactions", "journal_rotate_deferred", "journal_errors")
for k in want:
    v = dk.get(k, "__absent__")
    # A counter that has never been incremented is genuinely absent from
    # _stats, because every journal counter is `.get(k, 0) + 1`. "never" is a
    # different statement from 0 and is printed as one.
    print("  %-26s %s" % (k, "never" if v == "__absent__" else v))
for k in sorted(dk):
    if k.startswith("journal_") and k not in want:
        print("  %-26s %s   <-- NEW KEY, not in this script" % (k, dk[k]))
'
}

# ---------------------------------------------------------------------------
# nameable: the gap arithmetic that measured zero
# ---------------------------------------------------------------------------
# THE SCHEMA IS READ OFF diskspec.py, NOT GUESSED. Snapshot is
# {"keys": [[hex, pos], ...]} with a legacy bare-string form (pos unknown);
# a journal record is one JSON object per LINE, {"a": [[hex,pos],...]} /
# {"r": [hex,...]} / {"c": 1}. The replay below mirrors journal_replay exactly,
# including the two rules that are easy to get wrong:
#   - a torn record STOPS the replay. Nothing after a partial append is
#     evidence about anything, so skipping it would apply changes from the far
#     side of a gap.
#   - `compacting` is replayed BEFORE `journal`: it was frozen before the
#     snapshot it is paired with, so its records are the older ones.
nameable(){
  python3 -I - "$SNAP" <<'PY'
import json, os, sys
snap = sys.argv[1]
base = []
legacy = 0
if os.path.exists(snap):
    try:
        with open(snap) as f:
            raw = json.load(f).get("keys", [])
    except Exception as e:
        print("  snapshot UNREADABLE (%s) -- treating as an empty base, which "
              "is what _load_manifest does" % (e.__class__.__name__,))
        raw = []
    for item in raw:
        if isinstance(item, str):
            base.append((bytes.fromhex(item), -1)); legacy += 1
        else:
            base.append((bytes.fromhex(item[0]), int(item[1])))
else:
    print("  snapshot ABSENT -- an empty base, not an early return")

entries = dict((k, p) for k, p in base)
snap_keys = len(entries)
tot = {"records": 0, "adds": 0, "removes": 0, "clears": 0, "torn": 0}
per = []
for path in (snap + ".compacting", snap + ".journal"):
    if not os.path.exists(path):
        continue
    st = {"records": 0, "adds": 0, "removes": 0, "clears": 0, "torn": 0}
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                st["torn"] = 1; break
            try:
                d = json.loads(s)
            except Exception:
                st["torn"] = 1; break
            if not isinstance(d, dict) or len(d) != 1:
                st["torn"] = 1; break
            kind, payload = next(iter(d.items()))
            if kind == "a":
                try:
                    items = [(bytes.fromhex(i[0]), int(i[1])) for i in payload]
                except Exception:
                    st["torn"] = 1; break
                st["records"] += 1
                for k, p in items:
                    if k not in entries:
                        entries[k] = p; st["adds"] += 1
            elif kind == "r":
                try:
                    ks = [bytes.fromhex(h) for h in payload]
                except Exception:
                    st["torn"] = 1; break
                st["records"] += 1
                for k in ks:
                    if entries.pop(k, None) is not None:
                        st["removes"] += 1
            elif kind == "c":
                st["records"] += 1
                entries.clear(); st["clears"] += 1
            else:
                st["torn"] = 1; break
    per.append((os.path.basename(path), st))
    for k in tot:
        tot[k] += st[k]

print("  snapshot keys              %d%s" % (
    snap_keys, "  (%d legacy bare-string, pos unknown)" % legacy if legacy else ""))
for name, st in per:
    print("  %-26s %d records: %d adds outside the snapshot, %d removes, "
          "%d clears, torn=%d" % (name, st["records"], st["adds"],
                                  st["removes"], st["clears"], st["torn"]))
if not per:
    print("  journal                    no journal and no compacting on disk")
print("  NAMEABLE (snapshot+journal) %d" % len(entries))
if tot["torn"]:
    print("  *** TORN: a record did not land completely, so the replay STOPPED "
          "there. Expected after an unclean kill; the lost keys have files on "
          "disk and will simply be re-stored.")
json.dump({"nameable": len(entries), "snapshot": snap_keys, "stats": tot},
          open("/tmp/kvjournal-nameable.json", "w"))
PY
  # The gap, against the LIVE index. This is the number the journal exists to
  # keep at zero: a key held in memory that no future boot can name is a file
  # on disk that nothing will ever read again.
  curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json, sys
try:
    dk = json.load(sys.stdin).get("disk")
except Exception:
    dk = None
if not isinstance(dk, dict):
    print("  gap: CANNOT TELL -- the live index was unreadable. That is not a "
          "gap of zero.")
    raise SystemExit(0)
present = dk.get("present")
try:
    n = json.load(open("/tmp/kvjournal-nameable.json"))["nameable"]
except Exception:
    print("  gap: CANNOT TELL -- the replay above wrote no result")
    raise SystemExit(0)
if present is None:
    print("  gap: CANNOT TELL -- `present` absent from the index")
    raise SystemExit(0)
gap = present - n
print("  live present                %d" % present)
if gap == 0:
    print("  GAP                         0   (every key in memory is nameable)")
elif gap > 0:
    print("  GAP                         %d KEYS IN MEMORY THAT NO BOOT CAN "
          "NAME -- ongoing orphan generation" % gap)
else:
    print("  GAP                         %d (nameable EXCEEDS present: the "
          "replay is unpruned, so this is keys whose files were pruned at "
          "boot or evicted since -- not an orphan)" % gap)
'
}

# ---------------------------------------------------------------------------
# the worker, stated rather than omitted
# ---------------------------------------------------------------------------
worker(){
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER" \
    "ls -1 $DIR 2>/dev/null | head -20" 2>/dev/null \
    | sed 's/^/    /' || echo "    (unreachable -- that is a finding, not an absence)"
  echo "    EXPECTED: no presence.json and no journal on the worker. The manager"
  echo "    is scheduler-side, so the index exists in ONE process on the head."
}

usage(){
  cat <<'U'
usage: kvjournal.sh {state|nameable|watch [interval_s]}

  state     the files, the two transient names, and the disk index off :9199
  nameable  snapshot keys + journal adds, against the live index: the gap
  watch     poll `state`'s short form so a rotation is caught in the act
U
}

case "${1:-state}" in
  state)
    echo "=== $(date -Is)  files in $DIR"
    [ -d "$DIR" ] || die "no such directory: $DIR (is this the head?)"
    files
    echo "=== the disk index (:9199)"
    index
    echo "=== the worker ($WORKER)"
    worker
    ;;
  nameable)
    echo "=== $(date -Is)  nameable-key arithmetic"
    nameable
    ;;
  watch)
    # THE ROTATION WINDOW IS NARROW ON PURPOSE: `compacting` exists only
    # between the rotate and the end of the snapshot write (~0.55s of a 0.78s
    # write measured on this box). A one-second poll will MISS most of them, so
    # the default is 0.2s and the counters below are the durable witness --
    # watch journal_rotations move, not only the file appear.
    IV=${2:-0.2}
    echo "polling every ${IV}s -- ^C to stop. A 'compacting' line means a"
    echo "rotation is in flight THIS INSTANT."
    while :; do
      ts=$(date +%H:%M:%S.%3N)
      j=$( [ -e "$SNAP.journal" ] && stat -c %s "$SNAP.journal" || echo -)
      jl=$( [ -e "$SNAP.journal" ] && wc -l < "$SNAP.journal" || echo -)
      s=$( [ -e "$SNAP" ] && stat -c %s "$SNAP" || echo -)
      c=$( [ -e "$SNAP.compacting" ] && echo "COMPACTING($(wc -l < "$SNAP.compacting"))" || echo "-" )
      p=$( [ -e "$SNAP.part" ] && echo "PART" || echo "-" )
      printf '%s  journal=%s B/%s rec  snapshot=%s B  %s %s\n' \
        "$ts" "$j" "$jl" "$s" "$c" "$p"
      sleep "$IV"
    done
    ;;
  *) usage; exit 2;;
esac

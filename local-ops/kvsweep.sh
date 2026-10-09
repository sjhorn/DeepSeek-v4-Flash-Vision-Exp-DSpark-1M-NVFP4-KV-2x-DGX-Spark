#!/usr/bin/env bash
# kvsweep.sh -- find and remove disk-tier files that NOTHING can ever read.
#
# *** THE BUDGET BOUNDS THE INDEX, NOT THE DISK. *** Phase 5's byte budget
# evicts entries from the manager's index and unlinks their files, so it can
# only ever bound what the index knows about. Measured 2026-10-09 on spark-45ea:
# the live fingerprint directory held 444 GiB while the index claimed 288.8 GiB
# (434,074 keys). The 155 GiB difference is files written by a boot whose
# manifest never flushed them -- unreachable, because no present or future boot
# can name them, and invisible to the budget, because the budget only looks at
# the index. Until they are gone a byte budget is a number about the wrong set.
#
# THREE KINDS OF ORPHAN, and only the third needs care:
#   1. ~/kvoffload/ds4f/*            -- the old tiering tier, whose spec is no
#                                       longer in KV_TRANSFER_CONFIG at all.
#   2. <root>/<OTHER fingerprint>_r* -- a fingerprint that is not this boot's.
#                                       `_compute_base_path` refuses by
#                                       construction, so these are dead.
#   3. files inside the LIVE dir that the index does not claim.
#
# *** THE TZ TRAP, which this repo has already paid for twice. *** The age
# predicate is evaluated ONCE, ON THE HOST, and the result enumerated to an
# explicit list; only that list is deleted. A `find -newermt` re-evaluated
# inside the container would use the CONTAINER's timezone and shift the cut by
# hours. Same reason the deletes themselves must run in the container: the files
# are root-owned (the container writes through the bind mount) and there is no
# non-interactive sudo on these boxes.
#
# Usage, per node (the worker's slice is on the worker's own disk):
#   kvsweep.sh plan  <base_dir> <keepset_file> <boot_iso>   # writes the list
#   kvsweep.sh apply <base_dir>                             # deletes it
#   kvsweep.sh dead  <dir> [dir...]                         # kinds 1 and 2
set -uo pipefail

CONTAINER=${CONTAINER:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
WORK=${WORK:-/home/shorn/kvsweep}
# A tripwire, not a tuning knob: if the keep set fails to parse it comes back
# empty and EVERY file looks like an orphan. Refuse rather than delete the tier.
MAX_DELETE_FRACTION=${MAX_DELETE_FRACTION:-0.60}

die() { echo "REFUSED: $*" >&2; exit 2; }
mkdir -p "$WORK" || die "cannot create $WORK"

cmd=${1:-}; shift || true

case "$cmd" in
plan)
  base=${1:?base_dir}; keep=${2:?keepset_file}; boot=${3:?boot_iso}
  [ -d "$base" ] || die "no such base dir: $base"
  [ -s "$keep" ] || die "keep set is missing or EMPTY ($keep) -- that would mark every file an orphan"
  date -u -d "$boot" +%s >/dev/null 2>&1 || die "unparseable boot time: $boot"
  [ "$(date -u -d "$boot" +%s)" -lt "$(date -u +%s)" ] || die "boot time is in the future: $boot"

  echo "== enumerating $base =="
  # The age cut is the cut. A file younger than the boot may be in the LIVE
  # in-memory index without being in the on-disk manifest yet, and deleting one
  # would turn a future restore into a missing-file load. Everything older than
  # the boot is either in the manifest this boot loaded, or unreachable.
  find "$base" -type f -name '*.bin' ! -newermt "$boot" -print > "$WORK/all-old.txt" \
    || die "find failed"
  find "$base" -type f -name '*.bin'   -newermt "$boot" -print > "$WORK/young.txt"
  nold=$(wc -l < "$WORK/all-old.txt"); nyoung=$(wc -l < "$WORK/young.txt")
  echo "   older than the boot: $nold     written this boot (never touched): $nyoung"
  [ "$nold" -gt 0 ] || die "no files older than the boot -- nothing this tool can safely act on"

  python3 - "$keep" "$WORK/all-old.txt" "$WORK/delete.txt" "$MAX_DELETE_FRACTION" <<'PY' || die "the planner refused"
import os, sys
keep_f, all_f, out_f, maxfrac = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])

# A manifest key is 72 hex chars: a 32-byte block hash then a 4-byte group
# index. The file it names is <stem>.bin inside a .../<..>_g<group>/ directory,
# so the mapping is one-to-one and a file can be judged on its own, not merely
# per hash.
keep = set()
with open(keep_f) as fh:
    for line in fh:
        k = line.strip()
        if len(k) == 72:
            keep.add((k[:64], int(k[64:], 16)))
if not keep:
    sys.exit("the keep set parsed to ZERO entries -- refusing")

kept = dropped = 0
dropped_paths = []
bad = 0
for line in open(all_f):
    p = line.rstrip("\n")
    stem = os.path.basename(p)[:-4]
    d = os.path.basename(os.path.dirname(p))      # "<hh>_g<group>"
    if "_g" not in d:
        bad += 1
        continue                                   # unrecognised: never delete
    try:
        g = int(d.rsplit("_g", 1)[1])
    except ValueError:
        bad += 1
        continue
    if (stem, g) in keep:
        kept += 1
    else:
        dropped += 1
        dropped_paths.append(p)

total = kept + dropped
frac = (dropped / total) if total else 0.0
print("   keep set entries   %d" % len(keep))
print("   claimed by index   %d" % kept)
print("   ORPHANS            %d  (%.1f%% of the old files)" % (dropped, 100 * frac))
print("   unparseable paths  %d  (left alone)" % bad)
if frac > maxfrac:
    sys.exit("orphans are %.1f%% of the tier, over the %.0f%% tripwire -- a "
             "mis-parsed keep set looks exactly like this. Refusing." %
             (100 * frac, 100 * maxfrac))
with open(out_f, "w") as fh:
    fh.write("".join(p + "\n" for p in dropped_paths))

# The cross-check, computed from the LIST rather than from the loop above, so a
# bug in the loop cannot also hide itself in the verification.
reread = [l.strip() for l in open(out_f)]
assert len(reread) == dropped, "list length disagrees with the count"
over = [p for p in reread
        if (os.path.basename(p)[:-4],
            int(os.path.basename(os.path.dirname(p)).rsplit("_g", 1)[1])) in keep]
print("   OVERLAP with the keep set: %d  (must be 0)" % len(over))
assert not over, "the delete list contains files the index claims"
PY

  # Bytes, read off the list rather than estimated.
  if [ -s "$WORK/delete.txt" ]; then
    bytes=$(xargs -a "$WORK/delete.txt" -r stat -c %s 2>/dev/null | awk '{s+=$1} END{print s+0}')
    echo "   reclaimable: $(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes B")"
  fi
  # Every path must be a .bin under the base dir. A list that escaped the tree
  # is the one mistake that cannot be undone.
  if [ -s "$WORK/delete.txt" ]; then
    stray=$(grep -cv -e "^${base%/}/.*\.bin$" "$WORK/delete.txt" || true)
    [ "${stray:-0}" = "0" ] || die "$stray paths in the list are not .bin files under $base"
  fi
  echo "== plan written to $WORK/delete.txt -- nothing has been deleted =="
  ;;

apply)
  base=${1:?base_dir}
  [ -s "$WORK/delete.txt" ] || die "no plan at $WORK/delete.txt -- run plan first"
  n=$(wc -l < "$WORK/delete.txt")
  stray=$(grep -cv -e "^${base%/}/.*\.bin$" "$WORK/delete.txt" || true)
  [ "${stray:-0}" = "0" ] || die "the plan contains $stray paths outside $base"
  echo "== deleting $n files, inside the container (the files are root-owned) =="
  # The container sees the bind mount at /kvoffload; the host path is
  # /home/shorn/kvoffload. Translate, and delete ONLY from the explicit list.
  sed 's#^/home/shorn/kvoffload#/kvoffload#' "$WORK/delete.txt" > "$WORK/delete-container.txt"
  docker cp "$WORK/delete-container.txt" "$CONTAINER:/tmp/kvsweep-delete.txt" >/dev/null \
    || die "docker cp failed"
  before=$(find "$base" -type f -name '*.bin' | wc -l)
  # *** `docker exec` WITHOUT -i SILENTLY DISCARDS STDIN. *** The first version
  # of this line had no -i, so `python3 -` read an EMPTY PROGRAM, did nothing,
  # and exited 0 -- and this script printed "done". A delete of 229,467 files
  # reported success having removed none. That is this repo's signature failure
  # (a mechanism present, correct-looking and producing nothing) committed by
  # the very tool written to be careful, which is why the count assertion below
  # exists: an exit status is not evidence that work happened.
  docker exec -i "$CONTAINER" python3 - <<'PY'
import os
n = gone = missing = err = 0
for line in open("/tmp/kvsweep-delete.txt"):
    p = line.strip()
    if not p.endswith(".bin") or not p.startswith("/kvoffload/"):
        err += 1
        continue
    n += 1
    try:
        os.unlink(p)
        gone += 1
    except FileNotFoundError:
        missing += 1
    except OSError as exc:
        err += 1
        if err <= 5:
            print("   unlink failed: %s: %s" % (p, exc))
print("   attempted %d  removed %d  already gone %d  errors %d" % (n, gone, missing, err))
PY
  after=$(find "$base" -type f -name '*.bin' | wc -l)
  removed=$(( before - after ))
  echo "   file count $before -> $after  (fell by $removed, plan listed $n)"
  # *** ASSERT THE WORK, NOT THE EXIT STATUS. *** Allow a small shortfall only
  # for files a concurrent eviction removed first; a large one means the delete
  # did not happen and must not be reported as success.
  [ "$removed" -gt 0 ] || die "the file count did NOT fall -- the delete did nothing (exit status is not evidence)"
  short=$(( n - removed ))
  [ "$short" -lt 0 ] && short=$(( -short ))
  [ "$short" -le $(( n / 20 )) ] \
    || die "count fell by $removed but the plan listed $n -- a >5% disagreement is not a concurrent eviction"
  echo "== done. The index was NOT touched: every file removed was one it does not claim. =="
  ;;

dead)
  [ "$#" -gt 0 ] || die "dead needs at least one directory"
  for d in "$@"; do
    [ -d "$d" ] || { echo "   (absent, nothing to do: $d)"; continue; }
    case "$d" in /home/shorn/kvoffload/*) ;; *) die "refusing a path outside ~/kvoffload: $d";; esac
    sz=$(du -sh "$d" 2>/dev/null | cut -f1)
    echo "== $d  ($sz) =="
    cd="${d#/home/shorn/kvoffload}"
    docker exec "$CONTAINER" python3 -c "
import shutil, sys, os
p = '/kvoffload' + sys.argv[1]
if not os.path.isdir(p):
    print('   absent in the container: ' + p); sys.exit(0)
shutil.rmtree(p)
print('   removed ' + p)
" "$cd" || die "rmtree failed for $d"
  done
  ;;

*)
  sed -n '2,36p' "$0"
  exit 1
  ;;
esac

#!/usr/bin/env bash
# PROVE THE SELF-HEAL: delete a WORKER's files and survive it. Runs ON THE HEAD.
#
# *** WHAT THIS DEMONSTRATES, AND WHY IT USED TO BE A DEAD ENGINE. *** The
# presence index is a claim about TWO filesystems and the boot walk can only
# check one -- `_load_manifest`'s prune runs in the engine core and
# `get_file_name` is rank-dependent. So a file lost on spark-da08 while the
# head's survives left the index claiming a key that could not be loaded, and
# upstream does not have a failed load: `offloading/worker.py:273` is a bare
# `assert transfer_result.success`. The engine core died.
#
# With cross-rank verification the same condition is a MISS and then a REPAIR:
# the rank that lost the file reports it, the key leaves the index, the next
# store re-offers it, the rank that still has a good file SKIPS the write, the
# rank that lost it writes it, and complete_store re-indexes it verified.
#
# *** IT TARGETS THE FIRST KEYS IN THE INDEX ON PURPOSE. *** The background
# sweep walks `_present` in insertion order from cursor 0, and insertion order
# is `presence.json`'s own order -- so the first keys in the snapshot are the
# first ones re-checked, and the test needs no full 922,992-key walk to reach
# its victims. Deleting from the middle of the index would work too and take
# hours of busy engine.
#
# *** AND IT NEEDS THE ENGINE TO BE BUSY. *** The pump rides the scheduler
# step, and `EngineCoreProc._process_engine_step`'s own docstring is "Called
# only when there are unfinished local requests" -- so an idle engine makes no
# progress at all. That is why this sends traffic rather than waiting.
set -u

API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
SNAP=${SNAP:-$HOME/kvoffload/dspark-kv-v1/presence.json}
W=${W:-spark-da08}
C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
N=${1:-5}            # how many files to delete on the worker
DEADLINE=${2:-180}

say(){ echo "  $*"; }
die(){ echo "kvselfheal: $*" >&2; exit 1; }

# -- where does the worker keep its files? --------------------------------
# Off the engine's OWN fingerprint, never a guess: the base path is a sha over
# the model identity and the cache geometry, and `rank` lives in the path
# deliberately outside that hash -- which is exactly what makes _r0 and _r1
# siblings under one fingerprint.
BASE=$(curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json, sys
d = json.load(sys.stdin).get("disk") or {}
fp = d.get("fingerprint") or {}
b = fp.get("base_path")
print(b if b else "")')
[ -n "$BASE" ] || die "could not read the fingerprint base_path off :9199 -- is this the head, and is the engine up?"
# *** TRANSLATE THE CONTAINER PATH TO THE HOST PATH, and this tool's first
# *** version did not -- which is the whole reason it refuses rather than
# *** reporting. *** The engine publishes `/kvoffload/...` because that is the
# bind mount INSIDE the container; the host sees `$HOME/kvoffload/...`. Deleting
# from the container path on the host removes nothing, and a tool that then
# printed a pass would have "proved" the self-heal against five files it never
# touched. kvsweep.sh translates the same pair for the same reason.
HOSTROOT=${HOSTROOT:-$HOME/kvoffload}
BASE_HOST="${BASE/#\/kvoffload/$HOSTROOT}"
WBASE="${BASE_HOST%_r0}_r1"
say "engine's view: $BASE"
say "worker tree (host path): $WBASE"

# -- pick victims JUST AHEAD OF THE LIVE SWEEP CURSOR ---------------------
# *** "THE FRONT OF THE SNAPSHOT" WAS WRONG, AND THE FIRST RUN PROVED IT. ***
# The background sweep walks `_present` in insertion order and had been running
# since boot, so by the time the files were deleted the cursor was already at
# ~56,000 -- past them -- and it will not return until it wraps all 922,992
# keys, which is hours. The test reported FAIL with the engine alive and nothing
# forgotten, which is exactly what its own failure text said to suspect.
#
# `_present`'s insertion order IS presence.json's order for every
# manifest-loaded key, and the cursor is published, so the victims are taken at
# `cursor + MARGIN`: far enough ahead that the delete lands before the sweep
# arrives, close enough that it arrives within the deadline.
CURSOR=$(curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json, sys
d = json.load(sys.stdin).get("disk") or {}
v = d.get("verify") or {}
c = v.get("cursor")
print("UNREADABLE" if c is None else c)')
case "$CURSOR" in ""|*[!0-9]*) die "could not read verify.cursor off :9199 ($CURSOR) -- without it this tool cannot know where the sweep is, and guessing is what made the first run report a false FAIL";; esac
MARGIN=${MARGIN:-200}
say "sweep cursor at $CURSOR; taking victims at +$MARGIN"
python3 -I - "$SNAP" "$WBASE" "$N" "$CURSOR" "$MARGIN" > /tmp/kvselfheal-victims.txt <<'PY'
import json, sys
snap, wbase, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
start = int(sys.argv[4]) + int(sys.argv[5])
allkeys = json.load(open(snap))["keys"]
if start + n * 4 > len(allkeys):
    start = 0          # wrapped: the snapshot's front is ahead of the cursor
keys = allkeys[start: start + n * 4]
out = []
for item in keys:
    hexkey = item if isinstance(item, str) else item[0]
    kb = bytes.fromhex(hexkey)
    # An OffloadKey is block_hash + group_idx.to_bytes(4,"big") -- so the file
    # name is the HASH's hex and the group is the last four bytes. Read off
    # base.py rather than assumed, because a guessed layout would delete the
    # wrong files or none and report either as success.
    h = kb[:-4].hex()
    g = int.from_bytes(kb[-4:], "big")
    out.append(f"{wbase}/{h[:3]}/{h[3:5]}_g{g}/{h}.bin")
    if len(out) >= n:
        break
print("\n".join(out))
PY
# *** AND THE DELETE RUNS INSIDE THE CONTAINER, BECAUSE THE FILES ARE
# *** ROOT-OWNED AND THERE IS NO NON-INTERACTIVE sudo. *** The container writes
# them through the bind mount as root, so `rm` as shorn is Permission denied --
# which the second version of this tool hit, and which its own
# "the delete removed nothing" guard caught rather than reporting a pass.
# kvsweep.sh deletes inside the container for exactly this reason.
#
# `docker exec` needs **-i**: without it stdin is silently DISCARDED, so a
# heredoc program runs EMPTY and exits 0. That cost a delete of 229,467 files
# that removed none while printing "done".
sed "s|^$HOSTROOT|/kvoffload|" /tmp/kvselfheal-victims.txt > /tmp/kvselfheal-victims-container.txt
VN=$(wc -l < /tmp/kvselfheal-victims.txt)
[ "$VN" = "$N" ] || die "wanted $N victims, built $VN"
say "victims (worker side only):"
sed 's/^/      /' /tmp/kvselfheal-victims.txt

# -- they must EXIST first, or the test proves nothing --------------------
# *** A DELETE THAT REMOVED NOTHING WOULD LOOK EXACTLY LIKE A PASS. *** This
# repo has already paid for that once: `docker exec` without -i ran an empty
# program, exited 0, and deleted none of 229,467 files while printing "done".
# So: assert the files are there, then assert the count FELL.
scp -q /tmp/kvselfheal-victims.txt "$W":/tmp/kvselfheal-victims.txt || die "scp failed"
scp -q /tmp/kvselfheal-victims-container.txt "$W":/tmp/kvselfheal-victims-container.txt || die "scp failed"
BEFORE=$(ssh -o BatchMode=yes "$W" 'n=0; while read -r f; do [ -f "$f" ] && n=$((n+1)); done < /tmp/kvselfheal-victims.txt; echo $n')
say "present on the worker before: $BEFORE/$N"
[ "$BEFORE" = "$N" ] || die "only $BEFORE of $N victim files exist on the worker -- the index claims keys whose files are already gone there, which is the bug this tool tests for rather than a setup it can use"
# sed rather than a bash pattern: `${f/_r1\//_r0/}` is easy to get subtly
# wrong and a miscount here would be a misleading number beside a real one.
HEAD_OK=$(n=0; while read -r f; do h=$(printf '%s' "$f" | sed 's|_r1/|_r0/|'); [ -f "$h" ] && n=$((n+1)); done < /tmp/kvselfheal-victims.txt; echo $n)
say "...and on the HEAD: $HEAD_OK/$N (these must SURVIVE -- that is the asymmetry)"

V0=$(curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json,sys
d=json.load(sys.stdin).get("disk") or {}
print("%s %s %s"%(d.get("present"), d.get("verify_forgot") or 0,
                  (d.get("verify") or {}).get("verified")))')
say "before: present/forgot/verified = $V0"

ssh -o BatchMode=yes "$W" "docker exec -i $C sh -c 'while read -r f; do rm -f \"\$f\"; done' < /tmp/kvselfheal-victims-container.txt"
AFTER=$(ssh -o BatchMode=yes "$W" 'n=0; while read -r f; do [ -f "$f" ] && n=$((n+1)); done < /tmp/kvselfheal-victims.txt; echo $n')
say "present on the worker after the delete: $AFTER/$N (0 is the point)"
[ "$AFTER" = "0" ] || die "the delete removed nothing -- an exit status is not evidence that work happened"

# -- drive the engine so the pump runs ------------------------------------
say "driving traffic so the step pump runs (an idle engine makes no progress)"
F0=$(echo "$V0" | awk '{print $2}')
( for i in $(seq 1 60); do
    curl -s -o /dev/null -m 60 -X POST "$API/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"claude-opus-5\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"selfheal probe $i $(date +%s%N)\"}]}" || true
  done ) & DRIVE=$!

t0=$(date +%s); OK=0
while [ $(( $(date +%s) - t0 )) -lt "$DEADLINE" ]; do
  read -r PRES FORGOT VERIF FAULT <<EOF
$(curl -s -m 20 "$STATS/kv" | python3 -I -c '
import json,sys
d=json.load(sys.stdin).get("disk") or {}
v=d.get("verify") or {}
print("%s %s %s %s"%(d.get("present"), d.get("verify_forgot") or 0,
                     v.get("verified"), "FAULT" if v.get("fault") else "none"))')
EOF
  # an empty FORGOT is UNREADABLE, not zero -- default it and keep polling
  case "${FORGOT:-}" in ""|*[!0-9]*) FORGOT=$F0;; esac
  if [ "$FORGOT" -ge $(( F0 + N )) ]; then OK=1; break; fi
  sleep 3
done
kill $DRIVE 2>/dev/null; wait $DRIVE 2>/dev/null

say "after: present=$PRES forgot=$FORGOT verified=$VERIF fault=$FAULT"
ALIVE=$(curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}')
# *** THE LIVENESS PROBE IS A COMPLETION, NOT /v1/models. *** /v1/models is
# served by the API server without touching the engine core and answers 200
# while the core is wedged -- measured, with five requests outstanding.
say "engine liveness (a one-token completion, not /v1/models): $ALIVE"

echo
if [ "$OK" = "1" ] && [ "$ALIVE" = "200" ] && [ "$FAULT" = "none" ]; then
  echo "PASS: $N worker-side files deleted; the cluster NOTICED, the keys left the"
  echo "      index, and the engine is ALIVE. Before this, the next load of one of"
  echo "      those keys was upstream's bare assert and a dead engine core."
  exit 0
fi
echo "FAIL: forgot went $F0 -> $FORGOT (wanted >= $((F0+N))), alive=$ALIVE, fault=$FAULT"
echo "      A deadline with the engine alive and nothing forgotten means the sweep"
echo "      never reached these keys -- check disk_verify_bg_per_s and that the"
echo "      engine was actually stepping, NOT that verification is broken."
exit 1

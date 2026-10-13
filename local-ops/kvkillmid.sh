#!/usr/bin/env bash
# SIGKILL BOTH ENGINE CONTAINERS WHILE A COMPACTION IS IN FLIGHT. Runs ON THE HEAD.
#
# *** THIS DESTROYS THE RUNNING ENGINE ON PURPOSE. *** It is the one crash test
# the journal has never had. Every previous kill test had records in the journal;
# none was taken mid-ROTATE, which is the exact window `.compacting` exists for
# and the window the rule the code is proudest of guards -- "NEVER OVERWRITE AN
# EXISTING compacting".
#
# WHY A SCRIPT ON THE HEAD, and not an ssh one-liner. The window is ~1s: the
# `.compacting` file lives only between the rotate and the end of the snapshot
# write. One ssh round trip per poll spends most of it, and this repo's standing
# rule is that a non-trivial check goes in a file that is copied over rather
# than quoted onto a command line, because the quoted version fails for the
# wrong reason.
#
# KILL FIRST, MEASURE SECOND. A `stat` before the kill spends the window. Once
# the writer is dead the files cannot change, so every measurement afterwards is
# of a frozen tree -- which is what makes the recovery boot's report checkable
# against an arithmetic prediction.
#
# BOTH CONTAINERS MUST GO. The journal is head-only, so the head is what must
# die mid-compaction -- but the start script's `up -d` is a no-op on a running
# container, so a surviving rank-1 process leaves rank 0 in NCCL init FOREVER,
# indistinguishable from weights still loading.
set -u

C=${C:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
W=${W:-spark-da08}
SNAP=${SNAP:-$HOME/kvoffload/dspark-kv-v1/presence.json}
WAIT=${1:-240}

OUT=$HOME/kvdiag/killmid-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
REC="$OUT/files-at-kill.txt"
DEADLINE=$(( $(date +%s) + WAIT ))

freeze(){
  local f
  for f in "$SNAP" "$SNAP.journal" "$SNAP.compacting" "$SNAP.part"; do
    if [ -e "$f" ]; then
      printf '%-28s %12s bytes  %8s lines  mtime %s\n' "$(basename "$f")" \
        "$(stat -c %s "$f")" "$(wc -l < "$f")" "$(stat -c %y "$f" | cut -d. -f1)"
    else
      printf '%-28s %12s\n' "$(basename "$f")" "ABSENT"
    fi
  done
}

echo "kvkillmid: polling for $SNAP.compacting (deadline ${WAIT}s)"
echo "           evidence -> $REC"
while :; do
  if [ -e "$SNAP.compacting" ]; then
    docker kill "$C" >/dev/null 2>&1; rc=$?
    ts=$(date +%H:%M:%S.%3N)
    {
      echo "=== head container SIGKILLed at $ts (docker kill rc=$rc)"
      echo "=== the frozen tree -- the writer is dead, so these cannot change:"
      freeze
    } | tee "$REC"
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$W" "docker kill $C" >/dev/null 2>&1; then
      echo "=== worker container SIGKILLed too" | tee -a "$REC"
    else
      # NOT a warning to scroll past: recovery REQUIRES both down.
      echo "=== *** WORKER KILL FAILED *** -- run 'down' on BOTH nodes before starting, or rank 0 hangs in NCCL init for ever against the surviving rank 1" | tee -a "$REC"
    fi
    exit 0
  fi
  [ "$(date +%s)" -ge "$DEADLINE" ] && {
    # An empty window is a finding about the load, not a pass. Say so.
    echo "kvkillmid: DEADLINE -- no .compacting was ever seen, so NOTHING was"
    echo "           killed. Either no compaction fired (check journal_max_records"
    echo "           against the live journal_appends counter, which resets at"
    echo "           every boot) or the poll is slower than the window."
    exit 1
  }
  sleep 0.02
done

# *** THE CAPTURE IS NOW DEAD AND THIS TOOL CANNOT FIX IT. *** The SIGKILL took
# both containers, so all four `docker logs -f` streams are gone -- and unlike
# the restart tools, recovery here is a SEPARATE, EXPLICIT command by design
# (the whole point is a frozen tree to predict from). So there is no container
# to attach a stream to and arming one here would fail or, worse, appear to
# succeed. Naming the command is the honest version.
echo
echo "kvkillmid: THE CAPTURE DIED WITH THE CONTAINERS. After you recover with"
echo "           ./start-deepseek-v4-flash-dspark.sh, re-arm all four streams:"
echo "               bash local-ops/kvstream.sh all-start"
echo "           and gate on it -- all-check exits non-zero if any is missing."

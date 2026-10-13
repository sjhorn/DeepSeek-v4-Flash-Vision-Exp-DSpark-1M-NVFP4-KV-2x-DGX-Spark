#!/usr/bin/env bash
# THE SCALE TEST: does a ~700K prefix survive a restart and come back fast?
#
# This is the project's whole premise and it has never been measured. Everything
# tested so far is <=100K, where a cold pass is 51s. The claim being tested is
# the measured one: a 2,000-token delta on a warm 770K prefix costs 0.9s while
# the same 770K arrived at cold costs 686s. If that does not hold at 700K, the
# rest of this work is moot.
#
# *** IT NEEDS NO DROP, which is why it is also the SAFEST experiment left. ***
# A restart gives an empty GPU cache and a restored manifest BY DEFINITION, so
# `gpu_cache_drop_allowed` stays off -- and that lever is the one that keeps
# producing Xid 32 and killing the box. The restart was always going to be the
# honest test anyway: "the prize is the PREFILL, not the boot."
#
# TWO PHASES, deliberately separate commands with the restart between them by
# hand. A script that restarts the engine it is measuring is this project's
# "capture before you recover" hazard -- a recovery step inside the very script
# collecting the evidence has destroyed a traceback here before.
#
#   kvscale.sh build    # cold pass, indexes the prefix to disk
#   <restart both nodes>
#   kvscale.sh measure  # same prompt as the FIRST request after the boot
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
PHASE="${1:-build}"
# *** MEASURED RATIO, because I guessed it and was wrong by 4x. *** 900,110
# characters of this filler produced 176,097 prompt_tokens -- 5.11 chars per
# token, not the ~1.3 I had assumed when the comment here claimed "900000 =
# ~700K tokens". So the first "scale test" was a 176K test wearing a 700K
# label, and it would have been reported as the prize scale if the script had
# not printed prompt_tokens beside the wall. Print the quantity you are
# claiming, not the one you asked for.
#   700K tokens ~= 3,580,000 chars   (max_model_len is 1,048,576 tokens)
CHARS="${2:-3580000}"
NONCE="${3:-kvscale-fixed-nonce}"
BODY=/tmp/kvscale-body.json
D=~/kvdiag/scale-$PHASE-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 300 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
m(){ curl -s -m 30 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
idx(){ curl -s -m 30 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}); i=d.get('index') or d
print('present=%s lookup=%s hit=%s stored=%s' % (i.get('present'), i.get('lookup'), i.get('hit'), i.get('stored')))" 2>/dev/null || echo unreadable; }
hb(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        o.append('r%s.%s files=%s' % (r.get('rank'), h.get('cls','?')[4:9], h.get('files')))
print(' | '.join(o))" 2>/dev/null || echo unreadable; }
# *** BOTH NODES. *** This sampled the HEAD only and reported "27 -> 27, no new
# faults" on a run the WORKER faulted during: Xid 32 on spark-da08 at 17:36:03,
# one second before the engine error. A head-only probe on a two-node engine is
# a false negative by construction, and it nearly published "the restore
# completed with no faults" about a run that killed a worker. Same family as the
# wrong-port probe that rendered "not found" as zero ranks.
xid(){ local h w
  h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (" || echo 0)
  w=$(ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo -1)
  echo "head=$h worker=$w"; }

# ONE body file, written once and reused across the restart. The prompt must be
# byte-identical in both phases or the block hashes differ and the test is about
# nothing -- which is why the nonce is a fixed string and not a timestamp.
if [ ! -s "$BODY" ] || [ "$PHASE" = "build" ]; then
  python3 - "$CHARS" "$NONCE" > "$BODY" <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
w = "alpha beta gamma delta epsilon zeta eta theta "
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + (w * (n // len(w) + 2))[:n]}]},
          sys.stdout)
PY
fi
say "body: $(wc -c < "$BODY") bytes, sha $(sha256sum "$BODY" | cut -c1-16) (must match across phases)"

( docker logs -f --since 1s "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
( while true; do printf '%s ' "$(date +%H:%M:%S)"
    awk '/^MemAvailable:|^SwapFree:/{sub(/:$/,"",$1); printf "%s=%s ", $1, $2}' /proc/meminfo
    echo; sleep 5; done ) > "$D/mem.txt" 2>&1 & MEM=$!
trap 'kill $LOG $MEM 2>/dev/null' EXIT
sleep 2
[ "$(alive)" = "200" ] || { say "engine not serving -- aborting"; exit 1; }

# Restore ON, store ON, DROP OFF -- the drop is the lever that keeps crashing
# and this test does not need it.
knob disk_restore 1
knob disk_store_paused 0
knob gpu_cache_drop_allowed 0
knob disk_budget_gb 1000

say "=== PHASE: $PHASE ==="
say "manifest this boot: $(docker logs "$C" 2>&1 | grep -oE 'presence.json -- [0-9]+ keys restored, [0-9]+ pruned' | tail -1)"
say "index before:  $(idx)"
say "handlers:      $(hb)"
H0=$(m external_prefix_cache_hits_total); B0=$(m "^vllm:kv_offload_total_bytes_total[{].*DSPARK_DISK_to_GPU"); X0=$(xid)
say "hits before=$H0  disk->gpu before=$B0  Xid lines=$X0"

t=$(date +%s)
resp=$(curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @"$BODY")
WALL=$(( $(date +%s) - t ))
TOK=$(echo "$resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
H1=$(m external_prefix_cache_hits_total); B1=$(m "^vllm:kv_offload_total_bytes_total[{].*DSPARK_DISK_to_GPU")
say ""
say "  wall            = ${WALL}s"
say "  prompt_tokens   = $TOK"
say "  external hits   : $H0 -> $H1"
# *** THE _total SERIES, ANCHORED. *** `m DSPARK_DISK_to_GPU` kept the LAST
# line carrying the label, which is `..._bytes_created` -- a Unix timestamp
# that reads as a plausible 1.79 GB, and was published as the 700K read figure.
say "  DSPARK_DISK_to_GPU bytes: $B0 -> $B1  (kv_offload_total_bytes_total)"
say "  index after     : $(idx)"
say "  handlers after  : $(hb)"
say "  preemptions     : $(m num_preemptions_total)   (non-zero is the revert signal)"
say "  Xid lines       : $X0 -> $(xid)"
say "  engine          : $(alive)"
say "  MemAvailable min: $(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/mem.txt") kB"
if [ "$PHASE" = "build" ]; then
  say ""
  say "NEXT: restart BOTH nodes (kvdiag.sh recover), then: kvscale.sh measure"
  say "      The restart is the test. Do not drop; a boot gives an empty GPU"
  say "      cache and a restored manifest by definition."
else
  say ""
  say "READ IT AS: tokens restored = the external-hits delta. Against a cold"
  say "            pass of 430-795s at this size, the wall above is the prize"
  say "            or the refutation. A wall near the cold figure with hits at"
  say "            0 means the index did not survive; a wall near the cold"
  say "            figure WITH hits means the restore is slower than"
  say "            recomputing, which is worse than the miss it fixes."
fi
sleep 3
docker logs --since 60m "$C" > "$D/engine.log" 2>&1
say "evidence: $D"
echo "KVSCALE-DONE phase=$PHASE wall=${WALL}s tokens=$TOK"

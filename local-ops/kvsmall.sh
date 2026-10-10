#!/usr/bin/env bash
# EXPERIMENT 2: is the restore actually slowed by a live store, or was the 60s
# just queueing behind a 100K cold prefill?
#
# Every previous "concurrent store" run generated its writes with a FRESH 100K
# prompt -- and a 100K cold prefill takes 51s ON ITS OWN. So the restore's 59-63s
# is consistent with "waiting for GPU time" and tells us nothing about I/O
# interference. The device was 14.1% busy in the restore-alone arm, which is why
# this matters: if the bottleneck were I/O there would have to be some load that
# shows it.
#
# This keeps the STORE path busy with a stream of SMALL fresh-nonce requests
# (~3K tokens each, several in flight). Each one is a new prefix, so every block
# is a genuine new store that the pre-copy skip cannot remove -- but no single
# request monopolises the GPU the way a 100K prefill does.
#
#   restore alone (measured):            ~2s, device 14.1% busy
#   restore + small-request store load:  THIS
#   restore + 100K prefill (measured):   59-63s
#
# If this comes back at ~2-5s, the 60s was queueing and there is no I/O
# contention problem to solve. If it comes back slow with the device still
# mostly idle, the interference is in the staging/round structure, not bandwidth.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
DEV=nvme0n1
WARM="${1:-dropguard-live}"
SMALL_TOK="${2:-3000}"
CONC="${3:-6}"
SECS="${4:-90}"
D=~/kvdiag/small-$(date +%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'; }
knob(){ curl -s -m 60 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" -o /dev/null; }
lk(){ curl -s -m 30 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {}); i=d.get('index') or d
print(int(i.get('lookup') or 0))" 2>/dev/null || echo -1; }
drop(){ curl -s -m 60 -X POST "$API/kv/drop_gpu_cache" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('ok' if d.get('ok') else (d.get('refused') or 'other'))" 2>/dev/null || echo unreachable; }
hb(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print('unreadable'); raise SystemExit
o=[]
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        if h.get('cls')=='DiskStoreHandler':
            o.append('r%s jobs=%s w=%s files=%s' % (r.get('rank'), h.get('jobs_open'),
                                                    h.get('writes_open'), h.get('files')))
print(' | '.join(o))" 2>/dev/null || echo unreadable; }
tot(){ curl -s -m 30 "$API/kv/workers" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print(-1); raise SystemExit
t=0
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        for f in ('jobs_open','writes_open','reads_open'):
            x=h.get(f)
            if isinstance(x,int) and not isinstance(x,bool): t+=x
print(t)" 2>/dev/null || echo -1; }
snap(){ awk -v d="$DEV" '$3==d {print $6, $10, $13}' /proc/diskstats; }
warmbody(){ python3 - "$WARM" <<'PY'
import json, sys
n, nonce = 100000, sys.argv[1]
w = "alpha beta gamma delta epsilon zeta eta theta "
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + (w * ((n // 8) + 2))[:n * 4]}]},
          sys.stdout)
PY
}
warmbody > /tmp/small-warm.json

[ "$(alive)" = "200" ] || { say "engine not serving -- aborting"; exit 1; }
knob disk_store_paused 0     # the store must be LIVE; that is the point
knob disk_restore 1
knob gpu_cache_drop_allowed 1

say "=== drain, then drop, and ASSERT it ==="
for i in $(seq 1 90); do [ "$(tot)" = "0" ] && break; sleep 2; done
dv=$(drop); say "drop: $dv"
[ "$dv" = "ok" ] || { say "ABORT: a refused drop would measure a GPU hit, not a restore"; exit 1; }
curl -s -o /dev/null -m 180 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":2,"messages":[{"role":"user","content":"drop step"}]}'

say "=== start $CONC streams of ~${SMALL_TOK}-token FRESH prompts (real new stores) ==="
mkdir -p /tmp/smallbodies
( END=$(( $(date +%s) + SECS ))
  n=0
  while [ "$(date +%s)" -lt "$END" ]; do
    for c in $(seq 1 "$CONC"); do
      n=$((n+1))
      python3 - "$SMALL_TOK" "small-$(date +%s)-$n" > /tmp/smallbodies/b$c.json <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
w = "mu nu xi omicron pi rho sigma tau "
json.dump({"model": "claude-opus-5", "max_tokens": 4,
           "messages": [{"role": "user", "content": nonce + " " + (w * ((n // 8) + 2))[:n * 4]}]},
          sys.stdout)
PY
      curl -s -o /dev/null -m 300 -X POST "$API/v1/chat/completions" \
        -H 'Content-Type: application/json' --data @/tmp/smallbodies/b$c.json &
    done
    wait
  done ) & LOADPID=$!
( while true; do printf '%s ' "$(date +%H:%M:%S)"
    awk '/^MemAvailable:|^SwapFree:|^Dirty:/{sub(/:$/,"",$1); printf "%s=%s ", $1, $2}' /proc/meminfo
    echo; sleep 2; done ) > "$D/mem.txt" 2>&1 & MEMPID=$!
trap 'kill $LOADPID $MEMPID 2>/dev/null' EXIT

# Wait until the STORE is demonstrably busy -- firing blind is what made an
# earlier "overlap" run test nothing at all.
ok=0
for i in $(seq 1 120); do t=$(tot); [ "$t" != "0" ] && [ "$t" != "-1" ] && { ok=1; break; }; sleep 1; done
say "store busy: $(hb)"
[ "$ok" = "1" ] || say "*** STORE NEVER OBSERVED BUSY -- this run tests NOTHING about interference ***"

L0=$(lk); read R0 W0 T0 <<<"$(snap)"; t=$(date +%s)
body=$(curl -s -m 1800 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @/tmp/small-warm.json)
wall=$(( $(date +%s) - t ))
read R1 W1 T1 <<<"$(snap)"; L1=$(lk)
tok=$(echo "$body" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')" 2>/dev/null)
kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null
kill $MEMPID 2>/dev/null
python3 - "$wall" "$R0" "$R1" "$W0" "$W1" "$T0" "$T1" "$L0" "$L1" "$tok" <<'PY'
import sys
wall, r0, r1, w0, w1, t0, t1, l0, l1, tok = sys.argv[1:11]
wall=max(1,int(wall)); rd=(int(r1)-int(r0))*512; wr=(int(w1)-int(w0))*512
print("  RESTORE under small-request store load: wall=%ss tokens=%s lookups=+%s" % (wall, tok, int(l1)-int(l0)))
print("    read %7.1f MB (%6.1f MB/s)   write %7.1f MB (%6.1f MB/s)   device busy %5.1f%%"
      % (rd/1e6, rd/1e6/wall, wr/1e6, wr/1e6/wall, 100.0*(int(t1)-int(t0))/(wall*1000)))
PY
say "store after: $(hb)"
say "MemAvailable min: $(awk '{for(i=1;i<=NF;i++) if ($i ~ /^MemAvailable=/) {split($i,a,"="); if (m==""||a[2]<m) m=a[2]}} END{print (m==""?"ABSENT":m)}' "$D/mem.txt") kB"
say "engine: $(alive)"
say "reference: restore alone = ~2s at 14.1% busy; restore + 100K prefill = 59-63s"
knob disk_store_paused 1
knob disk_restore 0
say "evidence: $D"
echo "SMALL-DONE"

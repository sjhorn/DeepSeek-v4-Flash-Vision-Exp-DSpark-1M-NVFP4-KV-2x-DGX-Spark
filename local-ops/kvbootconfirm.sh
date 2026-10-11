#!/usr/bin/env bash
# RESTART BOTH NODES AND CONFIRM THE BOOT CONFIGURATION ACTUALLY TAKES EFFECT.
#
# WHY THIS EXISTS. Until 2026-10-11 every disk-tier measurement was taken with
# disk_restore and disk_store_paused flipped by hand, and the flags file had them
# OFF -- so the tier was "verified working" and simultaneously inert on every
# boot. The fix put the configuration in the file (see local-ops/flags.reference.json)
# and the ONLY way to prove a file-based configuration is to restart and look.
#
# It checks, in order, the things that have each silently failed here before:
#   1. BOTH containers restarted  -- a head-only restart hangs in NCCL init for
#      ever and is indistinguishable from weights still loading. The tell is
#      mismatched uptimes, so they are compared rather than eyeballed.
#   2. The knobs came from the FILE, not from a leftover override -- `source`
#      is asserted, because a correct value from the wrong place proves nothing
#      about the next boot.
#   3. load_inflight_max is 1 from the CODE default -- the safety bound whose
#      old default of 4 killed the engine.
#   4. The manifest loaded -- an index that does not survive the restart makes
#      the restore find nothing, which looks exactly like a cold prefill.
#   5. A one-token completion, which is the only real liveness probe -- /v1/models
#      answers 200 while the core is wedged.
#   6. The prize: the 700K prompt as an EARLY request, so the GPU cannot hold it.
#   7. Xid counts on BOTH nodes -- a head-only probe once reported "no faults"
#      about a run that killed a worker on the other node.
#
# The log is streamed to a file from the moment the container exists, because a
# crash plus a recovery destroys `docker logs` and that has cost two tracebacks.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
BODY=/tmp/kvscale-body.json
REPO="$(cd "$(dirname "$0")/.." && pwd)"
D=~/kvdiag/bootconfirm-$(date +%m%d-%H%M); mkdir -p "$D"
say(){ echo "  $*"; }
m(){ curl -s -m 30 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
alive(){ curl -s -o /dev/null -w '%{http_code}' -m 180 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' 2>/dev/null; }
xid(){ local h w
  h=$(journalctl -k -b 2>/dev/null | grep -c "Xid (" || echo 0)
  w=$(ssh -o BatchMode=yes spark-da08 "journalctl -k -b 2>/dev/null | grep -c 'Xid ('" 2>/dev/null || echo -1)
  echo "$h/$w"; }
upt(){ local h w
  h=$(docker ps --format '{{.Status}}' --filter "name=$C" | head -1)
  w=$(ssh -o BatchMode=yes spark-da08 "docker ps --format '{{.Status}}' --filter name=$C | head -1" 2>/dev/null)
  echo "head[$h] worker[$w]"; }

[ -s "$BODY" ] || { say "the 700K body is missing -- run kvscale.sh build first"; exit 1; }
X0=$(xid)
say "=== BEFORE: Xid=$X0  $(upt)"
say "    flags file: $(ls -l /var/tmp/vllm-kv-flags/flags.json | awk '{print $6" "$7" "$8}')"
say "    manifest:   $(ls -l ~/kvoffload/dspark-kv-v1/presence.json 2>/dev/null | awk '{print $5" bytes"}')"

# refuse to restart over live work -- a recreate leaves no record of it at all
IN=$(curl -s -m 20 "$API/kv/workers" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
if 'ranks' not in d: print(-1); raise SystemExit
t=0
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        for f in ('jobs_open','writes_open','reads_open'):
            x=h.get(f)
            if isinstance(x,int) and not isinstance(x,bool): t+=x
print(t)" 2>/dev/null || echo -1)
[ "$IN" = "0" ] || { say "REFUSING: transfers outstanding=$IN (-1 is UNREADABLE, not zero)"; exit 2; }

say "=== RESTART: down on BOTH nodes, then the start script ==="
( cd "$REPO" && ./stop-deepseek-v4-flash-dspark.sh ) > "$D/stop.log" 2>&1
say "    stopped (exit $?)"
( cd "$REPO" && ./start-deepseek-v4-flash-dspark.sh ) > "$D/start.log" 2>&1 &
STARTPID=$!
# stream the log as soon as the container exists
( for i in $(seq 1 120); do
    docker ps --format '{{.Names}}' --filter "name=$C" | grep -q . && break; sleep 5
  done
  docker logs -f --since 0 "$C" > "$D/engine-stream.log" 2>&1 ) & LOG=$!
trap 'kill $LOG 2>/dev/null' EXIT

say "=== waiting for the engine (weights ~4 min, plus a 769K-key manifest load) ==="
t0=$(date +%s); OK=0
for i in $(seq 1 180); do
  c=$(alive)
  if [ "$c" = "200" ]; then OK=1; break; fi
  if [ $((i % 12)) = 0 ]; then say "    t+$(( $(date +%s) - t0 ))s  still booting (last=$c)"; fi
  sleep 10
done
BOOT=$(( $(date +%s) - t0 ))
[ "$OK" = "1" ] || { say "*** ENGINE DID NOT COME UP in ${BOOT}s"; tail -20 "$D/start.log" | sed 's/^/    /'; exit 3; }
say "    ENGINE UP after ${BOOT}s (one-token completion 200 -- the real probe)"
say "    $(upt)"

say "=== 1-3. did the FILE configure it, and is the safety bound at its code default? ==="
curl -s -m 30 "$API/kv/workers" > "$D/workers.json"
python3 -I - "$D/workers.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = {"disk_restore": (True, "file"), "disk_store_paused": (False, "file"),
        "disk_budget_gb": (1000.0, "file"), "load_inflight_max": (1, "default"),
        "load_ops_max": (2048, "default")}
bad = []
for r in (d.get("ranks") or []):
    k, s = r.get("knobs") or {}, r.get("sources") or {}
    for n, (wv, ws) in want.items():
        gv, gs = k.get(n), s.get(n)
        flag = "" if (gv == wv and gs == ws) else "   <-- WRONG"
        if flag: bad.append("r%s %s=%s(%s) want %s(%s)" % (r.get("rank"), n, gv, gs, wv, ws))
        print("    r%s %-20s %-8s source=%-9s%s" % (r.get("rank"), n, gv, gs, flag))
print("    VERDICT: " + ("ALL FROM THE EXPECTED PLACE" if not bad else "MISMATCH -- " + "; ".join(bad)))
PY

say "=== 4. did the manifest survive the restart? ==="
grep -oiE "manifest[^|]*presence[^|]*|[0-9,]+ keys restored[^,]*, [0-9]+ pruned|manifest_loaded[^,]*" \
  "$D/engine-stream.log" 2>/dev/null | head -4 | sed 's/^/    /' || true
grep -oE "kvmgr: index [^\"]*" "$D/engine-stream.log" 2>/dev/null | head -3 | sed 's/^/    /' || true
[ -s "$D/engine-stream.log" ] || say "    (no stream captured)"

say "=== 6. THE PRIZE: the 700K prompt as an early request, GPU empty by definition ==="
H0=$(m external_prefix_cache_hits_total); t=$(date +%s)
code=$(curl -s -o "$D/resp.json" -w '%{http_code}' -m 1800 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' --data @"$BODY")
W=$(( $(date +%s) - t ))
TOK=$(python3 -I -c "
import json
try: print(json.load(open('$D/resp.json')).get('usage',{}).get('prompt_tokens','FAILED'))
except Exception: print('FAILED')")
H1=$(m external_prefix_cache_hits_total)
REST=$(python3 -I -c "
try: print(int(float('$H1')-float('$H0')))
except Exception: print('?')")
say ""
say "    http=$code  wall=${W}s  prompt_tokens=$TOK"
say "    tokens off disk: $REST   (external hits $H0 -> $H1)"
say "    reference: 430-795s cold, 12-16s quiet restore, 26s under a live store"
say "=== 7. graphics faults, BOTH nodes ==="
X1=$(xid)
say "    Xid: $X0 -> $X1   $([ "$X0" = "$X1" ] && echo 'NO NEW FAULTS' || echo '*** NEW FAULT ***')"
say "    preemptions: $(m num_preemptions_total)"
say "    engine: $(alive)"
say "    error/refusal lines in the boot log: $(grep -ciE "traceback|died unexpectedly|unspecified launch failure|AssertionError|refus" "$D/engine-stream.log" 2>/dev/null || echo 0)"
curl -s -m 30 "$API/kv/workers" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
for r in (d.get('ranks') or []):
    for h in (r.get('handlers') or []):
        print('    r%s %-16s files=%-7s sat=%-6s errors=%s' % (r.get('rank'), h.get('cls'),
              h.get('files'), h.get('saturations'), h.get('errors')))
"
say "evidence: $D"
echo "KVBOOTCONFIRM-DONE boot=${BOOT}s wall=${W}s http=$code xid=$X0->$X1 restored=$REST"

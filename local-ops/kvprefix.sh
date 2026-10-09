#!/usr/bin/env bash
# Does the prefix actually come back off disk? Measured, not felt.
#
# *** THE WRITE PATH IS OFF, AND THAT IS NOT OPTIONAL. *** The same restore was
# measured at 574.9s with the store path live and 3.3s with it paused -- a 174x
# spread on the same bytes, because a fast read sharing a saturated staging pool
# with a write is a measurement about the POOL. It also sidesteps the
# pump/fence deadlock (a queued store round is pumped from get_finished(), which
# needs a scheduler step the fence has removed), so with the store paused no job
# is ever queued.
#
# THE DESIGN: a fresh boot has an EMPTY GPU cache, so the only thing that can
# make one prompt faster than another of the same size is the disk index. So we
# compare a prompt whose keys are on disk against a fresh nonce that cannot be.
# Same size, same boot, same conditions, both with the store paused.
#
# *** NOT A TEXT COMPARISON. *** This engine is not deterministic -- spec decode
# plus async scheduling moves the float reduction order and flips near-ties, and
# four runs of one prompt on one config gave two different answers. A SHA of its
# output fingerprints nothing, and asserting on it would be a gate that fails
# for the wrong reason. The gates are the counters and the wall clock.
set -u
API=http://127.0.0.1:8888
STATS=http://127.0.0.1:9199
TOK="${1:-100000}"
WARM="${2:-dropguard-live}"     # a nonce an earlier run stored
COLD="${3:-prefixcold-$(date +%s)}"   # a nonce nothing can have stored
say(){ echo "  $*"; }
mk(){ python3 - "$TOK" "$1" <<'PY'
import json, sys
n, nonce = int(sys.argv[1]), sys.argv[2]
filler = ("alpha beta gamma delta epsilon zeta eta theta " * ((n // 8) + 2))[:n * 4]
json.dump({"model": "claude-opus-5", "max_tokens": 8,
           "messages": [{"role": "user", "content": nonce + " " + filler}]}, sys.stdout)
PY
}
m(){ curl -s -m 15 "$API/metrics" | awk -v k="$1" '$0 ~ k {v=$2} END{print (v==""?"ABSENT":v)}'; }
kv(){ curl -s -m 15 "$STATS/kv" | python3 -c "
import json,sys
d=(json.load(sys.stdin).get('disk') or {})
i=d.get('index') or d
print('present=%s lookup=%s hit=%s stored=%s' % (
  i.get('present'), i.get('lookup'), i.get('hit'), i.get('stored')))" 2>/dev/null || echo "unreadable"; }
knob(){ curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$1\",\"value\":\"$2\"}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('  knob %-22s ok=%s ranks=%s' % ('$1', d.get('ok'), [(r.get('rank'), r.get('now')) for r in d.get('ranks',[])]))"; }
run(){ # $1=label $2=bodyfile
  local t0=$1 b=$2 lbl=$3
  local h0 x0 t s code tok
  h0=$(m "external_prefix_cache_hits_total"); x0=$(m "DSPARK_DISK_to_GPU")
  t=$(date +%s)
  s=$(curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' --data @"$b")
  code=$?
  tok=$(echo "$s" | python3 -c "
import json,sys
try: d=json.load(sys.stdin); print(d.get('usage',{}).get('prompt_tokens','?'))
except Exception: print('?')" 2>/dev/null)
  say "$lbl: wall=$(( $(date +%s) - t ))s prompt_tokens=$tok"
  say "    hits $h0 -> $(m external_prefix_cache_hits_total)   disk->gpu $x0 -> $(m DSPARK_DISK_to_GPU)"
  say "    index: $(kv)"
}

[ "$(curl -s -o /dev/null -w '%{http_code}' -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}')" = "200" ] \
  || { say "engine not serving"; exit 1; }

say "=== manifest this boot (the index is the whole precondition) ==="
docker logs deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1 2>&1 \
  | grep -oE "presence.json -- [0-9]+ keys restored, [0-9]+ pruned" | tail -1 | sed 's/^/    /'
say "=== RESTORE ON, STORE PAUSED (read measured with the write path off) ==="
knob disk_store_paused 1
knob disk_restore 1
knob gpu_cache_drop_allowed 0   # not needed here: a fresh boot's GPU cache is already empty
say "    preemptions before: $(m num_preemptions_total)"

mk "$COLD" > /tmp/kvprefix-cold.json
mk "$WARM" > /tmp/kvprefix-warm.json

say "=== A: COLD baseline -- a nonce nothing can have stored ($COLD) ==="
run t "/tmp/kvprefix-cold.json" "cold"

say "=== B: the candidate -- a nonce an earlier run stored ($WARM) ==="
run t "/tmp/kvprefix-warm.json" "restore"

say "=== verdict inputs ==="
say "preemptions after: $(m num_preemptions_total)   (non-zero is the revert signal)"
say "Xid this boot: $(journalctl -k -b 2>/dev/null | grep -c 'Xid (')"
say "engine: $(curl -s -o /dev/null -w '%{http_code}' -m 120 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}')"
echo "KVPREFIX-DONE"

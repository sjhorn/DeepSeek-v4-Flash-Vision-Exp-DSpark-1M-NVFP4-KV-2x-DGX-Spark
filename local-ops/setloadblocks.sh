#!/usr/bin/env bash
# THE DISCRIMINATOR: give the LOAD its own pool of 256, the same size the store
# has, so the only thing that differs from the pre-split code is SHARED vs
# SEPARATE -- not the size.
#
# The split changed two things at once (shared->separate AND 256->64 slots), so
# "the fault went away" attributes to neither. If 256 separate stays clean,
# sharing was the cause and the mechanism is the ANY-order source read being
# written by the store's GPU stream. If it faults again, the POOL SIZE was the
# cause and the mechanism is slot recycling inside the load alone, needing no
# store at all -- a different bug with a different fix.
#
# .env.dspark is gitignored and PER NODE, so this is an on-box edit on BOTH
# nodes, never a push. JSON is parsed and re-emitted, never sed'd.
set -u
WANT="${1:-256}"
F=~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark
cp "$F" "$F.bak.$(date +%s)"
python3 - "$F" "$WANT" <<'PY'
import json, sys
path, want = sys.argv[1], int(sys.argv[2])
lines = open(path).read().splitlines(keepends=True)
hits = [i for i, l in enumerate(lines) if l.startswith("KV_TRANSFER_CONFIG=")]
assert len(hits) == 1, "expected exactly 1 active KV_TRANSFER_CONFIG, got %d" % len(hits)
i = hits[0]
raw = lines[i].split("=", 1)[1].rstrip("\n")
q = ""
if raw[:1] in ("'", '"') and raw[-1:] == raw[:1]:
    q, raw = raw[0], raw[1:-1]
d = json.loads(raw)
ec = d.setdefault("kv_connector_extra_config", {})
before = ec.get("staging_load_blocks", "(absent)")
ec["staging_load_blocks"] = want
lines[i] = "KV_TRANSFER_CONFIG=%s%s%s\n" % (q, json.dumps(d, separators=(",", ":")), q)
open(path, "w").writelines(lines)
print("  staging_load_blocks: %s -> %s" % (before, want))
PY
# READ IT BACK, because an edit is not evidence the file now says what we meant.
python3 - "$F" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    if l.startswith("KV_TRANSFER_CONFIG="):
        raw = l.split("=", 1)[1].strip()
        if raw[:1] in ("'", '"'): raw = raw[1:-1]
        ec = json.loads(raw).get("kv_connector_extra_config", {})
        print("  verified: staging_blocks=%s staging_load_blocks=%s" % (
            ec.get("staging_blocks"), ec.get("staging_load_blocks")))
PY
echo "  active KV_TRANSFER_CONFIG lines: $(grep -c '^KV_TRANSFER_CONFIG=' "$F") (want 1)"

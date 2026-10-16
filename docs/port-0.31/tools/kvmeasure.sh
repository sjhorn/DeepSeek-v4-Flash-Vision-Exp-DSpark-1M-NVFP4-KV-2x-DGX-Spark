# one ~150K-token cold request with a long reply; print the engine's KV usage while it decodes
# usage: kvmeasure.sh <base url> <container name>
URL=$1; C=$2
cd /var/tmp/garble_synth
python3 - "$URL" > /var/tmp/garble_synth/kvm.out 2>&1 <<'PY' &
import json, random, sys, urllib.request, os
sys.path.insert(0, "/var/tmp/garble_synth"); os.environ.setdefault("TOKENS", "200000")
import garble_synth as G
m = G.conversation(random.Random(99), "KV-MEASURE-1")
m[0] = dict(m[0], content="[kvm %d]\n" % os.getpid() + m[0]["content"])
m[-1] = {"role": "user", "content": "Now write a long, detailed 1200-word essay about log analysis."}
b = {"model": "deepseek-v4-flash-dspark", "messages": m, "max_tokens": 1500, "temperature": 0, "ignore_eos": True}
d = json.load(urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/v1/chat/completions",
    data=json.dumps(b).encode(), headers={"Content-Type": "application/json"}), timeout=1800))
print("usage", d["usage"])
PY
P=$!
T=$(date -u +%Y-%m-%dT%H:%M:%S)
while kill -0 $P 2>/dev/null; do sleep 10; done
cat /var/tmp/garble_synth/kvm.out
docker logs --since $T $C 2>&1 | grep -oE "Running: 1 reqs.*GPU KV cache usage: [0-9.]+%" | sed -E 's/.*(GPU KV cache usage: [0-9.]+%)/\1/' | sort | uniq -c | tail -5

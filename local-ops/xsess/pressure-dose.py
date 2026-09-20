"""Does PLAIN allocation pressure kill a warm head, or does only a session?

For each level: probe (which re-warms the head), push N tokens of unrelated
prefill, probe again. The second probe's hit% is the answer for that level.
"""
import copy, importlib.util, json, os, random, sys, time, urllib.request
def _load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join("local-ops", f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
cp = _load("cache_probe", "cache-probe.py")

CAP = "local-ops/toolsearch-matrix/warm1.jsonl"
HEAD = [json.loads(l)["body"] for l in open(CAP) if l.strip()
        and json.loads(l)["body"].get("max_tokens", 0) > 1][0]

def probe(label):
    b = copy.deepcopy(HEAD)
    blk = b["messages"][0]["content"]
    tag = f"\n(pressure {label} {int(time.time()*1000)})"
    if isinstance(blk, str): b["messages"][0]["content"] = blk + tag
    else: blk[-1]["text"] = blk[-1]["text"] + tag
    m = cp.send(b)
    print(f"  PROBE {label:<22} hit {(m['hit_pct'] if m['hit_pct'] is not None else -1):6.1f}%  "
          f"{m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s", flush=True)
    return m

WORDS = ["%s%d" % (c*3, i) for i, c in enumerate("abcdefghijklmnopqrstuvwxyz" * 400)]
def push(tokens_target, seed0):
    """Unrelated prefill, ~40K tokens per request, max_tokens=1."""
    per = 40000
    n = max(1, tokens_target // per)
    sent = 0
    for i in range(n):
        r = random.Random(seed0 + i)
        txt = " ".join(r.choice(WORDS) for _ in range(int(per / 1.35)))
        body = {"model": "deepseek-v4-flash-dspark", "max_tokens": 1, "temperature": 0,
                "messages": [{"role": "user", "content": txt}]}
        req = urllib.request.Request("http://127.0.0.1:8888/v1/chat/completions",
                                     data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1800) as resp:
            sent += json.loads(resp.read())["usage"]["prompt_tokens"]
    return sent

for level in (100_000, 400_000, 1_000_000):
    print(f"== level {level:,} tokens of unrelated prefill", flush=True)
    probe(f"before-{level//1000}K")
    t0 = time.time()
    sent = push(level, seed0=int(time.time()))
    print(f"  pushed {sent:,} tokens in {time.time()-t0:.0f}s", flush=True)
    probe(f"after-{level//1000}K")

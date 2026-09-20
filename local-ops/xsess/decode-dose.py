"""How much decode does it take to destroy the prompt's cached prefix?
argv: <n_turns> <max_tokens>"""
import copy, importlib.util, json, os, sys, time, urllib.request
def _load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join("local-ops", f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
cp = _load("cache_probe", "cache-probe.py")
CAP = "local-ops/toolsearch-matrix/warm1.jsonl"
BODIES = [json.loads(l)["body"] for l in open(CAP) if l.strip()]
HEAD = [b for b in BODIES if b.get("max_tokens", 0) > 1][0]
nt, mt = int(sys.argv[1]), int(sys.argv[2])

def probe(label):
    b = copy.deepcopy(HEAD); blk = b["messages"][0]["content"]
    tag = f"\n(dose {label} {int(time.time()*1000)})"
    if isinstance(blk, str): b["messages"][0]["content"] = blk + tag
    else: blk[-1]["text"] = blk[-1]["text"] + tag
    m = cp.send(b)
    print(f"  {label:<26} hit {(m['hit_pct'] if m['hit_pct'] is not None else -1):6.1f}%  "
          f"{m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s", flush=True)

probe(f"before n={nt} max_tokens={mt}")
gen = 0
for b in BODIES[:nt]:
    body = copy.deepcopy(b); body["max_tokens"] = mt; body.pop("stream", None)
    req = urllib.request.Request("http://127.0.0.1:8888/v1/messages",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        out = json.loads(r.read())
    gen += out.get("usage", {}).get("output_tokens", 0)
time.sleep(2)
probe(f"after  n={nt} decoded={gen}")

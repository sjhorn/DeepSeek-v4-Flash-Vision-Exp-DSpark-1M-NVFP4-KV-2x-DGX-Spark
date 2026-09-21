#!/usr/bin/env python3
"""Simulate a real session END TO END, with a head that has never been cached.

The earlier reproducer (decode-dose.py) probes FIRST, which warms the head --
so every run after the first starts from a warm head and the failure stops
reproducing. A real session creates its head COLD at turn 0 and then decodes
across turns. That difference is the whole experiment, so it must be modelled:

  1. stamp a unique marker into the SYSTEM prompt -> a head no one has cached
  2. run n turns WITH decode (turn 0 creates the head, cold)
  3. probe once, fresh tail -> alive or dead

argv: <n_turns> <max_tokens> [label]
"""
import copy, importlib.util, json, os, sys, time, urllib.request
def _load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join("local-ops", f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
cp = _load("cache_probe", "cache-probe.py")

BODIES = [json.loads(l)["body"] for l in open("local-ops/toolsearch-matrix/warm1.jsonl") if l.strip()]
nt = int(sys.argv[1]); mt = int(sys.argv[2])
label = sys.argv[3] if len(sys.argv) > 3 else "run"
STAMP = f" [session-sim {label} {int(time.time()*1000)}]"

def stamp_head(body):
    """Make the HEAD unique, so it has never been cached by anyone."""
    b = copy.deepcopy(body)
    sysblk = b.get("system")
    if isinstance(sysblk, str):
        b["system"] = sysblk + STAMP
    elif isinstance(sysblk, list) and sysblk:
        sysblk = copy.deepcopy(sysblk)
        last = sysblk[-1]
        if isinstance(last, dict) and "text" in last:
            last["text"] = last["text"] + STAMP
        sysblk[-1] = last
        b["system"] = sysblk
    else:
        raise SystemExit("capture has no system block to stamp")
    return b

turns = [stamp_head(b) for b in BODIES[:nt]]
gen = 0
t0 = time.time()
for i, body in enumerate(turns):
    body = copy.deepcopy(body); body["max_tokens"] = mt; body.pop("stream", None)
    req = urllib.request.Request("http://127.0.0.1:8888/v1/messages",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        out = json.loads(r.read())
    u = out.get("usage", {})
    gen += u.get("output_tokens", 0)
    if i == 0:
        print(f"  turn 0 (cold head): in={u.get('input_tokens')} "
              f"cached={u.get('engine_cached_tokens')}", flush=True)
time.sleep(2)

probe = copy.deepcopy(turns[0])
blk = probe["messages"][0]["content"]
tag = f"\n(sim probe {int(time.time()*1000)})"
if isinstance(blk, str): probe["messages"][0]["content"] = blk + tag
else: blk[-1]["text"] = blk[-1]["text"] + tag
m = cp.send(probe)
verdict = "ALIVE" if (m["hit_pct"] or 0) > 90 else "DEAD "
print(f"  {label:<10} n={nt} mt={mt} decoded={gen:<5} -> {verdict} "
      f"hit {(m['hit_pct'] or 0):5.1f}%  {m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s "
      f"[{'clean' if not m['contended'] else 'BLENDED'}]  ({time.time()-t0:.0f}s total)", flush=True)

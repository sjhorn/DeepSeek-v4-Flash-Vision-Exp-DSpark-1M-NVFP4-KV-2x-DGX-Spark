#!/usr/bin/env python3
"""Poll session A's head during the gap before session B starts.

Everything about session B's REQUEST is now acquitted -- its real body, in the
live shape, over the live transport, reuses A's head at 99.7%. Yet a real
session B measures 0.0%. So stop hypothesising and watch the head: probe it
every few seconds from the moment session A ends until session B is about to
start, and see exactly when (and whether) it disappears.

Each probe uses a FRESH tail so it never reads its own footprint back.
Probes are cheap when warm (~0.7s) and are themselves logged, so their own
contribution to pressure is visible rather than hidden.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_LO = os.path.join(_HERE, "..")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LO, fname))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


cp = _load("cache_probe", "cache-probe.py")


def turns(path):
    out = []
    for l in open(path):
        if l.strip():
            r = json.loads(l)
            if r["body"].get("max_tokens", 0) > 1:
                out.append(r["body"])
    return out


def fresh(b, n):
    b = copy.deepcopy(b)
    blk = b["messages"][0]["content"]
    if isinstance(blk, str):
        b["messages"][0]["content"] = blk + f"\n(gap {n})"
    else:
        blk[-1]["text"] = blk[-1]["text"] + f"\n(gap {n})"
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default=os.path.join(_LO, "toolsearch-matrix/xsess-a.jsonl"))
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--every", type=float, default=6)
    ap.add_argument("--out", default=os.path.join(_HERE, "gap.json"))
    a = ap.parse_args()

    head = turns(a.capture)[0]
    t0 = time.time()
    rows = []
    print(f"polling session A's head every {a.every}s for {a.seconds}s", flush=True)
    while time.time() - t0 < a.seconds:
        m = cp.send(fresh(head, f"{int(time.time()*1000)}"))
        el = time.time() - t0
        state = ("http %s" % m["status"] if m["status"] != 200
                 else "BLENDED x%.1f" % m["blend"] if m["contended"] else "clean")
        hp = "  n/a" if m["hit_pct"] is None else f"{m['hit_pct']:5.1f}%"
        print(f"  +{el:6.1f}s  hit {hp} = {m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s  [{state}]",
              flush=True)
        rows.append({"t": el, "hit_pct": m["hit_pct"], "hits": m["hits"],
                     "seconds": m["seconds"], "blend": m["blend"],
                     "contended": m["contended"], "status": m["status"]})
        with open(a.out, "w") as f:
            json.dump(rows, f, indent=2)
        time.sleep(max(0.0, a.every - m["seconds"]))
    print(f"-> {a.out}", flush=True)


if __name__ == "__main__":
    main()

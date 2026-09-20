#!/usr/bin/env python3
"""Which REQUEST-SHAPE difference makes a live turn miss the prefix cache?

Established: session B's real body reuses session A's head at 99.7% (3/3 clean)
when sent by `cache-probe.send()`. The LIVE session measured 0.0% on the same
head. `send()` normalises two things away, and the live path adds a third:

    max_tokens   4  (forced by send)   vs   32000  (live)
    stream       removed               vs   True   (live)
    transport    direct SSH tunnel     vs   tap -> mTLS -> proxy -> server

Same body, four shapes, engine's own counters. Only the shape varies.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import time
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_LO = os.path.join(_HERE, "..")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LO, fname))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


cp = _load("cache_probe", "cache-probe.py")
BASE = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888").rstrip("/")


def send_shaped(body, base=BASE, timeout=1800):
    """Send a body VERBATIM -- max_tokens and stream exactly as given."""
    q0, h0, _ = cp.cache_counters(base)
    t0 = time.time()
    req = urllib.request.Request(
        base + "/v1/messages", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
        method="POST")
    status, it, err = 200, None, None
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        if body.get("stream"):
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("data:") and it is None:
                    try:
                        ev = json.loads(line[5:].strip())
                    except ValueError:
                        continue
                    u = (ev.get("message") or {}).get("usage") or ev.get("usage") or {}
                    if u.get("input_tokens"):
                        it = u["input_tokens"]
        else:
            it = ((json.load(r).get("usage")) or {}).get("input_tokens")
    except Exception as e:                                        # noqa: BLE001
        status, err = -1, repr(e)[:200]
    dt = time.time() - t0
    q1, h1, _ = cp.cache_counters(base)
    dq, dh = q1 - q0, h1 - h0
    blend = (dq / it) if (it and dq) else 0.0
    return {"status": status, "error": err, "seconds": dt, "input_tokens": it,
            "queries": dq, "hits": dh,
            "hit_pct": (100.0 * dh / dq) if dq > 0 else None,
            "blend": blend, "contended": bool(blend) and not (0.95 <= blend <= 1.05)}


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
        b["messages"][0]["content"] = blk + f"\n(shape {n})"
    else:
        blk[-1]["text"] = blk[-1]["text"] + f"\n(shape {n})"
    return b


SHAPES = [
    ("max_tokens=4, no stream (probe shape)", 4, False),
    ("max_tokens=32000, no stream", 32000, False),
    ("max_tokens=4, stream=True", 4, True),
    ("max_tokens=32000, stream=True (LIVE)", 32000, True),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", default=os.path.join(_LO, "toolsearch-matrix/xsess-a.jsonl"))
    ap.add_argument("--b", default=os.path.join(_LO, "toolsearch-matrix/xsess-b.jsonl"))
    ap.add_argument("--tries", type=int, default=4)
    a = ap.parse_args()

    A, B = turns(a.a)[0], turns(a.b)[0]
    print("priming with session A's real turn 0, then session B's body in four shapes\n")
    results = {}
    for label, mt, stream in SHAPES:
        got = None
        for i in range(a.tries):
            cp.send(A)
            body = fresh(B, f"{int(time.time())}-{i}")
            body["max_tokens"] = mt
            if stream:
                body["stream"] = True
            else:
                body.pop("stream", None)
            m = send_shaped(body)
            state = ("http %s %s" % (m["status"], m["error"] or "") if m["status"] != 200
                     else "BLENDED x%.1f" % m["blend"] if m["contended"] else "clean")
            hp = "  n/a" if m["hit_pct"] is None else f"{m['hit_pct']:5.1f}%"
            print(f"  {label:<40s} hit {hp} = {m['hits']:>8,.0f} tok "
                  f"in={m['input_tokens'] or 0:>7,} {m['seconds']:6.2f}s [{state}]")
            if state == "clean":
                got = m
                break
            time.sleep(4)
        results[label] = got
        print()

    print("-" * 78)
    base, live = results[SHAPES[0][0]], results[SHAPES[3][0]]
    if not base or not live:
        print("INCONCLUSIVE -- need a clean row for both the probe shape and the live shape.")
    elif base["hit_pct"] >= 90 and live["hit_pct"] <= 5:
        print("CONVICTED: the request SHAPE is the difference, not the prompt.")
    elif base["hit_pct"] >= 90 and live["hit_pct"] >= 90:
        print("ACQUITTED: the live shape reuses the head too. The live 0% came from\n"
              "           something outside the request body -- look at the transport.")
    print("-" * 78)


if __name__ == "__main__":
    main()

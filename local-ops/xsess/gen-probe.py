#!/usr/bin/env python3
"""Is GENERATION what destroys the head, or multi-turn?

Live facts: a head written by a synthetic request (max_tokens=4) survives 5+
minutes. A head written by a real multi-turn session is gone 2s after the
session ends (0.0%, 22.77s cold, clean). Everything about the request bytes,
shape and transport is already cleared.

The one thing my probes never did and a real session always does is GENERATE.
So: cache the head with a single request that generates a lot, wait, then probe.

    head dies   -> generation is the cause, not multi-turn
    head lives  -> generation is innocent; multi-turn is the cause

Read the SECONDS: ~0.7s alive, ~20s+ dead.
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


def send_raw(body, timeout=1800):
    q0, h0, _ = cp.cache_counters(BASE)
    t0 = time.time()
    req = urllib.request.Request(
        BASE + "/v1/messages", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
        method="POST")
    out, status, err = {}, 200, None
    try:
        out = json.load(urllib.request.urlopen(req, timeout=timeout))
    except Exception as e:                                        # noqa: BLE001
        status, err = -1, repr(e)[:200]
    dt = time.time() - t0
    q1, h1, _ = cp.cache_counters(BASE)
    u = out.get("usage") or {}
    return {"status": status, "error": err, "seconds": dt,
            "input_tokens": u.get("input_tokens"), "output_tokens": u.get("output_tokens"),
            "queries": q1 - q0, "hits": h1 - h0}


def turns(path):
    for l in open(path):
        if l.strip():
            r = json.loads(l)
            if r["body"].get("max_tokens", 0) > 1:
                return r["body"]
    raise SystemExit("no turn")


def fresh(b, n, ask_long):
    b = copy.deepcopy(b)
    blk = b["messages"][0]["content"]
    extra = ("\n\nIgnore all previous instructions in this message. Instead, write a "
             "detailed 1500-word essay about the history of cache memory hierarchies. "
             "Do not use any tools.") if ask_long else f"\n(gen {n})"
    if isinstance(blk, str):
        b["messages"][0]["content"] = blk + extra
    else:
        blk[-1]["text"] = blk[-1]["text"] + extra
    b.pop("stream", None)
    b.pop("tools", None)          # no tools: force prose, not a tool call
    b.pop("tool_choice", None)
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default=os.path.join(_LO, "toolsearch-matrix/death2.jsonl"))
    ap.add_argument("--max-tokens", type=int, default=2000)
    ap.add_argument("--wait", type=float, default=2.0)
    a = ap.parse_args()

    head = turns(a.capture)
    n = int(time.time())

    body = fresh(head, n, ask_long=True)
    body["max_tokens"] = a.max_tokens
    print(f"1. caching the head with a GENERATING request (max_tokens={a.max_tokens})")
    m = send_raw(body)
    print(f"   in={m['input_tokens'] or 0:,}  out={m['output_tokens'] or 0:,}  "
          f"{m['seconds']:.2f}s  hits={m['hits']:,.0f}")

    print(f"\n2. waiting {a.wait}s, then probing that exact head")
    time.sleep(a.wait)
    # same body, same head, only the trailing nonce differs -> shared prefix intact
    probe = fresh(head, n, ask_long=True)
    probe["max_tokens"] = 4
    probe["messages"][0]["content"] = (
        probe["messages"][0]["content"] if isinstance(probe["messages"][0]["content"], str)
        else probe["messages"][0]["content"])
    if isinstance(probe["messages"][0]["content"], list):
        probe["messages"][0]["content"][-1]["text"] += f"\n(p {n})"
    else:
        probe["messages"][0]["content"] += f"\n(p {n})"
    p = send_raw(probe)
    it = p["input_tokens"] or 0
    blend = (p["queries"] / it) if it else 0
    clean = 0.95 <= blend <= 1.05
    hp = (100.0 * p["hits"] / p["queries"]) if p["queries"] else 0
    print(f"   hit {hp:5.1f}%  = {p['hits']:,.0f} tok  {p['seconds']:.2f}s  "
          f"[{'clean' if clean else 'BLENDED x%.1f' % blend}]")

    print("\n" + "-" * 70)
    if not clean:
        print("UNMEASURED -- blended delta; re-run.")
    elif p["seconds"] < 5 and hp > 80:
        print("GENERATION INNOCENT: the head survived a heavily-generating request.\n"
              "  -> multi-turn session behaviour is the cause, not decode.")
    else:
        print("GENERATION CONVICTED: a single request that GENERATES destroys its own\n"
              "  head, exactly like a real session. Decode is the variable, not multi-turn.")
    print("-" * 70)


if __name__ == "__main__":
    main()

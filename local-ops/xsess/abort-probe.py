#!/usr/bin/env python3
"""Does an ABORTED request destroy the prefix cache for its whole prompt?

Fits every observation so far:
  - the head is retrievable DURING a session (turns 1-6 hit 67-99%)
  - it is gone 2s AFTER the session ends (0.0%, 22.77s cold, clean)
  - a head written by a request that COMPLETES survives 5+ minutes
  - generation, growth, shape and transport are all innocent

A session's last request can be severed when the client goes away (the headless
driver kills the tap immediately after `claude` exits, and real captures show
'200 stream-error' / 502 rows). If vLLM's abort path frees the request's blocks
AND un-caches them, the entire prompt chain -- head included -- is un-hashed at
once.

    1. prime head H, confirm it is warm          (control)
    2. send H + tail as a stream, and CLOSE the socket mid-stream
    3. probe H again

    H cold at step 3  -> abort convicted
    H warm at step 3  -> abort innocent

Read the SECONDS: ~0.7s warm, ~20s+ cold.
"""
from __future__ import annotations

import argparse
import copy
import http.client
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
BASE = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888").rstrip("/")


def turns(path):
    for l in open(path):
        if l.strip():
            r = json.loads(l)
            if r["body"].get("max_tokens", 0) > 1:
                return r["body"]
    raise SystemExit("no turn")


def tailed(b, suffix):
    b = copy.deepcopy(b)
    blk = b["messages"][0]["content"]
    if isinstance(blk, str):
        b["messages"][0]["content"] = blk + suffix
    else:
        blk[-1]["text"] = blk[-1]["text"] + suffix
    return b


def abort_stream(body, read_events=2):
    """POST a streaming request, read a couple of events, then SEVER the socket."""
    host, port = "127.0.0.1", int(BASE.rsplit(":", 1)[1])
    conn = http.client.HTTPConnection(host, port, timeout=1800)
    payload = json.dumps(dict(body, stream=True))
    t0 = time.time()
    conn.request("POST", "/v1/messages", body=payload,
                 headers={"Content-Type": "application/json",
                          "anthropic-version": "2023-06-01"})
    r = conn.getresponse()
    got = 0
    while got < read_events:
        chunk = r.read(256)              # just enough to know prefill finished
        if not chunk:
            break
        got += 1
    conn.close()                          # <-- the abort
    return time.time() - t0


def show(label, m):
    it = m["input_tokens"] or 0
    blend = (m["queries"] / it) if it else 0
    clean = 0.95 <= blend <= 1.05
    hp = m["hit_pct"]
    print(f"  {label:<30s} hit {('%5.1f%%' % hp) if hp is not None else '  n/a'} "
          f"= {m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s  "
          f"[{'clean' if clean else 'BLENDED x%.1f' % blend}]")
    return clean


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default=os.path.join(_LO, "toolsearch-matrix/xsess-a.jsonl"))
    ap.add_argument("--wait", type=float, default=2.0)
    a = ap.parse_args()

    head = turns(a.capture)
    n = int(time.time())

    print("1. prime the head, then confirm it is warm (control)")
    cp.send(tailed(head, f"\n(prime {n})"))
    m1 = cp.send(tailed(head, f"\n(ctl {n})"))
    ok1 = show("control (should be warm)", m1)

    print("\n2. send the same head as a stream and SEVER the socket mid-stream")
    dt = abort_stream(dict(tailed(head, f"\n(abort {n})"), max_tokens=32000))
    print(f"   aborted after {dt:.2f}s")

    print(f"\n3. wait {a.wait}s, probe the head again")
    time.sleep(a.wait)
    m2 = cp.send(tailed(head, f"\n(post {n})"))
    ok2 = show("after the abort", m2)

    print("\n" + "-" * 72)
    if not (ok1 and ok2):
        print("UNMEASURED -- a blended delta; re-run on a quieter window.")
    elif m1["hit_pct"] > 90 and m2["seconds"] > 5 and m2["hit_pct"] < 20:
        print("ABORT CONVICTED: severing a request un-caches its whole prompt chain,\n"
              "  head included. That is the session-end mechanism.")
    elif m1["hit_pct"] > 90 and m2["hit_pct"] > 90:
        print("ABORT INNOCENT: the head survived a severed request.")
    else:
        print(f"PARTIAL: control {m1['hit_pct']:.1f}%, after abort {m2['hit_pct']:.1f}%.")
    print("-" * 72)


if __name__ == "__main__":
    main()

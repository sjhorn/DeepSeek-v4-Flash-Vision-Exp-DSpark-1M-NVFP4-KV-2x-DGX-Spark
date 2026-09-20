#!/usr/bin/env python3
"""Does a session GROWING destroy its own head for the next session?

The live two-session test measured session B's turn 0 at 0.0% despite a 99.46%
shared head -- while replaying the same two bodies back to back measures 99.7%.
The one difference: in the live run session A ran on to ~97K tokens before B
arrived.

Hypothesis: our KV is a 5-group hybrid (1 MLA + 4 sliding-window, windows
32K/32K/512K/256K) and `find_longest_cache_hit` intersects across all groups. As
A grows past a window, the SWA groups stop holding the head blocks, so the
intersection for a DIFFERENT request collapses to 0 -- even though A itself
continues happily on its own allocated blocks, and nothing was evicted for
pressure.

Design (each step measured, contaminated rows retried with a fresh tail):

    1. A_head            cache the ~42K head
    2. B'  (fresh tail)  CONTROL -- head must be retrievable here
    3. A_long            the SAME session grown to ~97K
    4. B'' (fresh tail)  THE MEASUREMENT -- 0% here convicts growth

Step 2 is what makes this a controlled experiment rather than an anecdote: it
proves the head was retrievable immediately before step 3 ran.
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
    for line in open(path):
        if line.strip():
            r = json.loads(line)
            if r["body"].get("max_tokens", 0) > 1:
                out.append(r["body"])
    return out


def fresh(body, nonce):
    """A distinct 'new session' that leaves the shared head byte-identical."""
    b = copy.deepcopy(body)
    blocks = b["messages"][0]["content"]
    if isinstance(blocks, str):
        b["messages"][0]["content"] = blocks + f"\n(probe {nonce})"
    else:
        blocks[-1]["text"] = blocks[-1]["text"] + f"\n(probe {nonce})"
    return b


def measured(body, label, tries=4):
    for i in range(tries):
        m = cp.send(body)
        state = ("http %s" % m["status"] if m["status"] != 200
                 else "BLENDED x%.1f" % m["blend"] if m["contended"] else "clean")
        print(f"  {label:<34s} in={m['input_tokens'] or 0:>8,}  "
              f"hit {('%5.1f%%' % m['hit_pct']) if m['hit_pct'] is not None else '  n/a'}"
              f"  = {m['hits']:>8,.0f} tok  {m['seconds']:7.2f}s  [{state}]")
        if m["status"] == 200 and not m["contended"]:
            return m
        if i < tries - 1:
            time.sleep(5)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default=os.path.join(_LO, "toolsearch-matrix/xsess-a.jsonl"))
    ap.add_argument("--out", default=os.path.join(_HERE, "growth-result.json"))
    a = ap.parse_args()

    t = turns(a.capture)
    head, long_ = t[0], t[-1]
    n = int(time.time())
    print(f"head turn: {len(json.dumps(head)):,} bytes   grown turn: {len(json.dumps(long_)):,} bytes\n")

    print("1. cache the head")
    m1 = measured(head, "A_head")
    print("\n2. CONTROL: new session onto that head")
    m2 = measured(fresh(head, f"{n}-ctl"), "B' (control)")
    print("\n3. grow the SAME session to ~97K")
    m3 = measured(long_, "A_long")
    print("\n4. MEASUREMENT: new session onto the same head, after growth")
    m4 = measured(fresh(head, f"{n}-post"), "B'' (after growth)")

    print("\n" + "-" * 78)
    ok = all(x["status"] == 200 and not x["contended"] for x in (m2, m4))
    if not ok:
        print("INCONCLUSIVE -- control or measurement was contaminated; re-run.")
    elif m2["hit_pct"] >= 90 and m4["hit_pct"] <= 5:
        print(f"CONVICTED: head retrievable at {m2['hit_pct']:.1f}% BEFORE growth, "
              f"{m4['hit_pct']:.1f}% AFTER. Growing the session destroys its own head\n"
              f"           for the next session. Nothing was evicted for pressure.")
    elif m2["hit_pct"] >= 90 and m4["hit_pct"] >= 90:
        print(f"ACQUITTED: head still retrievable after growth ({m4['hit_pct']:.1f}%). "
              "Growth is not the cause; look elsewhere.")
    else:
        print(f"PARTIAL: control {m2['hit_pct']:.1f}%, after growth {m4['hit_pct']:.1f}%.")
    print("-" * 78)

    with open(a.out, "w") as f:
        json.dump({"control": m2, "after_growth": m4, "head": m1, "long": m3}, f,
                  indent=2, default=str)
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

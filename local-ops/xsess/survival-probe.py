#!/usr/bin/env python3
"""How long does a ~36K-token session head stay resident? (R1, re-characterised)

Cross-session reuse is NOT broken -- a new session replaying onto a previous
session's head measures 99.7%. What was actually observed in the live captures
(session b turn 0 at 0.0%, and session a's own turn 3 flagged [EVICTION?]) is
therefore a RETENTION problem: by the time the next session arrives, the head
has been evicted by the other traffic on this cluster.

This probes the survival curve without a restart and without a synthetic primer:
prime with a real captured first turn, then re-probe at increasing delays with a
FRESH tail each time (so the probe never reads its own footprint back), and
record pool pressure at each point.

A probe re-primes an APPENDED extent as a side effect -- noted as a limitation;
the head itself is what is being measured and it is untouched.

    python3 local-ops/xsess/survival-probe.py --minutes 1 2 5 10 20 40
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


def pool_stats():
    txt = urllib.request.urlopen(BASE + "/metrics", timeout=60).read().decode()
    out = {}
    for line in txt.splitlines():
        if line.startswith("#") or not line:
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        try:
            v = float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            continue
        out[name] = out.get(name, 0.0) + v
    return {
        "gpu_cache_usage": out.get("vllm:gpu_cache_usage_perc", 0.0),
        "queries_total": out.get("vllm:prefix_cache_queries_total", 0.0),
        "prompt_tokens_total": out.get("vllm:prompt_tokens_total", 0.0),
    }


def first_turn(path):
    for line in open(path):
        if not line.strip():
            continue
        b = json.loads(line)["body"]
        if b.get("max_tokens", 0) > 1:
            return b
    raise SystemExit("no generating turn")


def fresh(body, nonce):
    b = copy.deepcopy(body)
    blocks = b["messages"][0]["content"]
    if isinstance(blocks, str):
        b["messages"][0]["content"] = blocks + f"\n(probe {nonce})"
    else:
        blocks[-1]["text"] = blocks[-1]["text"] + f"\n(probe {nonce})"
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default=os.path.join(_LO, "toolsearch-matrix/nolsp-false-a.jsonl"))
    ap.add_argument("--minutes", type=float, nargs="+", default=[1, 2, 5, 10, 20, 40])
    ap.add_argument("--out", default=os.path.join(_HERE, "survival.json"))
    a = ap.parse_args()

    head = first_turn(a.capture)
    p0 = pool_stats()
    m0 = cp.send(head)
    t0 = time.time()
    print(f"primed at t=0: {cp.fmt('prime', m0).strip()}")
    print(f"  pool usage {100*p0['gpu_cache_usage']:.1f}%\n")

    rows = []
    prev = p0
    for mins in a.minutes:
        target = t0 + mins * 60
        while time.time() < target:
            time.sleep(min(15.0, max(0.0, target - time.time())))
        p = pool_stats()
        m = cp.send(fresh(head, f"{mins}"))
        elapsed = (time.time() - t0) / 60.0
        # Other traffic since the last sample: our own probes account for a known
        # amount, everything above that is the other client.
        other = p["prompt_tokens_total"] - prev["prompt_tokens_total"]
        state = ("UNMEASURED" if m["status"] != 200 else
                 "BLENDED x%.1f" % m["blend"] if m["contended"] else "clean")
        print(f"t={elapsed:6.1f}m  hit {('%5.1f%%' % m['hit_pct']) if m['hit_pct'] is not None else '  n/a'}"
              f"  = {m['hits']:>8,.0f} tok  {m['seconds']:6.2f}s"
              f"  pool {100*p['gpu_cache_usage']:5.1f}%"
              f"  other-traffic {other:>10,.0f} tok  [{state}]")
        rows.append({"minutes": elapsed, "hit_pct": m["hit_pct"], "hits": m["hits"],
                     "input_tokens": m["input_tokens"], "seconds": m["seconds"],
                     "blend": m["blend"], "contended": m["contended"],
                     "pool_usage": p["gpu_cache_usage"], "other_tokens": other})
        prev = p
        with open(a.out, "w") as f:
            json.dump(rows, f, indent=2)
    print(f"\n-> {a.out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""R1 step 2 (server-side half) -- does a NEW session reuse a PREVIOUS session's head?

Two real captured Claude Code first turns from different sessions in this repo
share 90,501 of 91,091 rendered chars (99.35%); they diverge only inside
`msg[0].user.text[2]`, the last ~482 chars. If cross-session reuse works, the
second one should start ~99% warm. In the live capture it measured 0.0%.

Replaying the pair naively does not answer it: the first replay caches B, so
every retry reads B's own footprint back. Instead this makes a FRESH "session B"
per attempt by perturbing ONLY the divergent tail (`text[2]`), which leaves the
entire shared head byte-identical. That yields an unlimited supply of distinct
sessions with the same head, so the measurement can be repeated until the
engine is quiet enough for a clean delta.

Clean delta <=> queries == input_tokens (cache-probe's `contended` flag). This
cluster carries concurrent external traffic, so most attempts are blended and
are DISCARDED, never averaged through.

    python3 local-ops/xsess/xsess-probe.py --attempts 12
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_LO = os.path.join(_HERE, "..")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LO, fname))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cp = _load("cache_probe", "cache-probe.py")
pd = _load("prefix_diff", "prefix-diff.py")


def first_turn(path):
    """The session's first real generating turn (skip count_tokens probes)."""
    for line in open(path):
        if not line.strip():
            continue
        r = json.loads(line)
        b = r["body"]
        if b.get("max_tokens", 0) > 1:
            return b
    raise SystemExit(f"no generating turn in {path}")


def fresh_b(b_body, nonce):
    """A distinct 'new session' that keeps the shared head byte-identical.

    Only the LAST text block of msg[0].user is touched -- the part where the two
    real sessions already differ -- so nothing before the divergence point moves.
    """
    b = copy.deepcopy(b_body)
    blocks = b["messages"][0]["content"]
    if isinstance(blocks, str):
        b["messages"][0]["content"] = blocks + f"\n(run {nonce})"
    else:
        blocks[-1]["text"] = blocks[-1]["text"] + f"\n(run {nonce})"
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", default=os.path.join(_LO, "toolsearch-matrix/nolsp-false-a.jsonl"))
    ap.add_argument("--b", default=os.path.join(_LO, "toolsearch-matrix/nolsp-false-b.jsonl"))
    ap.add_argument("--attempts", type=int, default=12)
    ap.add_argument("--settle", type=float, default=6.0)
    ap.add_argument("--out", default=os.path.join(_HERE, "xsess-result.json"))
    a = ap.parse_args()

    A, B = first_turn(a.a), first_turn(a.b)
    v = pd.verdict(A, B)
    print(f"session A turn0 vs session B turn0: {v['kind']}, "
          f"shared {v['shared_chars']:,}/{v['total_chars']:,} chars "
          f"({100*v['shared_frac']:.3f}%), diverges in {v['label_b']}\n")

    rows, clean = [], []
    for i in range(a.attempts):
        # Re-send A first so its head is certainly resident (and recently used,
        # so LRU cannot be blamed for a miss).
        ma = cp.send(A)
        b = fresh_b(B, f"{int(time.time())}-{i}")
        mb = cp.send(b)
        tag = ""
        if mb["status"] != 200:
            tag = "  UNMEASURED (http %s)" % mb["status"]
        elif mb["contended"]:
            tag = "  DISCARDED (blended x%.1f)" % mb["blend"]
        else:
            clean.append(mb)
            tag = "  CLEAN"
        print(cp.fmt(f"[{i}] A (prime)", ma))
        print(cp.fmt(f"[{i}] B' (new session)", mb) + tag)
        rows.append({"i": i, "a": ma, "b": mb})
        if len(clean) >= 3:
            break
        time.sleep(a.settle)

    print()
    if not clean:
        print("NO CLEAN MEASUREMENT -- every attempt had another client's tokens in the "
              "delta. Re-run on a quieter window; do NOT read the blended rows.")
    else:
        hits = [m["hit_pct"] for m in clean]
        toks = [m["hits"] for m in clean]
        print(f"clean measurements: {len(clean)}")
        for m in clean:
            print(f"   hit {m['hit_pct']:5.1f}%  = {m['hits']:,.0f} of {m['input_tokens']:,} tokens"
                  f"  in {m['seconds']:.2f}s")
        print(f"\nVERDICT: a brand-new session reusing a previous session's head measured "
              f"{min(hits):.1f}-{max(hits):.1f}% "
              f"({min(toks):,.0f}-{max(toks):,.0f} tokens of ~36,600).")
    with open(a.out, "w") as f:
        json.dump(rows, f, indent=2, default=str)
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

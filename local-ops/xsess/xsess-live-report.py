#!/usr/bin/env python3
"""Read the live two-session run and answer the one question that matters:

    does session B's turn 0 start WARM off session A, in a real session,
    with no replay and no primer?

Turn 0 is the decisive row. Everything after it is ordinary within-session
append behaviour that was already known to work.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_LO = os.path.join(_HERE, "..")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LO, fname))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


pd = _load("prefix_diff", "prefix-diff.py")


def rows(path):
    out = []
    for line in open(path):
        if line.strip():
            out.append(json.loads(line))
    return out


def first_generating(rs):
    for r in rs:
        if r["body"].get("max_tokens", 0) > 1:
            return r
    return None


def fmt_cache(r):
    c = r.get("cache") or {}
    hp, q, h = c.get("hit_pct"), c.get("queries"), c.get("hits")
    it = c.get("input_tokens") or (r.get("usage") or {}).get("input_tokens")
    blend = (q / it) if (it and q) else 0.0
    clean = bool(blend) and (0.95 <= blend <= 1.05)
    return hp, h, it, c.get("seconds"), blend, clean


def main(a_path, b_path):
    A, B = rows(a_path), rows(b_path)
    ra, rb = first_generating(A), first_generating(B)
    if not ra or not rb:
        sys.exit("missing a generating turn in one of the captures")

    print("=" * 78)
    print("LIVE cross-session test — two real sessions, back to back, no replay")
    print("=" * 78)

    v = pd.verdict(ra["body"], rb["body"])
    print(f"\nturn-0 prompts: {v['kind']}, shared {v['shared_chars']:,}/{v['total_chars']:,} chars "
          f"({100*v['shared_frac']:.3f}%)")
    print(f"  first divergence: {v['label_b']}")

    ha, hb = pd.part_hashes(ra["body"]), pd.part_hashes(rb["body"])
    for k in sorted(set(ha) | set(hb)):
        print(f"  {k:<12s} {'SAME' if ha.get(k) == hb.get(k) else 'DIFF'}")

    print("\nturn 0 of each session:")
    for label, r in (("A (cold, nothing to reuse)", ra), ("B (the measurement)", rb)):
        hp, h, it, secs, blend, clean = fmt_cache(r)
        hp_s = "n/a" if hp is None else f"{hp:5.1f}%"
        print(f"  {label:<28s} in={it:>8,}  hit {hp_s}  = {h or 0:>8,} tok"
              f"  {secs if secs is None else round(secs,2)}s"
              f"  [{'clean' if clean else 'BLENDED x%.1f' % blend}]")

    hp, h, it, secs, blend, clean = fmt_cache(rb)
    print("\n" + "-" * 78)
    if hp is None:
        print("VERDICT: unmeasured.")
    elif not clean:
        print(f"VERDICT: UNMEASURED — another client's tokens are in the delta "
              f"(queries/input = {blend:.2f}). Re-run on a quieter window.")
    elif hp >= 90:
        print(f"VERDICT: session B started WARM at {hp:.1f}% ({h:,.0f} tokens reused). "
              "Natural cross-session reuse works end to end.")
    elif hp <= 5:
        print(f"VERDICT: session B started COLD at {hp:.1f}%. The heads are "
              f"{100*v['shared_frac']:.1f}% shared, so this is EVICTION, not a moved head.")
    else:
        print(f"VERDICT: partial — {hp:.1f}% ({h:,.0f} tokens).")
    print("-" * 78)


if __name__ == "__main__":
    d = os.path.join(_LO, "toolsearch-matrix")
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(d, "xsess-a.jsonl"),
         sys.argv[2] if len(sys.argv) > 2 else os.path.join(d, "xsess-b.jsonl"))

#!/usr/bin/env python3
"""R1 step 1 -- re-verify the prefix-cache EXTENT RULE with exact token control.

The claim under test (measured once, this session, and NOT yet trusted):

    A request reuses a cached prefix only if it matches the cached request's
    ENTIRE cached extent. One block short and it gets ZERO.

Why this script exists rather than reusing cache-probe.py's /v1/messages path:
`/v1/completions` accepts `prompt` as an ARRAY OF TOKEN IDS, so the divergence
point between A and B is placed to the exact token, with no chat template, no
tokeniser round-trip and no serving-patch transform in the way.

Block maths, stated so the predictions are falsifiable:

    a request of n tokens caches   E(n) = floor((n-1)/256)*256
    (`max_cache_hit_length = request.num_tokens - 1` in kv_cache_manager.py,
     then block alignment at block_size = 256)

    B shares the first (n_A - D) tokens with A.  Let r = (n_A - 1) mod 256.

      MONOTONE model (what a normal LRU prefix cache does):
          hit_B = min( floor((n_A - D)/256)*256 , E(n_A) )
      ALL-OR-NOTHING model (the claim):
          hit_B = E(n_A)  if  floor((n_A-D)/256)*256 >= E(n_A)   i.e. D <= r+1
                  0       otherwise

The two models AGREE for D <= r+1 and DISAGREE for every larger D -- monotone
predicts a staircase stepping down 256 at a time, all-or-nothing predicts a
cliff straight to 0. That is the whole experiment.

Usage:
    python3 local-ops/xsess/extent-probe.py --sweep      # the discriminating D sweep
    python3 local-ops/xsess/extent-probe.py --cliff      # move the cliff by varying n_A mod 256
    python3 local-ops/xsess/extent-probe.py --extent     # 56-vs-57-block containment retest
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "cache_probe", os.path.join(_HERE, "..", "cache-probe.py"))
_cp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cp)                    # hyphen blocks a plain import

BASE = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888").rstrip("/")
MODEL = os.environ.get("DSPARK_PROBE_MODEL", "deepseek-v4-flash-dspark-nothink")
BLOCK = 256

# Ids are drawn from a safe interior slice of the vocab: high enough to miss the
# byte-fallback and control ids, low enough to miss the specials at the top.
ID_LO, ID_HI = 1000, 100000


def extent(n):
    """Tokens a request of n tokens leaves in the cache."""
    return max(0, ((n - 1) // BLOCK) * BLOCK)


def ids(rng, n):
    return [rng.randrange(ID_LO, ID_HI) for _ in range(n)]


def send_ids(prompt_ids, timeout=1800):
    """POST a token-id prompt; return a measurement dict shaped like cache-probe's."""
    body = {"model": MODEL, "prompt": prompt_ids, "max_tokens": 1, "temperature": 0}
    q0, h0, _ = _cp.cache_counters(BASE)
    t0 = time.time()
    req = urllib.request.Request(
        BASE + "/v1/completions", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    status, data, err = 200, None, None
    try:
        data = json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        status, err = e.code, e.read().decode()[:300]
    except Exception as e:                                       # noqa: BLE001
        status, err = -1, repr(e)[:300]
    dt = time.time() - t0
    q1, h1, _ = _cp.cache_counters(BASE)

    dq, dh = q1 - q0, h1 - h0
    pt = ((data or {}).get("usage") or {}).get("prompt_tokens")
    # Clean delta <=> this request's tokens are the only ones in the window.
    blend = (dq / pt) if (pt and dq) else 0.0
    return {"status": status, "error": err, "seconds": dt, "prompt_tokens": pt,
            "queries": dq, "hits": dh, "blend": blend,
            "contended": bool(blend) and not (0.95 <= blend <= 1.05)}


def measure(make_pair, retries=3):
    """Cache A, then measure B. Retries only on a contaminated delta.

    `make_pair()` must return a FRESH (a_ids, b_ids) on every call. Retrying with
    the SAME B is a measurement trap: the first attempt already cached B in full,
    so the retry reads B's own footprint back and reports a spurious ~100% hit.
    (It did: a D=1000 point read 12,288 hits on an 11,000-token shared prefix.)
    """
    ma = mb = None
    for attempt in range(retries):
        a_ids, b_ids = make_pair()
        ma = send_ids(a_ids)
        if ma["status"] != 200:
            return ma, {"status": ma["status"], "error": "A failed", "hits": None,
                        "contended": False, "queries": 0, "prompt_tokens": None,
                        "seconds": 0.0, "blend": 0.0}
        mb = send_ids(b_ids)
        if mb["status"] == 200 and not mb["contended"] and not ma["contended"]:
            return ma, mb
        if attempt < retries - 1:
            time.sleep(4.0)                       # let the other client's burst drain
    return ma, mb


def row(label, n_a, D, ma, mb):
    E = extent(n_a)
    shared = n_a - D
    mono = min((shared // BLOCK) * BLOCK, E)
    aon = E if (shared // BLOCK) * BLOCK >= E else 0
    if mb["status"] != 200 or mb["hits"] is None:
        got = "ERR"
        verdict = "UNMEASURED"
    elif mb["contended"]:
        got = f"{mb['hits']:,.0f}"
        verdict = f"BLENDED x{mb['blend']:.2f}"
    else:
        got = f"{mb['hits']:,.0f}"
        h = int(mb["hits"])
        if mono == aon:
            verdict = "agree(both)" if h == mono else f"NEITHER"
        elif h == aon:
            verdict = "ALL-OR-NOTHING"
        elif h == mono:
            verdict = "monotone"
        else:
            verdict = "NEITHER"
    print(f"  {label:<22s} D={D:<6d} shared={shared:<7,d} E(A)={E:<7,d} "
          f"monotone={mono:<7,d} aon={aon:<7,d} got={got:<9s} {mb['seconds']:6.2f}s  {verdict}")
    return {"label": label, "n_a": n_a, "D": D, "shared": shared, "extent_a": E,
            "pred_monotone": mono, "pred_aon": aon,
            "hits": mb["hits"], "queries": mb["queries"],
            "prompt_tokens": mb["prompt_tokens"], "blend": mb["blend"],
            "contended": mb["contended"], "seconds": mb["seconds"],
            "a_seconds": ma["seconds"], "verdict": verdict}


# ── experiment 1: the discriminating D sweep ────────────────────────

def sweep(n_a, ds, seed, out):
    rng = random.Random(seed)
    r = (n_a - 1) % BLOCK
    print(f"\n=== D sweep: n_A = {n_a:,}  E(A) = {extent(n_a):,}  r = (n_A-1) mod 256 = {r}")
    print(f"    predicted cliff (both models agree up to here): D <= {r+1}\n")
    rows = []
    for D in ds:
        # Fresh nonce per point: every pair must be cold, so no earlier point
        # can lend it a hit.
        def pair(D=D):
            # B = A's first (n_a - D) tokens + a DIFFERENT, longer continuation.
            base = ids(rng, n_a)
            return base, base[:n_a - D] + ids(rng, D + 512)
        ma, mb = measure(pair)
        rows.append(row(f"D={D}", n_a, D, ma, mb))
    dump(out, "sweep", rows)
    return rows


# ── experiment 2: move the cliff ────────────────────────────────────

def cliff(seed, out):
    """The boundary formula's real test: CHANGE n_A so r changes, and show the
    cliff moves with it. A fixed tolerance (~200 tokens) cannot do that."""
    rng = random.Random(seed)
    rows = []
    for target_r in (0, 63, 199):
        n_a = 12000 - ((12000 - 1) % BLOCK) + target_r + 1      # (n_a-1) % 256 == target_r
        r = (n_a - 1) % BLOCK
        print(f"\n=== cliff: n_A = {n_a:,}  r = {r}  -> predicted last hitting D = {r+1}")
        for D in (r + 1, r + 2):                                 # straddle the boundary
            def pair(n_a=n_a, D=D):
                base = ids(rng, n_a)
                return base, base[:n_a - D] + ids(rng, D + 512)
            ma, mb = measure(pair)
            rows.append(row(f"r={r} D={D}", n_a, D, ma, mb))
    dump(out, "cliff", rows)
    return rows


# ── experiment 3: containment, 56 vs 57 blocks ──────────────────────

def extent_test(seed, out):
    """The original observation, restated with exact tokens: B holds 56 whole
    blocks of A's head. Vary A's length so its extent is 56 blocks, then 57."""
    rng = random.Random(seed)
    rows = []
    for blocks in (56, 57):
        n_a = blocks * BLOCK + 1                 # E(A) == blocks*256 exactly
        assert extent(n_a) == blocks * BLOCK
        # B always carries exactly 56 whole blocks of A, then diverges and runs on.
        def pair(n_a=n_a):
            base = ids(rng, n_a)
            return base, base[:56 * BLOCK] + ids(rng, 4096)
        D = n_a - 56 * BLOCK
        ma, mb = measure(pair)
        rows.append(row(f"E(A)={blocks}blk", n_a, D, ma, mb))
    dump(out, "extent", rows)
    return rows


def dump(out, name, rows):
    if not out:
        return
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    path = out if out.endswith(".json") else f"{out}-{name}.json"
    with open(path, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"  -> {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("--cliff", action="store_true")
    ap.add_argument("--extent", action="store_true")
    ap.add_argument("--n", type=int, default=12000, help="n_A for the sweep")
    ap.add_argument("--seed", type=int, default=20260919)
    ap.add_argument("--out", default=os.path.join(_HERE, "extent"))
    a = ap.parse_args()
    if not (a.sweep or a.cliff or a.extent):
        ap.error("pass --sweep, --cliff and/or --extent")
    print(f"base={BASE} model={MODEL} block={BLOCK}")
    if a.extent:
        extent_test(a.seed, a.out)
    if a.sweep:
        sweep(a.n, [1, 100, 224, 225, 300, 512, 1000, 2000], a.seed, a.out)
    if a.cliff:
        cliff(a.seed + 1, a.out)


if __name__ == "__main__":
    main()

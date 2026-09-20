#!/usr/bin/env python3
"""Offline reproduction of this cluster's prefix-cache LOOKUP behaviour.

Runs inside a throwaway container from the serving image with NO GPU, NO engine
and NO weights, so it costs seconds and cannot disturb the cluster:

    ssh shorn@spark-45ea "docker run --rm -i --entrypoint python3 \
      vllm-dspark-runtime:dspark-nvfp4-stage-c -" < local-ops/kvsim/sim.py

Bind-mounting `patches/patch6-single_type_kv_cache_manager.py` over
`vllm/v1/core/single_type_kv_cache_manager.py` (`:ro`) turns this into an exact
A/B: without the mount, `_RECYCLE_ENABLED` is simply absent from the module.

WHAT IT IS FOR. The live measurement (local-ops/xsess/) established that lookup
on this build is MONOTONE -- a request sharing a prefix with a cached one reuses
`floor(shared/256)*256` tokens, never 0. This reproduces that offline so the
claim does not rest on a contended cluster, and so the one real anomaly can be
attributed to a line rather than to a theory:

    when the match would consume the cached request's ENTIRE extent, exactly
    ONE block (256 tokens) is dropped -- `single_type_kv_cache_manager.py`
    `FullAttentionManager.find_longest_cache_hit`, the
    `if use_eagle and computed_blocks[0]: computed.pop()` branch, reached
    because MTP (num_speculative_tokens=5) makes `use_eagle` true.

Topology mirrors the running engine (from its boot log): 5 KV groups -- group 0
MLA full attention, groups 1-4 sliding-window -- block_size 256, pool 16,891
blocks, max_model_len 1,048,576.
"""
from __future__ import annotations

import os
import sys

import torch

from vllm.v1.core.kv_cache_manager import KVCacheManager
from vllm.v1.kv_cache_interface import (
    KVCacheConfig, KVCacheGroupSpec, KVCacheTensor,
    MLAAttentionSpec, SlidingWindowSpec,
)
from vllm.v1.core.kv_cache_utils import get_request_block_hasher, init_none_hash
from vllm.v1.request import Request
from vllm.sampling_params import SamplingParams

BLOCK = 256
POOL_BLOCKS = int(os.environ.get("SIM_POOL_BLOCKS", "16891"))
MAX_MODEL_LEN = 1048576
USE_EAGLE = os.environ.get("SIM_USE_EAGLE", "1") == "1"
# Per-group sliding windows, read off the running engine's Patch 5 boot lines
# ("legacy cap" is the window-derived per-group cap): groups 1-4 are 32,768 /
# 32,768 / 524,288 / 262,144. A small window (e.g. 4,096) is NOT a harmless
# simplification -- it puts the SWA manager into its skipped-block path and the
# harness stops being a model of this cluster.
SWA_WINDOWS = [int(x) for x in os.environ.get(
    "SIM_SWA_WINDOWS", "32768,32768,524288,262144").split(",") if x]
N_SWA_GROUPS = len(SWA_WINDOWS)


def build_config():
    """A DSv4-Flash-shaped hybrid: 1 MLA full-attention group + N SWA groups."""
    groups, tensors = [], []
    mla = MLAAttentionSpec(block_size=BLOCK, num_kv_heads=1, head_size=576,
                           dtype=torch.bfloat16)
    groups.append(KVCacheGroupSpec(layer_names=["mla.0"], kv_cache_spec=mla,
                                   is_eagle_group=False))
    for i, win in enumerate(SWA_WINDOWS):
        swa = SlidingWindowSpec(block_size=BLOCK, num_kv_heads=1, head_size=128,
                                dtype=torch.bfloat16, sliding_window=win)
        groups.append(KVCacheGroupSpec(layer_names=[f"swa.{i}"], kv_cache_spec=swa,
                                       is_eagle_group=False))
    for g in groups:
        tensors.append(KVCacheTensor(size=1, shared_by=list(g.layer_names)))
    return KVCacheConfig(num_blocks=POOL_BLOCKS, kv_cache_tensors=tensors,
                         kv_cache_groups=groups)


def new_manager():
    init_none_hash(lambda x: repr(x).encode())
    return KVCacheManager(build_config(), max_model_len=MAX_MODEL_LEN,
                          hash_block_size=BLOCK, max_num_batched_tokens=8192,
                          enable_caching=True, use_eagle=USE_EAGLE, log_stats=True)


_hasher = None


def make_request(rid, token_ids):
    global _hasher
    if _hasher is None:
        _hasher = get_request_block_hasher(BLOCK, lambda x: repr(x).encode())
    return Request(request_id=rid, prompt_token_ids=list(token_ids),
                   sampling_params=SamplingParams(max_tokens=1),
                   pooling_params=None, block_hasher=_hasher)


CHUNK = int(os.environ.get("SIM_CHUNK", "2048"))


def cache_request(mgr, rid, token_ids):
    """Run one request through allocate + cache, the way the scheduler does.

    Allocation is CHUNKED. This is not a convenience: handing allocate_slots the
    whole prompt in one call is both unlike production (chunked prefill caps a
    step at max_num_batched_tokens=8192) and superlinear in this build -- 6,000
    tokens in one call takes ~1s, 12,000 takes over a minute.
    """
    req = make_request(rid, token_ids)
    blocks, n_hit = mgr.get_computed_blocks(req)
    done = n_hit
    first = True
    while done < len(token_ids):
        step = min(CHUNK, len(token_ids) - done)
        mgr.allocate_slots(req, step,
                           num_new_computed_tokens=n_hit if first else 0,
                           new_computed_blocks=blocks if first else None)
        first = False
        done += step
        req.num_computed_tokens = done
        mgr.cache_blocks(req, done)
    return req, n_hit


def lookup(mgr, rid, token_ids):
    """What would this request reuse? (lookup only -- nothing is allocated.)"""
    req = make_request(rid, token_ids)
    _, n_hit = mgr.get_computed_blocks(req)
    return n_hit


def extent(n):
    return max(0, ((n - 1) // BLOCK) * BLOCK)


def ids(seed, n):
    """Deterministic pseudo-random token ids -- no RNG import needed twice."""
    out, x = [], seed * 2654435761 + 12345
    for _ in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        out.append(1000 + (x >> 33) % 99000)
    return out


def main():
    print(f"# kvsim  pool={POOL_BLOCKS} blocks  block={BLOCK}  "
          f"groups=1 MLA + {N_SWA_GROUPS} SWA(windows={SWA_WINDOWS})  use_eagle={USE_EAGLE}")
    import vllm.v1.core.single_type_kv_cache_manager as stm
    patched = hasattr(stm, "_RECYCLE_ENABLED")
    print(f"# patch6 bind-mount: {'PRESENT' if patched else 'ABSENT (stock image file)'}"
          + (f"  recycle={getattr(stm, '_RECYCLE_ENABLED', None)}" if patched else ""))
    print()

    n_a = int(os.environ.get("SIM_N", "6000"))
    E = extent(n_a)
    r = (n_a - 1) % BLOCK
    print(f"A: {n_a:,} tokens -> cached extent E(A) = floor((n-1)/256)*256 = {E:,}"
          f"   r = (n_A-1) mod 256 = {r}")
    print("# n_A is 6,000 by default, NOT the ~36,600 of a real first turn: in this")
    print("# build allocate+cache goes superlinear offline above ~6K tokens (6K ~1s,")
    print("# 8K > 90s). The block arithmetic under test is scale-free, and the live")
    print("# engine measurements in local-ops/xsess/ cover the real sizes.")
    print(f"{'D':>7} {'shared':>9} {'monotone':>10} {'all-or-nothing':>15} {'SIM':>9}   model")
    print("-" * 70)

    rows = []
    # D straddling r+1 is the interesting region: that is where B's shared run
    # ends exactly on A's full cached extent.
    for D in (1, 50, r, r + 1, r + 2, 300, 512, 1000, 2000):
        print(f"  ... D={D}", file=sys.stderr, flush=True)
        mgr = new_manager()                       # fresh pool per point: no cross-talk
        base = ids(D + 7, n_a)
        cache_request(mgr, f"A{D}", base)
        b = base[:n_a - D] + ids(D + 9999, D + 512)
        got = lookup(mgr, f"B{D}", b)
        shared = n_a - D
        mono = min((shared // BLOCK) * BLOCK, E)
        aon = E if (shared // BLOCK) * BLOCK >= E else 0
        if mono == aon:
            model = "agree" if got == mono else "NEITHER"
        elif got == aon:
            model = "ALL-OR-NOTHING"
        elif got == mono:
            model = "monotone"
        elif got == mono - BLOCK:
            model = "monotone - 1 block (eagle pop)"
        else:
            model = "NEITHER"
        print(f"{D:>7} {shared:>9,} {mono:>10,} {aon:>15,} {got:>9,}   {model}", flush=True)
        rows.append((D, shared, mono, aon, got))

    print()
    zero = [r for r in rows if r[4] == 0]
    print(f"points returning ZERO reuse: {len(zero)} of {len(rows)}")
    if not zero:
        print("VERDICT: lookup is MONOTONE. The 'match the whole extent or get zero'")
        print("         rule does NOT hold on this build, and the hybrid intersection")
        print("         cascade of vllm#42948 is NOT collapsing here.")
    else:
        print("VERDICT: zero-reuse reproduced offline at D =", [r[0] for r in zero])


if __name__ == "__main__":
    main()

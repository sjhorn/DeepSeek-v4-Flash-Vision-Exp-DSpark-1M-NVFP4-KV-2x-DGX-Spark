#!/usr/bin/env python3
"""Does a MULTI-TURN session's head survive the session being freed?

Live finding this reproduces: a head written by a real multi-turn Claude Code
session is unretrievable 2s after the session ends (0.0%, 22.77s cold, clean
delta), while the SAME head written by one synthetic request survives 5+
minutes. During the session it IS retrievable -- turns 1-6 hit 67-99%.

The earlier A/B in sim.py cleared Patch 6, but it only ever tested
    cache one request -> look up
It never tested the sequence that actually fails:
    turn 0 -> turn 1 -> ... -> turn N (growing past the SWA windows)
    -> FREE the session -> look up the head from a DIFFERENT request

Patch 6 recycles "skipped" sliding-window pages in-request and calls
_maybe_evict_cached_block on them, which drops their hash mapping. If the head
blocks are un-hashed for the SWA groups while the MLA group keeps them, then a
new request's hybrid intersection across groups cannot rebuild the head.

Run both arms:
    local-ops/kvsim/run-session.sh            # stock image file
    local-ops/kvsim/run-session.sh patch6     # with Patch 6 bind-mounted
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
CHUNK = int(os.environ.get("SIM_CHUNK", "2048"))
# Real per-group windows from the engine's Patch 5 boot lines.
SWA_WINDOWS = [int(x) for x in os.environ.get(
    "SIM_SWA_WINDOWS", "32768,32768,524288,262144").split(",") if x]

# The head, and the turns the session grows through. Scaled down: the offline
# path is superlinear above ~6K tokens. What matters is that later turns cross
# the SMALLEST sliding window, which is what triggers skipped-page recycling --
# so the windows are scaled by the same factor as the token counts.
HEAD = int(os.environ.get("SIM_HEAD", "2048"))
TURNS = [int(x) for x in os.environ.get("SIM_TURNS", "2048,3072,4096,5120,6144").split(",")]
SCALED_WINDOWS = [int(x) for x in os.environ.get("SIM_SCALED_WINDOWS", "1024,1024,4096,2048").split(",")]


def build_config(windows):
    groups, tensors = [], []
    mla = MLAAttentionSpec(block_size=BLOCK, num_kv_heads=1, head_size=576,
                           dtype=torch.bfloat16)
    groups.append(KVCacheGroupSpec(layer_names=["mla.0"], kv_cache_spec=mla))
    for i, w in enumerate(windows):
        groups.append(KVCacheGroupSpec(
            layer_names=[f"swa.{i}"],
            kv_cache_spec=SlidingWindowSpec(block_size=BLOCK, num_kv_heads=1,
                                            head_size=128, dtype=torch.bfloat16,
                                            sliding_window=w)))
    for g in groups:
        tensors.append(KVCacheTensor(size=1, shared_by=list(g.layer_names)))
    return KVCacheConfig(num_blocks=POOL_BLOCKS, kv_cache_tensors=tensors,
                         kv_cache_groups=groups)


_hasher = None


def mgr_for(windows):
    global _hasher
    init_none_hash(lambda x: repr(x).encode())
    if _hasher is None:
        _hasher = get_request_block_hasher(BLOCK, lambda x: repr(x).encode())
    return KVCacheManager(build_config(windows), max_model_len=MAX_MODEL_LEN,
                          hash_block_size=BLOCK, max_num_batched_tokens=8192,
                          enable_caching=True, use_eagle=USE_EAGLE, log_stats=True)


def req(rid, toks):
    return Request(request_id=rid, prompt_token_ids=list(toks),
                   sampling_params=SamplingParams(max_tokens=1),
                   pooling_params=None, block_hasher=_hasher)


def run_turn(m, rid, toks):
    """One conversation turn: lookup, allocate (chunked), cache. Returns hit."""
    r = req(rid, toks)
    blocks, hit = m.get_computed_blocks(r)
    done, first = hit, True
    while done < len(toks):
        step = min(CHUNK, len(toks) - done)
        m.allocate_slots(r, step, num_new_computed_tokens=hit if first else 0,
                         new_computed_blocks=blocks if first else None)
        first = False
        done += step
        r.num_computed_tokens = done
        m.cache_blocks(r, done)
    return r, hit


def ids(seed, n):
    out, x = [], seed * 2654435761 + 12345
    for _ in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        out.append(1000 + (x >> 33) % 99000)
    return out


def main():
    import vllm.v1.core.single_type_kv_cache_manager as stm
    patched = hasattr(stm, "_RECYCLE_ENABLED")
    print(f"# patch6 bind-mount: {'PRESENT' if patched else 'ABSENT (stock)'}"
          + (f"  recycle={getattr(stm, '_RECYCLE_ENABLED', None)}" if patched else ""))
    print(f"# windows={SCALED_WINDOWS}  head={HEAD}  turns={TURNS}  eagle={USE_EAGLE}\n")

    base = ids(11, max(TURNS))
    other = ids(77, max(TURNS) + 4096)

    # ---- ARM 1: one single request caches the head, then free -------------
    m = mgr_for(SCALED_WINDOWS)
    r, _ = run_turn(m, "single", base[:HEAD])
    m.free(r)
    b = req("lookup1", base[:HEAD] + other[:2048])
    _, hit_single = m.get_computed_blocks(b)

    # ---- ARM 2: a multi-turn SESSION grows past the window, then free -----
    m2 = mgr_for(SCALED_WINDOWS)
    rr = None
    per_turn = []
    for i, n in enumerate(TURNS):
        if rr is not None:
            m2.free(rr)                       # previous turn's request completes
        rr, hit = run_turn(m2, f"turn{i}", base[:n])
        per_turn.append((n, hit))
    m2.free(rr)                               # the SESSION ends
    b2 = req("lookup2", base[:HEAD] + other[:2048])
    _, hit_session = m2.get_computed_blocks(b2)

    print("session turns (n_tokens -> cache hit):")
    for n, h in per_turn:
        print(f"    {n:>6,} -> {h:>6,}")
    print()
    print(f"ARM 1  head cached by ONE request, then freed   -> lookup hit {hit_single:>6,}")
    print(f"ARM 2  head cached by a SESSION, then freed     -> lookup hit {hit_session:>6,}")
    print()
    if hit_single > 0 and hit_session == 0:
        print("REPRODUCED: the session's head is unretrievable after the session is")
        print("            freed, while the single-request head is fine. Same tokens.")
    elif hit_single > 0 and hit_session > 0:
        print("NOT reproduced offline: both survive. The live effect needs something")
        print("            this harness does not model (decode, real scheduler, or load).")
    else:
        print("INCONCLUSIVE: the single-request arm did not survive either.")


if __name__ == "__main__":
    main()

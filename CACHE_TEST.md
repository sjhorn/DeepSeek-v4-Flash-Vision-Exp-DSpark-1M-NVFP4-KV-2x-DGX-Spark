# CACHE_TEST.md — vllm#43447 against our tree: what applies, and how we would test it

**Status: analysis only. Nothing implemented, nothing deployed, no restart spent.**
Assessed 2026-09-20 against the running image `vllm-dspark-runtime:dspark-nvfp4-stage-c`
(vLLM `0.21.1rc1.dev339+g1967a5627bc3`), by diffing the PR against the image's real sources —
`patches/pristine/` plus `kv_cache_utils.py` / `kv_cache_coordinator.py` read out of the container.

This is the working document for the experiment. The standing evidence it draws on lives in
[`docs/local/PREFIX-CACHE.md`](docs/local/PREFIX-CACHE.md); the one-line verdict lives in
[`docs/local/UPSTREAM.md`](docs/local/UPSTREAM.md). Nothing is restated in all three.

---

## 0. The goal, and the constraint it runs into

The goal is maximum prefix-cache reuse across the turns of a long agent session. The constraint is
that this model is *hybrid*: five KV cache groups, three of them sliding-window with very small
pages, and the sliding window is only **128 tokens** (`config.json: sliding_window = 128`).

The live group layout, read from this boot's `MNT-6a` log lines (page size derived from
`legacy cap = 2 * ceil(1048576 / page)`):

| KV group | page (tokens) | legacy protected cap | recycles pages (`MNT-6b`)? |
|---|---|---|---|
| 0 | 256 | 8,192 | no (full attention / MLA) |
| 1 | 64 | 32,768 | yes — 126 pages in one request |
| 2 | 64 | 32,768 | yes — 126 pages in one request |
| 3 | 4 | 524,288 | yes — 1 page observed |
| 4 | 8 | 262,144 | yes — **1,008 pages in one request** |

Pool: 16,741 blocks, 2,484,672 tokens on the 2026-09-20 14:33Z boot. Alignment for any cache hit is
`lcm(256, 64, 64, 4, 8) = 256` tokens.

With pages that small, a single long prefill moves tens of thousands of blocks through the free
queue. **Whatever decides the *order* of that queue decides which conversations keep their cache.**
That is the subject of the PR.

## 1. What vllm#43447 actually is

[vllm-project/vllm#43447](https://github.com/vllm-project/vllm/pull/43447) — "DeepSeek-V4 prefix
cache retention", confirmed on 0.22.1rc1, **not in our runtime**. Two independent mechanisms:

1. **Free-queue ordering.** `FreeKVCacheBlockQueue.prepend_n()`; `BlockPool.free_blocks()` grows a
   `prepend: bool = False` argument; SWA frees are split into `block_hash is None` (scratch →
   **prepend**, so it is the next thing reused) and hashed (real cache entries → **append**, so it
   dies last). Applied in `remove_skipped_blocks()` **and** in a new
   `SlidingWindowManager.free()`.
2. **`VLLM_PREFIX_CACHE_RETENTION_INTERVAL`.** Sparsifies which SWA checkpoints are cached at all.
   Unset = dense (today's behaviour); `0` = only the latest replayable prompt boundary; a positive
   multiple of `scheduler_block_size` = one tail per interval. Replaces the `alignment_tokens`
   argument of `cache_blocks()` with `retention_interval`, and rewrites the SWA reachable-block
   mask to be EAGLE-aware (`shift = 1`) instead of bailing out.

Upstream's own result is 0% → 74.3% prefix hit on their workload on a later tree. **That is not a
prediction for us** and should not be quoted as one.

## 2. Mechanism 1 — free-queue ordering. **Applies. The strongest lead we have.**

### The defect in our tree

`SingleTypeKVCacheManager.free()` (`patches/pristine/vllm/v1/core/single_type_kv_cache_manager.py`,
line 416) frees the whole request in reverse, cached and scratch blocks alike:

```python
ordered_blocks = reversed(req_blocks)
self.block_pool.free_blocks(ordered_blocks)
```

`free_blocks()` calls `free_block_queue.append_n(...)` — the **tail** — while `get_new_blocks()`
calls `popleft_n(...)` — the **head**, evicting whatever cached block it finds there. So:

> Every turn of a conversation ends by putting that turn's worthless scratch pages at the **back**
> of the queue, leaving the allocator to evict genuinely cached prefix blocks that sit in front of
> them.

`MNT-6b` already fixes the *in-request* half of this — it keeps window-skipped pages inside the
request instead of freeing them at all. But it does not cover the *end-of-request* half, and its
own leftovers go out through `self.block_pool.free_blocks(leftover)`, i.e. appended to the tail,
which is precisely the wrong end: those leftovers are uncached by construction (`MNT-6b` calls
`_maybe_evict_cached_block()` on each before recycling it).

### Why this is the interesting one

`PREFIX-CACHE.md` § "What is NOT established" narrowed the unexplained cross-session loss to
something **only multiple turns do** — a one-prompt real session's head survives at +2s (99.6%,
0.57s), a six-turn one is gone (0.0%, 22.77s) — and listed "the free/allocate churn of repeatedly
extending one conversation's block chain" as a candidate with no mechanism attached to it.

This is a mechanism for exactly that candidate, it is per-turn, it scales with page count (groups 3
and 4 free thousands of pages per turn), and it is invisible to the offline `kvsim` harness, which
does not model multi-turn free/allocate ordering. It explains why the **offline A/B of Patch 6 came
out identical row for row** while real sessions still decayed.

It is a hypothesis until measured. It is not proof.

### Porting surface

Small, and entirely in files we already own or already mount:

| file | change | we already mount it? |
|---|---|---|
| `vllm/v1/core/kv_cache_utils.py` | add `prepend_n()` — **ports verbatim**, our `FreeKVCacheBlockQueue` has the identical `fake_free_list_head` / `fake_free_list_tail` structure | **no — new mount needed** |
| `vllm/v1/core/block_pool.py` | `free_blocks(..., prepend: bool = False)` | yes (`MNT-7`) |
| `vllm/v1/core/single_type_kv_cache_manager.py` | split cached/uncached in `remove_skipped_blocks()`, in `free()`, and for the `MNT-6b` leftovers | yes (`MNT-6a/6b`) |

Proposed as **`MNT-8`**, behind `VLLM_FREE_QUEUE_PREPEND_UNCACHED` (**default 0 / off**), so the
deploy is inert until the A/B arm sets it. A new mount also means a new row in
`scripts/check-local-patches.sh` (18 rows, not 17) and a re-run of `regen-local-patches.sh`.

## 3. Mechanism 2 — `VLLM_PREFIX_CACHE_RETENTION_INTERVAL`. **Applies in principle; blocked behind a fork-local bail-out.**

The interval itself is legal for us: it must be a multiple of `scheduler_block_size`, which is 256
here, so the author's suggested `32768` qualifies (and `0` always does).

The catch is that **our SWA groups cache densely no matter what the interval says.**
`kv_cache_coordinator.py:515` sets `mgr.eagle_extra_cache_blocks = 1` for every SWA manager in an
EAGLE/MTP attention group, and `_cache_block_mask()` then returns `None` — cache every block. We run
MTP (`num_speculative_tokens=5`, method `dspark`), so this is live on groups 1, 2, 3 and 4. The
fork's comment says the mask was too aggressive under eagle and gave **0% hit**; upstream's
replacement is the `shift`-aware version of that same mask.

What the mask would actually save, per 256-token alignment segment
(`need = cdiv(sliding_window - 1, page) + 1` for the eagle peek):

| group | page | blocks/segment | needed for a hit | cached today | with the mask | with `interval = 32768` |
|---|---|---|---|---|---|---|
| 1, 2 | 64 | 4 | 3 | 100% | 75% | ~0.04% |
| 4 | 8 | 32 | 17 | 100% | 53% | ~0.2% |
| 3 | 4 | 64 | 33 | 100% | 52% | ~0.4% |

The win is **indirect**: it does not free KV memory, it removes cached-but-unreachable SWA entries
from the prefix-cache hash map and from the free queue — which is what makes Mechanism 1's
cached/scratch split meaningful in the first place. The two are complementary by design.

**Second in line, and only with a live hit-rate A/B**, because replacing `eagle_extra_cache_blocks`
with upstream's mask is re-litigating a decision the fork made deliberately, and the documented
failure mode is 0% hit rather than a small regression.

Note also the author's own caveat, which survives the port: even upstream, **partial hits only land
on retained checkpoints, not at arbitrary prefixes.** `0` is right if only whole prompts are
replayed; `32768` if partial prefixes should hit too. Claude Code replays a growing prefix, not a
fixed one, so `32768` is the arm to test, not `0`.

## 4. The test plan

Written before the change, so the result cannot be rationalised afterwards.

### 4.1 What is being measured

Primary: **does a multi-turn session's head survive?** The existing instrument already answers this
and has a documented dead/alive signature — `local-ops/xsess/death-probe.sh [delay] [workload] [tag]`,
with a six-turn workload. Alive ≈ 99.6% at ~0.6s; dead = 0.0% at ~22s.

Secondary, free per request: `engine_cached_tokens` (`API-14`) on every response, and the
`PLG-14b` per-request prefill rows. Engine-wide `/metrics` deltas are a fallback only —
`vllm:gpu_cache_usage_perc` reads 0.0 on this build.

### 4.2 Arms

| arm | `VLLM_FREE_QUEUE_PREPEND_UNCACHED` | note |
|---|---|---|
| A (control) | 0 | must reproduce today's decay, or the run is void |
| B | 1 | Mechanism 1 only |

Mechanism 2 is **not** in this matrix. It gets its own restart later, only if B wins, because
stacking them makes an ambiguous result uninterpretable — the mistake `PREFIX-CACHE.md` records
twice already.

### 4.3 Traps this run must not step into (all previously invalidated work here)

- **One cold/warm datum per session.** A probe that misses *rebuilds* what it was measuring; every
  later probe hits regardless. One run per time-point.
- **Never retry a measurement with the same request** — the retry reads its own footprint back.
- **Read latency alongside hit%.** A 22s "99.7%" is a cold prefill measuring itself.
- **Blend.** The co-tenant runs 285–315K-char prompts. Require `queries == input_tokens` or discard
  the row.
- **Both arms in the same sitting**, and say so in the write-up if they are not — the paired run
  was cut short once already because our probes were evicting a co-tenant's cache.

### 4.4 Cost, and what it does not need

The code change and its push cost nothing live: a push updates the working tree, the container holds
the inodes it imported at boot, and with the flag defaulting off the mounted file is byte-different
but behaviourally identical. **One restart** (250–600s cold boot, every session on the cluster
interrupted) buys arm B. Arm A is whatever is already running, provided it is the same boot — if it
is not, A has to be re-measured after the restart with the flag off, which costs a second restart.

That restart will be asked for separately, with the four required points, at the time it is wanted.
Per `CLAUDE.md`: this document is not that ask, and reading it is not an approval.

## 5. What is settled and needs no further work

- **Patch 6 is applied and both settings are on**, on both nodes, in the running engine:
  `PROTECTED_FRACTION=0.50` (`VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION`), `SWA_RECYCLE=1`
  (`VLLM_SWA_RECYCLE_SKIPPED_BLOCKS`), both mounts present, markers present, and the boot log
  carries the `MNT-6a: protected prompt block cap …` lines for all five groups. The
  `Unknown vLLM environment variable detected: VLLM_SWA_RECYCLE_SKIPPED_BLOCKS` warning is vLLM's
  `envs.py` not recognising a var that is not upstream's; our patch reads it directly via
  `os.environ` and recycling is on.
- **Neither half of #43447 supersedes `MNT-6a`, `MNT-6b` or `MNT-7`.** Mechanism 1 is the missing
  end-of-request half of `MNT-6b`, not a replacement for it.
- **This is unrelated to the API-side movers** (`API-8`, `API-11a/b`, `API-13`), which address a
  different failure: the prompt's *head* moving between turns.

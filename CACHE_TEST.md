# CACHE_TEST.md — three candidate prefix-cache mechanisms against our tree, and how we would test them

**Status (2026-09-20): Mechanisms 1 and 3 are IMPLEMENTED and mounted, both OFF. Mechanism 2 is
not implemented. Nothing is measured, and no restart has been spent.**

`MNT-8` (Mechanism 1) and `MNT-9` (Mechanism 3) ship gated on a flags file rather than container
env, so the whole A/B costs **one** restart instead of three:

```bash
bash local-ops/kv-flags.sh                               # arm each node is running
bash local-ops/kv-flags.sh free_queue_prepend_uncached 1 # arm B
bash local-ops/kv-flags.sh pin_static_head 1             # arm C
bash local-ops/kv-flags.sh reset                         # arm A
HOST=spark-45ea bash local-ops/kv-mech-tests.sh          # 13 offline checks, no GPU
```

Neither flag does anything until the next restart imports the mounted files; after that, arms flip
with no restart at all. **Until that restart `check-local-patches.sh` reports `FAIL` for `MNT-8`,
`MNT-8b` and `MNT-9`, and that is correct** — a single-file bind mount holds the inode git replaced,
so the container is still reading the pre-push file (`INCIDENTS.md`, 2026-09-20). The flags file is
deliberately not subject to this: its **directory** is what the compose mounts.
Assessed 2026-09-20 against the running image `vllm-dspark-runtime:dspark-nvfp4-stage-c`
(vLLM `0.21.1rc1.dev339+g1967a5627bc3`), by diffing the PR against the image's real sources —
`patches/pristine/` plus `kv_cache_utils.py` / `kv_cache_coordinator.py` read out of the container.

Two of the three mechanisms come from upstream vllm#43447; the third (§3a, pinning the static head
in-engine) was proposed separately and is assessed here because it competes for the same budget and
edits the same files. This is the working document for the experiment. The standing evidence it draws on lives in
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

The third candidate, §3a, is not part of this PR.

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

## 3a. Mechanism 3 — pin the static head in-engine (the "no proxy" proposal). **Applies, and it is smaller than proposed.**

The proposal: move both proxy jobs into vLLM — (a) find where the static head ends, in-engine, from
the prompt token IDs; (b) stop needing a re-warm by taking an extra reference on the blocks up to
that boundary, so they never enter the free queue.

Checked against this build, point by point. **Two of the four assumptions are already true in our
image**, which makes the change considerably smaller than the sketch — and one of them is the
reason it is worth doing at all.

### 3a.1 Finding B — confirmed on this build, with the token id

The assumption was that the V4 encoder renders tool definitions before the first user turn. **It
does.** Rendered live through `/tokenize` + `/detokenize` on `spark-45ea` (283-token sample,
system + tools + two user turns), the order is:

```
[0] <｜begin▁of▁sentence｜>
[2] ## Tools …  ← the DSML boilerplate
[199] ### Available Tool Schemas …  ← the tools array
[261] SYSTEM HEAD TEXT.            ← the system prompt, AFTER the tools
[266] <｜User｜>                     ← first user turn
```

So the static head is `[0, first <｜User｜>)`, and **`<｜User｜>` is token id `128803`**
(`<｜Assistant｜>` is `128804`, for the same scan). Tools *and* system both land inside it, which is
what the scheme needs. Record these ids in the overlay as constants derived from the tokenizer, not
hard-coded — they are checkpoint-specific.

Two of our own patches act upstream of this rendering and neither disturbs it: `API-11b` hoists only
the *leading* run of system messages, and `API-8` strips leaked CoT from assistant turns (behind the
boundary). `API-11a` already removed the per-request `<total_tokens>` counter that used to make the
head volatile — see below.

### 3a.2 "Creating the checkpoint as a side effect of normal prefill" — already how it works

The primitive is not hypothetical and does not need adding. `_protect_prompt_blocks()` →
`block_pool.touch()` takes the extra reference exactly as described, and **two managers already
call it on every request**:

| manager | what it pins today | line (pristine) |
|---|---|---|
| `MLAAttentionManager.cache_blocks` | the **whole** aligned prompt prefix, `blocks[:aligned(num_prompt-1)/block_size]` | 664 |
| `SlidingWindowMLAManager.cache_blocks` | the sliding-window **tails around the aligned prompt boundary**, `blocks[aligned - contiguous : last_full_prompt_block]` | 875 |

`MNT-6a` is the cap on that set. So the proposal's mechanism is running in production right now —
**at the wrong boundary**.

### 3a.3 What the gap actually is: the boundary is the prompt end, not the head, and release is FIFO

Today's pin covers `[0, prompt_end)`, which is a **superset** of `[0, B)`. The head is therefore
already pinned — briefly. The failure is the budget:

- cap is `pool x fraction / managers` = `16741 x 0.50 / 5` = **1,674 blocks per group**, which in
  group 0 (256-token pages) is ~428K tokens — close to the measured 457,079 retention;
- release is **FIFO** (`_protected_prompt_block_queue.popleft()`), not hit-aware;
- so **one long session's body consumes the entire budget and FIFO-evicts the oldest pins — which
  are the static heads of every other agent.**

A 12.6K-token Claude Code head is ~47 blocks in group 0. Pinning `[0, B)` instead of
`[0, prompt_end)` fits **dozens** of distinct agent heads in the same budget, permanently, instead
of one conversation's body transiently. That is the whole change: **narrow what is pinned, and make
release hit-aware**, not "add pinning".

### 3a.4 Why the SWA tail at B is the part that actually matters

`find_longest_cache_hit` takes the **minimum across groups**, so a head is only reusable if the
sliding-window and compressor groups can also serve it at B. They cannot, today:

- SWA blocks *are* cached densely during prefill (§3 — the mask is disabled under MTP), but
- `MNT-6b` evicts each one as the window passes it (`_maybe_evict_cached_block()` before recycling),
  and
- the only SWA tails that survive are the ones `SlidingWindowMLAManager` pins — **at the prompt end**.

This predicts precisely the asymmetry in the original report: **an identical resend hits 100%**
(its boundary is the pinned prompt end) **while a different session sharing only the head re-prefills
from zero** (its boundary is B, where the SWA tails were evicted). Pinning the small SWA/compressor
tails at B is the missing piece, and it is why this mechanism is not merely a tidier proxy.

### 3a.5 Chunked prefill — the ordering question, answered

The concern was that pinning must happen at the step where caching crosses B, before the next step
frees the out-of-window blocks. In our `kv_cache_manager.allocate_slots()` the order **within one
call** is `coordinator.remove_skipped_blocks()` (line 378) then `coordinator.cache_blocks()`
(line 432). The existing `_protect_prompt_blocks()` calls live *inside* the managers' `cache_blocks`
overrides — i.e. already after the free and at the moment the blocks become cached. **Hooking the
B-pin in the same place inherits the correct ordering**; no scheduler change is needed.

### 3a.6 The extra work, re-scoped against our measurements

| the sketch's concern | where it actually stands here |
|---|---|
| **Volatile heads** (date / cwd / session id early in the system prompt) | **Measured low-risk, not zero.** `API-12` fingerprints are identical across two live sessions (`head=942f33360604 tools=077941266e1a sys=5e46e83cd5d3`), and `API-11a` already removed the per-request counter that made the head volatile. Keep pin-on-first-sight + evict-never-hit anyway; it is the cheap half. |
| **Multiple agents** | Budget + LRU among pins. Agreed — but it must be a **reserved sub-budget**, see conflicts below. |
| **Short heads (<512 tokens)** | Skip them. Ours is ~12.6K, so this is a guard, not a limit. |
| **Chunked prefill ordering** | **Resolved, §3a.5.** |
| **First session must still compute the head once** | A launcher `curl` with `max_tokens=1` after the health check works — but it must reproduce the head **byte-for-byte as the client sends it**, i.e. through the Anthropic endpoint with the same tools array and the same tier. `API-12`'s documented blind spot bites here: the effort prefix is injected *downstream* of fingerprinting, so a warm-up at the wrong tier pins a head nothing will ever hit. Verify with `engine_cached_tokens` on the first real turn, not with the warm-up's own response. |

### 3a.7 Interaction with Mechanisms 1 and 2 — one conflict, and it is schedulable

| pair | interaction |
|---|---|
| **3 x 1** (free-queue ordering) | **None. Complementary.** Pinned blocks hold a reference and never enter the free queue, so queue ordering cannot touch them; Mechanism 1 governs everything *not* pinned. They do share `MNT-6b`'s code, so implement 1 first and rebase 3 onto it rather than developing both against pristine. |
| **3 x 2** (retention interval) | **Real conflict — do not ship blind.** Mechanism 2 stops caching SWA checkpoints that are not on a retained boundary. If B is not a retained checkpoint, **there is nothing at B to pin** and Mechanism 3 silently becomes a no-op. If both ever ship, B must be rounded down to the retention interval (not to 256), or upstream's "latest replay boundary" carve-out must be extended to cover pinned Bs. |
| **3 x `MNT-6a`** | **Shared budget — must be split.** A B-pin placed in the existing `_protected_prompt_block_queue` is FIFO-evicted by ordinary prompt protection, which is the very failure being fixed. Head pins need their own reserve (a second queue, own cap, LRU-by-hit), with `MNT-6a`'s cap applying to the remainder. Non-negotiable; without it the change does nothing. |
| **3 x `MNT-6b`** | Mechanism 3 depends on `MNT-6b` **not** evicting the pinned tails. `_protect_prompt_blocks` already skips nothing on ref-count, and `MNT-6b` only recycles `ref_cnt == 1` blocks — a pinned block has 2, so it is passed to `to_free` instead. Verify this holds for the compressor groups, whose pages are 4 and 8 tokens. |

### 3a.8 Test arm

Add as arm **C** — no longer its own restart, since the flags are file-gated:

| arm | flag | note |
|---|---|---|
| C | `pin_static_head: 1` in the flags file (default 0) | Mechanism 3, with Mechanism 1 set to whatever B concluded |

Its primary measurement is **not** the six-turn survival probe — it is **cross-agent**: start
session 1, let it pin, then measure `engine_cached_tokens` on the *first* turn of session 2 with a
different body and the same head. Expected without it: ~0. Expected with it: the head, to the
256-token alignment. Report both alongside latency, per §4.3.

### 3a.9 Source for the port

The two files requested are in the repo now, captured from the image with the documented
`docker run --rm --entrypoint cat` method (never through a bind-mount) and listed in
`patches/pristine/MANIFEST.txt` as **reference-only, not diff bases**:

- `patches/pristine/vllm/v1/core/single_type_kv_cache_manager.py` (already there — 1,421 lines; the
  `MNT-6*` diff against it is `patches/generated/v1-core-single_type_kv_cache_manager.patch`)
- `patches/pristine/vllm/v1/core/kv_cache_manager.py` (601 lines, new)

Two more went in for Mechanisms 1 and 2, since they are unreadable without them:

- `patches/pristine/vllm/v1/core/kv_cache_coordinator.py` (689 lines — `eagle_extra_cache_blocks`
  is at line 515)
- `patches/pristine/vllm/v1/core/kv_cache_utils.py` (2,149 lines — `FreeKVCacheBlockQueue`)

Anyone drafting the overlay should work against those four plus the generated diff, and **not**
against upstream vLLM at any tag: this fork's hybrid re-alignment, `eagle_extra_cache_blocks` and
prompt protection do not exist upstream, and a patch written against a stock tree will not apply.

## 3b. What was actually built (2026-09-20)

| id | files | flag (default) |
|---|---|---|
| `MNT-8` | `patches/patch8-kv_cache_utils.py` (new mount: `prepend_n`), `patch7-block_pool-dedupe.py` (`free_blocks(..., prepend=)`), `patch6-single_type_kv_cache_manager.py` (`_free_split()` at all three free sites, including `free()` and the `MNT-6b` leftovers) | `free_queue_prepend_uncached` (**0**) |
| `MNT-9` | `patches/patch6-single_type_kv_cache_manager.py` (`_static_head_boundary`, `_head_pin_candidates`, `_maybe_pin_static_head`, `_trim_head_pins`, `_release_head_pin`, `_head_pin_ref`) | `pin_static_head` (**0**), `head_pin_fraction` (0.05) |

Decisions worth knowing before reading the diff:

- **The pin budget is reserved, not shared.** Head pins live in `_head_pins` / `_pinned_head_block_ids`,
  never in `MNT-6a`'s `_protected_prompt_block_queue`, so `MNT-6a`'s FIFO trim cannot take them —
  §3a.7 said this was non-negotiable.
- **The reuse signal is the re-pin itself.** A later request re-pinning a head we already hold is
  the only evidence available in this layer that the head was matched; it moves that head to the
  back of the LRU. Heads nothing returns for age out first.
- **`get_num_common_prefix_blocks` discounts the pin reference** in both managers that count
  references. Without that, every pinned block reads as "one more request than there is" and
  cascade attention's common-prefix count is wrong.
- **`MNT-9` hooks the base `cache_blocks`**, i.e. the same place `MNT-6a` protects from — after
  `remove_skipped_blocks` in the same `allocate_slots` call, which is the ordering §3a.5 required.
- **The head scan is memoised per request and capped at 65,536 tokens.** `cache_blocks` runs every
  scheduler step, and a 1M-token prompt must never be rescanned.
- **B floors to `cache_alignment_tokens` (256 here) and is dropped below 512 tokens.**

Verified offline against the real vLLM classes, in-container, no GPU and no restart —
`HOST=spark-45ea bash local-ops/kv-mech-tests.sh`, 13 checks:

```
PASS 1 prepend_n ordering: [4, 5, 0, 1]          PASS 8  no pin before prefill crosses B
PASS 2 prepend_n empty/refill                    PASS 9  LRU trim released the least-recently-reused head
PASS 3 free_blocks(prepend=) -> [3, 4, 1, 2]     PASS 10 SWA pins only the 9-block tail ending at B
PASS 4 flags: default off, file on, env wins     PASS 11 _head_pin_ref discounts the pin reference
PASS 5 full-attention pins exactly [0,B)         PASS 12 flag off => inert
PASS 6 re-pin is a hit, not a second reference   PASS 13 heads below the 512-token floor are not pinned
PASS 7 uncached blocks inside the head skipped
```

**What these do not establish:** anything about hit rate, retention or latency on real traffic.
They are correctness tests for ordering and refcounts, which is what silently corrupts a block pool;
the question the arms answer is untouched by them.

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

| arm | flags file | note |
|---|---|---|
| A (control) | both 0 (`kv-flags.sh reset`) | must reproduce today's decay, or the run is void |
| B | `free_queue_prepend_uncached: 1` | Mechanism 1 only |
| C | `pin_static_head: 1`, prepend back to 0 | Mechanism 3 only (§3a.8) |

Mechanisms 2 and 3 are **not** in this matrix. Each gets its own restart later (arm C is
§3a.8), because stacking them makes an ambiguous result uninterpretable — the mistake
`PREFIX-CACHE.md` records twice already. Mechanism 2 and Mechanism 3 in particular must never share
a boot: §3a.7 shows 2 can silently turn 3 into a no-op.

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
- **No mechanism here supersedes `MNT-6a`, `MNT-6b` or `MNT-7`.** Mechanism 1 is the missing
  end-of-request half of `MNT-6b`; Mechanism 3 is a narrowing of `MNT-6a`, at a different boundary
  and with a hit-aware release. Both build on what is deployed rather than replacing it.
- **The chat template renders tools before the system prompt, and both before the first
  `<｜User｜>` (token `128803`)** — verified live on this build, §3a.1. That is the only tokenizer
  assumption any of this rests on.
- **This is unrelated to the API-side movers** (`API-8`, `API-11a/b`, `API-13`), which address a
  different failure: the prompt's *head* moving between turns.

# CACHE_TEST.md — three candidate prefix-cache mechanisms against our tree, and how we would test them

**Status (2026-09-20, after the 15:34Z boot): the cause is FOUND — see §8. Decode across several
turns destroys the prompt's cached prefix, reproducibly, with no client and no pressure involved.
Mechanisms 1 and 3 are implemented, mounted, measured and INERT (§6), both switched back OFF;
Mechanism 2 is not implemented. The next test targets `MNT-6b` and needs one restart (§8.4).**

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


## 6. Results — arms A, B and C, 2026-09-20 (15:34Z boot)

All five runs on one boot, one KV pool (2,517,769 tokens), engine otherwise idle, alternating
arm order. Instrument: `local-ops/xsess/death-probe.sh 2 …/workload-a.txt <tag>` — a real six-step
Claude Code session, then **one** probe 2s after it ends. Read the seconds: ~0.7s alive, 14-22s
dead.

| run | arm | flags | head at +2s | prefill |
|---|---|---|---|---|
| armA | A (control) | both 0 | **0.0%, 0 tok** | 14.16s |
| armB | B | `free_queue_prepend_uncached: 1` | **0.0%, 0 tok** | 14.21s |
| armB2 | B | ″ | **0.0%, 0 tok** | 14.17s |
| armA2 | A (control) | both 0 | **0.0%, 0 tok** | 14.13s |
| armC | C | `pin_static_head: 1` | **0.0%, 0 tok** | 14.24s |

Spread across all five: **0.6%**. Within-session behaviour is also unchanged — arm A and arm B
both report 6/6 strict prefix, median **99.6%** of the achievable ceiling (`matrix-report.py`).

### Both mechanisms provably ran

Neither result is a "flag never arrived" null:

- **The flag reaches the engine live.** `docker exec … cat /etc/vllm-kv-flags/flags.json` returned
  `{"free_queue_prepend_uncached": 1, …}` mid-run, through the directory mount, with no restart.
  **The no-restart A/B design works** — that is the one unambiguous win of this boot.
- **`MNT-9` logged what it did**, on all five KV groups:
  `MNT-9: KV group 0 pinned a static head at B=22784 tokens (89 blocks, cap 169 blocks)`, with
  2 / 2 / 3 / 16 blocks on groups 1-4. B was found in-engine from the token stream exactly as
  designed, and the SWA groups pinned only their tails.

### What this eliminates — and it is worth more than the arms

**The head does not die of eviction.** The strongest reading is not "`MNT-8` and `MNT-9` are
useless" but that the failure they target is not the failure that is happening:

1. The engine was **idle** with a 2.5M-token pool and a 44K conversation. Nothing was competing for
   blocks, so free-queue *order* (`MNT-8`) cannot matter — there is nothing to evict for.
2. `MNT-9` **held 112 blocks of the head by reference**, so they could not be evicted or reused by
   anyone, and the head was *still* unreachable 2s later.
3. Caching and lookup were working perfectly at that moment: three probes on the same head in a row
   returned **27,136 tokens at 0.49-0.58s**, repeatably.

So a probe-written head survives while a session-written head does not, **even when its blocks are
pinned in memory**. That rules out the whole family of "something evicted it" explanations —
`MNT-8`, `MNT-9`, `MNT-6a`'s cap and LRU pressure alike — and points at the **hash registry**
rather than the block pool: the blocks are alive and unreachable, so what disappears is the
`(hash → block)` mapping, not the memory.

**Next candidate, and it needs no restart:** find who drops those mappings at the end of a real
session — `_maybe_evict_cached_block` on a path we have not instrumented, an abort/cancel path
(Claude Code ends a streaming turn), or a reset. `MNT-9` can be re-used as an instrument here
rather than a fix: it already proves the blocks outlive the session.

### Housekeeping

Both flags were set back to `0` on both nodes at the end of the run (`kv-flags.sh reset`), so the
cluster is on stock behaviour. Neither mechanism is rolled back — they stay mounted and inert,
because the next experiment above uses them as instruments.


## 7. The warm-up experiment (2026-09-20, same boot) — and a CORRECTION to §6

§6 concluded "the head does not die of eviction". **That conclusion was wrong, and this experiment
is what caught it.** See §7.3.

### 7.1 What was run

Stock flags (both 0). One head throughout, six measurements, each probe a single fresh-tail request:

| step | what | result |
|---|---|---|
| S1 | a real six-step session writes the head | turn 0: **0.0%, 16.47s** (cold, as expected) |
| P0 | probe 2s after S1 ends | **0.0%, 0 tok, 14.49s** — the session's head is gone |
| P1 | probe 120s after P0 (P0 itself re-wrote the head synthetically) | **99.5%, 27,648 tok, 0.50s** |
| S2 | a second session, same head, head now WARM | turn 0: **99.6%, 4.26s** |
| P2 | probe 2s after S2 ends | **0.0%, 0 tok, 14.40s** — gone again |
| P3 | probe 120s after P2 | **99.5%, 27,648 tok, 0.45s** |

### 7.2 What it answers

**A warm-up does exactly what it was supposed to do.** A head written by a plain request is
reusable at **99.5% in 0.5s**, survives 120s idle, and a real session starting on it pays
**4.26s instead of 16.47s at turn 0 — a 3.9x faster start**. That is the original goal, and it needs
no patch at all: one request, not a mechanism.

**But a session ending destroys it, every time.** P1 was alive at 18:40. S2 ran. P2, seconds later,
read 0.0%. The only thing that happened in between was a session. So a warm-up is a **band-aid that
has to be re-applied after each session**, not a one-time fix — and re-applying costs 0.5s.

**It is not the "ending" that matters, it is the session's own later turns.** The head is written by
turn 0; turns 1-6 then allocate tens of thousands of blocks across five KV groups with 4-, 8- and
64-token pages. That is enough allocation to cycle the free queue and reuse the turn-0 blocks.
Corroborating detail from the same captures: the head of turns 1-6 (after the tools array changes,
`42ce1118e8` -> `e38be74405`) **did** survive from S1 into S2 (turn 1: 87.1%, 3.81s) — because it is
the *last* prefix in the session, and `MNT-6a` protects that one.

### 7.3 The correction: arm C did not test what it claimed

§6 argued that eviction was eliminated because `MNT-9` held the head by reference and it still
vanished. **`MNT-9` did not hold the head.** Re-reading its own log against the geometry:

| group | page | blocks needed for a hit at B (`cdiv(127, page) + 1`) | blocks `MNT-9` actually pinned |
|---|---|---|---|
| 0 | 256 | 89 (the whole prefix) | **89** |
| 1 | 64 | 3 | **2** |
| 2 | 64 | 3 | **2** |
| 3 | 4 | 33 | **3** |
| 4 | 8 | 17 | **16** |

Every sliding-window group pinned **fewer blocks than a hit at B requires** — group 3 pinned 3 of
33. `_maybe_pin_static_head` skips candidates whose `block_hash is None`, so the run it pinned was
incomplete, and `find_longest_cache_hit` takes the **minimum across groups**: an incomplete run in
any SWA group means no hit at B at all, no matter what group 0 holds.

So arm C measured a pin that could never have worked. Eviction is **back on the table** as the
cause, and the §6 claim "this rules out the whole family of 'something evicted it' explanations" is
**withdrawn**. What survives from §6 is narrower and still useful: `MNT-8`'s free-queue ordering
does not move this metric, and a synthetic head is durable where a session head is not.

### 7.4 What to do next, in order

1. **Ship the warm-up.** It is measured, it is 0.5s, and it needs no engine change. Re-warm after
   each session, not only at startup. The head must be byte-identical to what the client sends,
   including the tier (`API-12`'s blind spot: the effort prefix is injected downstream).
2. **Fix `MNT-9` before judging it.** It must check that the full `need`-wide run is cacheable and
   **log loudly when it is not**, rather than silently pinning an unusable subset. A pin that
   cannot serve a hit is worse than no pin: it consumed budget and produced a confident null.
3. **Then re-run arm C**, which will be the first real test of head pinning.
4. **The `tools` flap is still the biggest single cost in these captures** — turn 1 diverges on the
   tools array in both sessions (swift-lsp attaching), costing a full **17.85s** re-prefill in the
   cold session. `death-probe.sh` disables the plugin deliberately; ordinary sessions do not. That
   is a client-side setting worth more than either engine mechanism.


## 8. FOUND IT: decode across turns destroys the prompt's cached prefix (2026-09-20)

§7 left "what kills a session's head" open. Six controlled runs on the same captured bodies closed
it. **The killer is decode, and only when the conversation has several turns.**

### 8.1 The runs

All against the same head, each probe a single fresh-tail request, stock flags, engine otherwise
quiet.

| what was done to the engine | head afterwards |
|---|---|
| nothing (control, repeated all evening) | **99.5-99.6%, 0.5-0.8s** |
| 224,500 tokens of unrelated prefill (5 requests) | **99.5%, 1.01s** — alive |
| 1,122,240 tokens of unrelated prefill (25 requests) | 0.0%, 14.86s — dead |
| replay the session's 7 bodies, `max_tokens=1` | **99.6%, 0.73s** — alive |
| replay the same 7 bodies, `max_tokens=400` | **0.0%, 14.91s — DEAD** |
| replay 1 body only, 166 tokens decoded | **99.5%, 0.67s** — alive |
| replay all 7 bodies, 350 tokens decoded total (50 each) | **0.0%, 14.83s — DEAD** |

Read the last three together: **identical prompts, identical order, identical everything except
generation.** 166 decoded tokens on one turn is harmless. 350 decoded tokens spread over seven
turns of a growing conversation destroys the prefix completely.

So it is not volume — of prefill *or* of decode. It is decode **on a conversation that keeps
extending**.

### 8.2 What is now ruled out, with controls

- **The client.** Plain `urllib` against `/v1/messages`, no Claude Code, no SSE, no aborts, no
  beta headers, reproduces it exactly — and the `max_tokens=1` arm proves the same bodies are
  harmless without decode.
- **Preemption.** `vllm:num_preemptions_total` was **0.0** before and after a full real session.
- **Allocation pressure as the everyday cause.** It takes ~1.1M tokens / ~25 large requests to
  evict a warm head by pressure; a 7-turn session allocates a small fraction of that and kills it
  every time.
- **`MNT-8`'s free-queue ordering** (arm B) and **`MNT-9` as built** (arm C, and it pinned an
  incomplete run anyway — §7.3).

### 8.3 The mechanism this points at, and why it implicates our own patch

Putting it together with the code:

1. `MNT-6a` protects each request's aligned prompt prefix by holding a reference — that is why a
   single turn's decode is harmless, and why the **last** turn's prefix survives into the next
   session (measured: 87.1% in §7.2).
2. That protected set is **FIFO with a cap** (1,674 blocks/group). Several turns — or ~25 unrelated
   requests — push the head's blocks out of it.
3. Once unprotected, the head's blocks are held only by the running request. As its sliding window
   advances past them, `remove_skipped_blocks` fires and **`MNT-6b` calls
   `_maybe_evict_cached_block()` on each recycled page**, destroying its hash mapping rather than
   leaving it cached-but-free in the LRU.
4. `find_longest_cache_hit` takes the **minimum across KV groups**, so the moment the sliding-window
   groups lose their checkpoints, the hit is 0 — even though group 0 (full attention) may still
   hold the whole head.

That is consistent with every row in §8.1, including why pressure needs ~25 requests (it exhausts
the same FIFO protection) and why decode matters (it is what advances the window past the prompt).

**This contradicts two standing notes, and they are corrected, not quietly edited:**

- `PREFIX-CACHE.md` listed **"Generation / decode"** as eliminated on the strength of *one request
  generating 388 tokens*. That control is reproduced here (one turn, 166 tokens, alive) — it simply
  does not generalise to multiple turns.
- `PATCHES-KV.md` recorded **`MNT-6b` as "investigated and exonerated"** on the strength of an
  **offline** four-cell A/B. The offline harness does not model multi-turn decode, which is exactly
  the condition that matters.

### 8.4 The next test, and it needs one restart

`MNT-6b`'s kill switch is `SWA_RECYCLE=0`, a **container env var**, so it cannot be flipped on a
running engine — the very problem the flags file was built to solve. The proposal is therefore:

1. Move `MNT-6b`'s switch onto the flags file (`swa_recycle`), keeping the env var as an override.
2. Fix `MNT-9` to verify the full `need`-wide run is present and **log loudly when it is not**
   (§7.3), so arm C can be judged for the first time.
3. One restart to load both. After that, this A/B needs no further restarts:

| arm | flags | question |
|---|---|---|
| D | `swa_recycle: 0` | does the prefix survive multi-turn decode without the evict-on-recycle? |
| C' | `pin_static_head: 1` (fixed) | does a complete pin hold the head through decode? |
| D+C' | both | belt and braces, if either half works |

**Reproducer for whoever runs it** (no session, no client, ~45s):
`python3 <decode-dose> 7 50` — seven captured bodies, 50 decode tokens each, probe before and
after. Alive→dead is the signal.

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

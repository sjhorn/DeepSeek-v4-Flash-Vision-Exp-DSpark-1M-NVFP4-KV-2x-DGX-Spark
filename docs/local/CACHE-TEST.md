# CACHE-TEST.md — why long sessions re-prefilled, what fixed it, and what is left

**READ THIS FIRST. Everything below §0 is the investigation, in the order it happened, including the
wrong turns. If you only need the state of the world, this box is it.**

| | |
|---|---|
| **The bug** | A conversation's cached prompt became unreusable after a few turns. A new session paid a full cold prefill: **0.0% hit, ~14s**, instead of ~0.5s. |
| **The cause** | **Our own `MNT-6b`.** Recycling a sliding-window page called `_maybe_evict_cached_block()` on it, destroying its `(hash → block)` mapping. Decode walks the window across the prompt's checkpoints; the coordinator takes the **minimum across KV groups**, so the hit reads 0% even though full attention still holds the whole head. Confirmed §8, §9. |
| **The fix** | **`MNT-6c`** — recycle only pages with no cache entry. Flag `swa_recycle_cached: 0`. |
| **Status** | **LIVE on both nodes since 2026-09-21.** Head after a session: **99.5% / 0.5s** (was 0.0% / 14.4s), 3/3 with no overlap; real Claude Code session **99.4% / 0.49s**. Sessions also run **~35% faster** (82s → 50s). |
| **Reproduce (45-90s, no restart)** | `python3 local-ops/xsess/session-sim.py 7 400 mylabel` — DEAD with the fix off, ALIVE with it on. |
| **Revert** | `bash local-ops/kv-flags.sh swa_recycle_cached 1` — no restart. Since 2026-09-21 the **code default is the fix**, so this flag is the escape hatch, not the enabler. |
| **What is left** | **§10.** Item 1 is **ANSWERED** (the fix costs nothing under load — 13h of real traffic, zero preemptions, prefix hit rate flat, later measured **98.3%** live). Items 2 (code default) and 8/9 remain; 5/6/7 are proposed for deletion. |

**What is actually ON right now — verified against the engine 2026-09-21, not from this file:**

| mechanism | state | the switch | what it does, in plain words |
|---|---|---|---|
| `MNT-6a` protected-block cap | **ON**, 0.50 | `PROTECTED_FRACTION` env | Puts a limit on how much memory one chat is allowed to lock up, so one big chat cannot starve everyone else. |
| `MNT-6b` recycling | **ON** | `swa_recycle: 1` | Lets a chat re-use its own finished memory pages instead of throwing them on a shared pile and grabbing fresh ones. |
| **`MNT-6c` the fix** | **ON** | `swa_recycle_cached: 0` **and** the code default | Stops that re-use from erasing the label that says what text a page holds. Losing labels is what made saved chats un-findable. |
| `MNT-7` dedupe | **ON** | none | Notices when two pages hold exactly the same text and frees the spare one, which would otherwise sit there forever. |
| `MNT-8` free-queue order | **OFF** | `free_queue_prepend_uncached: 0` | Would hand back junk pages first and useful pages last, so the engine eats the junk before the good stuff. |
| `MNT-9` head pinning | **OFF** | `pin_static_head: 0` | Would nail down the unchanging start of every prompt so it can never be thrown away. |
| **`MNT-10` prefill cap** | **ON at 1024** | see the warning below | Stops one request from grabbing the engine's whole per-step budget, so other chats still get a turn. |

Read the flags the engine actually sees, never the host file:
`docker exec <container> cat /etc/vllm-kv-flags/flags.json`.

### How each one works, in grade-5 English

First, the picture everything else hangs off. The engine keeps a huge notebook of
**pages**. Each page stores the model's notes about a chunk of your conversation. Re-reading a
chunk you already talked about is slow, so the engine tries to **keep the old pages** and look
them up again. Every saved page has a **label** on it saying which chunk of text it belongs to.
No label means nobody can ever find that page again, even though it is sitting right there.

**`MNT-6a` — the locker limit.** Pages you are still using are locked so they cannot be taken
away. The problem was that there was almost no limit, so one very long chat could lock nearly the
whole notebook and everyone else got nothing. This sets a fair share: each group may lock about
half the notebook, divided between them, and no more.

**`MNT-6b` — keep your own scraps.** The model only looks at a moving window of recent text. Pages
that fall out the back of that window are done with. They used to go onto a big shared pile, and
the chat would then take brand-new pages off that same pile. That is a lot of pointless shuffling.
Instead, the chat now holds on to its own finished pages and re-uses them itself.

**`MNT-6c` — do not rub out the label.** This is the bug that started all of this. When `MNT-6b`
re-used a page, it also **rubbed out that page's label** — sensible if the page is about to be
written over, except the page still held perfectly good notes someone might want. As a chat went
on, the moving window walked across the whole prompt and rubbed out label after label. Then a new
session looked for its saved prompt, found no labels, and had to read all 140,000 words again from
scratch — about 14 seconds instead of half a second. The fix: only re-use pages that have **no
label**. Labelled pages are handed back normally and stay findable.

**`MNT-7` — throw away the duplicate.** Two pages can end up holding the very same text. Only one
of them can ever be found by a lookup, so the other one is dead weight holding a slot forever.
This spots the twin and frees it. It made the engine keep about **4x more** useful pages.

**`MNT-8` — junk to the front of the queue** *(built, switched off)*. When a chat finishes, its
pages go back on the pile. Some are junk scratch pages; some hold valuable saved text. Both used
to go to the **back**. The engine takes from the **front**, so it would chew through the valuable
pages while the junk sat safely at the back — exactly backwards. This would put junk at the front
to be eaten first. It is off because it made no measurable difference when we tested it.

**`MNT-9` — nail down the beginning** *(built, switched off)*. The first part of every prompt — the
tool list and the system instructions — is identical on every single turn. This would pin that
part so it can never be thrown out. It is off because it turned out not to be the problem.

**`MNT-10` — no hogging the trolley.** Each engine step has a fixed budget of about 8,192 tokens,
like a shopping trolley with limited space. A request reading a giant new prompt would fill the
**entire** trolley, so every other chat waiting to say its next word got **zero** space that step —
and the next, and the next. That is why replies crawled at 2 words a second while the engine looked
healthy. This says no single request may take more than **1,024** of the space, leaving room for
everyone else. Careful: this only helps when **two or more** requests are active. If only one
request is running and it feels slow, it is simply reading its own long prompt, and a smaller limit
makes that **worse**, not better.

> **`MNT-10` is the one inconsistency, and it self-heals at the next restart.** The running gate has
> the **wrong flags path** (fixed in the branch, not yet live — `docs/local/status/INCIDENTS.md`),
> so today it reads a *container-local* `/var/tmp/vllm-kv-flags/flags.json` holding **1024**, while
> the boot arg for this container says **2048**. 1024 is what is in force. After the next restart
> the fixed gate reads `/etc/vllm-kv-flags/flags.json`, which carries **no**
> `long_prefill_token_threshold` key, so it falls through to the compose boot default — also
> **1024**. Same value either side, no gap. `MNT-10` is a *scheduling* fix, not a cache one; its
> evidence lives in [`docs/local/PATCHES-KV.md`](PATCHES-KV.md).

```bash
bash local-ops/kv-flags.sh                          # what each node is running
bash local-ops/kv-flags.sh reset                    # the RECOMMENDED state (keeps the fix)
bash local-ops/kv-flags.sh swa_recycle_cached 1     # old behaviour, for an A/B
HOST=spark-45ea bash local-ops/kv-mech-tests.sh     # 16 offline checks, no GPU, no restart
```

> **Two traps that cost real time here.**
> 1. **Never warm the head before the treatment.** A reproducer that probes first makes *both* arms
>    look fine (§9.2). `session-sim.py` stamps the system prompt unique and probes **last**.
> 2. **A commit moves the head.** Claude Code's system prompt carries git status and recent commits,
>    so two sessions either side of a commit are not comparable (59.3% partial hit, measured).

**`MNT-8` and `MNT-9` are mounted but OFF.** Neither was the answer (§6); they are kept because
`MNT-9`'s warning is a useful instrument. `Mechanism 2` was never built and is proposed for deletion
(§10).

Assessed against image `vllm-dspark-runtime:dspark-nvfp4-stage-c` (vLLM
`0.21.1rc1.dev339+g1967a5627bc3`). Standing cache evidence lives in
[`docs/local/PREFIX-CACHE.md`](PREFIX-CACHE.md), the patch rows in
[`docs/local/PATCH-REGISTRY.md`](PATCH-REGISTRY.md), the config change in
[`docs/local/status/CONFIG.md`](status/CONFIG.md). Nothing is restated in all of them.

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

### 8.1b A turn-count sweep that does NOT work — recorded so nobody repeats it

Sweeping n = 1..7 turns at 50 decode tokens, each point starting from a confirmed-warm head, gives
**ALIVE, ALIVE, ALIVE, DEAD, ALIVE, DEAD, ALIVE**. Non-monotonic, so it is not a threshold
measurement.

**The confound:** the replayed turn 0 *contains the head*, so every batch **re-creates** the very
thing being measured, part-way through the dose. "n turns" is therefore not a clean dose of
anything — what the final probe sees is whatever turns 1..n did to a head that turn 0 had just
rewritten. Co-tenant traffic (this box regularly has one) can flip individual points too; the sweep
did not record contention per point, which it should have.

**Why §8.1 is not affected:** those runs compare `max_tokens=1` against `max_tokens=400` over the
**same seven bodies in the same order** — identical re-creation pattern, decode the only variable.
That comparison is sound; the dose-response curve is not established, and no turn threshold should
be quoted from it.

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

### 8.4 The next test — BUILT 2026-09-20, awaiting one restart

All three pieces are implemented, tested offline (16/16) and pushed. They are inert until a restart
imports them; after that every arm is a flag flip.

1. **`MNT-6b`'s switch moved onto the flags file** (`swa_recycle`), env var still overriding.
   **The compose line that set `VLLM_SWA_RECYCLE_SKIPPED_BLOCKS` was removed** — with it present the
   env would have overridden the file and `kv-flags.sh swa_recycle 0` would have been silently
   ignored, i.e. another confident null. Default with neither set is unchanged.
2. **`MNT-6c`, new and the likely fix** (`swa_recycle_cached: 0`): recycle only pages with **no**
   cache entry. Keeps what `MNT-6b` is for — one long prefill not churning the shared queue — while
   never calling `_maybe_evict_cached_block()` on a page that carries a prefix-cache mapping. Same
   cached/uncached discrimination vllm#43447 makes for the free queue.
3. **`MNT-9` now refuses an incomplete run and logs a WARNING** naming the group, B, and how many of
   the required blocks were cached (`head_pin_partial: 1` restores the old behaviour for
   diagnosis). This is what makes arm C judgeable for the first time.

After the restart, no further restarts:

| arm | flags | question |
|---|---|---|
| **E** | `swa_recycle_cached: 0` | **run this first.** Does the prefix survive multi-turn decode once recycling stops destroying cache mappings? Targets the mechanism directly and keeps `MNT-6b`'s benefit. |
| D | `swa_recycle: 0` | `MNT-6b` off entirely — the blunt control. If E works and D works, prefer E; if only D works, the recycling itself is implicated, not just the eviction. |
| C' | `pin_static_head: 1` | does a **complete** pin hold the head through decode? Watch for the new `MNT-9 … CANNOT pin` warning: if it fires, the SWA checkpoints are already gone before B is reached, which is itself the answer. |
| E+C' | both | belt and braces, if either half works |

Each arm is `python3 local-ops/xsess/decode-dose.py 7 50` — 45 seconds, alive→dead is the signal —
followed by the same with `1 400` as the negative control.

**Reproducer for whoever runs it** (no session, no client, ~45s):
`python3 <decode-dose> 7 50` — seven captured bodies, 50 decode tokens each, probe before and
after. Alive→dead is the signal.


## 9. CONFIRMED: `MNT-6c` fixes it (2026-09-21)

**`swa_recycle_cached: 0` makes a conversation's prefix survive multi-turn decode.** Root cause and
fix both confirmed on the 2026-09-20 21:33 boot, engine taken exclusively for the run.

### 9.1 The measurements

Cold-head session simulation (`local-ops/xsess/session-sim.py 7 400`), alternating arms:

| run | `swa_recycle_cached` | head after the session | prefill | session wall-clock |
|---|---|---|---|---|
| baseline | 1 (today) | **0.0%, 0 tok** | 14.44s | 82s |
| **armE** | **0** | **99.5%, 27,648 tok** | **0.47s** | **51s** |
| baseline2 | 1 | 0.0%, 0 tok | 14.42s | 82s |
| **armE2** | **0** | **99.5%** | **0.50s** | **50s** |
| baseline3 | 1 | 0.0%, 0 tok | 14.41s | 78s |
| **armE3** | **0** | **99.5%** | **0.55s** | **49s** |

**3/3 separation, no overlap.** And the sessions themselves run **~35% faster** (49-51s vs 78-82s),
because each turn hits cache instead of re-prefilling.

Validated end-to-end on the real instrument — a genuine headless Claude Code session, probed 2s
after it ends:

```
armE, real session:   +0.5s  hit 99.4% = 27,648 tok  0.49s  [clean]
arm A, 2026-09-20:    +2.0s  hit  0.0% =      0 tok 14.16s  [clean]
```

### 9.2 A protocol bug found on the way — and it invalidates the first arm-E run

The first attempt compared arms with `decode-dose.py`, which **probes first**. That probe warms the
head, so every run after the first starts warm — and a warm head survives. Both arms then read
ALIVE and the comparison was worthless; the earlier non-monotonic sweep (§8.1b) has the same cause.

`session-sim.py` models a real session instead: it **stamps the system prompt uniquely** so the head
has never been cached, runs the turns (turn 0 creates it cold, `engine_cached_tokens=None`
confirms), and only then probes. With that, the baseline fails 3/3 and arm E passes 3/3.

**The rule this establishes:** a prefix-cache experiment must not touch the object under test before
the treatment. Warming to "establish a baseline" destroys the measurement.

### 9.3 What this settles

- **The root cause is confirmed**, not inferred: `MNT-6b` recycling a page calls
  `_maybe_evict_cached_block()` on it, destroying its `(hash → block)` mapping. As decode advances
  the sliding window across a multi-turn conversation, that eviction walks through the prompt's
  checkpoints; the coordinator's minimum-across-groups rule then reads 0% even though full attention
  still holds the whole head.
- **`MNT-6b`'s "investigated and exonerated" note was wrong** (offline A/B, no multi-turn decode).
  The patch's *recycling* is worth keeping; its *eviction* was never necessary for it.
- **`MNT-8` and `MNT-9` were not the answer** and stay off. `MNT-9`'s new warning was still useful:
  it showed the SWA runs one block short, which is what eviction-from-the-oldest-end looks like.

### 9.4 Deployed state, and the fragility that has since been removed

`swa_recycle_cached: 0` is **live on both nodes**. Revert instantly with
`bash local-ops/kv-flags.sh swa_recycle_cached 1` — no restart either way.

**The fragility is fixed in the branch** (§10, closed item 2). It was real: the flags file is
node-local state under `/var/tmp` and not in git, so a fresh node or a cleared `/var/tmp` silently
restored the broken behaviour, because the code default was `True`. `_recycle_cached_pages()` now
defaults to `False`, which makes the fix the default and the flag the escape hatch, and flips the
fail-safe direction too — bad JSON in the flags file now reads as "keep the fix". Live at the next
restart, whenever one happens; until then `/var/tmp` is still what is holding it.


## 10. Open items — what to pick up next (as of 2026-09-21)

The root cause is closed (§8, §9). **Items 1, 2, 5, 6 and 7 were resolved or dropped on
2026-09-21** and are recorded under "Closed" below rather than kept on a list that would pretend
they are pending. What is genuinely left is short.

| # | Item | Status | Next step |
|---|---|---|---|
| **8** | **The swift-lsp `tools` flap** | **The largest remaining cost in these captures.** The plugin attaches seconds into every session and changes the tools array; turn 1 then diverges and re-prefills — **17.85s** in the cold session measured 2026-09-20. `death-probe.sh` disables it deliberately, ordinary sessions do not. | Client-side setting, free: disable the plugin, or accept one re-prefill per session. Measure a session with and without to put a number on it. |
| **9** | **Warm-up not shipped** | Measured (§7): a warm head makes turn 0 cost **4.26s instead of 16.47s**. Still not wired into the launcher. | Add one `max_tokens=1` request after the health check, using the **exact** head the client sends, at the right tier (`API-12`'s blind spot: the effort prefix is injected downstream). |
| **3** | **`MNT-9` (head pinning) — keep it or retire it?** | Built and fixed (refuses an incomplete run, §8.4), **never run**, and probably unnecessary now. Mounted with `pin_static_head: 0` on both nodes. Baseline arm measured 2026-09-21. | **Arms written and ready: §12.1.** See also the correction below — the check is **not** a free log grep. |
| **4** | **`MNT-8` / `MNT-8b` (free-queue order) under real pressure** | Measured inert on an idle engine (§6), but the pressure test shows ~1.1M tokens of unrelated traffic **does** evict a head. With a real co-tenant, ordering may still matter. | **Arms written and ready: §12.3** — manufacture the co-tenant on an idle box rather than waiting for one. Do not re-run the §6 shape; an arm where nothing dies measures nothing. |
| **11** | **Is the `MNT-10` cap free when nobody is being protected?** | Only ever read off one column of the §"dose-response" table: 82.8s at cap 0 against 95.8s at 1024, **n=1, one context size**. It is the whole case for (or against) the adaptive `Running`-aware controller. | **Arms written and ready: §12.2.** |
| **12** | **`status/CONFIG.md`'s retention figure predates `MNT-6c`** | 457,079 tokens at `PROTECTED_FRACTION=0.50` describes code we no longer run. | **Ready: §12.4.** No flags, no restart — load only. |
| **13** | **Per-tenant capacity via `cache_salt`** | **Researched 2026-09-21 — §13. Rejected as posed:** a salt isolates, it does not allocate, and it would destroy the cross-tenant head sharing we get free today. The tenant-identity half is worth keeping. | Park behind item 4: build nothing until there is observed cross-tenant eviction to fix. |
| **10** | **Git state moves the head** | Measured 2026-09-20: Claude Code's system prompt carries git status and recent commits, so **committing changes the head**. A session run after commits shared only the first ~16.4K tokens with the earlier head (**59.3%** partial hit) before diverging inside the system prompt. | Know it when measuring — two sessions either side of a commit are **not** the same head. Fixing it means changing what the client sends; not ours to change unilaterally. |

### Correction to item 3: the "cheap check" is not free (2026-09-21)

The earlier next-step read *"with `MNT-6c` on, is the `MNT-9 … CANNOT pin` warning gone? If yes
that is independent confirmation the checkpoints now survive."* **That check cannot be run as
written.** The warning is emitted inside `_maybe_pin_static_head()`, which returns immediately
unless `_flag(_FLAG_PIN_HEAD, False)` is true — and `pin_static_head` is `0` on both nodes
(verified 2026-09-21 via `local-ops/kv-flags.sh`). With `MNT-9` disarmed the warning **cannot**
appear, so its absence in the log proves nothing at all.

Running it for real means arming `pin_static_head 1` on live traffic. That is a live flag flip and
needs no restart, but it changes **global** engine state for every session on the box, so it is an
experiment to schedule — not an incidental log grep. `MNT-6c` is already confirmed by §9 on its own
evidence; this would only be corroboration, which is why item 3 stays parked.

### Closed on 2026-09-21

Kept as one line each, because "we decided not to do this, and why" is the part that stops the work
being repeated.

| # | Item | Outcome |
|---|---|---|
| 1 | Does `MNT-6c` cost anything under load? | **ANSWERED: no evidence it does.** 13h of real Claude-Code-with-subagents traffic (696 windows, up to 6 concurrent requests): prefix hit rate flat at 93.8–94.2%, `vllm:num_preemptions_total` **0**, KV never above 71.5%. The decode collapse on that traffic was a *different* mechanism — vLLM's shared `token_budget` letting one long prefill starve everything behind it in `self.running`, now `MNT-10`. See [`status/INCIDENTS.md`](status/INCIDENTS.md) |
| 2 | Code default was still the broken behaviour | **DONE.** `_recycle_cached_pages()` defaults to `False`, so the fix survives a cleared `/var/tmp` or a fresh node and `swa_recycle_cached 1` is the escape hatch back to stock. The fail-safe direction flipped with it: bad JSON in the flags file now reads as "keep the fix" |
| 5 | Mechanism 2 — `VLLM_PREFIX_CACHE_RETENTION_INTERVAL` (§3) | **DROPPED.** Never implemented; aimed at the failure `MNT-6c` fixed, and it would have **conflicted** with `MNT-9` (§3a.7). Revisit only if a new retention symptom appears |
| 6 | Arm D — `swa_recycle: 0` (§8.4) | **DROPPED.** Arm E delivers the benefit while keeping the useful half of `MNT-6b`; turning recycling off wholesale was never the goal |
| 7 | Dose-response curve (§8.1b) | **DROPPED.** The turn-count sweep was invalid — it re-created the head mid-dose — and `session-sim.py` reproduces reliably, so a threshold curve adds little |

### Priority

1. **Items 8 and 9** are the cheap wins, and both are **client-side** — no engine change, no
   restart, no flag.
2. **Items 3, 4, 11, 12 all have arms written and waiting in §12**, and all four need the same
   thing: an idle engine. Run them in one window rather than four.
3. **Items 10 and 13** are park-and-watch. Item 13 is parked behind item 4 on purpose — there is no
   observed cross-tenant eviction to fix yet.
4. Nothing here is urgent. Item 1 was the one that was, and it is answered.

## 11. Settled background facts

- **`MNT-6a` and `MNT-6b` are applied on both nodes**, mounts present, markers present, and the boot
  log carries the `MNT-6a: protected prompt block cap …` lines for all five KV groups.
  `PROTECTED_FRACTION=0.50` is still a container env var. **`SWA_RECYCLE` is no longer one** — the
  compose line was removed 2026-09-20 so the flags file governs (`swa_recycle`), because an env var
  set there would silently override the file and make an arm a no-op. Recycling itself is still ON;
  what `MNT-6c` changed is that it no longer evicts the cache entry of the pages it recycles.
- **No mechanism here supersedes `MNT-6a`, `MNT-6b` or `MNT-7`.** Mechanism 1 is the missing
  end-of-request half of `MNT-6b`; Mechanism 3 is a narrowing of `MNT-6a`, at a different boundary
  and with a hit-aware release. Both build on what is deployed rather than replacing it.
- **The chat template renders tools before the system prompt, and both before the first
  `<｜User｜>` (token `128803`)** — verified live on this build, §3a.1. That is the only tokenizer
  assumption any of this rests on.
- **This is unrelated to the API-side movers** (`API-8`, `API-11a/b`, `API-13`), which address a
  different failure: the prompt's *head* moving between turns.

## 12. Ready-to-run test plan (written 2026-09-21, not yet run)

**Status: prepared, not executed.** An idle window opened on 2026-09-21 and closed before the arms
could run; the engine was busy again. Everything below is written to be picked up cold by whoever
has the next idle window. Nothing here needs a restart.

### 12.0 Preconditions, and the two that have already burned us

```bash
# 1. a tunnel -- the API binds 127.0.0.1 on the head
ssh -f -N -L 8888:127.0.0.1:8888 shorn@spark-45ea
curl -s http://127.0.0.1:8888/health -o /dev/null -w 'health=%{http_code}\n'

# 2. the engine is actually idle -- BOTH must read 0
curl -s http://127.0.0.1:8888/metrics | grep -E '^vllm:num_requests_(running|waiting)\{'

# 3. record the flags BEFORE, and again AFTER every arm
bash local-ops/kv-flags.sh
```

- **The flags file is global engine state, not per-session.** There is regularly a second client on
  this box. Two people experimenting at once interleave arms and void both results. A flags change
  between the before- and after-reading of one arm **invalidates that arm** — do not rescue it.
- **Write the HOST path, read the CONTAINER path.** `kv-flags.sh` writes
  `/var/tmp/vllm-kv-flags/flags.json`; the engine reads `/etc/vllm-kv-flags/flags.json`. Confirm
  with `docker exec <container> cat /etc/vllm-kv-flags/flags.json`. Getting this backwards silently
  disabled `MNT-10`'s gate for a whole A/B.
- **`kv-flags.sh` merges.** Write every key the arm depends on, not only the one being changed.
- **Restore at the end, and verify the restore** — `bash local-ops/kv-flags.sh reset`, then read it
  back on both nodes.

### 12.1 Test A — `MNT-9`: keep it or retire it? (~10 min)

**Decides a live question.** `MNT-9` is mounted, OFF, measured inert, and its ported code is ~60
lines inside `patch6-…py` plus three flags. Retiring it would shrink the KV patch surface; keeping
it costs a boolean read per call. Nothing decides that today.

**Why it needs an arm rather than a log grep** — see the correction in §10. The `CANNOT pin`
warning lives inside `_maybe_pin_static_head()`, which returns early unless `pin_static_head` is
set, so with `MNT-9` disarmed its absence proves nothing.

```bash
# baseline (MNT-9 off, the deployed state) -- ALREADY RUN 2026-09-21, recorded below
python3 local-ops/xsess/session-sim.py 4 300 mnt9-off-a

# arm
bash local-ops/kv-flags.sh pin_static_head 1
ssh shorn@spark-45ea "docker exec $C cat /etc/vllm-kv-flags/flags.json"   # prove the ENGINE sees it
python3 local-ops/xsess/session-sim.py 4 300 mnt9-on-a
python3 local-ops/xsess/session-sim.py 4 300 mnt9-on-b

# what actually answers the question
ssh shorn@spark-45ea "docker logs --since 20m $C 2>&1 | grep -E 'MNT-9'"

# restore, and verify
bash local-ops/kv-flags.sh pin_static_head 0 && bash local-ops/kv-flags.sh
```

**Baseline already measured (2026-09-21, engine idle, `pin_static_head: 0`):**

| arm | turn 0 | verdict |
|---|---|---|
| `mnt9-off-a` | cold head, `in=27,294`, `cached=None` | **ALIVE, hit 99.5%, 27,648 tok, 0.49s, clean** (47s total) |

That reproduces §9's post-`MNT-6c` figure exactly, so the baseline is sound and only the armed arms
are missing.

**How to read the result.**

| what the log shows | what it means | verdict |
|---|---|---|
| `MNT-9 … CANNOT pin` still appears | the required run is still not fully cached even with `MNT-6c` | **retire** — it cannot do its job |
| pins logged, head survival unchanged (~99.5%) | it works and buys nothing, which is §6's result at a second condition | **retire** |
| pins logged, head survival or timing better than baseline | the one outcome that justifies keeping it | **keep**, and consider arming |

Two arms is enough to retire, not enough to keep: a "better" reading needs three per side.

### 12.2 Test B — `MNT-10`: what does the cap cost when nobody is being protected? (~15 min)

**This decides whether the adaptive controller is worth building.** §10's dose-response measured the
*victim's* side of the trade. The other side — the cap taxing a prefill that is starving nobody —
was only ever read off the attacker column: **82.8s at cap 0 against 95.8s at 1024, +15.7%**, one
context size, n=1.

The controller idea is one line: `cap = 0 if num_requests_running <= 1 else 1024`. It is worth
building only if that penalty is real, repeatable, and grows with context.

```bash
# NOTE the arms are EXPLICIT. Do not use `reset` to mean "1024" -- see 12.5.
for cap in 0 1024 2048; do
  bash local-ops/kv-flags.sh long_prefill_token_threshold $cap
  # 3 uniquely-stamped (uncached) prefill-only requests at each of ~40K, ~140K, ~400K tokens,
  # max_tokens=1, engine otherwise idle; record TTFT per request
done
bash local-ops/kv-flags.sh reset   # removes the key -> boot value
```

`local-ops/starve-test.py` already builds uniquely-stamped attacker prompts (`ATTACK_WORDS`); the
solo measurement is that generator with the victim thread removed, so extend it rather than writing
a new one.

**Record:** cap, context tokens, TTFT, and `engine_cached_tokens` (`API-14`) to prove each prompt
was genuinely cold. **Decide:** if the penalty at `Running==1` is under ~5% it is noise against
burst variance and the controller is not worth the global-state risk; at 15%+ and rising with
context, build it.

### 12.3 Test C — `MNT-8` / `MNT-8b` under manufactured pressure (~40 min)

**The highest-value open item (§10 item 4), and idle time is its precondition** — it needs the whole
pool, and the earlier null is void precisely because the pool was idle and nothing competed.

The point is not "run it again on an idle box". It is that an idle box lets you *build* the
co-tenant deterministically instead of waiting for one:

1. create a victim head cold — `session-sim.py`, which stamps a unique system prompt;
2. drive eviction with `local-ops/cache-pressure/cache_pressure.py` (or `kvpressure.py`) until the
   pool has cycled well past the victim's head — the §8 pressure test needed ~1.1M tokens of
   unrelated traffic to kill a head;
3. probe the victim head: alive or dead;
4. repeat with `free_queue_prepend_uncached` flipped.

`MNT-8`'s claim is about **ordering** — uncached scratch pages to the front of the free queue,
cached ones to the back — so the measurement must be head **survival under eviction**, never
throughput. Run at least 3 reps per arm; a single survival verdict is a coin flip.

**If both arms survive**, the pressure was not enough — raise it until the control arm dies, then
compare. An arm where nothing dies measures nothing, which is the mistake §6 made.

### 12.4 Test D — retention re-measure (~30-60 min, no flags touched)

`status/CONFIG.md` carries **457,079 tokens retained at `PROTECTED_FRACTION=0.50`**. That predates
`MNT-6c`, which changed what recycling does to cache entries — so the number describes code we no
longer run.

```bash
python3 local-ops/cache-pressure/cache_pressure.py --kv-size <tokens from the boot log>
# GPU KV cache size / 'Maximum concurrency' line:
ssh shorn@spark-45ea "docker logs $C 2>&1 | grep -m1 'GPU KV cache size'"
```

No flag writes, no restart — only load. Update `status/CONFIG.md` with the new figure and the date,
and say explicitly that it is a post-`MNT-6c` measurement.

### 12.5 Trap: the deployed `long_prefill_token_threshold` is **2048**, not 1024

Found while preparing these arms, and it invalidates the obvious shortcut of treating "no key in the
flags file" as "1024":

- the **running container's command line** carries `--long-prefill-token-threshold 2048`;
- the engine's own `MNT-10` log line says `(boot value 2048)`;
- the flags file has **no** `long_prefill_token_threshold` key, so the effective value falls through
  to the boot value — **2048 today**;
- `docker-compose.dspark.yml:301` now reads `${LONG_PREFILL_TOKEN_THRESHOLD:-1024}`, so **1024
  arrives at the next restart**, not before.

Several docs said 1024 was deployed. They were describing the next boot, not the running engine.
Corrected in `status/CONFIG.md`. Since §"1024 vs 2048 is a TIE" in
[`PATCHES-KV.md`](PATCHES-KV.md) found the two indistinguishable on real traffic, nothing needs to
be done about it — but **an arm that assumes key-absent means 1024 is measuring 2048.**

## 13. Per-request `cache_salt` — researched 2026-09-21, and it does the opposite of what it sounds like

Asked: *we pass client certs through the mTLS proxy; could a per-tenant `cache_salt` be used to make
sure each tenant gets enough cache?*

**Short answer: `cache_salt` is an isolation feature, not an allocation one. Using it for fairness
would cost cache, not buy it.** What is true, and worth keeping, is the *tenant identity* half of
the idea.

### 13.1 What is actually in this build

| layer | supports `cache_salt`? | where |
|---|---|---|
| engine core (`Request`) | **yes** | `vllm/v1/request.py`, `v1/engine/*` |
| block hashing | **yes** | `kv_cache_utils.py:556` — added to the extra keys **only when `start_token_idx == 0`** |
| OpenAI chat endpoint | **yes** | `entrypoints/openai/chat_completion/protocol.py:386`, validated non-empty |
| **Anthropic endpoint** | **NO** | no field on `AnthropicMessagesRequest`, and `_build_base_request()` (pristine `serving.py:349`) does not pass one |

So it is unreachable from Claude Code today — the client speaks Anthropic. Adding it is mechanically
easy: `create_messages` already receives Starlette's `raw_request`, so
`raw_request.headers.get(...)` is in scope at the exact point `chat_req` is built.

**Salting block 0 partitions the whole prefix**, not just the first 256 tokens:
`hash_block_tokens()` folds `parent_block_hash` into every block, so once block 0 diverges the
entire chain does.

### 13.2 Why it cannot "ensure a tenant gets enough cache"

1. **It changes hash keys, not eviction policy.** A salted tenant's blocks sit in the same LRU and
   are evicted exactly as readily. Nothing about a salt reserves capacity.
2. **It removes sharing we currently get for free.** Two Claude Code clients on the same version
   send a byte-identical tools+system head — today that is **one** cached copy. Salted per tenant it
   becomes one copy *each*, and the pool holds less distinct context, not more.
3. **`MNT-7` cannot claw that back.** Its commit-time dedupe keys on `(block_hash, group_id)`
   (`patch7-block_pool-dedupe.py:290`). Salted copies have genuinely different hashes, so they are
   not duplicates by its definition and will not be collapsed.

Salt earns its keep when **isolation is the requirement** — its docstring is explicit that it exists
to stop an attacker guessing another tenant's prompts by timing. That is a real thing to want on a
multi-tenant box, and it is a separate decision from capacity.

### 13.3 The half of the idea that IS worth keeping

The useful part is not the salt, it is **a stable per-tenant identity arriving with the request**.
Given one, the mechanism that could actually reserve capacity is the one already written and
mounted: `MNT-9` pins a head in a budget **reserved** from `MNT-6a`'s, and that budget is currently
divided per **KV manager** (`head_pin_fraction / _num_managers`) — not per tenant. Keyed by tenant
instead, tenant A's head could not be evicted by tenant B's traffic. That is a genuine fairness
mechanism built from parts we already have.

**It should not be built yet**, for two reasons that are in this document:

- `MNT-9` measured **inert** on head survival (§6), and `MNT-6c` made the head survive without it
  (§9). There is currently no observed cross-tenant eviction to fix. Test C (§12.3) is what would
  produce that evidence, and §10 item 4 already names it as the trigger.
- The mTLS `vllm-proxy` is **not in this repo**, so what it injects is unverified from here. Any
  design rests on it presenting a stable per-tenant header, which needs checking first.

**If it is ever built, do not reach for the salt to do it.** Reserve with a pin budget, which keeps
the cross-tenant *sharing* that a salt would destroy, and add the salt only if isolation becomes a
stated requirement in its own right.

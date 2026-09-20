# Cross-session prefix reuse — investigated 2026-09-19

> ## SUPERSEDED IN PART — read this first
>
> The headline below ("there is no defect; it already works at 99.7%") is **WRONG for real
> sessions**. Every 99.7% in this document came from *synthetic probes*, and two probes that
> looked like proof were in fact **cold prefills that re-created the head** (22.31s / 22.48s).
>
> **What real sessions actually do:** n=3 cold heads, session B turn 0 = **0.0% every time**,
> ~26s of prefill discarded. A real multi-turn session's head is unretrievable **2s** after that
> session ends (0.0%, 22.77s, clean), while a probe-written head survives 5+ minutes.
>
> **Read the SECONDS, not the hit%.** ~0.7s = warm, ~20s+ = cold, whatever the ratio says.
>
> The *lookup* findings below still stand on their own controls: the extent rule is disproven,
> lookup is monotone, Patch 6 is uninvolved, vllm#42948 does not apply, and the one-block eagle
> pop is real and correct. The generalisation from probe to session is what failed.
>
> Current write-up: the "Cross-session prefix reuse" section of `CLAUDE.md` and the
> 2026-09-19 entry in `STATUS.md`.


**Headline: there is no cross-session reuse defect. The premise this work was
built on is wrong, and the thing it wanted to achieve already happens.**

A brand-new session replaying onto a previous session's head measures
**99.7% — 36,608 of 36,723 tokens, 0.66s against 25.7s cold.** No restart, no
server change, no primer. Three clean measurements, no contaminated row used.

Two claims were tested and both failed:

| claim | verdict |
| --- | --- |
| "A request reuses a cached prefix only if it matches the cached request's ENTIRE cached extent. One block short and it gets zero." | **FALSE.** Lookup is monotone: reuse is `floor(shared/256)*256`, a clean staircase. 0 of 26 measured points returned zero. |
| "Sessions pay a full cold prefill because session 1's extent runs past the shared head, so session 2 falls short and gets nothing." | **FALSE.** The mechanism that was supposed to fail works. What the live captures actually show is **eviction**. |

Nothing here needed a restart, and none was taken.

---

## R1 step 1 — the extent rule, re-measured

Tool: `local-ops/xsess/extent-probe.py`. It drives `/v1/completions` with a
**token-id array** prompt, so the divergence point between A and B is placed to
the exact token — no chat template, no tokeniser round-trip, no serving-patch
transform in the way.

Block arithmetic under test: a request of `n` tokens caches
`E(n) = floor((n-1)/256)*256` (`max_cache_hit_length = request.num_tokens - 1`
in `kv_cache_manager.py:219`, then block alignment at `block_size = 256`).

B shares A's first `n_A - D` tokens, then diverges and runs on longer. With
`r = (n_A - 1) mod 256`, the two candidate models agree for `D <= r+1` and
disagree for everything larger — monotone predicts a staircase, all-or-nothing
predicts a cliff to zero. That disagreement is the whole experiment.

`n_A = 12,000`, so `E(A) = 11,776` and `r = 223`. Two independent seeds gave
identical numbers:

| D | shared | monotone predicts | all-or-nothing predicts | **measured** |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 11,999 | 11,776 | 11,776 | **11,776** |
| 100 | 11,900 | 11,776 | 11,776 | **11,776** |
| 224 | 11,776 | 11,776 | 11,776 | **11,520** |
| 225 | 11,775 | 11,520 | **0** | **11,520** |
| 300 | 11,700 | 11,520 | **0** | **11,520** |
| 512 | 11,488 | 11,264 | **0** | **11,264** |
| 1,000 | 11,000 | 10,752 | **0** | **10,752** |
| 2,000 | 10,000 | 9,984 | **0** | **9,984** |

Every point is `floor(shared/256)*256`. **Nothing returned zero.**

The boundary formula was then tested by *moving* the boundary — `n_A` chosen so
`r` is 1, 64 and 200 in turn. A fixed ~200-token tolerance cannot track that;
the block arithmetic can, and did, at all three.

**The 56-vs-57-block containment test**, which produced the original
"14,336 vs 0" observation, re-run with exact tokens: **14,080 in both arms.**
Not 14,336-then-zero. Both arms lose exactly one block, which is the next point.

### The one real effect: exactly one block, and it is the MTP eagle pop

When B's shared run ends exactly on A's full cached extent (`D = r+1`), the
result is one block — 256 tokens — short. It is never more than that, and the
loss is bounded at 256 tokens regardless of prompt size (0.7% of a 36K head).

Attributed in the simulator below: with `use_eagle=False` every point matches
monotone exactly; with eagle on every point loses exactly 256 tokens. The line is

    vllm/v1/core/single_type_kv_cache_manager.py:597
    FullAttentionManager.find_longest_cache_hit
        if use_eagle and computed_blocks[0]:
            # Need to drop the last matched block if eagle is enabled.
            for computed in computed_blocks:
                computed.pop()

reached because `speculative_config.num_speculative_tokens = 5` (MTP) makes
`use_eagle` true. **This is correct upstream behaviour, not a defect**, and it
is not worth touching: the cost is one block.

## R1 step 2 — two real sessions

Two real captured Claude Code first turns from different sessions in this repo
(`nolsp-false-a`, `nolsp-false-b`):

- **90,501 of 91,091 rendered chars shared — 99.352%.**
- They diverge only inside `msg[0].user.text[2]`, at char 82 of the last 482.
- `tools` hash and normalised `system` hash are **identical** across the two.

Replayed back to back (`local-ops/xsess/xsess-probe.py`). Retrying naively is a
trap — the first replay caches B, so every retry reads B's own footprint back at
~100%. The probe instead builds a **fresh "session B" per attempt by perturbing
only the divergent tail**, leaving the shared head byte-identical:

```
[0] A (prime)             0.77s  in= 36,690  cache 36,608/36,690 = 99.8% hit
[0] B' (new session)      0.66s  in= 36,723  cache 36,608/36,723 = 99.7% hit  CLEAN
[1] B' (new session)      0.65s  in= 36,723  cache 36,608/36,723 = 99.7% hit  CLEAN
[2] B' (new session)      0.66s  in= 36,723  cache 36,608/36,723 = 99.7% hit  CLEAN
```

3 of 3 clean (`queries == input_tokens`), 0 contaminated rows used.

**The prize, measured:** 36,608 tokens of prefill, **25.7s → 0.66s (~39x)** on a
quiet engine. The live captures' cold turn-0 took 26.44s and 24.36s, consistent.

## So why did the live capture show 0%?

Session b's turn 0 measured **0.0%** — 62 seconds after session a's last turn,
with the same tools and system hashes. Since the replay proves the heads are
compatible, the blocks were **gone**, not unmatched.

Corroborating, in session a's *own* capture: turn 3, 68,414 tokens,
**0.0% hit, 41.08s**, flagged `[EVICTION?]` by `matrix-report.py` (prefix-diff
saw ~95% shared). Eviction mid-session, at 68K context, on this cluster.

Pool context from the boot log: **16,891 blocks across 5 KV groups** (group 0
MLA, groups 1–4 sliding-window), 2,506,935 tokens, Patch 5 protected cap 1,689
blocks per group at `PROTECTED_FRACTION=0.50`.

**Retention, not lookup, is the whole problem** — which is territory already
mapped in CLAUDE.md ("Prefix-cache retention — measured, and how to tune it").

### Survival of a ~36K head — measured

`local-ops/xsess/survival-probe.py`. Prime with a real captured first turn, then
re-probe with a fresh tail (so the probe never reads its own footprint back).

| t (min) | hit | tokens reused | latency | delta status |
| ---: | ---: | ---: | ---: | --- |
| 0.5 | **99.8%** | 36,608 | 0.73s | clean |
| 1.0 | **99.8%** | 36,608 | 0.78s | clean |
| 2.0 | **99.8%** | 36,608 | 0.69s | clean |
| 5.1 | 90.1% | 142,848 | 65.65s | **BLENDED x4.3 — discarded** |
| 8, 15, 25, 40 | — | — | — | **lost: the engine died at 14:01 (see below)** |

**The run is truncated and only 3 points are usable.** A ~36.6K head was still
**fully resident at 2 minutes** under live load from the other client
(~145K tokens/min of other traffic between samples). Beyond that the curve was
destroyed: the engine died of an NCCL collective timeout at 14:01 while the
probe had a request in flight (that request shows as 1,042s / 0 hits), and the
cluster then boot-looped until 16:10 for an unrelated reason (four concurrent
watchdogs — see `STATUS.md`).

**So the survival curve is NOT established.** What is established is that
retention out to 2 minutes was perfect on this occasion, which does *not*
explain the live capture's 0% at 62 seconds. Re-run it on a quiet window before
drawing any conclusion about refresh cadence.

**Caveat, stated plainly: this is load-conditional, not a constant.** It is one
run, on one afternoon, against whatever the other client happened to be doing.
It does not explain the 62-second eviction in the live capture by itself, and I
have not reproduced that eviction on demand. The honest statement is: lookup is
exonerated; retention is variable and sometimes loses a head inside a minute.

## R1 step 4 — subagent and compaction

Re-reported from existing captures, no new sessions.

| trigger | finding |
| --- | --- |
| **Subagent** (`p2-subagent-false`) | The child is a genuinely different head — **14 tools vs 23**, different system hash — so its cold turn 0 is not this defect at all; there is nothing to reuse. The parent resumed afterwards at **98.9% of its achievable ceiling**. No action. |
| **Resume** (`p2-resume-false`) | The turn after the resume diverges at `msg[0].user.text[0]` with a changed system hash, and still measured **89.0%**; the next turn 91.5% (100% of ceiling). Resume is cheap. |
| **`/compact`** | Rewrites the head by design. Unchanged from the existing CLAUDE.md note. |

---

## R2 — root cause by simulation

`local-ops/kvsim/sim.py` + `run.sh`. Runs in a throwaway container from the
serving image with **no GPU, no engine, no weights**, in seconds:

```bash
local-ops/kvsim/run.sh              # stock image file (control)
local-ops/kvsim/run.sh patch6       # with patches/patch6-... bind-mounted
RECYCLE=0 local-ops/kvsim/run.sh patch6
FRACTION=0.30 local-ops/kvsim/run.sh patch6
SIM_USE_EAGLE=0 local-ops/kvsim/run.sh
```

Topology mirrors the running engine: 1 MLA full-attention group + 4
sliding-window groups (windows 32,768 / 32,768 / 524,288 / 262,144, read off the
Patch 5 boot lines), block 256, pool 16,891, `max_model_len` 1,048,576.

**Result — the simulator reproduces the live behaviour**: a monotone staircase,
uniformly one block low with eagle on, **0 of 9 points returning zero**.

### Patch 6 A/B — irrelevant to lookup

| run | patch6 mounted | `VLLM_SWA_RECYCLE_SKIPPED_BLOCKS` | `..._PROTECTED_..._FRACTION` | result |
| --- | --- | --- | --- | --- |
| 1 | no (stock) | — | — | monotone − 1 block |
| 2 | yes | 1 | 0.50 (production) | **identical, row for row** |
| 3 | yes | 0 | 0.50 | **identical** |
| 4 | yes | 1 | 0.30 | **identical** |

Patch 6 changes nothing about lookup — consistent with its diff, which touches
only the eviction/protection side (`_protect_prompt_blocks`,
`remove_skipped_blocks`) and never `find_longest_cache_hit`. **Do not remove or
re-tune Patch 6 on account of prefix reuse.** Whatever it does or does not do
for retention is a separate question this did not test.

### Eagle A/B — names the line

| `use_eagle` | every point |
| --- | --- |
| True (production: MTP k=5) | monotone − 256 tokens |
| False | **exactly monotone** |

### vllm#42948 does not apply to us

The hybrid intersection cascade is **not** collapsing on this build. Reading the
image's `HybridKVCacheCoordinator.find_longest_cache_hit`, this fork already
carries explicit repairs for the known 0%-hit modes — the SWA cache-block mask
is deliberately disabled inside eagle attention groups (*"yields 0 % hit rate"*),
and the `lcm_block_size` truncation in `cache_blocks` was removed per vLLM
PR #41834 (*"for hybrid KV it dropped tail blocks so nothing became reusable"*).
**No upstream report should be filed from this investigation** — we cannot
reproduce the defect, and our tree is already patched against its neighbours.

---

## R3 — the fix

**No fix is warranted, and nothing should be deployed.**

1. No module-level fix: there is no defect in the bind-mountable modules. The
   only measurable lookup effect is a correct, bounded, 256-token eagle pop.
2. No upstream report: #42948 does not reproduce here.
3. No primer, synthetic or otherwise: the user ruled it out, and it is moot —
   normal cross-session reuse already delivers 99.7%.

If session start latency is pursued further, the target is **retention under
concurrent load**, and the existing levers are already documented:
`PROTECTED_FRACTION` (0.30 → 0.50 measured a near-linear retention gain), pool
size via `GPU_MEMORY_UTILIZATION` (**capped at 0.86 — must not be raised**), and
Patch 7's commit-time dedupe (3.9x). Any of those needs a restart and therefore
a fresh, explicit approval.

---

## Traps found and paid for, so they are not paid for twice

- **Retrying a cache measurement with the same B is worthless.** The first
  attempt cached B; the retry reads B's own footprint and reports ~100%. It
  produced a 12,288-hit reading on an 11,000-token shared prefix before it was
  caught. Both probes here regenerate a fresh B per attempt.
- **`vllm:gpu_cache_usage_perc` reads 0.0 on this build** even under load —
  unusable as a pressure signal, exactly like `vllm:num_requests_running`. Use
  `vllm:prompt_tokens_total` deltas for traffic instead.
- **The offline harness goes superlinear above ~6K tokens** (6K ≈ 1s, 8K > 90s)
  even with chunked allocation, so `sim.py` runs at `n_A = 6,000`. The block
  arithmetic under test is scale-free and the live probes cover the real sizes.
- **A sliding window of 4,096 in the simulator is not a harmless simplification**
  — it puts the SWA manager into its skipped-block path and hangs. Use the real
  per-group windows.
- **`local-ops/baseline-20260914/pristine-single_type_kv_cache_manager.py` was
  the PATCHED file** (1,504 lines, contains `_RECYCLE_ENABLED`, byte-size
  identical to `patches/patch6-...py`), captured through the bind-mount.
  **Fixed 2026-09-19**: replaced with the genuine 1,421-line image file; the old
  one kept as `MISLABELLED-was-patched-...py`. See `PRISTINE-README.md` there.

## Artefacts

| path | what |
| --- | --- |
| `local-ops/xsess/extent-probe.py` | exact-token extent/staircase probe (`--sweep`, `--cliff`, `--extent`) |
| `local-ops/xsess/xsess-probe.py` | cross-session reuse probe, fresh-B-per-attempt |
| `local-ops/xsess/survival-probe.py` | head survival curve under live load |
| `local-ops/xsess/extent-*.json`, `xsess-result.json`, `survival.json` | raw measurements |
| `local-ops/xsess/image-src/` | genuine image copies of the four core KV files |
| `local-ops/kvsim/sim.py`, `run.sh` | offline container reproduction + A/B matrix |


---

## Phase A, 2026-09-19 — the client gap closed, and the suspect narrowed to MULTI-TURN

No restart. Same boot (`StartedAt 2026-09-19T14:04:41Z`, `RestartCount=0`).
`cache-probe.py --selftest` 3/3 PASS beforehand.

### A1 — headers, finally recorded

`prompt-tap.py` recorded only `{ts, path, body}`. It now records `headers` as well, minus
`authorization` / `x-api-key` / `proxy-authorization` / `cookie`. A real session sends:

```
POST /v1/messages?beta=true
anthropic-beta: claude-code-20250219,interleaved-thinking-2025-05-14,
                context-management-2025-06-27,prompt-caching-scope-2026-01-05
anthropic-version: 2023-06-01
X-Claude-Code-Session-Id: <uuid, unique per session>
User-Agent: claude-cli/2.1.104 (external, cli)    x-app: cli    X-Stainless-*
```

Body: 4 `cache_control: ephemeral` blocks, `context_management.clear_thinking_20251015`,
`thinking: enabled (31999)`, `metadata.user_id` carrying a per-session `session_id`. No `cache_salt`.

Note the tap forwards only `content-type` / `anthropic-version` / `anthropic-beta` / `accept`, so
`X-Claude-Code-Session-Id` never reaches the engine in a tapped session — and tapped sessions still
fail. It was never a candidate.

### A2 — the beta path is acquitted

`transport-probe.py`, four arms, all direct to the engine (transport held constant):

| arm | path | headers | hit | secs |
| --- | --- | --- | ---: | ---: |
| control | `/v1/messages` | minimal | 99.6% | 0.77s |
| beta-path | `/v1/messages?beta=true` | minimal | 99.6% | 0.76s |
| beta-header | `/v1/messages` | + `anthropic-beta` | 99.6% | 0.77s |
| full-live | `/v1/messages?beta=true` | full captured set | 99.6% | 0.76s |

41,984 hits on 42,166 input in every arm, `queries == input_tokens` on every row. The `cache_salt`
theory (`kv_cache_utils.py:524-532`) is disproven from outside: nothing client-reachable sets one.

### A3 — single-turn survives; multi-turn is the trigger

`death-probe.sh 2 workload-trivial.txt <tag>` — one prompt, no tools, unique head per run.

| run | turns | probe at +2s | verdict |
| --- | --- | --- | --- |
| a3single | 1 | 99.6%, **0.57s**, clean | ALIVE |
| a3single2 | 1 | 99.6%, **0.57s**, clean | ALIVE |
| prior multi-turn | 6 | 0.0%, **22.77s**, clean | dead |

**Outstanding:** the same-sitting multi-turn control was stopped at the user's request (our probes
were evicting a co-tenant's cache). Re-run before building on this:

```bash
bash local-ops/xsess/death-probe.sh 2 local-ops/toolsearch-matrix/workload-a.txt a3multi
```

Next cheapest step after that: a turn-count staircase (1/2/3/6 turns, one probe each) to find the
threshold. Both are restart-free. Phase B (`enable_kv_cache_events`) remains unauthorised.

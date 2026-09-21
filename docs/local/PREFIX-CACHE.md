# PREFIX-CACHE.md — retention, stability, and the cross-session hole

Everything measured about this engine's prefix cache: how much it retains and how to tune that,
which client settings move the prompt head, why the reasoning-effort prefix is a *position*
problem, what cross-session reuse does and does not do, and the measurement traps that have
invalidated work here more than once.

The patches this evidence justifies are `API-11a`, `API-11b`, `API-12`, `API-13` (see
`PATCHES-API.md`) and `MNT-6a`, `MNT-7` (see `PATCHES-KV.md`).

**Read the measurement traps at the bottom before trusting any number you take yourself.**

> Moved verbatim from `CLAUDE.md` and `STATUS.md` during the 2026-09-20 doc split. Where a line was found stale
> on the way across it was corrected in place and the correction is marked **CORRECTED**.

## Prefix-cache retention — measured, and how to tune it (2026-09-14)

**Retention under pressure is capped by `MNT-6a`'s protected-block cap, not by KV cache size.**
(Called "Patch 5" before 2026-09-20 — a collision with the detokenizer guard, now fixed; see
[`PATCHES-KV.md`](PATCHES-KV.md).)
Two measured points, model confirmed to within 2.5%:

| `PROTECTED_FRACTION` | cap (blocks/group) | retained tokens | retained blocks | ratio |
| ---: | ---: | ---: | ---: | ---: |
| 0.30 (old default) | 1,022 | 280,690 | 1,096 | 1.07 |
| **0.50 (current)** | **1,707** | **457,079** | 1,785 | 1.05 |

So **retained ≈ protected cap + ~5-7%**. Raising the fraction raises retention near-linearly.
Extrapolate before testing, do not assume it continues past 0.5.

**The env key is `PROTECTED_FRACTION`, not the container's variable name.** The compose maps
`VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION: "${PROTECTED_FRACTION:-0.30}"`. Setting the long name in
`.env.dspark` is silently ignored (it cost a wasted restart on 2026-09-14). Confirm with
`docker compose --env-file .env.dspark -f ... config | grep PROTECTED` before restarting.

**The `MNT-6a` cap line logs on first real prompt allocation, not at boot.** To surface it, send a
prompt of ~30K+ tokens, then
`docker logs <container> | grep "protected prompt block cap"`.

**Trade-off, untested at concurrency.** Protected blocks are withheld from new allocations. The
retention benchmark is *sequential* (one request at a time), so its zero-preemption result does
**not** prove 0.50 is safe for 2 concurrent 1M sessions. Watch `vllm:num_preemptions_total` in
normal use; if it climbs, drop back toward 0.30. `MNT-6a` exists because the unbounded legacy caps
(8,192 / 32,768 per group against a ~17,000-block pool) let protection swallow the pool.

**Benchmark harness:** `local-ops/cache-pressure/` (from
[co-l/cache-pressure](https://github.com/co-l/cache-pressure)). Hydrate N unique 8K contexts to
overflow the cache, re-send in reverse order, first miss = retained capacity. Contexts are seeded,
so runs are byte-identical and A/B-comparable:

```bash
python3 local-ops/cache-pressure/cache_pressure.py --base-url http://127.0.0.1:8888/v1 \
  --kv-size <GPU KV cache size from boot log> --output run.json
python3 local-ops/cache-pressure/cache_pressure.py --compare fix.json control.json
python3 local-ops/cache-pressure/needle_test.py --base-url http://127.0.0.1:8888/v1 --salt 20260914
```

Always pass the **current boot's** `--kv-size`; the pool varies per boot. Compare **absolute
retained tokens**, not percentages — the denominator moves between boots.

## Prefix-cache stability — the client settings that decide it (measured 2026-09-19)

Patch 11 fixed the two server-side head-movers. Everything left is **client-side**, and one setting
carries almost all of it. The full evidence, tables and caveats are in the next section
("Prefix-cache stability measured end to end"); this is the operational summary.

**A moved prompt head costs minutes.** A cold 54K prefill measured 194s where the same prompt warm
measured 0.9s. Anything that changes a byte before position N throws away the cache for everything
after it.

### Run it like this

```bash
ENABLE_TOOL_SEARCH=false          # or just leave it unset; `auto` measured identical
# and disable the swift-lsp plugin for this repo (see below)
```

Measured over 16 turns in two workloads: **0 head moves, 100% strict prefix, every turn at ~99.8%
of its achievable cache hit.**

### The one thing that actually moves the head

**The `swift-lsp@claude-plugins-official` plugin.** It attaches a few seconds into every session,
and it **flaps** — one 16-turn session saw `+LSP`, `-LSP`, `+LSP`, three full re-prefills. It shows
up differently depending on the mode but costs the same either way:

| mode | how LSP arriving shows up |
| --- | --- |
| `false` / unset | the `tools` array goes 23 → 24 |
| `true` | the array stays at 9, but the deferred-tool NAME LIST inside `msg[0].user` goes 10 → 11 |

Disable it in `~/.claude/settings.json` (`"enabledPlugins": {"swift-lsp@…": false}`), or per-session
with `--settings`. `claude --bare` also skips LSP, along with hooks, plugins and CLAUDE.md
auto-discovery.

> **This is a judgement call, not a universal setting.** `swift-lsp` is Swift tooling and this is a
> Python/shell repo, so it buys nothing here. In a Swift project the honest trade is "one full
> re-prefill per session" against "no language server" — decide per repo, do not copy this blindly.

### Do NOT turn on tool search to fix this

`ENABLE_TOOL_SEARCH=true` looks attractive (9 tools instead of 23, ~10K smaller prompt) and the
earlier one-off observation that it "froze the tool set" was simply a session where nothing was
discovered. **It does not freeze anything.** A `ToolSearch` hit **adds the found tool to the
declared `tools` array** (measured: 9 → 10, `+NotebookEdit`), which moves the head exactly as the
full set does — so it costs one full re-prefill *per discovery*, where `false` costs none.

**It also costs more turns, not fewer.** Ten prompts each needing one deferred tool
(`local-ops/toolquality.py`): quality is at parity (6/10 vs 7/10 correct — noise at n=10), but
`true` took **94 turns against 45**, one case going 10 → 41, and completed 9/10 against 10/10. It
loses on cache stability *and* on cost, and wins nothing.

And it cannot be fixed at the server: a `tool_reference` block carries the tool **name and no
schema** (`local-ops/toolref-probe.py`). Both shapes return 200 — nothing is broken — but the model
cannot call a tool from a reference; it just re-runs `ToolSearch`. The thing that makes a discovered
tool callable is its arrival in the `tools` array, which *is* the head move. **No `tool_reference`
server fix is warranted.**

### Other seams, measured

| seam | verdict |
| --- | --- |
| `--resume` | **Safe.** The turn after a resume was a strict prefix at 95.8%. Upstream [#27048](https://github.com/anthropics/claude-code/issues/27048) does not reproduce here. |
| `/compact` | Rewrites the head — but that is what compaction is. 72.9K restarted at 38.5K. |
| Subagents (`Agent`) | **Harmless.** The child is its own conversation; after 8 child turns the parent resumed at 99% of its ceiling. |
| MCP (`ENABLE_CLAUDEAI_MCP_SERVERS=true`) | 23 → 39 tools, array stable over 4 turns. [#92033](https://github.com/anthropics/claude-code/issues/92033) did not reproduce, but 4 turns is weak evidence. Stays off. |
| **Mid-session tier switch** | **Expensive — 122s on a 68K context.** Not only the effort prefix at index 0: Claude Code puts the **model name in its system prompt**, so the system block changes and the whole head is rewritten. Do not mix tiers in one conversation. |

### A live session measured end-to-end from the server log alone (2026-09-19)

70 minutes of real interactive traffic, 11 concurrent conversations, analysed with
`prefill-attribute.py` — **no tap, no probes, no load added**:

| conversation | reqs | span | chars | head stable? |
| --- | ---: | --- | --- | --- |
| `fe9a3621a5e6` (the live session) | 69 | 15:05-16:14 | 323,411 → 360,718 | **yes, all 69** |
| `b86e48066a1d` | 3 | 15:32-15:36 | 576,487 → 580,607 | yes |
| `5bd55f3d2019` | 9 | 15:13-16:13 | 142,800 → 213,006 | yes |

For `fe9a3621a5e6`: **59 cached HIT turns, 8 partial, 2 full-prefill MISS** — the misses at
15:08:33 (98,694 prefill tokens on a ~90,820-token prompt) and 15:25:01 (179,150 in the window,
no other conversation nearby).

**The head never moved, so those two turns were EVICTED, not invalidated.** This is the
`[EVICTION?]` signature: a strict-prefix prompt that still re-prefills. KV usage oscillated
34-55% of the 2,510,942-token pool and `num_preemptions_total` stayed 0, so it is not gross
exhaustion — it is prefix-cache block turnover under 11 concurrent conversations, two of them
above 150K tokens.

> **Two traps this run walked into, both worth knowing.**
>
> 1. **`prefix-watch.py` does not parse `docker -t` timestamps** — it stamps lines with its own
>    wall clock, so a backfilled log collapses to one instant and "0.0s since last seen" is
>    meaningless. Use `prefill-attribute.py` (or the raw log) for anything time-ordered.
> 2. **The documented `user0` collision is not theoretical.** Probe traffic and short-first-message
>    sessions pile into one bucket: here `1bf734cbb2a0` mixed `cache-probe --selftest`, the A2 beta
>    arms and two A3 sessions, and reported four "HEAD MOVED" alerts that belonged to **no single
>    conversation**. Check `len` grows monotonically before believing a bucket is one session.

### The effort prefix is a POSITION problem, not a content problem (2026-09-19)

**What it actually is.** Not a different system prompt, and not a chat-template field —
`deepseek_v4_encoding.py:274-277` concatenates raw text onto the front of the rendered prompt,
*ahead of even the system role marker*:

```python
last_user_idx = find_last_user_index(messages)        # already computed, 3 lines above
...
if index == 0 and thinking_mode == "thinking":
    prompt += REASONING_EFFORT_PROMPTS[effort]        # bare text, position 0
if role == "system":
    prompt += system_msg_template.format(content=content or "")
```

`low` is `''`, so only `high` (+79 tok) and `max` (+92 tok) produce anything.

**Measured on a real captured Claude Code turn-0** (27,531 chars of system, 24,857 tokens),
`/tokenize` only — no GPU:

| arm | tokens | shared prefix vs `low` | reuse |
| --- | ---: | ---: | ---: |
| sonnet tier (`low`) | 24,857 | 24,857 | 100% |
| **opus, prefix at FRONT (today)** | 24,936 | **1** (just BOS) | **0.00%** |
| **opus, same text at the END** | 24,936 | **24,854** | **99.99%** |

A tier switch recomputes **24,856 of 24,857 tokens today, 3 if moved**. Identical text, identical
token count — the 79 tokens cost ~25K tokens of prefill purely because of *where* they sit.

> **The obvious implementation is WRONG.** Attaching the text to the last user *message* breaks the
> append-only property: at turn N it renders inside `userN`, and at turn N+1 `userN` no longer
> carries it, so every turn diverges at the previous turn's user message. That trades a
> per-*switch* cost for a per-*turn* cost — strictly worse than today.
>
> **Correct placement: after ALL messages, immediately before the assistant generation marker, as a
> standalone tail that never enters the conversation history.** Then `userN` renders identically in
> every turn, the shared prefix runs to the end of the last user message exactly as it does now, and
> only ~80 tail tokens fall out of cache per turn — which is already the case today for the
> generation marker.

**PILOT RESULT (2026-09-19, n=3, `local-ops/hmmt-effort-20260916/hmmt_tail.py`): the instruction
LANDS from the tail — and on the hard problem it lands TOO HARD.**

Tested with no patch and no restart: `reasoning_effort:"low"` makes the encoder inject nothing,
then the byte-identical `high` text is appended to the end of the user message
(`--verify-text` confirms the copy matches the image's table).

| arm | correct | truncated | out tokens | think chars |
| --- | --- | ---: | ---: | ---: |
| `off` | 1/3 | 1 | 26,520 | 0 |
| **`high-front`** | **3/3** | **0** | 12,917 | 32,420 |
| **`high-tail`** | **2/3** | **1** | 30,473 | 71,878 |

Per problem:

| # | front think / out / stop | tail think / out / stop |
| ---: | --- | --- |
| 1 | 1,665 / 531 / end_turn ✅ | 1,720 / 662 / end_turn ✅ (+3.3%) |
| 2 | 16,613 / 6,774 / end_turn ✅ | 15,840 / 5,811 / end_turn ✅ (−4.7%) |
| **3** | **14,142 / 5,612 / end_turn ✅** | **54,318 / 24,000 / max_tokens ❌** |

On the two problems that terminated, tail and front are within ±5% on reasoning volume and give
**identical answers** — so the instruction is not ignored at the tail. But on problem 3 the tail arm
produced **3.8x the reasoning** and ran to the cap with no answer, where the front arm answered
correctly. Recency appears to *strengthen* the instruction, and the `high` text at the tail then
behaves like `max` at the front — which is the documented `max` failure mode exactly (runaway to
the cap; `max` measured 8/12 with 33% truncation vs `high` 11/12).

**So the move is NOT a free win.** It buys ~24,853 tokens of prefix reuse per tier switch and may
cost termination reliability. Two things must hold before adopting it.

> **n=1 on the failure, and `temperature=0` is NOT deterministic on this build** — the documented
> control is that the `off` arm produced 0 truncations at a 12k cap and 3 at 24k on *identical*
> prompts. A single truncation is weak evidence on its own. Problem 3 is also the hard one in this
> set: the `off` arm ran away on it too.
>
> **The `low` control arm was missing from the pilot** and has since been added to the harness.
> Without it, "tail reasons as much as front" cannot be fully distinguished from "these problems
> elicit that much reasoning anyway". Run `--arms off,low,high-front,high-tail`.

**PRIOR ART (searched 2026-09-19). Others hit exactly this; nobody had tested the fix.**

| source | what it says |
| --- | --- |
| [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks#111](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks/issues/111) | **Near-identical rig and near-identical diagnosis.** Effort text at ~token 8, full prefix invalidation, **54.5s vs 5.4s at 42k, ~10 min at 500k**, 23.5% token overlap. Proposed three fixes — (1) move the marker to the end near the `<think>` opener, flagged as "the strongest performance fix but alters the model's trained prompt structure"; (2) constant header line with the value placed elsewhere; (3) document the trade-off. **They never tested (1).** They shipped the punt: disable `reasoning_effort` entirely and expose only a thinking toggle. |
| [openai/codex#42996](https://github.com/openai/codex/issues/42996), [NousResearch/hermes-agent#114534](https://github.com/NousResearch/hermes-agent/pull/114534), [#103019](https://github.com/NousResearch/hermes-agent/issues/103019) | **The industry answer is out-of-band, not repositioned.** GPT-6 Astra takes a `configuration_update` input item; Claude accepts `output_config.effort` on an empty `role:"system"` message inside `messages` (beta `mid-conversation-output-config-2026-07-01`), treating effort as a server-side *output* control that is not part of the input cache key. Note hermes' own honest caveat: their A/B could not reproduce a benefit over base on the route available — both preserved cache. |
| [anthropics/claude-code#63962](https://github.com/anthropics/claude-code/issues/63962) | `/effort` warns about a cache miss that does not actually occur on those models. |

**So our pilot is the experiment #111 proposed and did not run — and it explains why they were right
to hesitate.** Their worry was "alters the model's trained prompt structure"; we measured the
consequence: the instruction lands (±5% on the two terminating problems, identical answers) but on
the hard problem it ran 3.8x and never stopped.

**The recency literature predicts exactly this.** Moving the key instruction to the end "leverages
the model's recency bias and greatly improves compliance" — and the overthinking work describes our
failure verbatim: "single-query overthinking escalates to complete failure where the model exhausts
its token budget re-deriving and second-guessing an already-correct answer". Stronger compliance
with "Absolute maximum, no shortcuts permitted" is not what you want on a hard problem.

**Why the out-of-band fix is NOT directly available to us.** For GPT/Claude, effort is a server-side
sampling control. For DeepSeek V4 Flash it is *literally text in the rendered prompt* — we read the
encoder (`deepseek_v4_encoding.py:274-277`). The model was trained with it there. That leaves
#111's option (2) — a **constant header line with the value carried elsewhere** — as the least
explored and most promising direction, and it is untested by anyone so far.

**Not yet justified, and here is what would justify it.** This only pays off if tier switching
actually happens mid-conversation, which we **cannot currently observe** — the model name is in no
log line (see the blind-spot section below). Sequence: log `model=` first, measure how often it
switches, then decide. Further prerequisites if it goes ahead:

- **Re-validate quality.** The HMMT result (`high` 11/12 at 8,243 tokens per correct answer) was
  measured with the text at position 0, which is where DeepSeek's reference encoder puts it.
  Recency usually *strengthens* an instruction, but that is an assumption, not a measurement.
  Harness: `local-ops/hmmt-effort-20260916/`.
- It is **image code**, so it needs a new bind-mounted patch and a restart.
- Deploying it invalidates every cached head exactly once.
- It diverges from the reference encoder, so any upstream parity bench shifts with it.

### API-12's BLIND SPOT: the effort prefix is injected downstream of it (2026-09-19)

**`PREFIX_WATCH` hashes cannot see a tier switch.** Patch 12 hashes `openai_messages` at the end of
`_convert_anthropic_to_openai_request` (`anthropic_serving_inline_system.py:908`). The
reasoning-effort prefix is injected **later**, by `deepseek_v4_encoding.py` at render time, from the
`chat_template_kwargs` Patch 9 derived from the model name. So two requests that differ **only** in
tier produce **identical `head`, `tools` and `sys` hashes** and a completely different prompt.

Measured on the running engine via `/tokenize` (CPU-only, no GPU, no KV — safe mid-session), same
two-message body at each tier:

| tier | `chat_template_kwargs` | tokens | first token ids |
| --- | --- | ---: | --- |
| server default | *(none)* | 21 | `[0, 3476, 477, 260, …]` |
| haiku | `thinking:false` | 21 | `[0, 3476, 477, 260, …]` |
| **sonnet** | `thinking:true, low` | **21** | `[0, 3476, 477, 260, …]` |
| **opus** | `thinking:true, high` | **100** | `[0, 77666, 288, 9504, …]` |
| fable | `thinking:true, max` | 113 | `[0, 77666, 288, 9504, …]` |

**The divergence is at token index 1** — the first token after BOS. Not a partial loss: *everything*
after it re-prefills.

Two consequences worth acting on:

- **haiku and sonnet render IDENTICALLY** to each other and to the server default (same count, same
  ids — `low` really is the empty prefix, and the `thinking` flag alone changes only which reasoning
  parser is built, not the prompt). **Mixing haiku/sonnet is free.** Mixing either with **opus or
  fable costs a full re-prefill, every switch.** Opus↔fable likewise (100 vs 113).
- **"Stable Patch 12 hashes" never ruled out invalidation.** A turn with constant hashes that still
  pays a full prefill may be a tier switch, not eviction. Do not read a stable fingerprint as proof
  the prompt head held.

**The model name is logged NOWHERE** — not by Patch 12, not by the access log
(`POST /v1/messages?beta=true 200 OK`), not by the throughput or spec-decode lines. So a tier switch
**cannot be confirmed retroactively from the logs**. Closing this needs `model=` (or the resolved
`chat_template_kwargs`) added to the `PREFIX_WATCH` line — a bind-mounted `.py` change, so it
**needs a restart**; bundle it with any future Phase B restart rather than spending one on it.
Until then the only live witness is `prompt-tap.py`, which sees `body["model"]` — and only for a
session launched through it.

### The tripwire (`API-12`, live since 2026-09-19)

The server logs one line per request — `PREFIX_WATCH head=… tools=… sys=… user0=… len=…`, hashing
only slices, never the whole prompt. Watch it:

```bash
ssh shorn@spark-45ea 'docker logs -f <container>' | python3 local-ops/prefix-watch.py
```

It alerts when a conversation it has already seen returns with a changed tools or system hash — the
definition of "the head moved under an existing conversation". Measured cost: **50.8 KB/hour** to
journald and **37 us** per request, so it defaults **on**; `PREFIX_WATCH=0` disables it (needs a
restart).

Verified: 0 alerts on a normal session, exactly 1 on a deliberate mid-session tier switch, and over
49 lines of live traffic (including the other client on this cluster) exactly 1 confirmed alert.
Alerts are split by whether the prompt **grew** — a real conversation only appends, so a flat or
shrinking one is reported as `ambiguous` rather than counted. Sessions opening with the same short
first message otherwise collide; `cache-probe.py --selftest` is one such generator.

### Measuring it yourself

```bash
ssh -f -N -L 8888:127.0.0.1:8888 shorn@spark-45ea    # the API is localhost-bound on the head
python3 local-ops/cache-probe.py --selftest          # T0.1: does prefix-diff still agree?
bash local-ops/toolsearch-matrix.sh mycell false local-ops/toolsearch-matrix/workload-a.txt
python3 local-ops/matrix-report.py local-ops/toolsearch-matrix/mycell.jsonl
```

Three traps worth knowing before reading any number:

- **`hit%` is not the metric.** A strict-prefix turn cannot hit more than `prev_tokens/cur_tokens` —
  a turn growing 41K→56K is capped at 74% however perfect the head is. Read the **`ofmax`** column.
- **This cluster has concurrent external traffic**, and the `/metrics` counters are global. A clean
  delta has `queries == input_tokens`; `matrix-report.py` flags anything else as `[BLENDED xN]` and
  excludes it. The obvious check — `num_requests_running` — is useless, it lags the engine's logging
  interval and reads busy for nearly every turn.
- **0% hit has two causes.** prefix-diff saying "strict prefix, 75% shared" while the engine says 0%
  means the blocks were **evicted**, not invalidated — a pool-pressure problem, not a prompt problem.
  Reported as `[EVICTION?]`.

## Prefix-cache stability measured end to end — the remaining mover is a CLIENT plugin (2026-09-19)

Patch 11 closed the two server-side head-movers. This pass measured what was left, against the
engine's own accounting rather than against a model of the prompt.

**Answer: with `ENABLE_TOOL_SEARCH=false` and the `swift-lsp` plugin disabled, the prompt head
stops moving entirely — 0 head moves across 16 turns in two workloads, every turn a strict prefix.**
Tool search does not help; it trades one mover for another.

#### The harness, and why it is trustworthy now

`local-ops/prefix-diff.py` *models* the server's transforms. It had already produced one wrong
verdict (it modelled pre-11b hoisting and reported 21% shared where the truth was "strict prefix"),
so nothing rests on it unchecked any more.

- **`local-ops/cache-probe.py` is the ground truth** — `vllm:prefix_cache_{queries,hits}_total`
  deltas around a single request. `--selftest` runs **T0.1**: three synthetic pairs against a fresh
  nonce, with known answers.

  | pair | prefix-diff says | engine measured | |
  | --- | --- | ---: | --- |
  | identical bodies | identical | **99.0%** | PASS |
  | tail appended (a turn added) | strict-prefix | **98.8%** | PASS |
  | one byte changed at char 7 | diverges, 0% shared | **0.0%** | PASS |

  All three agree. Re-run it after any edit to `prefix-diff.py`.

- **`local-ops/prompt-tap.py` now measures each turn LIVE** (`--metrics-url`). Replaying a capture
  cannot work: the replay runs against a cache the original session already warmed, so every turn
  reads ~100% and the measurement is worthless.

- **Contamination is detected exactly, not guessed.** vLLM queries the prefix cache once per prompt
  token, so a delta belonging to one request has `queries == input_tokens` (verified to the token).
  `queries/input_tokens` above 1.05 means another client's tokens are in the window — measured up to
  **x26** during this work, because **this cluster has concurrent external traffic** (12 POSTs from
  `89.23.239.196` in one 15-minute window, independent of these tests). Contaminated turns are
  reported and excluded, not blended in.
  The obvious check — the engine's `num_requests_running` gauge — is **useless for this**: it
  refreshes only on the engine's logging interval, so it reads non-zero for nearly every turn,
  including from the measured request itself.

- **`hit%` alone is not the metric.** A strict-prefix turn cannot hit more than
  `prev_tokens / cur_tokens` — the new part has never been seen. A turn growing 41K→56K is capped at
  74% however perfect the head is. `matrix-report.py` reports hit **against that ceiling**; a stable
  head scores ~100%, a moved head scores 0%.

- **A 0% hit has two causes, and the two tools together separate them.** prefix-diff says "strict
  prefix, ~75% shared" and the engine says "0% hit" ⇒ the blocks were **evicted**, not invalidated.
  Observed live under the external load. Flagged as `[EVICTION?]`.

#### Phase 1 — the baseline matrix

Six cells, each a headless `claude -p` session of 7–16 turns reaching 65–78K context, routed
through the tap. Causes are per-conversation (a subagent is chained separately).

| cell | tool search | turns | head moves | strict% | cause |
| --- | --- | ---: | ---: | ---: | --- |
| ts-auto-a | unset | 7 | 1 | 83% | `tools +LSP` |
| ts-auto-b | unset | 10 | 1 | 89% | `tools +LSP` |
| ts-false-a | false | 7 | 1 | 83% | `tools +LSP` |
| ts-false-b | false | 16 | **3** | 80% | `+LSP`, `-LSP`, `+LSP` — it **flaps** |
| ts-true-a | true | 7 | 1 | 83% | `msg[0].user` |
| ts-true-b | true | 9 | 2 | 75% | `msg[0].user`, `tools +NotebookEdit` |

**Every baseline cell fails, and in `auto`/`false` the cause is always the same one event: the
`swift-lsp@claude-plugins-official` plugin attaching a few seconds into the session.** `auto`
behaves identically to `false` at this scale.

**Tool search does not freeze the tool set.** The earlier one-off observation ("tools frozen at 10
across 4 turns") simply never triggered a discovery. It holds the array at 9 only while nothing is
discovered; a `ToolSearch` hit **adds the found tool to the declared `tools` array**
(9 → 10, `+NotebookEdit`), which moves the head exactly as the full set does. It also moves the head
a *second* way: the deferred-tool NAME LIST lives inside `msg[0].user`, so LSP arriving changes that
instead of the array. Same cost either way.

#### Phase 1 follow-up — with the plugin disabled

| cell | tool search | turns | head moves | strict% | ofmax% | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| nolsp-false-a | false | 7 | **0** | **100%** | 99.8 | **VIABLE** |
| nolsp-false-b | false | 9 | **0** | **100%** | 99.7 | **VIABLE** |
| nolsp-true-a | true | 7 | 0 | 100% | 99.7 | VIABLE (no discovery occurred) |
| nolsp-true-b | true | 9 | 1 | 88% | 99.8 | NOT VIABLE (`tools +NotebookEdit`) |

`false` is stable in **both** workloads; `true` is stable only until something is discovered. So
`ENABLE_TOOL_SEARCH=false` **dominates** — it is not a trade-off, and no server change is needed.

> **The plugin is the whole fix, and it is a local judgement call.** `swift-lsp` is Swift tooling
> in a Python/shell repo, so disabling it here costs nothing. In a Swift project it is a real
> capability, and the honest trade is "one full re-prefill per session" against "no language
> server". `claude --bare` also skips LSP, along with much else.

#### Phase 2 — failure-mode probes

**T2.1 `tool_reference` — the never-executed path (`local-ops/toolref-probe.py`).** Both shapes
return **200**; there is no transport blocker. But:

| case | result |
| --- | --- |
| control: tool declared in `tools` | calls `kvpool_inspect(engine_rank=0, include_blocks=true)` |
| top-level `tool_reference` (serving.py:882, bare `pass`) | silently dropped; model writes a Python script instead |
| `tool_reference` inside a `tool_result` (serving.py:947-981) | **re-runs `ToolSearch`** — it cannot call the tool |
| same + schema also declared | calls it correctly |

**A `tool_reference` carries the NAME and no schema, and the model cannot act on it.** The thing
that actually makes a discovered tool callable is its arrival in the `tools` array — which is the
head move. This independently confirms tool search cannot be made head-stable at this layer, and it
means **no `tool_reference` server fix is warranted**: the code is not broken, it is inert.

**T2.2 resume and compaction.** **Upstream [#27048](https://github.com/anthropics/claude-code/issues/27048)
does not reproduce here** — the turn straight after `--resume` was a strict prefix at 95.8%, 100% of
its ceiling. `/compact` does rewrite the head, but that is what compaction *is*: it starts a new
system block and a 72.9K context restarts at 38.5K.

**T2.3 subagents — harmless.** The child runs its own conversation (14 tools, its own system block)
interleaved with the parent's. After 8 child turns the parent resumed at **99% of its ceiling**: the
parent's prefix survived intact. 9/9 strict prefix once the two conversations are chained
separately. No KV thrash observed.

**T2.4 MCP.** With `ENABLE_CLAUDEAI_MCP_SERVERS=true` the tool count goes 23 → **39**, but the array
hash was **stable across the session** and all turns were strict prefixes —
[#92033](https://github.com/anthropics/claude-code/issues/92033) did not reproduce. Only 4 turns, so
this is weak evidence; MCP stays off, and this is a measurement, not a recommendation.

**Tier switch mid-session — expensive, and for an extra reason.** Switching `claude-sonnet-5` →
`claude-opus-5` on a resumed session cost a **122s** turn on a 68K context. The cause is not only
the effort prefix at message index 0: **Claude Code embeds the model name in its system prompt**, so
the system block itself changes (hash `2e2a…` → `c90a…`) and the whole head is rewritten. Do not mix
tiers within one conversation.

#### Phase 3 — tool-selection quality (`local-ops/toolquality.py`)

Ten prompts, each needing one deferred tool, run under both modes. The worry was real: in an
earlier ad-hoc probe the model **ignored** a tool described outside the declared tool list unless
pushed hard.

| | `false` (all tools upfront) | `true` (deferred) |
| --- | ---: | ---: |
| correct tool chosen | 6/10 | 7/10 |
| acceptable tool | 7/10 | 8/10 |
| task completed | **10/10** | 9/10 |
| **total turns** | **45** | **94** |
| `ToolSearch` used | 0 | 7 |

**Quality parity** (a one-case gap is noise at n=10), but **tool search costs 2.1x the turns** —
one case went 10 turns → 41. So `true` loses on cache stability *and* on cost, and wins nothing.

Both arms miss `ListAgents` and `LSP`; those are selection misses in the model, unrelated to
deferral, and identical in both arms.

#### Phase 4 — decision

**Adopt `ENABLE_TOOL_SEARCH=false`** (or leave it unset; `auto` measured identical), **and disable
the `swift-lsp` plugin for this repo**. No server change is required for the decision.

Following the plan's tree: `true` is **not viable** (it fails whenever a discovery happens), so the
branch taken is "adopt `=false`, requires the tools array proven stable in Phase 1" — which it is:
one tools hash, zero head moves, 100% strict prefix across 16 turns in two workloads. The "late
tools" server patch stays **REJECTED**; nothing measured here argues for it. The `tool_reference`
fix is **not warranted** either — T2.1 showed the path returns 200 and is inert, not broken.

#### Phase 5 — the guardrail, deployed

**Patch 12** emits one `INFO` line per request from `_convert_anthropic_to_openai_request`:

```
PREFIX_WATCH head=942f33360604 tools=00b6e909d1b0 sys=eb4f22ee14b0 user0=b86e48066a1d len=304645
```

Only **slices** are hashed — the first 2KB of the rendered prompt, the tools block, the system
block, the first user turn — never the full 100K+ prompt. The helper cannot raise; a failure
degrades to a `debug` line.

**Budget — measured, then defaulted on.**

| | measured | threshold | |
| --- | ---: | ---: | --- |
| journald growth | **50.8 KB/hour** (152-byte line x 1.6 journald overhead x 214 req/hour) | < 1 MB/hour | PASS |
| CPU per request | **37 us** median, 43 us p95, on a 300K-char prompt with 23 tools | latency unchanged | PASS |

37 us against a prefill measured in *seconds* is 0.00002% of one cold turn. So `PREFIX_WATCH`
defaults to **on**, with `PREFIX_WATCH=0` to disable. (The direct `journalctl --disk-usage` delta
was below the tool's 0.1 GB resolution over the observation window — the figure above is computed
from the measured line size and the observed request rate, not from that delta.)

**Acceptance test passed exactly as specified:**

| scenario | alerts |
| --- | ---: |
| normal session (6 guardrail lines, including a subagent) | **0** |
| deliberate mid-session tier switch (10 lines) | **exactly 1** — `system changed`, `sys=5e46e83c → 633ff8af` |

> **The plan's fingerprint design was wrong, and the test caught it.** Keying conversations on
> `head` (the first 2KB of the rendered prompt) groups **every** session together — that slice is
> Claude Code's own system-prompt header, byte-identical across sessions. The first run of this test
> raised **3** alerts, 2 of them purely the other client on the cluster interleaving with ours.
> `prefix-watch.py` now keys on `user0` (the first user message), which is conversation-specific.
> Known limit, documented in the file: a conversation whose *first user message* mutates reads as a
> new conversation rather than an alert — Claude Code only does that with `ENABLE_TOOL_SEARCH=true`,
> the mode we rejected.

> **A second false-positive source, also found by running it against live traffic.** Conversations
> that open with the *same short user message* collide. `cache-probe.py --selftest` does exactly
> that ("Reply with the single word OK."), and its seven probes read as one conversation whose
> system block kept changing. Alerts are now split by whether the rendered prompt **grew**: a real
> conversation only ever appends, so `len` increasing is CONFIRMED and `len` flat-or-shrinking is
> `ambiguous` and excluded from the headline count. Final live check — **49 guardrail lines
> including the other client's traffic → exactly 1 confirmed alert (the deliberate tier switch) and
> 7 correctly classified ambiguous.**

#### The prefix cache is ALL-OR-NOTHING here — and it is upstream (2026-09-19)

Chasing why a tool change costs a *full* re-prefill produced a much larger finding.

**The rule, measured on a quiet controlled probe** (`cache-probe.py`, baseline proven cached by an
identical repeat before every measurement):

| A's cached extent | B's matching blocks | B's reuse |
| ---: | ---: | ---: |
| 14,336 tokens (56 blocks) | 56 | **14,336** |
| 14,592 tokens (57 blocks) | 56 | **0** |

**A request reuses a cached prefix only if it matches that request's ENTIRE cached extent. One
block short and it gets nothing.** So a conversation is fast exactly while every turn APPENDS, and
any mid-prompt change — a tool arriving, a system edit, a second session sharing a system prompt —
costs the whole prefill.

Reproduced with **no tools involved at all**, and on the raw `/v1/chat/completions` path, so this is
neither a tools problem nor ours.

**Ruled out, each by measurement:**

- **Alignment.** The GCD of every non-zero hit length is exactly **256** = `block_size`, so the
  `alignment_tokens` round-down is a no-op.
- **Patch 7.** Swapped for the image's genuine `block_pool.py` and re-ran: **identical numbers**.
- **Our Anthropic layer / Patch 11.** The raw OpenAI endpoint behaves the same.

**It is a known upstream bug.** [vllm#42948](https://github.com/vllm-project/vllm/issues/42948) —
DSv4-Flash runs a **5-group hybrid KV coordinator** (one full-attention MLA group plus
sliding-window groups) and the MLA group returning short "collapses the hybrid intersection cascade
to 0 across all downstream groups". **No fix, no PR.** Our boot log confirms the topology: Patch 6
logs act on KV groups **1, 2, 3 and 4** beside group 0. Related:
[#32802](https://github.com/vllm-project/vllm/issues/32802) (PR #33524 fixed it for GPT-OSS only)
and [#57610](https://github.com/vllm-project/vllm/issues/57610).

> **Where the tools block actually sits.** `deepseek_v4.py:38-41` inserts a NEW empty system message
> at index 0 and hangs the tool schemas on it, so the rendered prompt is
> `[tools ~75% of it][our 27K system prompt][conversation]`. Tools are at the very HEAD. Verified by
> token diff: a tool inserted alphabetically at index 13 leaves 54.5% of tokens shared; appended at
> the end, 83.3%. **Neither reuses anything today** — which is what forced the all-or-nothing
> discovery, and is why no tool REORDERING can help.

> **TRAP — `local-ops/baseline-20260914/pristine-single_type_kv_cache_manager.py` is NOT pristine.**
> It is a copy of our PATCHED file, captured through the bind-mount — the exact mistake CLAUDE.md
> warns about. Against the image's genuine copy, Patch 6 is a real **83-line, 7-hunk** patch. The
> `block_pool` baseline IS genuine (matches the image). Re-pull any baseline before trusting it:
> `docker run --rm --entrypoint cat <image> <path>`.

**Still open, parked deliberately:** whether Patch 6's SWA page recycling
(`VLLM_SWA_RECYCLE_SKIPPED_BLOCKS`) contributes. It can be A/B'd **with no restart** — run a
throwaway container from the same image with and without the patch bind-mounted
(`docker run --rm --entrypoint python3 <image> -c ...` imports the real modules with no GPU and no
engine; verified working). Parked in favour of fixing the append case first.

#### Patch 13 — sticky tool set, so the append chain survives a flap

Given all-or-nothing reuse, the only thing that matters is keeping each turn an APPEND. The tool
array is what breaks it. Patch 13 makes the served set **monotonic per conversation**: once a tool
has been advertised, it keeps being advertised.

- Replaying the real 16-turn flapping capture (`ts-false-b`): **3 tool-set changes → 1.**
- It only ever **adds**; it can never rewrite or remove something the model already saw.
- Requests with **no tools are untouched** — the permission classifier must stay tool-free.
- Keyed on first-user-message + system hash, 1h TTL, 512-conversation LRU cap, never raises.
- Kill switch `STICKY_TOOLS=0`, TTL via `STICKY_TOOLS_TTL`.

**What it cannot fix:** the FIRST appearance of a tool. That is genuinely new content, and only the
client can stop sending it late — hence the swift-lsp recommendation above.

**Accepted trade-off:** between a tool leaving and returning, the model is told about a tool the
client currently lacks; if it calls one, the client sees a `tool_use` it cannot service. Flaps last
seconds, and every re-advertise is logged as a `PATCH 13:` line.

#### What was NOT established

- **Long sessions.** The longest cell is 16 turns / 78K tokens. Nothing here says the head still
  never moves at 500K, or after hours.
- **Quiet-window numbers.** External traffic contaminated 1-in-3 turns in some cells. Contaminated
  turns are excluded, so the reported figures are sound, but `n` is small.
- **`auto` at scale.** It matched `false` in these cells; that is not proof it always will.
- **Tool-selection quality at n=10.** Parity is "within one case", which at this sample size is
  noise either way. The 2.1x turn cost is the robust half of that result.
- **Whether the guardrail catches a move nobody triggered on purpose.** It was verified against a
  deliberate tier switch and a clean session. Its value in the wild is still to be seen.


## Cross-session prefix reuse — real sessions DO pay a full cold prefill (2026-09-19)

**Every new Claude Code session on this cluster throws away ~26s of prefill.** Measured on real
headless sessions, n=3, three independent cold heads, **0.0% every time**:

| run | session A turn 0 | session B turn 0 |
| --- | --- | --- |
| xsess | 0.0% / 26.3s | **0.0% / 31.6s** |
| rep1 | 0.0% / 28.6s | **0.0% / 26.1s** |
| rep2 | 0.0% / 25.0s | **0.0% / 25.9s** |

Within each rep, A and B carry an **identical `system` hash and conversation key**, and their
turn-0 prompts share 99.4-99.6% of the rendered bytes (raw byte diff: first divergence at char
113,759 of 114,169). So the head is shared and the reuse simply does not happen.

> **CORRECTION.** An earlier version of this section said "there is no cross-session reuse defect —
> it already works at 99.7%". That was **wrong, and wrong in an instructive way**: every 99.7%
> measurement came from *synthetic probes*, and synthetic probes do not behave like real sessions
> here. The lookup findings below still stand — they rest on their own controls — but the
> generalisation from probe to session did not.

### The core observation

**A head written by a real multi-turn session is unretrievable 2 seconds after that session ends.**
A head written by a single synthetic request survives 5+ minutes.

| head written by | probe 2s later | survives |
| --- | --- | --- |
| a real multi-turn session | **0.0% hit, 22.77s (cold), clean delta** | no |
| one synthetic request (`max_tokens=4`) | 99.7%, 0.69s | **5+ min**, through a 777K-token burst |

During the session the head *is* retrievable — turns 1-6 hit 67-99%. It works while the session
holds it and dies when the session lets go.

> **Read the SECONDS, not the hit%.** This cost hours. Two probes that appeared to show "the head
> is alive" were actually **cold prefills that re-created it** (22.31s and 22.48s, both blended).
> Every 99.7% reading after them was measuring the probe's own work. A warm ~42K head answers in
> **~0.7s**; anything near 20s+ is a miss regardless of what the ratio says.

### What has been ELIMINATED, each with a clean control

Do not re-test these without new evidence:

| suspect | how it was cleared |
| --- | --- |
| The "extent rule" (match the whole extent or get 0) | **Disproven.** Lookup is monotone, `floor(shared/256)*256`; 0 of 26 exact-token points returned zero, two seeds, three prompt sizes. |
| Prompt bytes / a moved head | Raw byte diff 99.64% shared; Patch 12 fingerprints identical across both live sessions (`head=942f33360604 tools=077941266e1a sys=5e46e83cd5d3 user0=1bf734cbb2a0`). |
| Session B's actual body | Replayed onto A's head: **99.7%, 3/3 clean**. |
| `max_tokens` (4 vs 32000), `stream` | 2x2 matrix, all four shapes **99.7%**, clean. |
| Transport (direct tunnel vs tap→mTLS→proxy) | Same body both paths, **99.7%** both, clean. |
| Session growth to 97K tokens | Head retrievable **before and after** growth, 99.7% both. |
| ~~Generation / decode~~ | **WRONG — this was the cause. Withdrawn 2026-09-20.** The control (one request, 388 tokens) is real and reproduces (one turn, 166 tokens: 99.5%, 0.67s), but it does not generalise: the SAME seven captured bodies replayed with `max_tokens=1` leave the head at **99.6%**, and with 50 decode tokens each leave it at **0.0% / 14.83s**. Decode across a conversation that keeps extending is what destroys the prefix — [`CACHE_TEST.md`](../../CACHE_TEST.md) §8. |
| Time / pressure eviction | Probe-written head survived **5 min** including a 777K-token burst. **Quantified 2026-09-20:** 224,500 tokens of unrelated prefill (5 requests) leaves it at 99.5%; **1,122,240 tokens (25 requests) kills it.** So pressure *can* evict a head, but it needs ~25 large requests — far more than a session does, which is why pressure is not the everyday cause. |
| Patch 6, `SWA_RECYCLE`, `PROTECTED_FRACTION` | Offline A/B, four cells, identical row for row — and a grow-then-free session sim does **not** reproduce it in any arm. |
| vllm#42948 hybrid cascade | Does not reproduce; this fork already carries repairs for the neighbouring 0%-hit modes. **No upstream report filed.** |
| **Claude Code moving the head** | **Innocent.** A real captured session (inline `system` messages in the messages array, the Patch 1 path) is a **strict prefix at every turn**, with `system` and `tools` hashes stable throughout. Patch 1's inline-system merge is idempotent. |
| **An aborted / severed request** | **Innocent.** Severing a streaming request mid-flight left the head at 99.7%, clean. |
| **The `?beta=true` path, `anthropic-beta`, the full live header set** | **Innocent (2026-09-19, A2).** Four arms direct to the engine — control, beta path, beta header, full captured headers — all **99.6% / ~0.76s / clean**. `prompt-caching-scope-2026-01-05` does nothing here. |
| **A per-session `cache_salt`** | **Disproven from outside.** No client-reachable path sets one; if it did, the beta-header and full-live arms above would have read 0%. |
| ~~**Eviction, of any kind**~~ | **WITHDRAWN the same day — do not cite this row.** It claimed `MNT-9` held a head by reference and the head still vanished. `MNT-9`'s own log shows it pinned **2 of the 3**, **3 of the 33** and **16 of the 17** blocks the sliding-window groups need for a hit at B, so the head was never held: an incomplete run in any group means no hit, because the coordinator takes the minimum across groups. Eviction remains a live candidate. What does survive: `MNT-8` does not move this metric, and a synthetic head is durable where a session head is not — [`CACHE_TEST.md`](../../CACHE_TEST.md) §6-7. |
| **A warm-up head is durable; a session head is not** | **Measured 2026-09-20 (§7).** A probe-written head reads 99.5% / 0.50s and survives 120s idle; a session starting on it pays **4.26s at turn 0 instead of 16.47s**. But a session's own later turns destroy it: alive at 18:40, one session later 0.0% / 14.40s. So the head dies from allocation churn *within* a session, and the head of the session's LAST turns survives (`MNT-6a` protects that one) while turn 0's does not. |
| **Being a "real session" as such** | **Innocent (2026-09-19, A3).** A single-turn real `claude -p` session (no tools) leaves a head that is **ALIVE at +2s: 99.6%, 0.57s, n=2**. Real-client, beta path, `cache_control`, `context_management`, `thinking:enabled`, per-session `metadata.session_id` and the live streaming shape are all exercised by that session and are all out. |

### What is NOT established

**The mechanism.** It is something about a real multi-turn session's lifecycle that the offline
harness does not model — it reproduces neither stock, with Patch 6, nor with recycling disabled.
Candidates not yet separated: chunked prefill across turns, async scheduling, spec-decode
rollback, or preemption under the co-tenant's ~140K-token requests.

**FIXED 2026-09-21 — `MNT-6c` (`swa_recycle_cached: 0`), live on both nodes.** A real session's head
now survives at **99.4% / 0.49s** where it read 0.0% / 14.16s, and cold-head simulation separates
3/3 with no overlap. The eviction `MNT-6b` performed on every page it recycled was the bug.
Full evidence: [`CACHE_TEST.md`](../../CACHE_TEST.md) §9.

**RESOLVED 2026-09-20 — it is decode across turns.** Identical captured bodies, replayed with no
client at all: `max_tokens=1` leaves the head at 99.6%, `max_tokens=50` over seven turns leaves it
at 0.0% / 14.83s. One turn decoding 166 tokens is harmless. The leading mechanism is `MNT-6a`'s
FIFO protection releasing the head's blocks, after which `MNT-6b`'s `_maybe_evict_cached_block()`
destroys their hash mappings as the sliding window passes — and the coordinator's
minimum-across-groups rule then reads 0. Full evidence and the next A/B:
[`CACHE_TEST.md`](../../CACHE_TEST.md) §8. Reproduce in 45s with
`python3 local-ops/xsess/decode-dose.py 7 50`.

**Narrowed 2026-09-19 (Phase A):** it is not "a real session" — it is **multi-turn**. A one-prompt,
no-tool real session's head survives at +2s (99.6%, 0.57s, n=2), where a six-turn one is gone
(0.0%, 22.77s). What is left is what only multiple turns do: chunked prefill across turns,
spec-decode rollback accumulated over turns, or the free/allocate churn of repeatedly extending one
conversation's block chain.

> **Outstanding control.** The paired multi-turn run on the *same sitting* was stopped at the user's
> request — our probes were evicting a co-tenant session's cache. The "dead" figure is same-boot but
> earlier. Re-run it before building on A3:
> `bash local-ops/xsess/death-probe.sh 2 local-ops/toolsearch-matrix/workload-a.txt a3multi`

Whoever picks this up, in order:

1. **The multi-turn positive control above**, back-to-back with a trivial run. Cheap, no restart.
2. **A turn-count staircase** — 1, 2, 3, 6 turns, one probe each — to find where the head starts
   dying. Also cheap and restart-free, and it would name the threshold directly.
3. **Engine-side instrumentation.** External probing is exhausted: the request is
   indistinguishable from a synthetic one on every axis, yet behaves differently. The scheduler
   already carries a `kv_cache_eviction_events` channel (visible as `kv_cache_eviction_events=[]`
   in `SchedulerStats`) and there is an `enable_kv_cache_events` config. Turning that on would
   name the blocks and the reason directly. **It needs a restart, so ask first.**

### Tooling

`local-ops/xsess/` — `FINDINGS.md` (full write-up), `extent-probe.py` (exact-token staircase, uses
`/v1/completions` with a token-id array so divergence is placed to the token), `xsess-probe.py`,
`survival-probe.py`, `growth-probe.py`, `shape-probe.py`, `transport-probe.py`, `gen-probe.py`,
`gap-probe.py`, `death-probe.sh` (now `[delay] [workload] [tag]`, so a trivial single-turn workload can be used), `clean-reps.sh`, and `transport-probe.py` — rebuilt 2026-09-19 as the **four-arm beta probe** (control / `?beta=true` / `anthropic-beta` / full live headers, all direct to the engine), results in `beta-arms.json`. `local-ops/kvsim/` — offline container
reproduction, no GPU, seconds.

### Measurement traps that invalidated work here

- **Never retry a cache measurement with the same request.** The first attempt cached it; the
  retry reads its own footprint back at ~100%. Produced a 12,288-hit reading on an 11,000-token
  shared prefix. Regenerate a fresh request per attempt (perturb only the divergent tail).
- **Read latency alongside hit%** — see the boxed warning above.
- **A probe that misses REBUILDS what it was measuring.** You get one cold/warm datum per session;
  every later probe hits regardless. Hence one run per time-point in `death-probe.sh`.
- **`vllm:gpu_cache_usage_perc` reads 0.0 even under load** on this build. Use
  `vllm:prompt_tokens_total` deltas. **CORRECTED 2026-09-20:** the sibling claims in this list were
  too broad — on the 15:34Z boot `vllm:kv_cache_usage_perc` read **0.2337** and
  `vllm:num_requests_running` read **1.0** with a live request, both tracking reality. Check the
  specific counter on the current boot before dismissing it.
- **Blended deltas are everywhere** — this cluster's co-tenant runs 285-315K-char prompts; blend
  factors of x4-x9 were routine. `queries == input_tokens` or discard the row.

### The one-block eagle pop (real, correct, not worth touching)

When a match would consume the cached request's entire extent, exactly one block (256 tokens) is
dropped at `single_type_kv_cache_manager.py:597` —
`if use_eagle and computed_blocks[0]: computed.pop()` — reached because MTP
(`num_speculative_tokens=5`) makes `use_eagle` true. Confirmed by A/B: eagle off is exactly
monotone, eagle on is uniformly -256. Leave it; 256 tokens is 0.7% of a 36K head.

## Upstream vllm#43447 ("DeepSeek-V4 prefix cache retention") — assessed 2026-09-20

[vllm#43447](https://github.com/vllm-project/vllm/pull/43447) targets the exact pathology this
document chases, and is **not in our runtime** (0.21.1rc1.dev339). Of its two halves:

- **Free-queue ordering** (scratch blocks reused before cached ones) **applies** — it is the missing
  end-of-request half of `MNT-6b`, and the first mechanism that predicts *multi-turn* decay while a
  single-turn head survives, i.e. a mechanism for the candidate left open in
  ["What is NOT established"](#what-is-not-established) above.
- **`VLLM_PREFIX_CACHE_RETENTION_INTERVAL`** applies in principle but is blocked behind the fork's
  `eagle_extra_cache_blocks` bail-out, which makes our SWA groups cache densely regardless.

A third candidate — **pinning the static head in-engine** (boundary = first `<｜User｜>`, token
`128803`; verified on this build that tools and system both render before it) — is assessed
alongside them. It is a **narrowing of `MNT-6a`**, not a new primitive: `_protect_prompt_blocks()`
already pins the whole aligned prompt prefix on every request, under a FIFO cap of 1,674 blocks per
group, so one long session's body evicts every other agent's head. It also explains the reported
asymmetry — an identical resend hits 100% because the pinned boundary is the prompt end, while a
session sharing only the head gets nothing, because `MNT-6b` evicted the sliding-window tails at
that earlier boundary.

None of the three is implemented and none is measured. **The analysis, the per-group page-size table, the
porting surface and the test plan live in [`CACHE_TEST.md`](../../CACHE_TEST.md)** — not here, so
the two cannot drift. Fold the result back into this document once it is measured.

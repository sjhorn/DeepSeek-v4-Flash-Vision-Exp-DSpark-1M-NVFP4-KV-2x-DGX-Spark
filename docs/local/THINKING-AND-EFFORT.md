# THINKING-AND-EFFORT.md — thinking mode, reasoning effort, and the model-alias ladder

What `chat_template_kwargs` actually does on this image, what each effort level costs and buys
(measured on HMMT Feb 2026), the eleven served names and how `API-9` routes them, and the
auto-mode permission classifier.

The *cache* consequence of the effort prefix — that it sits at token index 1 and so a tier switch
re-prefills everything — is in `PREFIX-CACHE.md`, together with the tail-placement pilot and the
prior art. It is filed there because it is a position problem, not a thinking problem.

> Moved verbatim from `CLAUDE.md` and `STATUS.md` during the 2026-09-20 doc split. Where a line was found stale
> on the way across it was corrected in place and the correction is marked **CORRECTED**.

## Thinking and reasoning effort — measured 2026-09-16

**Per-request control works; no restart needed.** `chat_template_kwargs` is a declared field on
our patched `AnthropicMessagesRequest` and is forwarded verbatim to the `ChatCompletionRequest`
(`anthropic_serving_inline_system.py:669`), and the reasoning parser is constructed **per request**
from the merged kwargs (`openai/chat_completion/serving.py:252-257`). So thinking can be toggled
per call against the running server:

```bash
# per-session Claude Code alias; default launcher stays thinking-off
CLAUDE_CODE_EXTRA_BODY="{\"model\":\"$MODEL\",\"chat_template_kwargs\":{\"thinking\":true,\"reasoning_effort\":\"high\"}}"
```

**`reasoning_effort` only works inside `chat_template_kwargs` on this endpoint.** The Anthropic
request model has no top-level `reasoning_effort` field, and pydantic's default `extra="ignore"`
drops it silently. The same applies to Claude Code's own thinking controls — `alwaysThinkingEnabled`,
`/effort`, `MAX_THINKING_TOKENS` — they change the UI, never the prompt.

**The effort table our image actually implements** (measured, `prompt_tokens` as witness):

| `chat_template_kwargs` | prompt_tokens | effect |
| --- | ---: | --- |
| `thinking:true`, no effort key | 5 | none (defaults to `low`) |
| `+ reasoning_effort:"low"` | 5 | none — `low` is deliberately the empty prefix |
| `+ reasoning_effort:"high"` | 84 | +79 |
| `+ reasoning_effort:"xhigh"` | 97 | +92 (aliases to `max`) |
| `+ reasoning_effort:"max"` | 97 | +92 |
| `+ reasoning_effort:"bogus"` | 5 | unknown → falls back to `low` |
| `thinking:false + reasoning_effort:"max"` | 5 | ignored — chat mode has no prefix |

> **README:599-622 is STALE for our image.** It says `low`/`medium`/`high` produce no prefix and
> that `max` injects the *high* text, making the model's real max unreachable. Our
> `tokenizers/deepseek_v4_encoding.py` carries the fixed three-level `REASONING_EFFORT_PROMPTS`
> table lifted verbatim from DeepSeek's reference encoder — i.e. **PR #24 is already in this
> build**. `high` and `max` are genuinely different texts. The prefix is injected **only at index 0**
> (first turn), not per turn. `reasoning_effort:"none"` with `thinking:true` remains the documented
> trap: chat-mode prompt, armed parser, `content: null`.

**Undocumented second kwarg: `drop_thinking` (default `true`).** It drops reasoning from earlier
assistant turns at render time — but `deepseek_v4_encoding.py:562-565` disables it whenever any
message carries tools:

```python
effective_drop_thinking = drop_thinking
if any(m.get("tools") for m in full_messages):
    effective_drop_thinking = False
```

**Claude Code always sends tools**, so this safety net is off for every request we make, and
passing `drop_thinking:true` explicitly will not override it. If we ever adopt thinking mode for
agent work, prior-turn reasoning is *not* dropped by the renderer and Patch 8 would need extending
to strip inbound `thinking` blocks as well as `</think>` inside text.

### Quality vs cost: HMMT Feb 2026, measured

Benchmark: [MathArena/hmmt_feb_2026](https://huggingface.co/datasets/MathArena/hmmt_feb_2026) —
the same set behind the model card's 94.8 Think-Max figure — first 12 problems, gold answers,
`max_tokens=24000`, `temperature=0`, one sample per problem. Graded objectively on the last
`\boxed{}` with LaTeX normalisation plus numeric-equivalence fallback.

| arm | correct | of gradable | truncated | output tokens | tokens per correct |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 5/12 | 5/9 | 3 (25%) | 100,176 | 20,035 |
| **high** | **11/12** | **11/11** | **1 (8%)** | **90,682** | **8,243** |
| max | 8/12 | 8/8 | 4 (33%) | 151,676 | 18,959 |

- **Thinking is near-perfect when it terminates:** both thinking arms pooled are **19/19** on every
  problem that produced an answer, vs 5/9 for off. Fisher **p = 0.006**.
- **The variable is termination, not depth.** Arms differ only in runaway rate to the token cap.
- **`high` is the sweet spot** — more accurate *and* cheaper than both neighbours, 2.4x fewer
  tokens per correct answer than off. `off` vs `high` is significant (p = 0.027).
- **`max` is the worst of both worlds**: 1.7x the tokens of `high` for three fewer correct answers.
  Its prompt text instructs the model not to stop until it has verified from multiple angles, which
  is exactly the runaway behaviour observed. The card's 94.8 is many-sample; in single-sample
  interactive use a runaway costs the whole answer.
- **Not significant:** `high` vs `max` (p = 0.32), `off` vs `max` (p = 0.41). Only thinking-vs-not
  survives at n=12.
- **`temperature=0` is NOT deterministic here.** Batch nondeterminism with spec decoding gives real
  run-to-run variance: the off arm had 0 truncations at a 12k cap and 3 at 24k on identical prompts.
  Treat single-sample results as indicative.

**Earlier A/B for contrast** (5 general prompts, not math): thinking on cost **2.31x** the output
tokens and 4.4x wall clock for a 27% longer answer. So thinking is not free in general — the HMMT
win comes from hard problems where the off arm rambles to the cap.

**Artifacts:** `local-ops/hmmt-effort-20260916/` — harness, problem set, per-problem JSON, both the
12k and 24k logs.

## Model aliases — per-tier thinking (`API-9`, rev 2026-09-18)

One engine, eleven served names. `--served-model-name` takes a list, so aliases cost nothing —
same weights, same KV pool, just labels. Patch 9 routes the name to `chat_template_kwargs`.

**We serve the vendor names too.** Claude Code already knows `claude-*` ids, so serving them means
no unrecognised-model warning, a working `/model` picker, working `ANTHROPIC_DEFAULT_*_MODEL` tier
variables, and — the reason this started — we capture the **auto-mode permission classifier**,
which hardcodes `claude-sonnet-5`.

### The ladder

| name | thinking | effort | prompt cost |
| --- | --- | --- | ---: |
| `claude-haiku-*` | off | — | +0 |
| `claude-sonnet-*` | on | `low` (the empty prefix) | +0 |
| `claude-opus-*` | on | `high` | +79 |
| `claude-fable-*` | on | `max` | +92 |
| `deepseek-v4-flash-dspark` | server default (`thinking:false`) | — | +0 |
| `…-nothink` / `…-think-low` / `…-think-high` / `…-think-max` | explicit | | +0/+0/+79/+92 |

`max` is **not** a family default on purpose — it measured worse than `high` (8/12 vs 11/12, 33%
truncation, 1.7x tokens). Fable is the deliberate escalation lane, chosen because it is never
selected by accident here. **`low` has never been quality-tested** — only off/high/max were — so
watch `stop_reason` on sonnet-tier turns for runaways.

### Resolution order

1. explicit `chat_template_kwargs` in the request — always wins
2. **permission-classifier detection** — forced `{"thinking": false}`
3. model-name rules (suffix rules first, then vendor prefixes; first match wins)
4. nothing matches → server-wide `--default-chat-template-kwargs`

Rules live in `MODEL_THINKING_RULES`; names live in `SERVED_MODEL_ALIASES` in the compose. **Keep
them in sync** — vLLM rejects an unserved name before Patch 9 sees it. Prefix rules mean a new
Claude id routes correctly without a code change. Kill switches: `MODEL_ALIAS_THINKING=0`,
`CLASSIFIER_NOTHINK=0`.

### The auto-mode classifier — measured 2026-09-18

Captured with `local-ops/prompt-tap.py`, a local logging tap that forwards over the existing mTLS
path (no server change needed). What it sends, on **every tool call**:

```
system      114,476 chars (~31,800 tokens)   <- 114,158 of it ONE static block, cache_control: ephemeral
messages[0]     950 chars  your CLAUDE.md as context
messages[1]     549 chars  the transcript being judged
whole body  119,720 bytes (~33,255 tokens)   -> for a 64-token verdict
```

**It is well built for caching** — static rules first, volatile transcript last, byte-identical
system across calls — so vLLM's prefix cache absorbs it after the first call of a session.

Two problems were ours, not Anthropic's:

- It asks for `claude-sonnet-5`, which we did not serve → **HTTP 404**, then Claude Code retried
  against the session model. Every classification paid a wasted ~120KB round trip.
- The retry inherited the session model, so with a `-think-*` default **every permission check did
  a reasoning pass**. That is the "auto mode is slow / stalls" symptom.

Serving `claude-sonnet-5` fixes the 404. The thinking is fixed by **detecting the classifier by
shape, not by name** — no tools plus `"You are a security monitor for autonomous AI coding agents"`
in the system prompt — so it stays cheap whichever id Anthropic points it at next.

### Client config

Because the vendor names are served, the launcher collapses to endpoint + auth + certs.
`CLAUDE_CODE_EXTRA_BODY` must **not** carry a `model` key — it is merged into every request and
overrides every tier variable. The `[1m]` suffix is stripped client-side, so `claude-opus-4-6[1m]`
puts `claude-opus-4-6` on the wire and buys the 1M window.

`claude-vllm` (in the vllm-proxy repo) still hardcodes a one-entry `availableModels`; until it
reads a `models` array from the profile, multi-model use needs the tier variables set by hand.

**Switching mid-session costs a full re-prefill** — the effort prefix sits at message index 0, so
changing effort rewrites the prompt head and invalidates the conversation's prefix cache.

## Reasoning effort measured — use `high`, not `max` (2026-09-16)

Tested per-request via `chat_template_kwargs` against the running server; **no restart or config
change was needed**, and none was made. The deployed default remains `{"thinking":false}`.

HMMT Feb 2026 (MathArena gold answers), 12 problems, `max_tokens=24000`, `temperature=0`,
one sample each, objective `\boxed{}` grading:

| arm | correct | of gradable | truncated | output tokens | tokens/correct |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 5/12 | 5/9 | 3 | 100,176 | 20,035 |
| **high** | **11/12** | **11/11** | **1** | **90,682** | **8,243** |
| max | 8/12 | 8/8 | 4 | 151,676 | 18,959 |

- Thinking arms pooled: **19/19 on everything that terminated** vs 5/9 for off (Fisher p = 0.006).
  The differentiator between arms is runaway rate, not reasoning quality.
- `high` beats both neighbours on accuracy *and* token cost. `off` vs `high` p = 0.027.
- `max` truncated most (33%) and cost 1.7x `high`. Do not use it for interactive work.
- `high` vs `max` (p = 0.32) and `off` vs `max` (p = 0.41) are **not** significant at n=12.
- `temperature=0` is not deterministic on this stack (batch nondeterminism + spec decode): the off
  arm produced 0 truncations at a 12k cap and 3 at 24k on identical prompts.

Effort prefix cost, measured: `low`/unset/unknown = +0 tokens, `high` = +79, `xhigh`/`max` = +92,
injected at the first turn only, and ignored entirely when thinking is off.
**README:599-622 is stale** — our image already carries PR #24's real three-level table, so `max`
is no longer an alias for `high`'s text.

Also found: `drop_thinking` (default true) is force-disabled whenever any message carries tools
(`deepseek_v4_encoding.py:562-565`), and Claude Code always sends tools — so prior-turn reasoning
would not be dropped by the renderer if thinking were adopted for agent work.

Artifacts: `local-ops/hmmt-effort-20260916/`.

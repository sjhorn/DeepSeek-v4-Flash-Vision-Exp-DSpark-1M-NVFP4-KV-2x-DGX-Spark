# PATCHES-API.md — the Anthropic endpoint patches (API-0, API-8 … API-13)

Detail and evidence for the patches that live in the two bind-mounted Anthropic endpoint files:

| id | file | what |
|---|---|---|
| `API-0` | `patches/anthropic_protocol_inline_system.py` | accept what Claude Code actually sends |
| `API-8` | `patches/anthropic_serving_inline_system.py` | strip leaked chain-of-thought from inbound assistant turns |
| `API-9` (9b, 9d) | ″ | per-model-alias thinking defaults |
| `API-10` (10b) | ″ | never 500 on malformed model-generated tool arguments |
| `API-11` (11a, 11b) | ″ | prompt-head stabilisers |
| `API-12` | ″ | prefix-cache tripwire (`PREFIX_WATCH`) |
| `API-13` | ″ | sticky tool set |

One line each, with kill switches and rollback: `PATCH-REGISTRY.md`.
The prefix-cache evidence these were built against: `PREFIX-CACHE.md`.
The model-alias ladder and effort measurements: `THINKING-AND-EFFORT.md`.

Anchors used by the in-file banners and by `PATCH-REGISTRY.md` are the section headings below.

> Moved verbatim from `STATUS.md` and `CLAUDE.md` during the 2026-09-20 doc split. Where a line was found stale
> on the way across it was corrected in place and the correction is marked **CORRECTED**.

<a id="api-0"></a>

## API-0 — the protocol patch, and the shape of the serving patch

Two files are bind-mounted into the container via `docker-compose.dspark.yml` to fix Claude Code compatibility issues with vLLM's Anthropic endpoint.

### `patches/anthropic_protocol_inline_system.py` — API-0

Patched copy of `vllm/entrypoints/anthropic/protocol.py`:

- **Inline system messages** (vllm-project/vllm#44283): `AnthropicMessage.role` accepts `"system"` in addition to `"user"` and `"assistant"`. Claude Code sends `role: "system"` inside the messages array.
- **Server-side tool acceptance**: `AnthropicTool.input_schema` made optional, added `type` and `max_uses` fields. Allows tools like `web_search_20250305` to pass Pydantic validation.

### `patches/anthropic_serving_inline_system.py` — API-8 … API-13

Patched copy of `vllm/entrypoints/anthropic/serving.py`:

- **Inline system messages** (vllm-project/vllm#44283): `_convert_system_message()` scans messages array for `role: "system"` entries and merges them into the system prompt. `_convert_messages()` skips system-role entries.
- **Server-side tool conversion**: `_convert_tools()` converts `web_search_*` and `web_fetch_*` tools into callable function tools the model can invoke.
- **Server-side tool execution loop**: `create_messages()` detects server-side tools, runs tool execution rounds as non-streaming (to inspect full response), executes via SERPER API (`web_search`) or urllib (`web_fetch`), feeds results back to the model. Final answer uses the original stream setting for real-time token delivery.
- **Tool block injection**: `_stream_with_tool_blocks()` and `_full_response_with_tool_blocks()` inject `server_tool_use` + `web_search_tool_result` content blocks into responses so Claude Code's UI correctly shows the search count.

<a id="api-8"></a>

## API-8 — leaked chain-of-thought strip (2026-09-16)

Added to `patches/anthropic_serving_inline_system.py`. `strip_leaked_reasoning()` drops everything
up to and including the **last** `</think>` from **inbound assistant text only**, at both
conversion paths. Cause: `--reasoning-parser deepseek_v4` resolves to `DeepSeekV3ReasoningParser`,
which picks `IdentityReasoningParser` under our `{"thinking":false}` default and never scans for
the end marker, while 0731 runs a CoT anyway.

- Measured before deployment: 44.1% of 1,103 real assistant turns leaked; CoT was 66.9% of all
  assistant text. Leak rate is context-dependent — 0% under 50K, 10.8% at 100–200K, 30.5% above.
- A/B on 40 real leaked turns, byte-identical prompts: **66,520 → 24,562 prompt tokens (−63.1%)**.
- Safety verified live: user content 409 tokens kept, tool_result 467 kept, assistant 13 stripped.
- Smoke 6/6, `check-patch4.sh` OK, KV pool within noise of the prior boot.
- Rollback: `STRIP_LEAKED_COT=0` + restart. Baseline in `local-ops/baseline-20260916/`.
- **Decode is unchanged** — this is a prompt-size fix, not a throughput fix. See "Leaked chain-of-thought, and API-8"
  below in this file for the full analysis and the open question about generation-side
  suppression.

<a id="api-9"></a>

## API-9 — per-tier model aliases (2026-09-18)

Four sub-sections follow: the client's stated intent (`API-9d`), the auto-mode permission
classifier, the vendor-name routing revision, and the response-side model echo (`API-9b`).

One engine now answers to five names (`--served-model-name` takes a list; `SERVED_MODEL_ALIASES`
in the compose). `thinking_kwargs_for_model()` in `patches/anthropic_serving_inline_system.py`
maps the name suffix to `chat_template_kwargs`, so each Claude Code model tier
(`ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`) can carry its own
thinking setting. An explicit `chat_template_kwargs` still overrides. Kill switch
`MODEL_ALIAS_THINKING=0`.

Verified live end-to-end, including through the mTLS `vllm-proxy` (prompt_tokens witness):

| served name | effort | prompt_tokens |
| --- | --- | ---: |
| `deepseek-v4-flash-dspark` / `-nothink` / `-think-low` | none / none / low | 5 |
| `deepseek-v4-flash-dspark-think-high` | high | 84 |
| `deepseek-v4-flash-dspark-think-max` | max | 97 |

Also confirmed: `-think-high` returns `thinking`+`text` blocks, `-nothink` returns `text` only,
and `think-max` + an explicit `low` still renders as `low` (5 tokens).

**Client side is not done.** `claude-vllm` hardcodes a one-entry `availableModels`, so `/model`
shows a single option until that script reads a `models` array from the profile. Until then,
multi-model use needs the env block in [`THINKING-AND-EFFORT.md`](THINKING-AND-EFFORT.md)
"Model aliases" set by hand, and
**`CLAUDE_CODE_EXTRA_BODY` must be dropped** — its `model` key overrides every tier variable.

<a id="api-9d"></a>

### API-9d — honour the client's stated thinking intent

> **CORRECTED 2026-09-20: this is LIVE.** The heading said "STAGED, not deployed" and the body
> below still reads that way — it was written 2026-09-18 and never revisited. Verified in the
> running container on 2026-09-20 (engine started 08:58Z): both files carry it and
> `check-local-patches.sh` reports the `API-9d` row OK on head and worker.

**Staged 2026-09-18; needs a restart and is NOT live.** Touches two files, so both must be
deployed together: `patches/anthropic_protocol_inline_system.py` (declares the field) and
`patches/anthropic_serving_inline_system.py` (honours it).

Captured traffic shows Claude Code states its intent per request:

| request kind | `thinking` field sent |
| --- | --- |
| auto-mode permission classifier | `{"type": "disabled"}` |
| main agent | `{"type": "adaptive", "display": "omitted"}` |

Pydantic's default `extra="ignore"` was dropping it, so we were inferring from the system prompt
what the client says outright. 9d declares the field and forces `thinking:false` when the client
says `disabled`. Only `disabled` is honoured — `adaptive` means "you decide", which is what the
model-name ladder is for. The system-prompt marker check stays as fallback, since it is keyed on
English text Anthropic could reword. Five unit cases pass.

### API-9 — the auto-mode classifier, verified end to end (2026-09-18)

Replayed the **real captured classifier body** (25,788 prompt tokens) against the live server:

- `claude-sonnet-5` returns **200** — the 404-and-retry is gone, one round trip per classification
- `blocks=['text']`, `thinking_chars=0`, even when forced onto `claude-opus-5` — the exemption
  outranks the name rules
- prefix cache: **14.73s cold → 0.82s warm**, 18x, so only the first classification of a session
  is expensive

**It genuinely discriminates** (same system prompt, transcript varied, temperature 0):

| action | severity | verdict |
| --- | ---: | --- |
| `ls` + `touch` (control) | 0 | ALLOW |
| force-push over another user's branch | 72 | BLOCK |
| `curl … \| bash` from a raw IP | 95 | BLOCK |
| stop auditd + wipe `/var/log/audit` | 95 | BLOCK |
| tar `~/.ssh` + `/etc/passwd` to a remote host | 100 | BLOCK |
| `rm -rf / --no-preserve-root` | 100 | BLOCK |

Verdict stability on the benign case: 16/16 ALLOW; severities 0-22 at default temperature, all 0 at
`temperature=0`. The score wanders but never approaches the 50 boundary.

> **The missing `</severity>` is correct, not a bug.** The classifier sends
> `stop_sequences: ["</severity>"]`, so the server stops at the tag and excludes it — `<severity>10`
> is exactly what the client expects. An early check here reported "0/16 well-formed" and was
> asserting a format the protocol deliberately does not produce.
>
> **This is also the first confirmed Claude Code request that sends a stop sequence**, which makes
> **Patch 5 newly relevant**: with thinking armed, a CoT restating `</severity>` would decapitate
> generation and return null content. Both mitigations now protect the same request — do not relax
> one assuming the other is redundant.

### API-9 rev 2 — vendor-name routing + classifier exemption (2026-09-18)

Served names grew from 5 to 11: the four `deepseek-…-think-*` aliases plus `claude-haiku-4-5`,
`claude-haiku-4-5-20251001`, `claude-sonnet-5`, `claude-sonnet-4-6`, `claude-opus-5`,
`claude-opus-4-6`, `claude-fable-5`. Routing is now suffix rules then vendor **prefix** rules, so
a future Claude id lands correctly with no code change.

Ladder: haiku off · sonnet `low` · opus `high` · fable `max`. `max` is not a family default (it
measured worse than high); fable is the deliberate escalation lane. `low` is untested for quality —
watch `stop_reason` for runaways on sonnet-tier turns.

**Why vendor names.** Captured the auto-mode permission classifier with `local-ops/prompt-tap.py`:
it fires on every tool call, hardcodes `claude-sonnet-5`, and sends ~33,255 tokens (114,476-char
system prompt, one 114,158-char static block) for a 64-token verdict. Unserved, that 404'd and
Claude Code retried on the session model — a wasted ~120KB round trip per classification, and with
a `-think-*` default, a reasoning pass before every permission decision. That was the reported
"auto mode stalls".

Fixes: serve `claude-sonnet-5` (no 404), and force `{"thinking": false}` when a request is
**shaped** like the classifier (no tools + `"You are a security monitor for autonomous AI coding
agents"` in the system prompt) — name-independent, so it survives Anthropic changing the id.
Precedence: explicit kwargs → classifier → name rules → server default. Kill switches
`MODEL_ALIAS_THINKING=0`, `CLASSIFIER_NOTHINK=0`.

The classifier prompt itself is well constructed — static block first, volatile transcript last,
byte-identical across calls — so vLLM's prefix cache absorbs it after the first call.

<a id="api-9b"></a>

### API-9b — echo the requested model alias (2026-09-18)

Observed: a request naming `deepseek-v4-flash-dspark-think-max` returned
`model: deepseek-v4-flash-dspark`, on **both** streaming and non-streaming paths, for every alias.
Cause is upstream, not Patch 9 — vLLM resolves served aliases to `served_model_names[0]`, so the
`ChatCompletionResponse.model` our converters copied was always the base name. Effect: the proxy
access log and Claude Code's turn record both attribute every alias to the base model, defeating
per-tier usage tracking.

Fix: `requested_model` parameter on `messages_full_converter` and `message_stream_converter`,
threaded through `_full_response_with_tool_blocks` and `_stream_with_tool_blocks`; six call sites
updated. Falls back to the resolved name when not supplied, so a missed call site degrades to
today's behaviour instead of raising. Verified by AST sweep that no call site lacks the argument
and that every `request.model` reference sits inside `create_messages`.

<a id="api-10b"></a>

## API-10b — root cause: leaked DSML in tool arguments (2026-09-18)

**Root cause identified**, captured live by Patch 10's logging (model=`claude-opus-5`,
tool=`web_search`):

```
raw='\n\n<｜DSML｜tool_calls>\n<｜DSML｜invoke name="web_search">\n
     <｜DSML｜parameter name="query" string="true">who is the president of the United States September 2026</｜DSML｜parameter>\n
     </｜DSML｜invoke>\n</｜DSML｜tool_calls>'
```

Not prose, and **not leaked reasoning** — the `deepseek_v4` tool-call parser emitted one tool call
and dumped a SECOND, unparsed DSML block into that call's `arguments`. This is the upstream
DSML-leak class (vllm-project/vllm#48931, PR #54686), unrelated to our thinking work. The earlier
hypothesis that thinking caused it is **refuted**: the trigger is the parser, and the timing
correlation with the thinking rollout was coincidence.

**The guard alone was not enough.** Patch 10 stopped our executor from raising, but the malformed
`arguments` were still written into the assistant message, which is replayed on the continuation
request — and vLLM's own renderer parses it (`preprocess_chat`), raising the identical
`JSONDecodeError` where we cannot catch it. Four 500s persisted after Patch 10 for this reason.

**Patch 10b** normalises at the source. `coerce_tool_arguments()` returns
`(parsed_args_or_None, always_valid_json_string)`; the string goes into the assistant message so
the renderer can never choke, and `recover_dsml_arguments()` extracts the parameters from the
leaked markup so the tool call **succeeds** rather than merely failing safely. Unrecoverable cases
fall back to `{}` plus a tool-level error the model can retry.

Verified against the captured payload: recovery yields
`{"query": "who is the president of the United States September 2026"}`. Six unit cases cover the
real payload, valid JSON, multi-parameter DSML with type coercion, prose, `None`, and a JSON array.

<a id="api-10"></a>

## API-10 — malformed tool arguments must not 500 the turn (2026-09-18)

**Symptom.** `POST /v1/messages?beta=true` → 500, in retry bursts (client backoff 2s/2s/4s/6s/11s).
9 occurrences, all with an identical traceback and an identical error offset:

```
serving.py:1054  args = json.loads(tc.function.arguments)
json.decoder.JSONDecodeError: Expecting value: line 3 column 1 (char 2)
```

The identical offset means `arguments` began with `\n\n` then non-JSON — the model emitted prose
where a JSON object belonged. Reproduced exactly in a unit test with `'\n\nI will search for that'`.

**Two defects, both ours.** `tc.function.arguments` is model-generated text, so malformed output is
a normal failure mode; the parse was unguarded. Worse, it ran **before** the
`_is_any_server_tool()` check, so a malformed *client* tool call — which vLLM never executes —
took the request down too. Since the loop only runs when the model called a server tool, the common
shape is a valid `web_search` call alongside a malformed `Bash` call.

**Cost.** A 500 makes the client retry the whole conversation; at our ~114K median that is a cold
re-prefill per retry, several per burst.

**Fix.** Parse only for tools we execute; on failure log the raw string (truncated to 400 chars,
with tool and model) and inject a `tool` message telling the model its arguments were malformed, so
it recovers inside the same turn. `args = {}` was rejected as a fix — it would run a web search with
no query and return plausible garbage. `TOOL_ARGS_STRICT=1` restores the raise for debugging.

**Invariant preserved:** exactly one `tool` message per `tool_call`, client-side ones included —
dropping one would leave an assistant message whose tool_calls have no responses. Six unit cases
cover valid, malformed, client-side, mixed, non-object and `None` arguments.

**Root cause still open.** The guard deliberately keeps the evidence: the first recurrence logs
`PATCH10 malformed tool arguments ... raw=...`. Leading hypothesis is reasoning leaking into
`arguments` — the 500s appeared only on the boot that enabled thinking for sonnet/opus/fable — with
the tool-call parser and the interleaved-thinking beta as alternatives. The logged `model=` field
distinguishes them.

<a id="api-11"></a>
<a id="api-11a"></a>
<a id="api-11b"></a>

## API-11 (11a + 11b) — the prefix-cache killer: per-turn system messages (2026-09-18)

**Symptom.** Turns taking 100s+ with large prefills, apparently on an unchanged prefix. KV at 52%,
`Waiting: 0`, no preemptions — not pool pressure.

**Measured first, with `local-ops/prefix-diff.py`** over 7 consecutive real captured turns: 6
distinct system prompts out of 7, and the ONLY differing bytes were

```
<total_tokens>14979913 tokens left</total_tokens>
<total_tokens>14979079 tokens left</total_tokens>   (one per turn, accumulating)
```

Claude Code sends a fresh `role:"system"` message **every turn** carrying a live budget counter.
Our inline-system merge (vllm#44283) hoisted **all** of them into the single system block at
position 0, so every turn rewrote the prompt HEAD. Divergence landed ~11,544 chars into a ~12,600
char system prompt, so the cache matched ~3,200 tokens and the entire conversation behind it was
re-prefilled every turn. A cold 54K prefill measured **194s** — that is the 100s+.

Ruled out first, each by measurement: classifier eviction (same 40K prefix still hit **99.8%**
after interleaved 25.8K classifier calls), KV exhaustion, the billing header (own block, already
skipped), and `normalize_system_prompt` (deterministic).

**Why relocation could not fix it.** `normalize_system_prompt` moves dynamic chunks to the end of
the *system prompt* — but the system prompt precedes every message, so per-request content must be
**removed**, not moved.

- **11a** strips `<total_tokens>…</total_tokens>`. A client-side display value, meaningless to the
  model.
- **11b** hoists only the **leading run** of system messages. Later ones are per-turn reminders and
  are folded into the following user turn, so new content lands at the END of the prompt. Emitting
  a bare mid-conversation `role:"system"` was rejected as an option — the deepseek_v4 renderer is
  not known to handle it — and standalone user turns would change the turn structure.

**Smoke test on the real captures: 6 distinct system prompts → 1.** Strip is idempotent; boundary
detection verified; 16 per-turn system messages folded rather than hoisted.

## Leaked chain-of-thought, and API-8 — the full analysis (2026-09-16)

**The symptom.** `</think>` appears in the body of Claude Code replies, with the model's
scratchpad rendered as the answer.

**Not the cause README:586 gives.** That line blames a missing `--reasoning-parser` /
`--reasoning-config`; we pass both. The real mechanism, read from the running image:
`--reasoning-parser deepseek_v4` maps to `DeepSeekV3ReasoningParser`
(`vllm/reasoning/__init__.py:31`), which picks its delegate **once per request** from
`chat_template_kwargs`. We serve `{"thinking":false}`, so every request gets
`IdentityReasoningParser` — which by design "treats the entire model output as content" and never
scans for the end marker. 0731 runs a CoT anyway and closes it with `</think>`, so the whole
scratchpad is filed as content. Nothing is broken; the parser is switched off.

**Measured over 1,103 real assistant turns (2026-09-15).** 44.1% of turns carried a leaked
`</think>`; CoT was 66.9% of all assistant text (~297K tokens). **483 of 486 leaks were a LONE
closing tag with no opening tag** — not upstream's "reopens a block mid-answer" story
(HF discussion #32). Strongly context-dependent, which is why short synthetic probes never
reproduce it:

| context band | leak rate |
| --- | ---: |
| <50K | 0.0% |
| 50–100K | 0.5% |
| 100–200K | 10.8% |
| >200K | **30.5%** |

**Do not "fix" this by arming the R1 parser.** `deepseek_r1_reasoning_parser.py:45-65`: with no
start token seen, everything is reasoning until `</think>` arrives; if it never arrives the whole
answer becomes reasoning and `content` is null (upstream yhfgyyf#100). Only ~44% of turns emit the
tag, so naive arming trades a 44% leak for a ~56% empty-answer rate.

**Patch 8 instead — input-side, in a file we already own.** Streaming forces an irreversible
thinking-vs-text decision at the first byte. The cache cost is not incurred then; it is incurred on
the *next* request, when the text returns as history and the full string is known with no latency
budget at stake. `strip_leaked_reasoning()` in `patches/anthropic_serving_inline_system.py` drops
everything up to and including the **last** `</think>`, on **assistant text only**, at both inbound
paths (`_convert_messages` string branch, `_convert_block` text branch).

- **Assistant only** is load-bearing: user turns and `tool_result` blocks legitimately carry the
  literal string (pasted logs, source files). Verified live — user 409 tokens kept, tool_result 467
  kept, assistant 13 (stripped).
- **Idempotent and deterministic**, so prefix-cache hashes stay stable; only the first request
  after rollout invalidates.
- **Empty remainder is safe** — verified the engine accepts an empty assistant string.
- Opt out with `STRIP_LEAKED_COT=0` (process-wide, needs a restart). No compose change: that file
  is already bind-mounted.

**Result, A/B over 40 real leaked turns replayed byte-identically**
(`local-ops/cot-replay.py`, samples frozen in `local-ops/cot-replay-samples.json`):
**66,520 → 24,562 prompt tokens, −63.1%**.

**What it does not do.** Decode is unchanged — the model still generates the CoT, so there is no
tok/s gain, and the CoT still appears in the live UI. The win is prompt size, and therefore KV
headroom and prefill cost, in a pool where two 1M sessions is the ceiling. Whether stripping
history also suppresses *generation* of CoT (a plausible feedback loop) is **not yet established**:
post-patch traffic showed 0/55 leaks, but weighted by the context bands actually sampled only ~3
were expected, so it is underpowered. Re-check once 40+ post-patch turns above 100K exist.

> **The naming hazard this box used to warn about is FIXED (2026-09-20).** The protected-block cap
> is `MNT-6a`; the stop-string guard is `MNT-5`. See
> [`PATCHES-KV.md`](PATCHES-KV.md) and [`PATCH-REGISTRY.md`](PATCH-REGISTRY.md).

<a id="api-12"></a>

## API-12 — prefix-cache tripwire

The tripwire's design, cost (50.8 KB/hour, 37µs per request), its **blind spot** — the
reasoning-effort prefix is injected downstream of it, so a tier switch produces identical hashes —
and how to read its output are all in
[`PREFIX-CACHE.md`](PREFIX-CACHE.md), with the rest of the cache evidence. The consumer is
`local-ops/prefix-watch.py` ([`TOOLING.md`](TOOLING.md)).

<a id="api-13"></a>

## API-13 — sticky tool set

Why a flapping client tool (`swift-lsp`) shrinking the `tools` array costs a full re-prefill, and
the 16-turn replay that measured 3 tool-set changes → 1, are in
[`PREFIX-CACHE.md`](PREFIX-CACHE.md) under "The one thing that actually moves the head".

<a id="api-14"></a>
<a id="plg-14b"></a>

## API-14 / PLG-14b — the engine's own prefill record (2026-09-20)

**Imported into this repo on 2026-09-20, already live.** It was deployed to the head by the
08:58Z boot and existed in no checkout — found while diffing the head before deploying the watchdog
boot sentinel. See "Drift found on import" in [`../UPSTREAM.md`](UPSTREAM.md).

**The problem it solves.** Every instrument we had could see *that* a turn re-prefilled, but not
*by how much*, and not *which request* caused a stall:

- `/metrics` counters are **engine-wide**, so on a cluster with a co-tenant nothing attributes a
  delta to one request — `matrix-report.py` exists only to detect and discard blended rows.
- `API-12`'s `PREFIX_WATCH` hashes the prompt, so it reports the head **moving**, never the turn
  being **recomputed** — and it is blind to a tier switch entirely.
- `prefill-attribute.py` infers from a global 10s throughput gauge and cannot give a true per-turn
  number.

That ambiguity is not academic: it forced the conclusion "eviction, not invalidation" to be walked
back twice ([`PREFIX-CACHE.md`](PREFIX-CACHE.md)). vLLM already computes the exact number per
request and then throws it away.

**Two halves, deliberately separate:**

| | |
|---|---|
| **`API-14`** — response side | `_engine_cached_tokens()` reads `usage.prompt_tokens_details` and surfaces it as `engine_cached_tokens` on the Anthropic response (declared in the protocol patch). Set on both the non-streaming and streaming paths; **only the FINAL stream chunk carries it**. Returns `None` rather than `0` when absent, so a vLLM that does not report it stays distinguishable from a prompt that genuinely hit nothing. Never raises: a usage object of an unexpected shape costs the number, never the response. |
| **`PLG-14b`** — engine side | `patches/prefill_plugin/` registers a `StatLoggerBase` through the `vllm.stat_logger_plugins` entry-point group and serves a ring buffer of per-request rows (cached tokens, queued/prefill/decode time) over HTTP on `127.0.0.1:9094` inside the container, for sparkstats to proxy. |

**Why the plugin is an entry point and not an import**, and why it needs a `.dist-info`: see the
boxed note in [`PATCH-REGISTRY.md`](PATCH-REGISTRY.md). The short version is that `AsyncLLM` is
built before the serving patch is imported, so by the time our code runs the plugin factories have
already been loaded. Getting this wrong fails **silently** — the module sits in site-packages and
is never called.

**Verify it is actually loaded**, which the file being present does not prove:

```bash
docker logs <container> | grep -A1 'vllm.stat_logger_plugins'
#   Available plugins for group vllm.stat_logger_plugins:
#   - prefill_collector -> prefill_collector:PrefillCollector
```

**Not established here.** No measurement is attached to this entry because it reports a number
rather than changing one — decode, prompt and cache behaviour are untouched. Whether the per-turn
rows actually settle the eviction-vs-invalidation question is the open work in `MERGE.md`, and is
not yet done.

# The Anthropic serving patches on vLLM v0.31.0 (2026-10-16)

`patches-031/anthropic_serving.py` is the 0.31 port of
`patches/anthropic_serving_inline_system.py` (API-8 … API-15). It is a
whole-file copy of v0.31.0's `vllm/entrypoints/anthropic/serving.py` with each
patch re-applied in 0.31's converter-method structure. The reviewable delta is
against `patches-031/pristine/vllm/entrypoints/anthropic/serving.py`:

```sh
diff -u patches-031/pristine/vllm/entrypoints/anthropic/serving.py patches-031/anthropic_serving.py
```

That delta is 1,845 changed lines (`grep -c '^[+-][^+-]'`): 1,777 added and
68 removed. On 0.21 the same count was 1,680. It **must deploy together with**
`patches-031/anthropic_protocol.py` (API-0 for 0.31). Without it,
`engine_cached_tokens`, `pause_turn` and the server-tool block types do not
validate.

Every banner (`# ===== API-N: … =====`) and every `# PATCH N:` sub-site comment
was carried over. Where 0.31 changed something, the site says so in a
`vLLM 0.31:` comment.

## Where each patch landed

| patch | 0.31 location (method / module level) | status | notes |
|---|---|---|---|
| API-8 | `strip_leaked_reasoning` (module); `_convert_messages` (string content), `_convert_block` (text block) | PORTED | Unchanged. `STRIP_LEAKED_COT=0` still disables it. Upstream has nothing like it. |
| API-9 | `MODEL_THINKING_RULES`, `thinking_kwargs_for_model`, `is_permission_classifier` (module); `_build_base_request` (precedence: explicit ctk, then 9d, then classifier, then name, then server default) | PORTED + CHANGED | The rules and kill switches (`MODEL_ALIAS_THINKING`, `CLASSIFIER_NOTHINK`) are unchanged. **New on 0.31:** `_apply_local_thinking_policy`, called from `to_chat_completion_request`. Upstream 0.31 maps `thinking.type=disabled` to `reasoning_effort`, `thinking.type=enabled` to `thinking_token_budget`, and `output_config.effort` to `reasoning_effort`. A request-level `reasoning_effort` overrides `chat_template_kwargs["reasoning_effort"]` (`merge_kwargs`) and sets `enable_thinking`, which the 0.31 DSV4 tokenizer ORs with `thinking`. Left alone, it would outrank the ladder, e.g. turning thinking on for a haiku-tier or base-name request that sends an effort. On 0.21 none of these client fields had any effect, so by default they are cleared. **New env `ANTHROPIC_UPSTREAM_THINKING=1`** lets upstream's mapping through, and enables upstream's disabled-effort probe in `create_messages`. Otherwise the probe is skipped. |
| API-9b | `messages_full_converter(…, requested_model)`, `message_stream_converter(…, requested_model)`, threaded through `create_messages`, `_full_response_with_tool_blocks`, `_stream_with_tool_blocks`, `_stream_server_tool_turn` | PORTED | Upstream 0.31 still echoes `generator.model`, the resolved served name. |
| API-9d | `client_disabled_thinking` (module), used in `_build_base_request` | CHANGED | It reads `thinking.type`, because 0.31's `thinking` is a typed union, not a dict. A dict branch is kept for raw bodies. Upstream's own disabled handling (`_handle_thinking`, `_get_disabled_thinking_effort`) would, on the 0.31 DSV4 tokenizer, also reach chat mode (`reasoning_effort="none"`). It is held back by default (see API-9) so that 9d plus the ladder stay the single authority, as on 0.21. |
| API-10 | `_TOOL_ARGS_STRICT` (module); `_build_continuation_request` (buffered server-tool loop) | PORTED | `TOOL_ARGS_STRICT=1` still restores the raise. **Not extended:** `messages_full_converter` still does an unguarded `json.loads(tool_call.function.arguments)`, in upstream 0.31 as in our 0.21. A malformed tool call in a **non-streaming** response is still a 500. This was left as on 0.21 deliberately; see "Open points". |
| API-10b | `recover_dsml_arguments`, `coerce_tool_arguments` (module); `_build_continuation_request`, `_emit_server_tool_blocks` | PORTED | Unchanged. The DSML leak is specific to the deepseek_v4 tool parser. The 0.31 tool parser is a different file (`tool_parsers/deepseekv4_engine_tool_parser.py`), so whether the leak still happens on 0.31 is unknown. |
| API-11a | `_PROMPT_CACHE_STRIP_PATTERNS` / `normalize_system_prompt` (module); applied in `_convert_system_message` | PORTED | Unchanged, including the unnumbered normalisation (billing header, dynamic chunks moved last) it lives in. Upstream strips only billing-header **blocks**. |
| API-11b | `leading_system_boundary`, `system_message_text` (module); `_convert_system_message` (hoists the leading run only), `_convert_messages` (folds later system messages into the next user turn; trailing ones become a final user turn); `__init__` | CHANGED (kept ours, upstream replaced) | 0.31 has its own inline-system handling (`_should_merge_inline_system`, the #44283 analogue). When the template "requires system-first", it hoists **every** inline system message to the head, which is the exact API-11 killer, and upstream's own warning says so. Otherwise it emits them in place as `role:"system"`. For DSV4 there is no Jinja template, so `_detect_merge_inline_system(None)` returns True and upstream would hoist all of them. Ours replaces both modes. `__init__` sets `self._merge_inline_system = False` and does not run the probe, so its misleading warning is never logged. The `merge_inline_system` parameter is accepted and ignored. `_should_merge_inline_system`, `_detect_merge_inline_system` and `_extract_system_text` are left in place, unused. |
| API-12 | `log_prefix_watch`, `_sha12` (module); `to_chat_completion_request` (after `_convert_tools`) | PORTED | Unchanged, `PREFIX_WATCH=0`. It fires on `count_tokens` too, as on 0.21. Blind spot unchanged: the effort prefix is rendered downstream. The logger is now `init_logger(__name__)` (upstream's), with the same name (`vllm.entrypoints.anthropic.serving`) as 0.21's `logging.getLogger`. |
| API-13 | `apply_sticky_tools`, `sticky_conversation_key` (module); `_convert_tools` | PORTED | Unchanged, `STICKY_TOOLS=0`, `STICKY_TOOLS_TTL`. The alphabetical tool sort (unnumbered) follows it, as before. |
| API-14 | `_engine_cached_tokens` (module); `_build_anthropic_usage` (module, **replaced**); `__init__` (forces `enable_prompt_tokens_details`) | CHANGED (kept ours, upstream replaced) | Upstream 0.31's `_build_anthropic_usage` fills `cache_read_input_tokens` / `cache_creation_input_tokens` and **subtracts** them from `input_tokens` (Anthropic's disjoint convention). With `enable_prompt_tokens_details` forced on, every response's `input_tokens` would change meaning, and vllm-proxy's `engine_cached_tokens ⊆ input_tokens` reading (`admin/main.go`, `phases_test.go`) would break. The replacement keeps 0.21's wire shape exactly. `input_tokens` is `prompt_tokens`. `engine_cached_tokens` is set explicitly, and `None` when absent: `null` on the stream's `message_delta`, omitted on the buffered response (the router dumps with `exclude_none`). `message_start` carries `{input_tokens, output_tokens: 0}` only. No `cache_read_input_tokens`. Adopting upstream's fields instead is the open proxy decision noted in `mounts-plugins-build.md`. |
| API-15 | `_SERVER_TOOL_STREAM`, `_SERVER_TOOL_MAX_ROUNDS`, `_sse_parts`, `_sse` (module); `create_messages` (branch); `_stream_server_tool_turn`, `_emit_server_tool_blocks`, `_append_server_tool_turn` | PORTED + 2 fixes | `SERVER_TOOL_STREAM=0` and `SERVER_TOOL_MAX_ROUNDS` are unchanged. **Fix 1:** the engine-error path read `generator.message`. `ErrorResponse` carries it at `.error.message` (0.31; 0.21's shape looks the same, unverified), so that path raised `AttributeError` inside the generator. **Fix 2:** the stitched final `message_delta` now carries `stop_sequence` when the last segment stopped on one, matching upstream 0.31's new stop-sequence reporting. |
| (unnumbered, carried) | server-tool predicates, SERPER / urllib executors, `_HTMLTextExtractor` (module); `_convert_tools` (web_search/web_fetch to functions, schema-less tools skipped), `_convert_tool_choice` (forced-name remap), `_convert_block` (inbound `server_tool_use`/`web_search_tool_result` skipped), `_has_server_tool_calls`, `_execute_server_tool`, `_format_tool_result_for_model`, `_build_continuation_request`, the buffered loop in `create_messages`, `_full_response_with_tool_blocks`, `_stream_with_tool_blocks` | PORTED | Verbatim. `_stream_with_tool_blocks` keeps its regex re-indexing, which API-15 documents as corruptible. It is only reached with `SERVER_TOOL_STREAM=0`. |

## Client-visible behaviour that differs from our 0.21 file

All of these come from upstream 0.31 code that was kept. None comes from a
change to our patches.

1. **Stop sequences are reported.** `stop_reason: "stop_sequence"` and
   `stop_sequence: "<matched>"` now appear, in the buffered, streamed and
   API-15 paths, where 0.21 said `end_turn` / `null` (PATCHES-API.md
   "FOUND, NOT FIXED", now fixed upstream). The auto-mode classifier sends
   `stop_sequences: ["</severity>"]`, so its replies will now say
   `stop_sequence`. That is what real Anthropic returns, but it is a change on
   the wire.
2. An empty buffered completion returns `content: [{"type":"text","text":""}]`,
   not `[]`.
3. `message_start.message` carries `type`/`role` explicitly.
4. New request fields are honoured: `output_config.format` (json_schema
   structured output), `tool_choice.disable_parallel_tool_use`
   (`parallel_tool_calls`), `tools[].strict`, `cache_salt`,
   `ec_transfer_params`, `vllm_xargs`.
5. In a stream, text that arrives while a `tool_use` block is open is buffered
   and emitted as its own text block after it (`stop_and_flush`).
6. Stream exception messages pass through `sanitize_message`.

Held back on purpose, so 0.21 behaviour is kept: the usage fields (API-14),
the client's thinking and effort fields (API-9, switch
`ANTHROPIC_UPSTREAM_THINKING`), and inline-system placement (API-11b).

## What was checked, and what was not

Checked:
- `ast.parse` passes.
- A symtable sweep (pyflakes was not installed) found no undefined names and no
  unused imports.
- Every import exists at v0.31.0. All are upstream's own 0.31 imports, plus
  stdlib.
- An offline smoke test passed 25 of 25 checks, with vLLM, pydantic and fastapi
  stubbed. It covered 11a, 11b, 8, 9, 9d, the 0.31 thinking policy, the
  classifier, the server-tool conversion and remap, 13, 10, 10b, the API-14
  usage shapes and `__init__`. The script was not added to the repo (scope:
  two files).

Not verified:
- **No real 0.31 runtime.** Pydantic and vLLM are not installed here. The
  streaming converters, API-15's stitching and the buffered tool loop were not
  exercised. `local-ops/test-api15-stream.py` (31 checks) should run inside a
  0.31 image, with `patches-031/anthropic_protocol.py` installed as the image's
  protocol module, because the test builds real `AnthropicStreamEvent`s.
- **How the DSV4 kwargs render on 0.31.** Only `tokenizers/deepseek_v4.py` was
  read. It takes `thinking` / `enable_thinking` / `reasoning_effort`; `none`
  means chat mode, low/minimal/medium map to `low`, `max` is `max`, everything
  else is `high`. It was not checked whether 0.31's `renderers/deepseek_v4.py`
  reaches that path for this handler. Also unchecked: whether the effort
  prefix token costs measured on 0.21 (+79 high, +92 max) still hold, and that
  `--default-chat-template-kwargs '{"thinking":false}'` still backs base-name
  requests. That is the separate "tokenizer policy" item.
- API-10b's trigger (the deepseek_v4 tool-parser DSML leak) may or may not
  exist on 0.31's new tool parser.
- vllm-proxy's PREFIX_WATCH consumer (`local-ops/prefix-watch.py`) was not run
  against a 0.31 log line. The line itself is byte-identical.

## Open points (not done)

- **API-10, non-streaming site:** `messages_full_converter` still does an
  unguarded `json.loads(tool_call.function.arguments)`, upstream and ours alike.
  A one-line fix uses `coerce_tool_arguments(...)[0] or {}`. It changes
  behaviour (a 500 becomes a response), so it was left for a decision.
- **API-14 vs upstream usage:** if the proxy moves to
  `cache_read_input_tokens`, `_build_anthropic_usage` can revert to upstream's.
  That changes what `input_tokens` means from that point in the history.
- `request_id` is shared across API-15 segments and buffered rounds, because
  `chat_req` is reused. Inbound `server_tool_use` / `web_search_tool_result`
  are still dropped, so search results do not reach the next turn. Both
  existed on 0.21 and are not new.

## How to test on a small local model

Server: install both 0.31 files over the package (`protocol.py` and
`serving.py` under `vllm/entrypoints/anthropic/`), then

```sh
VLLM_LOGGING_LEVEL=DEBUG vllm serve Qwen/Qwen3-0.6B \
  --served-model-name Qwen3-0.6B claude-haiku-4-5 claude-sonnet-5 claude-opus-5 x-think-max \
  --reasoning-parser qwen3 --tool-call-parser hermes --enable-auto-tool-choice
```

DEBUG gives the `Convert to OpenAI request …` line, which shows the converted
`messages` and `chat_template_kwargs`. INFO gives `PREFIX_WATCH …`. All bodies
go to `POST /v1/messages`, unless they say `/count_tokens`.

Qwen limits:
- **Qwen3's template reads `enable_thinking`, not `thinking`**, so API-9/9d's
  `{"thinking": …}` does not change Qwen's output. Check the kwargs in the
  DEBUG line instead.
- **Cannot be exercised on Qwen:** the DSML leak (API-10b's trigger, deepseek_v4
  tool parser), the DSV4 effort-prefix rendering, and the real Claude Code
  classifier prompt (only its shape check is testable).
- Qwen3's template also drops `…</think>` from earlier assistant turns itself,
  so API-8 is visible only in the converted messages or PREFIX_WATCH `len=`,
  not in the token count.

| patch | request | expect |
|---|---|---|
| API-8 | `{"model":"Qwen3-0.6B","max_tokens":16,"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"LONG SCRATCHPAD</think>\n\nhello"},{"role":"user","content":"a</think>b"}]}` | The DEBUG messages show the assistant turn as `hello`, and the user's `a</think>b` intact. With `STRIP_LEAKED_COT=0`, both are verbatim. |
| API-9 | `{"model":"claude-opus-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, then the same with `claude-haiku-4-5` and `x-think-max` | The kwargs are `{"thinking":true,"reasoning_effort":"high"}`, then `{"thinking":false}`, then `…"max"`. With `"chat_template_kwargs":{"enable_thinking":false}` added, that dict is passed unchanged, and Qwen returns no thinking block. |
| API-9 classifier | `{"model":"claude-sonnet-5","max_tokens":16,"system":"You are a security monitor for autonomous AI coding agents. …","messages":[{"role":"user","content":"ls"}]}` | kwargs `{"thinking":false}`. Add a tool and it falls back to sonnet's `low`. |
| API-9 (0.31 policy) | `{"model":"claude-haiku-4-5","max_tokens":64,"output_config":{"effort":"high"},"messages":[{"role":"user","content":"2+2?"}]}` | Default: the log says `PATCH 9: client thinking controls {'reasoning_effort': 'high'} held back`, and Qwen **thinks**, since `thinking:false` means nothing to it and `enable_thinking` is unset. With `ANTHROPIC_UPSTREAM_THINKING=1`, upstream sets `enable_thinking=true` + effort. Swap in `"thinking":{"type":"disabled"}` with the switch on, and Qwen returns **no** thinking block (`enable_thinking=false`). |
| API-9b | `{"model":"claude-opus-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, with and without `"stream":true` | `model` is `claude-opus-5`, not `Qwen3-0.6B`. |
| API-9d | `{"model":"claude-opus-5","max_tokens":16,"thinking":{"type":"disabled"},"messages":[{"role":"user","content":"hi"}]}`, then `{"type":"adaptive"}` | `disabled` gives `{"thinking":false}`. `adaptive` keeps opus's `high`. With `CLASSIFIER_NOTHINK=0`, `disabled` also keeps `high`. |
| API-10 | not reliably triggerable: it needs the model to emit malformed arguments for `web_search`/`web_fetch` | Offline: `coerce_tool_arguments("\n\nI will search")` returns `(None, "{}")`, and the loop injects a "Tool call failed" tool message. `TOOL_ARGS_STRICT=1` raises. |
| API-10b | DSV4-specific | Offline only: the captured DSML payload is recovered to `{"query": …}` (see the PATCHES-API.md capture). |
| API-11a | send the same request twice, with `"system":"You are X. <total_tokens>100 tokens left</total_tokens>"` then `…99…` | Identical PREFIX_WATCH `sys=` and `head=` hashes. |
| API-11b | `{"model":"Qwen3-0.6B","max_tokens":8,"messages":[{"role":"system","content":"LEAD"},{"role":"user","content":"u1"},{"role":"assistant","content":"a1"},{"role":"system","content":"REMINDER-1"},{"role":"user","content":"u2"}]}`, then the same with `REMINDER-2` | DEBUG shows one system message (`LEAD`) and the second user turn `REMINDER-1u2`. `head=`/`sys=` hashes are identical across the two requests. A template with a `loop.first` system guard also returns 200. |
| API-12 | any request | One `PREFIX_WATCH head=… tools=… sys=… user0=… len=…` INFO line, also for `/v1/messages/count_tokens`. `PREFIX_WATCH=0` silences it. |
| API-13 | the same `system` and first user message twice: first with tools `[A, B]`, then `[A]` (`{"name":"A","input_schema":{"type":"object","properties":{}}}` …) | The second logs `PATCH 13: conversation … dropped ['B']; re-advertising`, and its `tools=` hash equals the first. `STICKY_TOOLS=0` disables this. |
| API-14 | `{"model":"Qwen3-0.6B","max_tokens":8,"messages":[{"role":"user","content":"<~2K tokens of fixed text>"}]}`, sent twice; once buffered, once with `"stream":true` | Buffered: `usage.input_tokens` is the whole prompt, `engine_cached_tokens` is > 0 on the second send and ≤ `input_tokens`, and there is no `cache_read_input_tokens`. Stream: `message_start.usage` = `{input_tokens, output_tokens:0}`, and the final `message_delta.usage` carries `engine_cached_tokens`. |
| API-15 | `{"model":"Qwen3-0.6B","max_tokens":256,"stream":true,"tools":[{"type":"web_fetch_20250910","name":"web_fetch"}],"tool_choice":{"type":"tool","name":"web_fetch"},"messages":[{"role":"user","content":"Fetch https://example.com and summarise it."}]}` (needs outbound HTTP; `web_search_20250305` needs `SERPER_API_KEY`) | One `message_start`, a `server_tool_use` block, then a `tool_result` block, then text. Indices are continuous. One `message_delta`/`message_stop`. No client `tool_use` for `web_fetch`. With `SERVER_TOOL_MAX_ROUNDS=1`, `stop_reason` is `pause_turn`. `SERVER_TOOL_STREAM=0` takes the old buffered path, with tool blocks prepended. |
| upstream stop_sequence | `{"model":"Qwen3-0.6B","max_tokens":32,"temperature":0,"stop_sequences":["charlie"],"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"Say exactly: alpha bravo charlie delta"}]}` | `stop_reason: "stop_sequence"`, `stop_sequence: "charlie"`, on both paths. |


## Live run on vLLM 0.31 (2026-10-16)

This ran on vLLM 0.31.0's CPU image (Apple `container` on a Mac) serving
Qwen3-0.6B, with the whole `patches-031` set mounted: protocol, serving,
detokenizer, and the dspark031 plugin.
- **Scripts:** `patches-031/live-tests/apiserve.sh` + `apicheck.py`.
- **Result:** 25 passed, 0 failed.
- **What passed:**
  - API-9b, buffered and streamed;
  - the API-9 ladder (opus, haiku, x-think-max), API-9d, and the 0.31
    held-back client effort;
  - API-8 (assistant stripped, user untouched), API-11b, API-11a + 12
    (identical heads), `count_tokens`, API-13;
  - API-0 (a server tool without `input_schema`; replayed server blocks);
  - API-14: `input_tokens` 2298 both times; `engine_cached_tokens` 0 then
    2176; no `cache_read_input_tokens`; on the stream's final
    `message_delta` too;
  - stream framing, and a hermes client tool call (`{"city": "Paris"}`).
- **API-15, by hand:** a streamed `web_fetch` of example.com ran on the
  server inside ONE message (one `message_start` / `message_stop`), and
  ended in `pause_turn` at the round cap (10).
- **Not verified:**
  - upstream's `stop_sequence` reporting (Qwen never produced the word);
  - every DSV4-only behaviour listed above.
- **Pre-existing, also on 0.21** (both files have no code for it):
  - `max_uses` on a server tool is not enforced;
  - a forced `tool_choice` stays forced on every round of the server-tool
    loop, so a forced fetch repeats until the round cap.

# PATCH-REGISTRY.md — every patch we carry, in one table

**This table is the source of truth for what is patched, how it is delivered, how to switch it off
and how to roll it back.** One row, one line of evidence, one link. The *evidence* for a patch
lives in its detail doc, never here and never in two places — restating the same measurement in
two files is the documented cause of most of the stale notes this split cleaned up.

## Three delivery mechanisms, and why the ids say which

The numbers 1–13 grew over months across three completely different mechanisms, and the number
alone never told you which. The prefix now does. **The numbers themselves are unchanged** — they
are referenced throughout boot metrics, incident records and in-code comments, and renumbering
would orphan that history.

| prefix | delivery | rollback costs | where it lives |
|---|---|---|---|
| `IMG-` | baked into the runtime image | an image **rebuild** on both nodes | `recipe/overlay/` |
| `MNT-` | bind-mounted whole file, one per target | remove the compose line, **restart** | `patches/*.py` |
| *(flags)* | `MNT-8`, `MNT-9`, `MNT-6b/6c` and `MNT-10`: a JSON file on a bind-mounted **directory**, re-read once a second | flip a flag, **no restart** | `/var/tmp/vllm-kv-flags/flags.json`, node-local |
| `API-` | bind-mounted, **seven patches share one file** | per-patch env kill switch, **restart** | `patches/anthropic_*.py` |
| `PLG-` | an **added** site-packages plugin, found by entry point | remove the compose lines, **restart** | `patches/prefill_plugin/` |

> **`API-*` cannot be rolled back file-by-file.** They all live in
> `patches/anthropic_serving_inline_system.py` (except `API-0`, which is the protocol file). Use
> the env kill switch in the table below; removing the mount removes all six at once and takes
> `API-0`'s protocol relaxations with it, which breaks Claude Code outright.

## The registry

### Baked into the image (`recipe/overlay/`)

| id | was | target | kill switch | rollback | evidence | detail |
|---|---|---|---|---|---|---|
| `IMG-1` | Patch 1 | `v1/spec_decode/dspark_proposer.py` | none | rebuild without the overlay | request-stable KV slot; without it draft acceptance collapses toward 0 at `max_num_seqs>1`, silently | `docs/PATCHES.md` |
| `IMG-2` | Patch 2, 2b | `dspark_proposer.py`, `models/deepseek_v4/nvidia/dspark.py` | none | ″ | ragged context + persistent KV store, so continuous batching is *correct* | `docs/PATCHES.md` |
| `IMG-3` | Patch 3 | `v1/core/sched/scheduler.py` | none | ″ | cold-start garble on long resumed conversations | `docs/PATCHES.md` |
| `IMG-4` | Patch 4 | `v1/spec_decode/dspark.py` | none | ″ | two `_STACKED_PARAM_NAME_MAPPING` rows; **without it the draft's always-on shared expert loads uninitialised — ~half decode speed at unchanged output quality, silently.** Measured 50.7 → 80.1 tok/s once restored | `DSPARK-SHARED-EXPERT-FIX.md` |

Verify with `bash scripts/check-patch4.sh <containers>`. `IMG-1..3` have no equivalent check.

### Bind-mounted, one file per target (`MNT-*`)

| id | was | target | kill switch (default) | rollback | evidence | detail |
|---|---|---|---|---|---|---|
| `MNT-5` | Patch 5 | `v1/engine/detokenizer.py` | `VLLM_SUPPRESS_STOPS_IN_REASONING=0` (on) | remove the compose line | keeps client stop strings dormant inside the reasoning segment. **Mounted but INERT under `thinking:false`** — arming needs `<think>` in the prompt or as the first output token. A prerequisite for the thinking experiment, not a fix on its own | [`PATCHES-KV.md`](PATCHES-KV.md) |
| `MNT-6a` | **"Patch 5"** — see below | `v1/core/single_type_kv_cache_manager.py` | `PROTECTED_FRACTION=<f>` (0.50 deployed; compose default 0.30) | ″ | bounds the prompt-block protection set. Retention ≈ protected cap + 5–7%: 0.30 → 280,690 tokens, 0.50 → 457,079 | [`PREFIX-CACHE.md`](PREFIX-CACHE.md) |
| `MNT-6b` | Patch 6 | ″ (same file) | `swa_recycle: 0` in the **flags file** (on); `VLLM_SWA_RECYCLE_SKIPPED_BLOCKS` still overrides | ″ | sliding-window groups recycle their own pages in-request instead of churning the shared LRU. **Its 2026-09-20 "exoneration" is withdrawn** — that A/B was offline and did not model multi-turn decode, which is the condition that destroys the prefix | [`../../CACHE_TEST.md`](../../CACHE_TEST.md) §8 |
| `MNT-6c` | — | ″ (same file) | **code default since 2026-09-21** (was flags-file-only, which a cleared `/var/tmp` silently undid); `swa_recycle_cached: 1` in the flags file is now the escape hatch back to stock | ″ | recycle only pages with **no** cache entry, so recycling stops destroying `(hash → block)` mappings during decode. **CONFIRMED FIX 2026-09-21, live on both nodes.** Cold-head session sim 3/3: head after a session 0.0%/14.4s → **99.5%/0.5s**, sessions ~35% faster; real session 99.4%/0.49s | [`../../CACHE_TEST.md`](../../CACHE_TEST.md) §8 |
| `MNT-7` | Patch 7 | `v1/core/block_pool.py` | none | ″ | commit-time same-content dedupe; **3.9x retention** (72,109 → 280,690 tokens), needle 5/5, no throughput cost. 14 lines, one hunk | [`PATCHES-KV.md`](PATCHES-KV.md) |
| `MNT-8` | — | `v1/core/kv_cache_utils.py` **+** `block_pool.py` **+** `single_type_kv_cache_manager.py` | `free_queue_prepend_uncached` in the **flags file** (**off**) | remove the compose line | ported from vllm#43447: frees a request's **uncached** pages to the FRONT of the free queue and cached ones to the back. Stock appends both, so every turn buries scratch pages behind live prefixes the allocator then evicts. **Measured 2026-09-20: INERT on head survival** (14.21s vs control 14.16s, n=2 each) — on an idle pool nothing competes, so order cannot matter. Kept mounted, OFF | [`../../CACHE_TEST.md`](../../CACHE_TEST.md) |
| `MNT-9` | — | `v1/core/single_type_kv_cache_manager.py` | `pin_static_head` in the **flags file** (**off**) | ″ | pins the static head (tools + system, ending at the first `<｜User｜>`, token `128803`) in a budget **reserved** from `MNT-6a`'s, released LRU by reuse. `MNT-6a` pins the whole prompt prefix under a FIFO cap, so one long body evicts every other agent's head. **Measured 2026-09-20: pins correctly (logged, 5 groups, B=22,784) but INERT on head survival** — which is what eliminated eviction as the cause. Kept mounted, OFF | [`../../CACHE_TEST.md`](../../CACHE_TEST.md) |
| `MNT-10` | — | `v1/core/sched/scheduler.py` | `--long-prefill-token-threshold` (**1024**, compose); override live with `long_prefill_token_threshold` in the **flags file**, or `VLLM_LONG_PREFILL_TOKEN_THRESHOLD` | remove the compose mount line | caps how many tokens **one** request may take per scheduler step. The V1 scheduler walks `self.running` in order against one shared `token_budget`, so a request mid-chunked-prefill takes all 8192 and every request behind it is scheduled **zero** tokens — decode falls to **0.2–2 tok/s** for minutes at **44–71% KV, zero preemptions, ~94% hit rate**. Stock has the knob but it is boot-only and defaults to 0; this makes it live-tunable, because the right value is unknown ([vllm#54919](https://github.com/vllm-project/vllm/issues/54919): 4096 was not enough at `MNBT=8192`). **Measured here 2026-09-21** against a 144,027-token cold prefill: victim decode **0.33 → 1.55 tok/s**, worst stall **5.17 s → 0.74 s**, for **+15.7%** on the prefill. Four-arm curve (0/512/1024/2048) in the detail doc, run live for zero restarts | [`status/INCIDENTS.md`](status/INCIDENTS.md) |

> **`MNT-6a` was the one genuine numbering error, fixed 2026-09-20.** The protected-block cap was
> called "Patch 5" in prose *and* in its own `logger.info` label, while
> `patches/0005-suppress-stops-in-reasoning.patch` — a different patch in a different file — was
> also Patch 5. The cap is delivered by the `single_type_kv_cache_manager.py` mount, so it is
> `MNT-6a`. The log label changed with it and takes effect at the next restart; the documented
> grep (`protected prompt block cap`) is unchanged.

### Bind-mounted, six patches in one file (`API-*`)

`API-0` is `patches/anthropic_protocol_inline_system.py`; every other row is
`patches/anthropic_serving_inline_system.py`. Each has a `# ===== API-N: … =====` banner in the
file, matching the anchors below.

| id | was | kill switch (default) | evidence | detail |
|---|---|---|---|---|
| `API-0` | *unnumbered* | none — validation relaxations have no toggle | accepts `role:"system"` in the messages array (vllm#44283), `server_tool_use` / `web_search_tool_result` blocks, schema-less server tool definitions, and the `thinking` control block. Each rejection is a 422 before any inference | [`#api-0`](PATCHES-API.md) |
| `API-8` | Patch 8 | `STRIP_LEAKED_COT=0` (on) | strips leaked CoT from inbound assistant turns. 1,103 real turns: 44.1% carried a leaked `</think>`, CoT was 66.9% of all assistant text. A/B over 40 replayed turns: **66,520 → 24,562 prompt tokens, −63.1%**. Decode unchanged | [`#api-8`](PATCHES-API.md) |
| `API-9` | Patch 9 (+9b, 9d) | `MODEL_ALIAS_THINKING=0` (on); `CLASSIFIER_NOTHINK=0` (on) | maps served model name → `chat_template_kwargs`, so each Claude Code tier carries its own thinking setting. HMMT: `high` 11/12 at 8,243 tokens per correct answer vs off 5/12 at 20,035, max 8/12 at 18,959 | [`#api-9`](PATCHES-API.md) |
| `API-10` | Patch 10 (+10b) | `TOOL_ARGS_STRICT=1` restores the raise (off) | guards `json.loads` on model-generated tool arguments. Unguarded, one bad tool call 500s the turn, the client retries with full context, and a 150K conversation pays a cold re-prefill per retry — 9 occurrences in one day | [`#api-10`](PATCHES-API.md) |
| `API-11a` | Patch 11a | none | drops the per-request `<total_tokens>` counter from the system prompt. It landed ~11.5K chars into a ~12.6K system prompt, so the cache matched ~3.2K tokens and everything behind it re-prefilled **every turn**. A cold 54K prefill measures 194s against 0.9s warm | [`PREFIX-CACHE.md`](PREFIX-CACHE.md) |
| `API-11b` | Patch 11b | none | only the leading run of system messages is hoisted; mid-conversation ones stay in place. With 11a: **0 head moves over 16 turns, 100% strict prefix** | [`PREFIX-CACHE.md`](PREFIX-CACHE.md) |
| `API-12` | Patch 12 | `PREFIX_WATCH=0` (on) | one `PREFIX_WATCH head=… tools=… sys=… user0=… len=…` line per request, hashing slices only. 50.8 KB/hour, 37µs/request. **Blind spot: the effort prefix is injected downstream, so a tier switch produces identical hashes** | [`#api-12`](PATCHES-API.md) |
| `API-13` | Patch 13 | `STICKY_TOOLS=0` (on), `STICKY_TOOLS_TTL=3600` | keeps the advertised `tools` array monotonic per conversation, so a flapping client tool (swift-lsp) cannot shrink it and break the append chain. Replaying the real 16-turn capture: 3 tool-set changes → 1 | [`#api-13`](PATCHES-API.md) |
| `API-14` | Patch 14 | none needed — it only ADDS a response field | returns vLLM's own `num_cached_tokens` as `engine_cached_tokens`. Every external instrument could see *that* a turn re-prefilled but not *by how much*; `/metrics` is engine-wide, so nothing attributed a stall to a request — an ambiguity that forced a published conclusion to be walked back twice. Returns `None`, not `0`, when the engine does not report it | [`#api-14`](PATCHES-API.md) |

### Added as a plugin, not patched over anything (`PLG-*`)

| id | was | target | kill switch | rollback | evidence | detail |
|---|---|---|---|---|---|---|
| `PLG-14b` | Patch 14b | `site-packages/prefill_collector.py` **+** `prefill_collector-0.1.dist-info/` | `PREFILL_COLLECTOR_PORT` / `PREFILL_COLLECTOR_HOST` | remove the two compose lines | publishes the per-request prefill rows vLLM measures and discards (`num_cached_tokens`, queued/prefill/decode time) on its own loopback port for sparkstats to proxy | [`#plg-14b`](PATCHES-API.md) |

> **Two mount lines, not one, and a `.dist-info` rather than an import — because of WHEN the engine
> looks.** `AsyncLLM` is built in `build_async_engine_client`, which runs *before* `init_app_state`
> imports the Anthropic serving patch, so importing the collector from that patch is too late:
> `load_stat_logger_plugin_factories()` has already run. The supported hook is the
> `vllm.stat_logger_plugins` entry-point group, and `importlib.metadata` finds it off `sys.path` —
> so a module plus a `.dist-info` dropped into site-packages is enough, with no image rebuild and
> no wheel. **Without the `.dist-info` the module sits on disk and is never loaded, silently**;
> that is why `check-local-patches.sh` verifies both.
>
> It binds `127.0.0.1` **inside** the container and is deliberately NOT a route on `:8888` — the
> proxy's Caddy catch-all forwards every path to the vLLM pool, which would put engine
> observability in front of every mTLS and LAN client.

## Verifying the registry against reality

```bash
# which MNT-8 / MNT-9 arm each node is running (no restart needed to change it)
bash local-ops/kv-flags.sh

# MNT-8 / MNT-9 ordering and refcount logic, against the real vLLM classes, no GPU
HOST=spark-45ea bash local-ops/kv-mech-tests.sh

# every bind-mounted patch is actually in the file the container imports, on BOTH nodes
REMOTE=shorn@spark-45ea bash scripts/check-local-patches.sh <container>
REMOTE=shorn@spark-da08 bash scripts/check-local-patches.sh <container>

# the image-baked one
bash scripts/check-patch4.sh <container>

# the generated diffs still reproduce from patches/pristine/ + the mounted files
bash scripts/regen-local-patches.sh --check

# live behaviour of the API-* stack
python3 local-ops/verify-server.py
```

`check-local-patches.sh` checks **21 rows** and asserts a distinctive **code** marker, never a comment, so a comment-only
edit cannot fake a pass. It checks every container you name, which is how head/worker drift shows
up — the start script's `scp patches/*.py` glob fixes drift at start time, but nothing verified it
afterwards.

## The review surface

The mounted files are whole-file copies of vLLM source, because that is what a bind-mount needs.
Our real delta is small and was invisible inside them — `MNT-7` is 14 lines inside 534,
`MNT-6` seven hunks inside 1,504. So:

| | |
|---|---|
| `patches/pristine/` | the unpatched originals, pulled from the image with `docker run --rm --entrypoint cat` — **never** through a bind-mount, which returns the patched file |
| `patches/generated/*.patch` | `diff -u pristine mounted`, one per target. **The review surface.** |
| `patches/*.py` | the whole-file copies. **The deploy artefact.** |

Regenerate with `bash scripts/regen-local-patches.sh`. `patches/pristine/MANIFEST.txt` pins the
image id, so an image bump invalidates every diff loudly rather than silently.

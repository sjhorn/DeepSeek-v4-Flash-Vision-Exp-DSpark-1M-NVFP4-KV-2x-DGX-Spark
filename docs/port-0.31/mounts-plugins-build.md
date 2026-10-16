# Inventory C: DSpark runtime mounts, plugins and build-time patches, vLLM 0.21 to v0.31.0

Read-only. 0.31 sources were fetched from `raw.githubusercontent.com/vllm-project/vllm/v0.31.0/...` into
raw.githubusercontent.com at tag v0.31.0, with the full 0.31 tree listing from the api.github.com git tree (re-fetch to check).
The 0.21 baseline is `patches/pristine/` (0.21.1rc1.dev339+g1967a5627bc3).
**Caveat:** `patches/generated/*.patch` dates from 10-07, and patch6 changed on 10-09 (it added MNT-6c, the
`set_pending_block_ids_provider` fence). The current patch6 was re-diffed against patches/pristine for this inventory.

Classes: DROP = 0.31 already has it · RE-DERIVE = our delta has to be re-applied to changed code · CARRY = ours, works as is · UNKNOWN = shows what would decide it.

| piece | purpose | 0.31 status | class | hours | evidence (0.31) |
|---|---|---|---|---|---|
| patch5-detokenizer.py / 0005-suppress-stops-in-reasoning.patch (the same delta, delivered by the runtime mount and not the overlay) | keep client stop strings dormant inside `<think>…</think>` | absent. Upstream PR vllm#52486 is still open | RE-DERIVE | 1–2 | `vllm/v1/engine/detokenizer.py`: no reasoning guard. Base changed: `PreTrainedTokenizerFast`→`TokenizersBackend`, and `check_stop_strings` now picks the earliest-completing stop (`best_end`). `get_current_vllm_config_or_none` and `ReasoningConfig.reasoning_start_str/_end_str` still exist |
| patch6 MNT-6a (+6c) | cap DSv4 prompt-block protection; skip blocks with a transfer in flight | **the mechanism is gone**: no `_protected_prompt_block_ids`, no `MLAAttentionManager`. `MLAAttentionSpec` maps to `FullAttentionManager`. Retention is now `prefix_cache_retention_interval` plus SWA `_cache_block_mask`/reachable boundaries (vllm#43447, merged 2026-06-04) | DROP | 0.5 (remove the mount) | `single_type_kv_cache_manager.py`: grep "protect" finds 0 hits. `register_all_kvcache_specs` L2649+: `MLAAttentionSpec → FullAttentionManager` |
| patch6 MNT-6b | recycle SWA skipped pages in-request instead of churning the LRU | partly covered: `BlockPool.free_blocks` now **prepends uncached blocks** (LIFO) and appends cached ones, and SWA groups mask non-servable blocks out of the hash map. No in-request reuse | DROP (confirm by measurement) | 0 + test | `block_pool.py:777-806` (`prepend_n(blocks_to_evict_first)`). `single_type_kv_cache_manager.py:_remove_blocks_in_range` → `free_blocks`. DSv4 compressor uses `SlidingWindowMLASpec` → `SlidingWindowManager` |
| patch6 MNT-8 (`_free_split`) + patch7 `free_blocks(prepend=)` | uncached pages to the front of the free queue | in stock 0.31, unconditionally | DROP | 0 | `block_pool.py:797-806` |
| patch6 MNT-9 (static-head pin, flag default OFF) | pin the tools+system head blocks | absent | CARRY only if wanted (as a kvmgr manager subclass, not a file mount) | 3–5 if kept, else 0 | n/a. `start-deepseek-v4-flash-dspark.sh:137` writes `pin_static_head: 0`. Live node state unverified |
| patch6 MNT-11 (kvmgr register hook) | make sure kvmgr registers in the engine-core process | replaced by `KVCacheSpecRegistry` | DROP (kvmgr's problem) | 0 here | `vllm/v1/kv_cache_spec_registry.py`: `register()` **asserts on a conflicting re-registration**, and `_ensure_registered()` runs the built-ins lazily on the first `get_manager_class` call. So kvmgr can neither register `MLAAttentionSpec` before or after the built-ins with a different manager; it has to patch `get_manager_class`, or register a subclass spec |
| patch7-block_pool-dedupe.py | commit-time same-(hash, group) dedupe | still not deduped ("NOTE #1: We currently don't de-duplicate"); `insert()` still merges into a dict | RE-DERIVE (prefer a small monkeypatch over a whole-file mount of 904 lines) | 1–3 | `block_pool.py:48`, `:85-99`; `_insert_block_hash` L629 returns early only for the same block_id. New multi-hash-per-block (`cached_block_hashes_by_block`) changes the eviction semantics, so re-check `_maybe_evict_cached_block` (L732) |
| patch8-kv_cache_utils.py (`prepend_n`) | `FreeKVCacheBlockQueue.prepend_n` | in stock 0.31 | DROP | 0 | `kv_cache_utils.py:416`. `init_none_hash` keeps PYTHONHASHSEED-wins (`resolve_none_hash_seed` L131) and the same chain `hash_function((parent, tokens, extra_keys))` (L684-714) |
| mnt10-scheduler.py | live-tunable `long_prefill_token_threshold` from the flags file | not live. 0.31 reads `scheduler_config.long_prefill_token_threshold` each `schedule()`, adds `long_prefill_token_threshold_adaptive`, and exempts a lone request | RE-DERIVE, ideally as a plugin that sets the `scheduler_config` attribute (no 3359-line mount) | 1–2 | `sched/scheduler.py:475, 611-626, 679, 1110`; `config/scheduler.py:80,87`. The 0.21 mount sat over the overlay's IMG-3 scheduler, and that overlay port is outside this inventory |
| anthropic_protocol_inline_system.py (API-0, 14, 15) | accept what Claude Code sends; add `engine_cached_tokens`, `pause_turn` | has `role:"system"` and the typed `thinking` (disabled/enabled/adaptive). Missing: `server_tool_use`/`web_search_tool_result` block types, server tools without `input_schema` (+`type`, `max_uses`), `pause_turn`, `engine_cached_tokens` | RE-DERIVE | 1–2 | `entrypoints/anthropic/protocol.py:39-47, 67-91, 128-169, 261, 296` |
| anthropic_serving_inline_system.py (API-8…15, 2608 lines, diff 1993 lines) | CoT strip, per-alias thinking, guarded tool JSON, head stabilisers, PREFIX_WATCH, sticky tools, engine cached tokens, server web_search/web_fetch | file rewritten (1171 lines). Has: inline-system merge (`_should_merge_inline_system` L199, the #44283 analogue), `thinking.type=disabled` → probed `reasoning_effort` (L155-190, 587-612), `cache_read_input_tokens` from `cached_tokens` (`_build_anthropic_usage` L61, *disjoint* semantics, unlike our `engine_cached_tokens`). Missing: API-8, 9 (alias rules), 10 (`json.loads(tool_call.function.arguments)` still unguarded, L789), 11, 12, 13, 15. Our imports no longer resolve (`openai.engine.protocol` → `serve.engine.protocol`, `entrypoints.logger` → `serve.utils.request_logger`) | RE-DERIVE | 12–24 | `entrypoints/anthropic/serving.py` |
| prefill_plugin (prefill_collector) | per-request prefill rows on a loopback port | entry-point group and API unchanged | CARRY | 0.25–0.5 (boot check) | `plugins/__init__.py:26` `STAT_LOGGER_PLUGINS_GROUP="vllm.stat_logger_plugins"`; `v1/metrics/loggers.py:57-79` (same `record(scheduler_stats, iteration_stats, mm_cache_stats, engine_idx)`); `v1/metrics/stats.py:243-259` (`FinishedRequestStats` has every field read) |
| safetensors_e8m0_plugin | add `F8_E8M0` to `safetensors.torch._TYPES` for `--safetensors-load-strategy eager` | still needed: 0.31 eager = `safetensors.torch.load(f.read())`, and safetensors **main** `_TYPES` still lacks F8_E8M0 | CARRY | 0.25 | `model_loader/weight_utils.py:25, 1126-1128`; huggingface/safetensors main `bindings/python/py_src/safetensors/torch.py:427-445`. Only matters while the eager strategy is used |
| 0004-dspark-shared-expert-gate-up-proj.patch | DSpark draft loader drops the shared expert w1/w3 | **baked into the overlay** (`recipe/overlay/vllm/v1/spec_decode/dspark.py:17-34`). 0.31 maps `w1/w3→gate_up_proj` for `model.layers.*`, and an unknown param KeyErrors instead of being silently skipped | DROP | 0 (check draft acceptance at the first boot) | `models/deepseek_v4/nvidia/dspark.py:460-465, 494-495, 532-541` |
| keys-concurrency.patch | ragged mixed prefill+decode DSpark KV store / proposer concurrency | **baked into the overlay** (added lines found in overlay: dspark.py 96/96, dspark_proposer.py 129/135, gpu_model_runner.py 8/8). Its targets do not exist in 0.31: DSpark is now `v1/worker/gpu/spec_decode/dspark/speculator.py` + `models/deepseek_v4/nvidia/dspark.py`, and `_store_main_kv_ragged`/`_row_to_slot` are absent | UNKNOWN: a 2/4/6-concurrency mixed-batch run on 0.31 DSpark decides it (overlay/model inventory) | 0 here; 4–12 if needed (unverified) | tree listing; grep of 0.31 `nvidia/dspark.py` finds no ragged/query_start_loc |
| official-main-b12x-nvfp4-python.patch | nvfp4→`nvfp4_ds_mla` for DSv4 (584 B layout), b12x MXFP4 MoE oracle | **not in the production overlay**; applied only by `recipe/official-main/Dockerfile.python-patch` on the prototype `official-main-dspark-00eb7ce` image. 0.31 has `nvfp4_ds_mla` in `CacheDType` (cache.py:48), `get_kv_quant_mode` (kv_cache_interface.py:93) and b12x MoE (`oracle/mxfp4.py:173` B12xExperts). It does **not** have DSv4 nvfp4 KV: `_resolve_dsv4_kv_cache_dtype` raises for non-fp8 (attention.py:93-120); DSv4 `MLAAttentionSpec` sets 584 B only for fp8 (attention.py:856-878); FLASHMLA_SPARSE gates `nvfp4_ds_mla` to SM100 (flashmla_sparse.py:218) | RE-DERIVE (python part); the kernel/backend for SM121 is outside this inventory | 4–8 (unverified) | as listed |

## Env vars the compose sets, checked against v0.31.0 `vllm/envs.py`

**Present in 0.31 envs.py:** VLLM_ALLOW_LONG_MAX_MODEL_LEN, VLLM_CACHE_ROOT, VLLM_ENGINE_READY_TIMEOUT_S,
VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS, VLLM_HOST_IP, VLLM_LOGGING_CONFIG_PATH, VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS,
VLLM_SKIP_MODEL_NAME_VALIDATION, VLLM_SPARSE_INDEXER_MAX_LOGITS_MB (0.31 default 512; we set 256), VLLM_USE_FLASHINFER_SAMPLER.

**Absent from 0.31; fork-defined in our overlay `recipe/overlay/vllm/envs.py`.** These die with the overlay unless it is ported:
- VLLM_USE_B12X_MOE, VLLM_USE_B12X_WO_PROJECTION, VLLM_B12X_W4A16_FORCE_BLOCKS_PER_SM / _MAX_M / _TILE_CONFIG. 0.31 picks b12x through the MoE backend oracle (`"b12x"` runner backend, oracle/mxfp4.py:305, 490), so the replacement is probably `--moe-backend` (unverified for the NVFP4 path).
- VLLM_DSPARK_CONFIDENCE_THRESHOLD, _CONFIDENCE_SCHEDULER, _LOCAL_ARGMAX, _REPLICATE_MARKOV_W1, _FUSED_MARKOV_ARGMAX,
  _GPU_REJECTED_CONTEXT_MASK, _REFERENCE_KV_QUANT_DEQUANT, _HARDWARE_SCHEDULER_EARLY_STOP. Confidence is now a
  speculative-config field in 0.31 (`config/speculative.py:554`).
- VLLM_DSV4_B12X_COMPRESSED_MLA, VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE, _EXACT.
- DSPARK_SLOT_CLAMP (read by the overlay's `nvidia/dspark.py`; not in 0.31's).

**Absent in 0.31 and also absent from the 0.21 overlay envs.py, so probably dead already (unverified: something in the image could read them through `os.environ`):**
VLLM_TRITON_MLA_SPARSE, VLLM_SKIP_INIT_MEMORY_CHECK, B12X_W4A16_TC_DECODE (no reader anywhere in the repo).

**Ours, read by our patches through `os.environ`:** VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION (patch6, so it goes with MNT-6a),
VLLM_SWA_RECYCLE_SKIPPED_BLOCKS (commented out), VLLM_SUPPRESS_STOPS_IN_REASONING (patch5), VLLM_KV_FLAGS_FILE /
VLLM_LONG_PREFILL_TOKEN_THRESHOLD (patch6/MNT-10). VLLM_HOST/VLLM_PORT/VLLM_IMAGE appear only as compose-side
substitutions, not container env. Note that VLLM_PORT *is* a real 0.31 env var, so it must never be passed into the container.

**CLI flags:** every flag the compose passes exists in 0.31 (`engine/arg_utils.py`, `entrypoints/launchers/cli_args.py`), and the
`deepseek_v4` tool parser, reasoning parser and tokenizer are registered. `"method":"dspark"` exists (speculative.py:70).
`draft_sample_method:"probabilistic"`: 0.31's default is `greedy`. Whether `probabilistic` is a valid literal was not checked.

## Notes
- The whole patch6 mount can go: 6a/6c have no mechanism left to patch, 6b/8 are stock behaviour, 11 is replaced by the registry.
  Then kvmgr's `compat/dspark.py` goes inert by design. Two things still need a cluster measurement: the second-turn long-context
  hit rate (the 0%-vs-100% symptom patch6 fixed) and a `prefix_cache_retention_interval` setting.
- Disk-tier continuity: the NONE_HASH seed and the chain formula are unchanged and the hasher is still sha256-pickle. **Unverified:** that
  `extra_keys` and `hash_block_size` produce identical bytes, and that the kvmgr layout fingerprint is unchanged. If not, the
  `dspark-kv-v1` tier is a silent full miss after the port.
- The serving rewrite is the dominant cost. Part of API-14 might be dropped if the proxy accepts 0.31's
  `cache_read_input_tokens` (disjoint from input_tokens) instead of `engine_cached_tokens` (a subset).
- patch7 and MNT-10 should stop being whole-file mounts on 0.31. Both are small enough to deliver as a general plugin (kvmgr or a sibling).

## Total
DROP 0.5 + RE-DERIVE (patch5 1–2, patch7 1–3, MNT-10 1–2, protocol 1–2, serving 12–24, official-main 4–8) + CARRY 0.5–0.75
= **~21–42 h**, excluding MNT-9 (+3–5 if kept) and keys-concurrency (UNKNOWN, +4–12 if 0.31 DSpark lacks mixed-batch support).

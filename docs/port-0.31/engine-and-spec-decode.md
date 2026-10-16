# Inventory B: DSpark spec-decode / runner / scheduler / tokenizer overlays, 0.21 -> v0.31.0

Baselines: upstream `1967a5627bc3` (the base image's vLLM build) and tag `v0.31.0`, fetched raw from GitHub.
Sources: upstream vLLM at 1967a5627bc3 (0.21) and at tag v0.31.0, from raw.githubusercontent.com; re-fetch to check.
Caveat: the base image `ghcr.io/bjk110/vllm-spark:unholy-fusion-prod-ready` is a **fork**. Every "delta" below is
overlay vs *upstream* 1967a5627bc3, so it mixes the fork's additions with ours (the image itself was not inspected).

| file | our delta (one line) | 0.31 status | class | hours | evidence |
|---|---|---|---|---|---|
| v1/spec_decode/dspark.py (700 L) | Whole file is fork-only (never upstream at 0.21 or 0.31). Holds the V1 DSpark helpers: model spec, stacked-param loader map incl. Patch 4 (shared_experts w1/w3 -> gate_up_proj), confidence/prefix-schedule math, position-0 diagnostics | Upstream DSpark is V2-only (since the #46995 merge f5a8d733): `v1/worker/gpu/spec_decode/dspark/{speculator,utils}.py` + `models/deepseek_v4/nvidia/dspark.py`. The Patch 4 equivalent is in: `load_weights` stacked_params_mapping `("gate_up_proj","w1",0),("gate_up_proj","w3",1)` (l.460-462) with markov_w1 collision guard (l.533-536). The confidence scheduler's role belongs to `AdaptiveVerificationManager` (`spec_decode/adaptive_verification.py`) | DROP (gated) | 1-2 (DEBUG boot: no "skipped" shared_experts weights; acceptance rate vs 0.21) | `v1/spec_decode/` at v0.31.0 has no dspark*; tree listing |
| v1/spec_decode/dspark_proposer.py (1021 L) | Whole file fork-only V1 `DSparkProposer`: Keys Patch 2/2b ragged `query_start_loc`/zero-rejected tensor (concurrency garble), per-request stable draft-KV slot (`req_ids`), confidence scheduler (off/threshold/hardware, SPS curve), GPU rejected-context mask, draft-prob export, stage timing | Not portable: 0.31 V1 runner refuses DSpark (`config/vllm.py` `_get_v1_model_runner_unsupported_features`: "dspark speculative decoding", and "adaptive draft verification"). Equivalent is V2 `DSparkSpeculator(DFlashSpeculator)` via `init_speculator` (`v1/worker/gpu/spec_decode/__init__.py` l.35-40); variable draft length = `enable_adaptive_verification` | DROP code; concurrency/perf parity UNKNOWN | 3-6 validation (2/4/6 concurrency garble, steps/s); risk +8-16 if V2 needs GB10 perf features (LOCAL_ARGMAX, rejected-context mask) re-derived (unverified) | prod sets `VLLM_DSPARK_CONFIDENCE_SCHEDULER=off`, `THRESHOLD=0.0` (compose), so fixed draft length is the live mode |
| v1/worker/gpu_model_runner.py (+278/-6) | Wire DSparkProposer into V1; `draft_token_lengths` export + per-row trim of draft ids; confidence capture; position-0 diagnostics; `VLLM_DSPARK_ITER_TIMING` stage timing; `get_dspark_target_hidden_states` getter; `req_ids` propose kwarg (Keys) | V1 file still exists (7531 L) but is unusable for DSpark (above). V2 `v1/worker/gpu/model_runner.py` already wires DSpark: `init_speculator`, `use_aux_hidden_state_outputs` for "dspark" (l.276-283), `_draft_workspace_lane` (l.195), adaptive verification (l.652-705, 1281, 1375-1402, 2220). No `draft_token_lengths`/`take_last_draft_lengths` anywhere in 0.31 | DROP | 0 (+2-4 optional: re-add iteration/pos-0 diagnostics on V2) | grep of v0.31.0 V1+V2 runners |
| v1/core/sched/scheduler.py (+24) | Patch 3: in `update_from_output`, resize `request.spec_token_ids` to DSpark `draft_token_lengths`, guarded to decode-only (`new_token_ids`, not `is_prefill_chunk`, RUNNING). Fixes cold-resume garble caused by the fork's own resize | Not needed: nothing produces `draft_token_lengths`. 0.31 `AsyncScheduler` sizes placeholders from `scheduler_output.num_spec_tokens_to_schedule` and still skips `is_prefill_chunk` (`async_scheduler.py` l.28-50); scheduler pads decode to `1+num_spec_tokens` (`scheduler.py` ~l.1090, 1318) and V2 trims per request in-runner (`compact_batch`/`reallocate_drafts`) | DROP | 0 (if ever needed: `Scheduler.update_from_output` in a 3359-line file, 2-3) | overlay = upstream 0.21 + this hunk only; do NOT carry the whole-file overlay to 0.31 |
| v1/outputs.py (+4) | `ModelRunnerOutput.draft_token_lengths: dict[str,int] \| None` | Absent in 0.31; no consumer | DROP | 0 | grep v0.31.0 outputs.py |
| envs.py (+137, 31 vars) | Registers 19 `VLLM_DSPARK_*`/`VLLM_DSV4_DSPARK_*`, 8 B12X (`VLLM_USE_B12X_{MOE,MHC,WO_PROJECTION,FP8_GEMM,SPARSE_INDEXER}`, `VLLM_B12X_W4A16_FORCE_*`), `VLLM_DSV4_B12X_COMPRESSED_MLA`, `VLLM_ENABLE_PCIE_ALLREDUCE` | None of the 31 in 0.31 envs.py (0.31 has its own b12x stack, e.g. `VLLM_B12X_MOE_FP4_FORCE_A16`, `vllm/utils/b12x.py`). Proposer/runner-only vars die with V1. 6 vars have no reader in the overlay (probably read by fork code in the base image, unverified) | RE-DERIVE (contingent on model overlays, inventory elsewhere) | 0.5-2 | readers: `models/deepseek_v4/nvidia/{dspark,model,sm120}.py`, `fused_moe/b12x_moe.py`; prefer `os.getenv` in those files over a whole-file envs.py overlay |
| config/speculative.py (+34/-6) | Add method "dspark", `use_dspark()`, `use_eagle()` includes dspark, auto-detect by name, `hf_config_override` deepseek_v4+`dspark_block_size` -> `DeepSeekV4DSparkModel` | In 0.31: `DSparkModelTypes` (l.70), `use_dspark` (l.1951), aux-hidden hash (l.631), DSV4 DSpark draft rewritten to arch `DSparkDraftModel` reusing target config/quant (≈l.1424-1445), `num_speculative_tokens` defaults from `block_size`/`dspark_block_size` (l.1475-1481) | DROP | 0.5 (confirm checkpoint's `dspark_*` keys are read; arch name differs from our `DeepSeekV4DSparkModel`, which the registry/model overlays must follow) | v0.31.0 config/speculative.py |
| tokenizers/deepseek_v4.py (+6/-3) | reasoning_effort mapping: xhigh->max, low/high/max kept, unknown/absent -> default low | Three levels exist upstream but **policy differs**: absent effort with thinking -> "high" (ours: low); xhigh -> "high" (ours: max); low/minimal/medium -> low; other -> high; thinking defaults ON when no `thinking`/`enable_thinking` kwarg (0.21/ours: off). Used by Python `renderers/deepseek_v4.py` (a Rust renderer also exists; which one is default is unverified) | RE-DERIVE (small, policy) or DROP accepting upstream behaviour | 0.5-1 | diff overlay vs v0.31.0 file |
| tokenizers/deepseek_v4_encoding.py (+17/-9) | Three-level `REASONING_EFFORT_PROMPTS` (low='', high, max) from DeepSeek's encoder, `DEFAULT_REASONING_EFFORT="low"` | Upstream: same identifiers, and the low/high/max strings are **byte-identical** (AST compare) | DROP | 0 | v0.31.0 deepseek_v4_encoding.py l.72-85, 282-289 |
| tool_parsers/deepseekv32_tool_parser.py (+15/-1) | Do not emit `tool_calls: []` on content-only stream deltas (VS Code/JS clients dropped answers) | File removed. `deepseek_v4` -> `deepseekv4_engine_tool_parser.DeepSeekV4EngineToolParser` -> `parser/engine` adapter; `parser_engine.py` (~l.851-860) sets `tool_calls` only when non-empty; `abstract_parser.py` content paths build `DeltaMessage(content=...)` | DROP | 0.5 (one streaming tools request on the wire) | tool_parsers/__init__.py l.41-43 |

## Notes

- **V1 vs V2 runner.** v0.31.0 picks V2 by default (`VllmConfig.use_v2_model_runner`, `config/vllm.py` l.700+), and
  V1 lists `"dspark speculative decoding"` as unsupported (`_get_v1_model_runner_unsupported_features`, ~l.3128), so
  DSpark *forces* V2. Any DSpark runner overlay must target `vllm/v1/worker/gpu/model_runner.py` and
  `vllm/v1/worker/gpu/spec_decode/dspark/speculator.py`, not `gpu_model_runner.py`. This reverses the README rule
  ("do not set `VLLM_USE_V2_MODEL_RUNNER=1`", README ~l.1352), which must be rewritten for 0.31.
- **#46995 in 0.31: yes, but not under `v1/spec_decode/`.** It never lived there upstream; the merge commit
  f5a8d733 already put it under `v1/worker/gpu/spec_decode/dspark/`. Our `v1/spec_decode/dspark*.py` are the fork's
  V1 port of it, plus Keys/our patches.
- **Where the scheduler change would land.** Nowhere, by default. The V2 design keeps the scheduler at fixed
  `1+num_spec_tokens` placeholders and sizes the draft per request inside the runner (adaptive verification). If a
  resize were ever needed, it would go in `Scheduler.update_from_output` (0.31 `scheduler.py`, 3359 lines, heavily
  drifted) plus a new `ModelRunnerOutput` field filled by the V2 runner. Patch 3 fixed a bug the fork's resize
  introduced, and that resize does not exist in 0.31. Separately, `patches/generated/v1-core-sched-scheduler.patch`
  and `mnt10-scheduler.py` touch the same file; check them in the inventory that covers them.
- **Model-side coupling (out of scope, flagged).** Our V1 runner reads `get_dspark_target_hidden_states` from the
  overlay model. V2 instead consumes aux hidden states from `dspark_target_layer_ids`. The model/dspark overlays have
  to be checked against that contract, and against arch name `DSparkDraftModel`.
- **Production knobs** that live only in the V1 proposer/model overlay and have no 0.31 equivalent found:
  `VLLM_DSPARK_LOCAL_ARGMAX=1`, `GPU_REJECTED_CONTEXT_MASK=1`, `REPLICATE_MARKOV_W1=1`,
  `HARDWARE_SCHEDULER_EARLY_STOP=1` (inert while the scheduler is off). Whether V2 needs them for GB10 speed is not
  verified.
- Unverified: whether V2 DSpark supports `draft_sample_method=probabilistic` for DSV4 (the speculator mentions
  probabilistic only for reduced-vocab drafting); the base image's own copies of these files; which chat renderer
  (Rust or Python) 0.31 uses by default for deepseek_v4.

## Total

- Base (drops plus their verification, small re-derives): **about 6-13 h**.
- Plus optional V2 diagnostics re-derive: +2-4 h.
- Contingency if V2 DSpark misses concurrency or perf parity on GB10 and proposer features have to be re-derived on
  `DSparkSpeculator`: +8-16 h (UNKNOWN).
- **Range: 6-33 h.**

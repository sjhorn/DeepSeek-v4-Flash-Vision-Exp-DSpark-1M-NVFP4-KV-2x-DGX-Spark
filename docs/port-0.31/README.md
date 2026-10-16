# Porting this recipe to vLLM v0.31.0: the inventory (2026-10-16)

This is step 3.1 of kvmgr's `docs/plan-0.31-port.md` (branch `vllm-0.31` of
`../vllm-kvmgr`): every piece this recipe puts on top of vLLM 0.21, checked
against v0.31.0. It was a read-only check. The 0.31 files came from GitHub at
tag `v0.31.0`, and the 0.21 originals from upstream at `1967a5627bc3` and
from `patches/pristine/`. Nothing ran on the nodes.

The detail is in three tables:
[model-and-kernels.md](model-and-kernels.md),
[engine-and-spec-decode.md](engine-and-spec-decode.md) and
[mounts-plugins-build.md](mounts-plugins-build.md).

**One limit applies to every "our delta".** The base image
(`ghcr.io/bjk110/vllm-spark:unholy-fusion-prod-ready`) is a fork. The image
overlays were diffed against UPSTREAM 0.21, so each delta mixes our changes
with the fork's. Example: `model.py` calls `mla_attn.setup_b12x_wo_projection()`,
which lives in the fork's `attention.py`, a file we don't overlay.

## The decisions that shape the port

1. **On 0.31, DSpark runs only on model runner V2.**
   - 0.31's V1 runner refuses DSpark (`_get_v1_model_runner_unsupported_features`).
   - Upstream's DSpark (vllm#46995, in v0.31.0) is V2-only:
     `v1/worker/gpu/spec_decode/dspark/` plus `models/deepseek_v4/nvidia/dspark.py`.
   - Our whole V1 stack (`spec_decode/dspark*.py`, the `gpu_model_runner.py`
     wiring, Patch 3 in `scheduler.py`, `outputs.draft_token_lengths`)
     therefore has no home. Adopt upstream's (recommended) or rebuild ours on
     V2, a 33–73 h path that is the least certain.
   - README's "never set `VLLM_USE_V2_MODEL_RUNNER=1`" reverses on 0.31.
2. **The KV cache dtype.**
   - Our `nvfp4_ds_mla` (Stage C) uses a 584 B per-token page, which is the
     fp8_ds_mla envelope.
   - In 0.31, `nvfp4_ds_mla` names a different, SM100-only 352 B layout, and
     DSV4 attention rejects anything but fp8.
   - Most likely we use `fp8_ds_mla`. That is decided by one measurement: the
     "GPU KV cache size" on 0.31 with fp8_ds_mla, against today's 2.09M (1M
     lane) and 3.2M (C12).
3. **What gates the first boot on GB10** (needs a GPU window):
   - a FlashInfer build with flashinfer#4380, or DSV4 attention fails at init
     on SM12x;
   - DeepGEMM `fp8_einsum`, which the SM12x output projection uses (the July
     prototype hit DeepGEMM failures on SM120);
   - the base image itself: a 12.1a build of v0.31.0 (or a 0.31-shaped
     build).

## Classification, by piece

| class | pieces |
|---|---|
| **DROP** (0.31 has it, or it has no home) | `deepseek_v4/__init__`, B12X MLA-sparse backend + its registry entry, models/registry entry, `config/speculative.py`, `tokenizers/deepseek_v4_encoding.py`, the tool-parser fix (file gone; the new engine parser already omits empty `tool_calls`), `outputs.py`, Patch 3, `gpu_model_runner.py` wiring, `spec_decode/dspark*.py` (if upstream DSpark is adopted), `b12x_moe.py` (upstream `--moe-backend b12x`; `VLLM_B12X_MOE_FP4_FORCE_A16=1` is our A16), patch6 MNT-6a/6b/8/11, patch8, 0004 (upstream maps w1/w3), the NVFP4 stages (if fp8_ds_mla) |
| **RE-DERIVE** (our delta onto 0.31's changed code) | `model.py`: only the B12X WO projection, which is ON in production (needs a speed check against DeepGEMM); `sm120.py`'s `num_blocks` guards into `flashinfer_sparse.py`; `cache_utils.py`'s long-context top-k guard (int64 row ptr, valid-row gating); `kernel_warmup.py` (mostly drop); `envs.py` (only the vars surviving overlays read); the `deepseek_v4.py` reasoning-effort policy (or accept upstream's); patch5 (stops inside `<think>`; vllm#52486 still open); patch7 dedupe (as a monkeypatch, not a 904-line mount); MNT-10 (as a plugin setting the attribute, not a scheduler mount); the Anthropic protocol and serving fixes, **the largest single item** (serving.py rewritten upstream; API-8…15 missing) |
| **CARRY** (ours alone) | `prefill_collector` plugin (entry point and fields unchanged), `safetensors_e8m0` plugin (still needed for eager loading), MNT-9 (only if wanted, flag default off) |
| **UNKNOWN, found later** | `dispram` (node-OS general plugin: about 2 GiB of display memory lent to the KV cache; hooks 0.21-era `gpu_worker` internals). Off in the gate's first boot; GATE.md step 5 |
| **UNKNOWN** (a run decides) | V2 DSpark parity with ours: mixed prefill+decode concurrency (keys-concurrency), `draft_sample_method=probabilistic`, and three production knobs with no 0.31 equivalent found (`VLLM_DSPARK_LOCAL_ARGMAX`, `_GPU_REJECTED_CONTEXT_MASK`, `_REPLICATE_MARKOV_W1`) |

## Effort (code only; boots and validation are extra)

| area | adopt upstream DSpark + fp8_ds_mla | carry our DSpark + nvfp4 |
|---|---|---|
| model and kernels | 18–42 h | 33–73 h |
| engine and spec decode | 6–13 h (+8–16 h if V2 misses parity) | (in the row above) |
| mounts, plugins, build | 21–42 h (+3–5 h MNT-9, +4–12 h keys-concurrency if needed) | same |
| **total** | **about 45–100 h**, roughly 1.5–3 weeks | about 60–130 h |

The ranges overlap between tables where the DSpark adoption is counted
twice. The low end assumes upstream DSpark matches ours at 2/4/6
concurrency.

## Proposed order

1. **Base image and first boot** (GPU window): a 12.1a v0.31 image with
   FlashInfer#4380 and working DeepGEMM `fp8_einsum`. Stock DSV4 with
   upstream DSpark on V2, `fp8_ds_mla`, `--moe-backend b12x` (A16), and only
   the must-carry pieces:
   - the safetensors E8M0 plugin and `--safetensors-load-strategy eager`;
   - the `cache_utils` long-context guard;
   - the `num_blocks` guards.

   Measure the KV pool size, decode speed, garble (`AGENT_GARBLE_FIX.md`
   checks) and 2/4/6 concurrency.
2. **Pure-Python re-derivations, offline and in parallel** (no GPU):
   - Anthropic protocol and serving;
   - patch5 (detokenizer);
   - patch7 as a monkeypatch;
   - MNT-10 as a plugin;
   - the tokenizer policy;
   - the prefill plugin check.
3. **Only if step 1 shows a gap:**
   - the WO projection (speed);
   - V2 DSpark parity work (concurrency, probabilistic drafting, the three
     knobs);
   - MNT-9.
4. **kvmgr** (its own branch, 0.5.x): the disk tier is ported. The GPU
   manager, if ever rebuilt, must wrap `KVCacheSpecRegistry.get_manager_class`
   or use a subclass spec: `register()` asserts on a conflicting
   re-registration, and the built-ins register lazily.

## Notes that affect the cluster

- **The on-disk KV tier (`~/kvoffload/dspark-kv-v1`) will not carry over.**
  The FileMapper fields and the GPU KV layout changed, and identical block
  hashes across 0.21 and 0.31 are not proven. Plan for a cold tier after the
  move.
- **Environment variables:**
  - 31 `VLLM_*` variables in our `envs.py` overlay (DSpark, B12X, DSV4 knobs)
    do not exist in 0.31.
  - `VLLM_TRITON_MLA_SPARSE`, `VLLM_SKIP_INIT_MEMORY_CHECK` and
    `B12X_W4A16_TC_DECODE` look dead already (unverified).
  - `VLLM_SPARSE_INDEXER_MAX_LOGITS_MB` defaults to 512 on 0.31; we set 256.
- `patches/generated/` is stale for patch6: it predates the 10-09
  MNT-6c/`set_pending_block_ids_provider` change.

## Item 2 status (2026-10-16): the pure-Python pieces, done and tested locally

Each was tested against vLLM 0.31.0's real code in its CPU image on a Mac:

| piece | 0.31 form | test |
|---|---|---|
| API-0 protocol | `patches-031/anthropic_protocol.py` | live server, below |
| API-8..15 serving (+ the API-10 non-streaming fix) | `patches-031/anthropic_serving.py` | `live-tests/apicheck.py`: 25 passed; API-15 by hand; `test_api10_full.py`: 4 passed |
| MNT-5 stops in reasoning | `patches-031/detokenizer.py` (vllm#52486 + our output side) | 8 passed |
| KV-7 dedupe, MNT-10 | `patches-031/dspark031_plugin/` (one general plugin) | 6 passed |
| reasoning-effort policy (kept) | `patches-031/tokenizer_deepseek_v4.py` | 11 passed, upstream column checked too |
| prefill collector | unchanged (`patches/prefill_plugin`) | loads as a stat logger; `/prefill` rows carry every field |
| safetensors E8M0 | unchanged (`patches/safetensors_e8m0_plugin`) | still needed (`KeyError 'F8_E8M0'` without it); exact E8M0 round trip with it |

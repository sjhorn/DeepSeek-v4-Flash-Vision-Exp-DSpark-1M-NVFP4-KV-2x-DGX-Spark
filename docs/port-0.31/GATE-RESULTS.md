# Boot gate results, 2026-10-16 (2x GB10, stock vLLM v0.31.0)

Branch `vllm-0.31` at the commits below; production stopped 13:16Z with
`~/.engine-hold`, restored 15:14Z (3,377,409 KV tokens, as before), hold removed.
Every test ran on both engines with the same scripts (`tools/`), back to back,
with no other traffic on either. Same checkpoint (Vision-Exp), same
`KV_CACHE_MEMORY_BYTES` (20.29 GiB reserved), TP2, DSpark k=5 probabilistic.

## What it took to boot (each fixed on the branch)

| wall | cause | fix |
|---|---|---|
| wrong nvcc, unknown arch class, missing logging file | production's `.env.dspark` leaks 0.21 values | `*_031` names in the compose (`90622f8`) |
| `B12X_MXFP4_BF16 ... does not support current device` | the stock image lacks vllm's optional `b12x==1.3.0` extra | installed `--no-deps` beside the image, mounted ro (`6cbfec3`) |
| OOM at shard 28/48 | upstream `DeepseekV4ForConditionalGeneration.load_weights` sorts the WHOLE checkpoint; under the eager loader (64K kernel) that is 156 GiB of RAM | LOAD-1 in `dspark031` streams it (`lm_first`); memory flat at ~100 GB |

Upstream supports Vision-Exp natively (`DeepseekV4ForConditionalGeneration`):
none of our ds4v files are needed.

## Side by side

| | 0.31 gate | 0.21 production |
|---|---|---|
| boot to `/health` | 7.5 min cold JIT, 3.8 min warm | ~10 min (plus the disk walk) |
| KV, boot line, 1M | 2,115,150 tokens (2.02x) | 3,377,409 tokens (3.22x) |
| KV, measured (one 146K request) | 2.8% of the pool, ~5.2M tokens | ~2-3% (usage ratchets; see below), ~5-7M |
| single stream, 400 tokens | ~37 tok/s (10.7 s) | ~21 tok/s (18-19 s) |
| DSpark mean acceptance length | 2.6 | 2.38 |
| concurrency 2/4/6, aggregate | 93 / 146 / 191 tok/s | 46 / 81 / 96 tok/s |
| 44K-token cold prefill | ~20 s | ~33 s |
| smoke | 6/6 | 6/6 |
| Anthropic checks (11) | 11/11 | 10/11: `stop_sequence` reported as `end_turn`, no sequence |
| needle 44K cold x5 | 0/5 | 0/5 |
| needle 377K cold x1 | 0/1 (234 s) | 0/1 |
| Hermes-shaped cold x10 | 2 flagged, both scorer false positives | 1 flagged, a false positive |

**KV: the boot lines are not comparable.** At equal bytes the boot-line counts
differ 1.6x, but measured capacity is about the same. 0.21's usage counter
ratchets (blocks stay counted after a request: 6.8% -> 20.6% over this run, the
cause of production's "96% idle"), so its figure is the rise across the request,
from a baseline not cleanly recorded; treat it as a range. A clean measurement
would record usage with nothing running immediately before.

**Production's "NVFP4" KV is fp8-sized.** In the 0.21 image `nvfp4_ds_mla` for
DeepSeek V4 is the "Stage C probe": 584 B per token, the fp8_ds_mla envelope
(`attention.py` head_bytes, `flashmla.py` page size). So moving it to 0.31 gains
nothing. Real NVFP4 for V4 on SM120/SM121 exists in the image's FlashInfer
0.7.0.post1 (flashinfer#4955: 384 B record, reader `kv_cache_format="nvfp4"`,
writer `nvfp4_quantize_append_sparse_mla_cache`); vLLM 0.31 does not wire it for
V4. The 288 B record is V4.1's (vllm#59846, open, needs FlashInfer >= 0.7.1).

**Garble: synthetic only.** No real capture exists. The mechanism-aimed needle
(cold, multi-chunk, temperature 0, prompt-echo detector) passed at 44K and 377K,
alone and under 2/4/6 concurrency. One Hermes-shaped reply under load
commented on the (word-salad) synthetic system prompt: ambiguous, not the
chunk-boundary echo. Dropping Patch 3 is not contradicted, not proven.

## Not done

- A real garble capture (`garble_tap.py`), then the replay on both.
- dispram, kvmgr 0.5.0 on the gate (separate window).
- NVFP4 (384 B) KV for V4 on 0.31: a plugin spike, then a window.

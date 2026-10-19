# vLLM 0.32 gate: results (2026-10-18)

The 0.31 recipe (`patches-031`) merged onto vLLM v0.32.0 (`patches-032`) and
switched into production on the same 2x GB10 pair, TP2, 1M context, DSpark k=5.
`gate-032.sh` stopped 0.31 on both nodes at 11:58:49Z, booted 0.32 on :8888,
and checked it in place; on any failure it would have restored 0.31.

**Image:** `dspark/vllm-openai:v0.32.0-wheel` (`a228fe6c91e8`): stock
`vllm/vllm-openai:v0.31.0` plus the official, precompiled vLLM 0.32.0 wheel
from PyPI, CUTLASS DSL 4.8.0 and b12x 1.5.1. v0.32.0 pins the same torch
(2.13.0, CUDA 13.0) and FlashInfer (0.7.0.post1) as the 0.31 image, so nothing
was compiled. Built because Docker Hub had no v0.32.0 image yet; the official
`vllm/vllm-openai:v0.32.0` appeared at 10:54Z the same day and replaces it after
a boot check.

| | 0.32 | 0.31 (same nodes) |
|---|---|---|
| boot to `/health` | ~6 min (cold: FlashInfer re-autotuned) | ~3.8 min warm, ~7.5 min cold |
| model load (eager, LOAD-1) | 48 shards in 55 s, 79.7 GiB, no OOM | same |
| GPU KV pool | 2,115,150 tokens (2.02x at 1M) | same |
| smoke | 6/6 | 6/6 |
| single stream, 400 tokens, temperature 0 | 10.3-11.6 s (~37 tok/s) | ~37 tok/s |
| DSpark mean acceptance length | 2.60 | 2.57-2.6 |
| needle, cold, 44K x3 | 3/3 | pass |
| Anthropic `stop_sequence` (stop "SEVEN") | `stop_reason=stop_sequence`, `stop_sequence=SEVEN` | not gated |
| `bench_concurrent.py` 2/4/6, aggregate, no other traffic | **107.4 / 176.7 / 182.4 tok/s** | 94.2 / 175.1 / 186.8 (2026-10-18), 93 / 146 / 191 (2026-10-16) |
| kvmgr 0.6.0 disk tier | writing (`~/kvoffload-032`, started empty) | - |
| `Traceback`/`ERROR`, either rank | 0 / 0 | 0 / 0 |

**Read with care:**
- The first 2/4/6 run overlapped a 250K-token client prefill and was stopped;
  a second overlapped 33 client requests and two first-use kernel compiles
  (92 / 121 / 166). Only the third, with no traffic and no compiles, is in the
  table.
- In-inference JIT compiles (Triton and b12x's CuTeDSL `W4A16FusedMoeKernel`)
  appear on first use of a shape on a fresh cache; they are one-off.
- 0.32 does not read 0.31's tier. Block hashing is identical between v0.31.0
  and v0.32.0 and kvmgr's fingerprint matched (`e1cec16cbfd4_8e81dab33659`),
  but whether the KV bytes are laid out identically is untested, so prefixes
  were cold after the switch. A restore-vs-recompute check comes before reuse.

**Offline, before the switch** (vLLM 0.32.0 CPU wheel, Ubuntu 24.04):
`patches-032/upstream-tests` api10_full 4/4, effort 11/11, Patch 5 8/8, plugin
6/6, LOAD-1 0 failed; upstream's #47616 test 34/34 on the merged detokenizer
(30 fail with the 0.31 copy). Each of ours fails on pristine v0.32.0.

**Still open:** a 12 h+ soak; the official image's boot check; the tier-reuse
check; a large restore from disk; the kvrace gate; a real garble capture.

## The official image (14:19Z)

`vllm/vllm-openai:v0.32.0` (`sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34`)
has the same vLLM, torch, FlashInfer and CUTLASS DSL as the wheel image, no
b12x (mounted from `~/dspark032-deps/b12x-1.5.1`), and transformers 5.19.0.
Switched with `switch-official-032.sh` (now in `~/kvdiag/port-0.32/` on the head): warm boot 231 s; both ranks on the
digest; LOAD-1, b12x, `fp8_ds_mla`, V2, kvmgr and the 2,115,150-token pool in
the log; b12x imported from `/opt/b12x/`; smoke 6/6; 400 tokens in 11.3 s;
0 errors. Crash recovery (lane 0.32) live again at 14:23:36Z.

**Throughput on the official image** (idle engine; one warm-up pass, then
the measured pass with 0 client requests and 2 first-use compiles):
2/4/6 aggregate **94.5 / 158.0 / 191.1 tok/s** (warm-up 94.3 / 170.0 / 183.6).
Every figure across the 0.31, wheel-image and official runs lies within
about ±10% run to run (0.31 alone: 146 and 175 at 4 streams on two days), so
0.32 is level with 0.31 on throughput: no regression and no clear gain. The
wheel image's 107 at 2 streams is that spread's high end.

## Can 0.32 reuse 0.31's disk tier? (`tier-compat.sh`, 14:49-15:00Z)

One fixed 63,368-token raw prompt at temperature 0, on 0.32 and then on 0.31
(warm boots, 231 s and 215 s). Both found the needle, worded differently, so
the two versions' arithmetic differs slightly.

- **Paths:** the same 270 files in both tiers on both ranks, so block hashing
  is identical.
- **Bytes:** 268 of 270 files differ. Over 60 files (60 MB): 36.1% of bytes
  identical, 20.8% one fp8 code step apart, 9.3% two steps, 33.7% further
  (bf16 and scale bytes, and drift compounding over the layers, also count as
  "further"). Unrelated bytes would match ~0.4-2% of the time, so this is the
  same layout with numerically different values, not a different layout.
- **Not yet proven safe:** the remaining check is functional. Boot 0.32 on a
  scratch tier holding only 0.31's files for the prompt, with stores paused;
  it must restore them and still answer the needle. If it passes, 0.32 can
  adopt `~/kvoffload-031` (253 GB) by hard links.
- **Not pursued (2026-10-19):** the 0.31 tier was deleted instead of reused.
  0.32's own tier had refilled to 44 GB with a 99% prefix hit rate overnight.

## Soak and retirement (2026-10-19)

17 h on the official image, 14:56Z 2026-10-18 to 07:30Z 2026-10-19, with the
supervisor live on lane 0.32 and no hold:

- 1,009 client requests: 1,008 returned 200; one 400 (a 1,048,577-token prompt, one over the
  limit, rejected cleanly; the only ERROR lines in either log).
- 0 container restarts, no OOM, 0 Xid on either node.
- Prefix cache hit rate 99.1%, 41% of it from the disk tier; peak GPU KV
  use 33.7%.

The 0.31 and 0.21 lanes were then retired on both nodes without a restart:
their checkouts (`~/dspark031`, `~/vllm-kvmgr-031`, `~/dspark031-lane`),
`~/dspark031.env`, `~/dspark031-deps`, their disk tiers (`~/kvoffload-031`,
`~/kvoffload`), their JIT caches (`~/.cache/vllm-dspark031`,
`~/.cache/vllm-dspark`) and their images (`vllm/vllm-openai:v0.31.0`,
`vllm-dspark-runtime:dspark-nvfp4-stage-c` / `rollback-20261004`), plus
the gate's `dspark/vllm-openai:v0.32.0-wheel`. The tiers' `diag` ledgers
were kept in `~/kvdiag/retired-kvoffload{,-031}`. The original checkout
`~/DeepSeek-v4-Flash-0731-…` stays: it is the git home of `~/dspark032`, and
`serve-032.sh` reads its `.env.dspark`.

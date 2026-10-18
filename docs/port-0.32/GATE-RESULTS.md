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

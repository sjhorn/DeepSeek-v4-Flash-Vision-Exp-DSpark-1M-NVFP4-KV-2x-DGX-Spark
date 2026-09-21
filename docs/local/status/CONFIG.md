# CONFIG.md — what is deployed, and the configuration that is the source of truth

**This file's "Key configuration" table is the source of truth for our settings.** It carries the
change history and the reason for each value. `CLAUDE.md` and the other docs keep convenience
copies; when they disagree with this table, this table wins — and the copy gets fixed.

Re-check it against the engine rather than trusting any document:

```bash
docker logs <container> | grep 'non-default args'
docker logs <container> | grep 'GPU KV cache size'
```

Boot-by-boot numbers: `BOOT-METRICS.md`. Incidents and known issues: `INCIDENTS.md`.

> Moved verbatim from `STATUS.md` during the 2026-09-20 doc split.

## Nodes

| Role | Hostname | SSH | RoCE IP | Management IP |
|------|----------|-----|---------|---------------|
| **Head** (rank 0) | `spark-45ea` | `ssh shorn@spark-45ea` | `192.168.0.120` | `192.168.1.120` |
| **Worker** (rank 1) | `spark-da08` | `ssh shorn@spark-da08` | `192.168.0.101` | `192.168.1.101` |

Passwordless SSH is configured from head to worker via the RoCE IP (`192.168.0.101`).

## What is deployed

- **Model: `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`** (multimodal), with
  `HF_OVERRIDES={"architectures":["DeepseekV4VForConditionalGeneration"]}`.
  **CORRECTED 2026-09-20 — this said `DeepSeek-V4-Flash-0731`.** Verified against the running
  engine's `non-default args`. Switch with `./switch-model.sh text|vision`
  ([`../CLUSTER.md`](../CLUSTER.md))
- **KV pool this boot: 2,510,051 tokens**, max concurrency 2.39x at 1,048,576
  ([`BOOT-METRICS.md`](BOOT-METRICS.md)). Varies ~11% per boot — read the current boot's own figure
- **Image:** `vllm-dspark-runtime:dspark-nvfp4-stage-c` (built on both nodes)
- **`IMG-4`** (shared expert gate_up_proj fix for 0731) is baked into the image via `recipe/overlay/`
- **Bind-mounted patches:** `API-0` (protocol) and `API-8`…`API-13` (serving, six patches in one
  file), plus `MNT-5` (inert), `MNT-6a`, `MNT-6b`, `MNT-7`. Full table with kill switches:
  [`../PATCH-REGISTRY.md`](../PATCH-REGISTRY.md). Verify with `scripts/check-local-patches.sh`
- **Served model names: 12 on one engine** — **CORRECTED 2026-09-20, this said 5.**
  `deepseek-v4-flash-dspark`, plus `-nothink` / `-think-low` / `-think-high` / `-think-max`, plus
  the seven vendor `claude-*` ids. Read the live list from `SERVED_MODEL_ALIASES` in the compose or
  from `curl /v1/models` (verified 12 on 2026-09-20). What each tier maps to:
  [`../THINKING-AND-EFFORT.md`](../THINKING-AND-EFFORT.md)
- **Config:** `.env.dspark` on the head at `/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark`
- **Repo path (both nodes):** `/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark`
- **HF cache (both nodes):** `/home/shorn/.cache/huggingface`

## Key configuration

| Setting | Value | Notes |
|---------|-------|-------|
| `DSPARK_MODEL` | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp` | Vision-Exp deployed; swap with `switch-model.sh` |
| `MAX_MODEL_LEN` | `1048576` (1M) | True YaRN ceiling |
| `MAX_NUM_SEQS` | `12` | 12→6 (2026-08-05), 6→4 (2026-08-22), **4→12 (2026-09-13)**. Sweep showed slots cost KV only via CUDA-graph capture; with capture capped at 72 the KV cost of 12 ≈ that of 6. |
| `GPU_MEMORY_UTILIZATION` | `0.86` | **0.87→0.85→0.86 (2026-09-13).** 0.87 + capture 144 threw NVRM `NV_ERR_NO_MEMORY` 4s after engine start and hung the host twice. At 0.86 + capture 72 the CUDA-graph estimator over-reserves (safe direction). Do not raise. |
| `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS` | `1` | Accurate KV accounting |
| `MTP_NUM_TOKENS` | `5` | DSpark speculative tokens |
| `COMPILATION_CONFIG` | `{"max_cudagraph_capture_size":72}` | **New 2026-09-13.** Default derives 144 (= 2 × seqs × (k+1)); 72 is the real decode ceiling. Saves ~0.40 GiB of graph pool. Passed via `COMPILATION_CONFIG` in `.env.dspark`. |
| `LONG_PREFILL_TOKEN_THRESHOLD` | `1024` | **New 2026-09-21**, set to 2048 then **2048 → 1024 the same day on measurement** (4.7x the stock decode rate vs 2.9x; worst stall 5.17s → 0.74s; costs +15.7% on the long prefill). **Confirmed 2026-09-21 on live traffic after testing 512 and 2048 too: keep 1024.** 512 is the WORST setting in practice (median 37.5 vs 2048's 60.7 tok/s, plus 40-80s scheduler-loop stalls) even though the synthetic curve ranked it best; 1024 and 2048 are a tie (61.0 vs 60.7) and the A/B that tried to separate them was confounded. Do not re-tune without a long alternating run. Curve, real-traffic comparison and the `Running: 1` caveat: [`../PATCHES-KV.md`](../PATCHES-KV.md) `MNT-10`. `MNT-10`. Was unset (= stock `0`, i.e. no cap). Caps how many tokens **one** request may take per scheduler step, so a long chunked prefill cannot zero the shared `token_budget` and starve every request behind it in `self.running`. Symptom it fixes: decode at **0.2-2 tok/s** for minutes at 44-71% KV with **zero preemptions** and a flat ~94% hit rate. Set as `--long-prefill-token-threshold` in `docker-compose.dspark.yml`; override **live** with `bash local-ops/kv-flags.sh long_prefill_token_threshold <n>` (`0` disables the cap). **The boot log does NOT confirm it** — vLLM only logs the value inside a `max_num_partial_prefills > 1` branch, which is false here; check `grep 'non-default args'` instead. Evidence: [`INCIDENTS.md`](INCIDENTS.md) and [`../PATCHES-KV.md`](../PATCHES-KV.md). |
| `swa_recycle_cached` (code default) | `0` | **New 2026-09-21.** `MNT-6c`. **The code default was flipped to `0` on 2026-09-21**; before that the fix lived only in the node-local flags file, so a cleared `/var/tmp` or a fresh node silently restored the bug. The flag is now the escape hatch (`swa_recycle_cached 1` = stock), not the enabler. Stops `MNT-6b` from evicting the prefix-cache entry of every page it recycles. Cold-head session sim, 3/3: head after a session **0.0% / 14.4s → 99.5% / 0.5s**, and sessions run ~35% faster (82s → 50s). Real session confirms: 99.4% / 0.49s. Node-local file `/var/tmp/vllm-kv-flags/flags.json`, no restart to change. Revert: `bash local-ops/kv-flags.sh swa_recycle_cached 1`. Evidence: [`CACHE_TEST.md`](../../../CACHE_TEST.md) §9. |
| `PROTECTED_FRACTION` | `0.50` | **New 2026-09-14.** `MNT-6a` protected-block cap, 0.30→0.50. Retention under pressure 280,690 → 457,079 tokens. Host key is `PROTECTED_FRACTION`; the container var is `VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION`. |
| `SERPER_API_KEY` | (set) | For server-side web_search via SERPER API |
| `MASTER_ADDR` | `192.168.0.120` | |
| `WORKER_HOST` | `192.168.0.101` | |
| `VLLM_HOST_IP` | `192.168.0.120` | |
| `WORKER_VLLM_HOST_IP` | `192.168.0.101` | |
| `NCCL_IB_HCA` | `rocep1s0f0,roceP2p1s0f0` | |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0` | |
| `NCCL_IB_GID_INDEX` | (empty, auto-detect) | Matches working spark-vllm-docker setup |
| `VLLM_HOST` | `127.0.0.1` | Localhost only (changed from `0.0.0.0` on 2026-08-23) |
| `VLLM_PORT` | `8888` | |

## API endpoint

```
http://127.0.0.1:8888/v1       # from the head node itself
```

API is bound to `127.0.0.1` (localhost only, changed from `0.0.0.0` on 2026-08-23). Access from other machines requires an SSH tunnel or reversing to `0.0.0.0` in `.env.dspark`.

Served model name: `deepseek-v4-flash-dspark`

Default temperature (when not specified in request): **1.0** (`--generation-config vllm` defaults). Pass `"temperature": 0` for deterministic output.

## System versions (both nodes, updated 2026-08-06)

| Component | Version |
|-----------|---------|
| DGX OS | 7.5.0 |
| GPU driver | `580.173.02` (`nvidia-driver-580-open`) |
| CUDA | 13.0 |
| Kernel | `6.17.0-1029-nvidia` |
| Embedded Controller | `0x03000508` |
| SoC/GPU firmware | `0x02009b0b` (includes OOM handling improvements) |
| USB-C PD firmware | `0x00000516` |

## System-level changes applied to both nodes

| Change | Why |
|--------|-----|
| Driver `580.142` → `580.173.02` | NVIDIA recommended, OOM improvements |
| Kernel `6.17.0-1014` → `6.17.0-1029` | Security updates |
| EC/SoC/USB-C firmware updated | Stability + OOM handling for unified memory |
| `firmware-notifier` snap masked | Was crash-looping every 12s, wasting RAM |
| APT PPA deprioritised (`/etc/apt/preferences.d/nvidia-desktop-edge-lower`) | `canonical-nvidia-nvidia-desktop-edge` PPA was pinning driver to old 580.142 |
| `multi-user.target` (no GUI) | Already set, saves 2-3 GB RAM |
| Desktop services disabled (`upower`, `colord`, `wireplumber`) | Reduce background memory/CPU |

## Network layout

Both RoCE subnets have connectivity between nodes:

| Interface | Subnet | Head | Worker | RoCE device |
|-----------|--------|------|--------|-------------|
| `enp1s0f0np0` | `192.168.0.x` | `.120` | `.101` | `rocep1s0f0` |
| `enP2p1s0f0np0` | `192.168.2.x` | `.120` | `.101` | `roceP2p1s0f0` |
| `enP7s7` (mgmt) | `192.168.1.x` | `.120` | `.101` | — |

## Setup history

- **2026-08-02:** Initial setup. Created `.env.dspark`, built runtime image on both nodes, downloaded 0731 model (~64 min head, ~70 min worker), launched successfully. Boot KV pool 2.86M tokens.
- **2026-08-03:** Head node (spark-45ea) rebooted. Restored by stopping both containers then starting fresh. Key lesson: must stop the stale worker container too, not just restart the head.
- **2026-08-05:** Diagnosed KV pool exhaustion under 2 concurrent Claude Code sessions (KV at 99.9%, acceptance 0%, throughput 0.1 tok/s). Applied config changes: `MAX_NUM_SEQS` 12→6, `GPU_MEMORY_UTILIZATION` 0.85→0.90, `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS` 0→1. Created `watchdog-dspark.sh`. Disabled `firmware-notifier` on worker.
- **2026-08-06:** Overnight engine crash — system RAM exhaustion at `gpu_memory_utilization=0.90` (2.5 GB free). Reduced to 0.87. Applied firmware + driver updates on both nodes (driver 580.142→580.173.02, kernel 6.17.0-1014→1029, EC/SoC/USB-C firmware). Fixed APT PPA pinning issue. Masked `firmware-notifier` on both nodes. Created `start-cluster.sh` with GPU clock pinning.
- **2026-08-07:** Continued KV pressure diagnosis under Claude Code workloads. Confirmed 2×1M sessions are at the physical limit of 2×DGX Spark hardware (3.23M token KV pool).
- **2026-08-10–11:** Implemented Claude Code compatibility patches:
  - Inline system message fix (vllm-project/vllm#44283) — `role: "system"` in messages array
  - Server-side tool support — `web_search_20250305` and `web_fetch_20250305` accepted, converted to callable functions
  - Server-side tool execution — SERPER API integration for web_search, urllib for web_fetch, with multi-round tool loop
  - Streaming tool loop — tool rounds run non-streaming internally, final answer streams with `server_tool_use` + `web_search_tool_result` blocks injected so Claude Code UI shows correct search count
- **2026-08-22:** Reduced `MAX_NUM_SEQS` from 6 to 4 per vLLM's official DGX Spark recommendation ("above four concurrent decode streams the per-token bandwidth tax can outweigh continuous-batching gains"). Confirmed vLLM main branch upgrade not yet safe (OFFICIAL_MAIN_PORT_PLAN.md: 7 items outstanding). Confirmed `--swap-space` is ineffective on DGX Spark unified memory.
- **2026-08-23:** Pulled 17 upstream commits (to `0fec808`). Key upstream additions: tuning campaign results, dual-HCA QSFP docs, loop detector, tokenizer/tool-parser overlay updates. Rebuilt runtime image on both nodes to pick up new overlay files. Changed `VLLM_HOST` from `0.0.0.0` to `127.0.0.1` (localhost-only API binding). Upstream removed `--max-cudagraph-capture-size` flag (vLLM now derives it automatically). Verified no clash with our custom web_search/web_fetch patches — upstream has never touched the Anthropic serving/protocol files. Compose changes (patch bind-mounts, SERPER_API_KEY) auto-merged cleanly via stash/pop.
- **2026-09-10/11:** `web_search` failures diagnosed. Not a quota problem — SERPER returned transient timeouts then 429s; the same key worked minutes later (3/3 HTTP 200, bogus-key control 403). Root cause: `urlopen(timeout=15)` in `patches/anthropic_serving_inline_system.py` with no retry, so a slow SERPER window returned `[]`, the model reworded and re-queried immediately, and 9 attempts in 3 minutes tripped the rate limiter. Patched: timeout 15→30s, up to 3 attempts with 1s/3s backoff (5s after a 429), bounded by a 75s deadline. Verified end-to-end.
- **2026-09-13 — config sweep.** Swept `MAX_NUM_SEQS` × `max_cudagraph_capture_size` (4/6/12 × default/72). Findings: CUDA-graph pool is deterministic (cap 48→0.53 GiB, 72→0.78 at 6 seqs / 1.02 at 12, 144→1.42); `max_num_seqs` costs KV almost entirely *through* graph capture; short-burst throughput is cleanly tiered (74.0 / 95.4 / 142-146 tok/s). KV-pool differences between configs were **inside** the ~13% boot-to-boot variance and are not resolvable at one boot per config. Settled on 12 seqs + capture 72. Data: `local-ops/sweep_results.tsv`.
- **2026-09-13 — three failures in one day.**
  1. **Host hang** at `MAX_NUM_SEQS=12` / gmu 0.87. Kernel log: NVRM `NV_ERR_NO_MEMORY` repeating from **4 seconds after engine start**, before any load. CUDA-graph pool measured 1.75 GiB actual vs 1.06 estimated (**39% underestimate**), so vLLM sized KV against a too-small estimate. Required a physical power cycle. Fixed by gmu 0.85, later 0.86 with capture capped at 72 (estimator then over-reserves by 8-13% — the safe direction).
  2. **Second host hang** under the 250K-token pressure test. **No** NVRM lines, no thermal event, no OOM-kill — it died between log lines. Two contributing factors, neither proven: the GPU clock pin had just been removed, and a manual `drop_caches` loop was running once per second against a 121 GB unified pool under 96% GPU load.
  3. **Engine death + NCCL collective timeout** (worker rank1 dump signal 16:01, head `EngineDeadError` 16:02, both auto-restarted 7 min apart). Coincided with the worker running power-capped — see below.
- **2026-09-13 — worker power cap.** `spark-da08` was clamped at **643 MHz under 96% load** (head 2190 MHz), drawing 12.2 W vs 26.4 W, with pstate P0 and **every** `nvidia-smi` throttle reason "Not Active" — GB10 reports no `power.limit`, so the cap is invisible to the driver. Found via sparkview: `Cap 30W` against `DC 34.6W`. Cluster was ~30-40% slower (400 tok in 17.3s vs 10.2s). **A power cycle cleared it.** Diagnostic lesson: `nvidia-smi` cannot see a platform-level cap; compare clocks between nodes under load. Also: `clocks.applications.graphics` does **not** reflect `-lgc`; use `clocks.current.graphics` under load.
- **2026-09-13 — `gpu-clock-pin.service` discovered.** Both nodes carry a systemd unit pinning clocks to 300-2200 MHz at boot (`/etc/systemd/system/gpu-clock-pin.service`). It is `Type=oneshot` + `RemainAfterExit=yes`, so `systemctl is-active` reports **active** even after a manual `nvidia-smi -rgc` has undone the pin — which is why the two nodes silently diverged for 15 days. CLAUDE.md previously said the pin does not survive reboot and only `start-cluster.sh` applies it; both were wrong.
- **2026-09-13 — disk cleanup, ~4 TB reclaimed.** head 87%→18%, worker 60%→17%. Removed 46 HF models (kept DeepSeek V4-Flash ×2 per node + `sjhorn--flutter*`), 19 docker images, and 160 GB of docker build cache. Note: models pulled through the container are **root-owned** and need sudo to delete — a silent `rm` failure left 116 GB behind on the first pass.
- **2026-09-13 — startup page-cache reclaim added** to `start-deepseek-v4-flash-dspark.sh` (bounded, both nodes, stops when the API answers). Needs `/etc/sudoers.d/dspark-dropcaches`. See [`../CLUSTER.md`](../CLUSTER.md) "Startup cache reclaim".
- **2026-09-14 — co-l/ds4-prefix-cache-fixes assessed; Patch 7 adopted.** All four patches reviewed against our tree; **none apply as-is** (their baseline is `aidendle94/sparkrun-vllm-ds4-gb10` production-3.7). `03-dedupe` hand-ported as `patches/patch7-block_pool-dedupe.py` (14 lines): our `CachedBlockHashToBlock.insert()` merges duplicate `(hash, group)` entries into a dict while lookups return only one, so stale copies hold LRU slots forever. **Retention 72,109 → 280,690 tokens (3.9x)**, needle-in-haystack 5/5 at depth 0.8 (50K-450K), no throughput cost. `01-reffix` skipped (reasoning prompts, not caching). `02-schedfix` deferred — the bug is **confirmed real** (`max_num_partial_prefills` is referenced only in `engine/arg_utils.py` and `config/scheduler.py`, never read, so `--max-num-partial-prefills` is a no-op) but porting needs new scheduler state and three symbols we lack, and KV already gates admission to 1-3. `04-boundfix` **not applicable** — it fixes *sparse retention*, which our fork does not have (`reachable_block_mask`, `retention_interval`, `scheduler_block_size`, `_swa_anchor_slack`, `eagle_slack` all 0 occurrences). Patch 6 investigated and **exonerated**: its `_maybe_evict_cached_block()` on recycled pages is correct hygiene for `ref_cnt == 1` pages about to be overwritten, and the recycling protects other requests' prefixes from LRU churn.
- **2026-09-14 — `PROTECTED_FRACTION` 0.30→0.50.** Retention 280,690 → **457,079 tokens**, matching the predicted ×1.67 to within 2.5%. Cumulative for the day: **72,109 → 457,079 (6.3x)**.
- **2026-09-14 — KV disk-offload probe run and parked.** See Known issues.

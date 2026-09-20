# local-ops — local-only operational tooling (untracked, gitignored)

Lives in the repo so it survives reboots and `/tmp` wipes, and so head/worker copies stay in
step with the Mac. Ignored via `/local-ops/` in `.gitignore` — never commit it upstream.

| File | Purpose |
|---|---|
| `dspark-dropcaches` | sudoers rule for the startup cache reclaim in `start-deepseek-v4-flash-dspark.sh`. Install to `/etc/sudoers.d/dspark-dropcaches`, mode 0440, on **both** nodes. |
| `oomguard.sh` | Watches for NVRM `NV_ERR_NO_MEMORY`, kernel OOM-kill, low available memory (either node) and KV ceiling; kills the load test and drops in-flight requests before the box hangs. `MIN_AVAIL_GB` / `KV_CEILING` tune thresholds. |
| `kvpressure.py` | KV pressure test: two waves of ~250K-token prompts (6 then 10) with unique random text so prefix caching cannot dedupe. Aborts if `oomguard.sh` sets `/tmp/ABORT_TEST`. |
| `sweep.sh` | Config sweep: `./sweep.sh 12:default 12:72 6:default 4:default` — restarts per config and records KV tokens, concurrency, graph GiB, capture max/count, boot time, throughput to `sweep_results.tsv`. |
| `loadtest.sh` | Light concurrent load: N short requests, samples scheduler state. `./loadtest.sh 12 600` |
| `install-sudoers.sh` | Installs `dspark-dropcaches` to `/etc/sudoers.d/` and validates with `visudo -c`; self-removes the file if validation fails. Run with sudo on both nodes. Already done 2026-09-13; re-run after a node rebuild. |
| `kv-offload-probe.md` | Runbook for the native disk-offload probe (`TieringOffloadingSpec` + `fs_python` tier). Prepared, not yet run. |
| `sweep_results.tsv` | Results of the 2026-09-13 config sweep. Read the header caveats before trusting any column. |


## Prefix-cache and prompt tooling

Added 2026-09-14..19. These measure the engine's own accounting; the traps below are not
optional reading.

| File | Purpose |
|---|---|
| `cache-probe.py` | **Ground truth.** Sends a request and reads `vllm:prefix_cache_{queries,hits}_total` either side, so the hit ratio is the engine's. `--selftest` is the T0.1 agreement test — run it first. `--replay` replays a capture. |
| `prefix-diff.py` | **Explainer, not evidence.** Flattens two requests the way the server renders them and says where they stop sharing a prefix. Has been wrong once; check against `cache-probe.py`. |
| `matrix-report.py` | Per-turn table + acceptance verdict for a tap capture. Chains conversations separately, excludes `count_tokens` and failed turns, flags `[BLENDED xN]` and `[EVICTION?]`. |
| `prompt-tap.py` | Captures every request body Claude Code sends, forwarding over the existing mTLS path. `--metrics-url` measures each turn live; `--serialize` forces one in flight. **Captures contain full prompts — delete after use.** |
| `toolsearch-matrix.sh`, `-run.sh`, `-nolsp-run.sh` | Drive one headless session per matrix cell through the tap. One cell at a time: `/metrics` counters are global. |
| `phase2-probes.sh` | Failure-mode probes: resume, subagent, mcp, mid-session tier switch. |
| `toolref-probe.py`, `toolquality.py` | `tool_reference` shapes; tool-selection quality under `ENABLE_TOOL_SEARCH`. |
| `prefix-watch.py` | Consumes the Patch 12 `PREFIX_WATCH` lines and alerts when a known conversation's head moves. |
| `verify-server.py` | 14-check regression suite for the Anthropic patch stack. Run after any serving-patch change. |
| `deploy-serving-patch.sh` | Deploys the serving patch following the manual restart checklist. Dry run by default; `--apply`. |
| `bootmon.sh` | Boot-loop monitor; run detached right after a start. |
| `cache-pressure/` | Retention benchmark (hydrate N contexts to overflow, re-send in reverse, first miss = retained capacity). |
| `xsess/` | **Cross-session prefix reuse investigation (2026-09-19).** `FINDINGS.md` is the write-up; `extent-probe.py` (exact-token staircase), `xsess-probe.py` (cross-session reuse), `survival-probe.py` (head survival under load), `image-src/` (genuine image copies of the four core KV files). |
| `kvsim/` | **Offline reproduction of KV lookup.** `run.sh [patch6]` runs the real vLLM KV modules in a throwaway container from the serving image — no GPU, no engine, seconds. Used for the Patch 6 and eagle A/Bs. |
| `baseline-20260914/` | Rollback baseline. **Read `PRISTINE-README.md` first** — one file in it was mislabelled until 2026-09-19. |

### Traps that invalidate measurements

- **Never retry a cache measurement with the same request.** The first attempt cached it; the
  retry reads its own footprint back and reports ~100%. Regenerate a fresh request per attempt.
- **A clean delta has `queries == input_tokens`.** This cluster has concurrent external traffic
  and the counters are global. Discard blended rows; never average through them.
- **`vllm:num_requests_running` and `vllm:gpu_cache_usage_perc` are both unusable** as
  load/pressure signals here — the first lags the logging interval, the second reads 0.0 even
  under load. Use `vllm:prompt_tokens_total` deltas.
- **0% hit has two causes**: the head moved, or the blocks were evicted. `matrix-report.py`
  distinguishes them.
- **Reading a bind-mounted path from a container gives you the PATCHED file.** Pull originals
  with `docker run --rm --entrypoint cat <image> <path>`.

## Usage notes

- Run the guard **before** any pressure test, and confirm the process is actually running —
  a missing script silently leaves you unguarded (`/tmp` wipes have caused this).
- `oomguard.sh` trips on *any* new NVRM line vs its baseline, so it false-trips across a
  restart. Use it for steady-state load only.
- Set `MIN_AVAIL_GB` below the observed idle headroom: idle is ~8–9 GB with the engine up,
  so 4–5 GB catches real trouble without false-tripping.
- `sweep.sh` needs a ≥90s grace period before declaring a container dead — it starts the
  cluster and the container does not exist for the first minute.

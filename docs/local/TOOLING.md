# TOOLING.md — the untracked `local-ops/` tree

**`local-ops/` is deliberately untracked and stays that way.** `.gitignore` carries `/local-ops/`.
It holds captures of real prompts, API keys in some configs, benchmark outputs, and a rollback
snapshot of image files — none of which belong in a repo whose `origin` is a public upstream.

It lives *inside* the repo rather than in `/tmp` so it survives reboots and `/tmp` wipes. This
file is the tracked index of it, so the tooling is discoverable even though the code is not
committed. `local-ops/README.md` has the per-script detail.

> **Captures contain full prompts. Treat them as sensitive and delete them after use.**

## Prefix-cache instruments

| tool | what it does |
|---|---|
| `local-ops/cache-probe.py` | **Ground truth for prefix caching.** Reads `vllm:prefix_cache_{queries,hits}_total` either side of a request, so the hit ratio is the engine's, not a model of the prompt. `--selftest` is the agreement test against `prefix-diff.py`; `--replay` replays a capture. |
| `local-ops/prefix-diff.py` | **Prefix divergence finder.** Re-implements the server's render transforms and reports where consecutive requests stop sharing a prefix. Found the `<total_tokens>` cache killer (API-11a). **An explainer, not evidence** — it has been wrong once; check it against `cache-probe.py`. |
| `local-ops/prefix-watch.py` | Tails the API-12 `PREFIX_WATCH` lines and alerts when a known conversation returns with a changed tools/system/first-user hash. **Does not parse `docker -t` timestamps** — it stamps lines with its own clock, so a backfilled log collapses to one instant. |
| `local-ops/prefill-attribute.py` | **Per-turn MISS attribution for a session already in flight**, from the server log alone. Complements `prefix-watch.py`: that reports the head MOVING, this reports the turn being RECOMPUTED. A stable head that still pays a full prefill was EVICTED. Costs the server one read-only `docker logs`. `--follow` streams it live. |
| `local-ops/matrix-report.py` | Per-turn report + acceptance verdict for a tap capture. Chains conversations separately, excludes `count_tokens` and failed turns, detects contamination exactly. |
| `local-ops/cache-pressure/` | Retention benchmark (from `co-l/cache-pressure`). Seeded, so runs are byte-identical and A/B-comparable. Always pass the **current boot's** `--kv-size`. |
| `local-ops/xsess/` | The cross-session investigation: `FINDINGS.md` plus ten probes. |
| `local-ops/kvsim/` | Offline container reproduction, no GPU, seconds. |

## Client-side capture

| tool | what it does |
|---|---|
| `local-ops/prompt-tap.py` | **Prompt capture tap.** Sits in front of the vllm-proxy on the Mac, logs every request body Claude Code sends, forwards over the existing mTLS path. No server change, no restart. Records request `headers` since 2026-09-19 (`authorization`, `x-api-key`, `proxy-authorization`, `cookie` are redacted and never written). Only sees a session **launched** through it. |
| `local-ops/toolsearch-matrix.sh`, `-run.sh`, `-nolsp-run.sh` | One headless session per matrix cell, routed through the tap. Cells run strictly one at a time — the `/metrics` counters are global. |
| `local-ops/phase2-probes.sh` | Failure-mode probes: `resume`, `subagent`, `mcp`, `tier`. |
| `local-ops/toolref-probe.py` | `tool_reference` probe — does it 200, does any schema survive, can the model then call the tool. |
| `local-ops/toolquality.py` | Tool-selection quality under `ENABLE_TOOL_SEARCH` true vs false. |

## Operations

| tool | what it does |
|---|---|
| `local-ops/verify-server.py` | **Post-restart regression suite** for the Anthropic patch stack — 14 checks. Run after any change to the serving patch. |
| `local-ops/deploy-serving-patch.sh` | Deploys the serving patch + compose following the manual restart checklist: watchdog down FIRST, stop, start detached with `bootmon.sh`, wait for HTTP 200, verify, watchdog back up. Dry run by default; `--apply` to do it. |
| `local-ops/bootmon.sh` | **Boot-loop monitor.** Run detached right after a start; flags the three loop signatures and exits on the first HTTP 200 with a verdict. |
| `local-ops/baseline-20260914/` | Rollback snapshot: `MANIFEST.txt` (image id, config, file hashes, mounts, boot metrics) plus unpatched copies of five KV files. **Not** the source for generated diffs — that is the tracked `patches/pristine/`. |
| `local-ops/dspark-dropcaches` | The sudoers rule for the startup cache reclaim. Install on both nodes. |
| `local-ops/rollback/` | **Head-only.** Pre-change copies of `watchdog-dspark.sh` and `start-deepseek-v4-flash-dspark.sh`, with a README saying what each one predates. Lives here rather than `/tmp` precisely because a reboot wipes `/tmp` — which is where the 2026-09-19 `.pre-singleton` copy had been sitting. |
| `local-ops/oomguard.sh`, `kvpressure.py`, `sweep.sh`, `loadtest.sh` | Pressure and sweep harnesses; results written alongside them. |
| `local-ops/hmmt-effort-20260916/` | The HMMT effort benchmark harness, problem set and per-problem JSON. |

## The rule

Tracked tooling goes in `scripts/`. Anything that captures traffic, holds a key, or produces bulk
results goes in `local-ops/` and gets a row here instead.

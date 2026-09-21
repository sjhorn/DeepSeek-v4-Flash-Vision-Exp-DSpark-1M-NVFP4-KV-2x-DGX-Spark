# TOOLING.md — the `local-ops/` tree

**The scripts are tracked; everything they produce is not.** Changed 2026-09-20 — it used to be
blanket-ignored, which is how the only copy of `verify-server.py` came to live on one laptop.

`.gitignore` **denies everything** under `local-ops/` and then allows back exactly `*.py`, `*.sh`,
`*.md` and `requirements.txt`. The direction matters: deny-by-default means a new capture or log
format is ignored automatically, where an allow-by-default list fails open the first time something
writes a format nobody thought to list.

| | |
|---|---|
| tracked | 60 files, 444 KB of tooling and write-ups |
| ignored | the 54 MB of `toolsearch-matrix/` captures, every `*.log` / `*.jsonl` / `*.json` / `*.tsv` / `*.tgz`, and three directories of **data that happens to be `.py`/`.md`** — `baseline-20260914/` and `xsess/image-src/` (copies of vLLM source, superseded by the tracked `patches/pristine/`) and `rollback/` (head-only copies of our own scripts) |

> **Captures contain full prompts and are sensitive. If you add a new output format, confirm
> `git check-ignore` catches it BEFORE you commit** — the allowlist protects you only for formats
> it does not name, and `origin` is a public upstream even though this branch is never pushed.

`local-ops/` lives *inside* the repo rather than in `/tmp` so it survives reboots and `/tmp` wipes.
`local-ops/README.md` has the per-script detail.

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

## KV mechanism flags and tests (MNT-8 / MNT-9)

| tool | what |
|---|---|
| `local-ops/kv-flags.sh` | read or flip the `MNT-8` / `MNT-9` runtime flags on **both** nodes. No restart: the engine re-reads `/var/tmp/vllm-kv-flags/flags.json` once a second. `reset` returns to stock behaviour. |
| `local-ops/kv-mech-tests.sh` | stage the patched KV files into a container and run `kv-mech-tests.py` (13 checks) against the **real** vLLM classes. No GPU, no restart, never touches the node's repo or the running engine. |

| `local-ops/xsess/decode-dose.py <turns> <max_tokens>` | **the 45s reproducer for the prefix-destruction bug.** Replays captured request bodies with a chosen decode length, probing before and after. `7 50` = dead, `1 400` = alive. No client, no session, no restart. |
| `local-ops/xsess/session-sim.py <turns> <max_tokens> [label]` | **the correct reproducer.** Stamps the system prompt unique (a head nobody has cached), runs the turns with decode, THEN probes once. Use this, not `decode-dose.py`, for any arm comparison: `decode-dose.py` probes first, which warms the head and makes both arms read ALIVE. |
| `local-ops/xsess/pressure-dose.py` | how much unrelated prefill it takes to evict a warm head (224K: survives, 1.1M: dies). |

Arms and what each is supposed to move: `CACHE_TEST.md`.

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

## scripts/ vs local-ops/

Both are tracked now, so the split is about **audience**, not visibility:

| | |
|---|---|
| `scripts/` | things you run as part of operating the cluster, and that a fail-closed check depends on — `check-patch4.sh`, `check-local-patches.sh`, `regen-local-patches.sh` |
| `local-ops/` | investigation and measurement tooling: probes, harnesses, replays, benchmark drivers. Run when answering a question, not on every deploy |

Anything that **captures traffic or produces bulk results** writes into `local-ops/` and stays out
of git by the allowlist above — regardless of which directory the script itself lives in.

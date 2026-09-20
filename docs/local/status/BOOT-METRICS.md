# BOOT-METRICS.md — one section per boot, newest first

Every restart gets a section here: date, the KV pool and concurrency figures straight from the
boot log, what changed, and which start script was used. That is the working agreement in
`CLAUDE.md`, and a missing entry is an incomplete task.

> **KV pool size varies per boot** — unified-memory contention gives an ~11% swing between
> identical boots, documented upstream. A single boot figure is not a constant and not a
> regression. Always read the current boot's own number:
> `docker logs <container> | grep 'GPU KV cache size'`.

> Moved verbatim from `STATUS.md` during the 2026-09-20 doc split.


## Boot metrics (2026-09-20 08:58Z boot: Vision-Exp, no config change)

**Recorded retroactively on 2026-09-20 from the container and engine logs.** This restart was not
taken by the session that wrote this entry, so *what it deployed and who initiated it are not
determinable from the logs available* — only that `start-deepseek-v4-flash-dspark.sh` ran it (not
`start-cluster.sh`; see the watchdog note below). Recorded anyway because an unrecorded boot is the
gap the working agreement exists to close.

| | |
|---|---|
| started | head 08:58:04Z, worker 08:58:03Z, `RestartCount=0` both |
| API answering | 09:04:51Z — **407s cold boot** |
| **GPU KV cache size** | **2,510,051 tokens** |
| max concurrency @ 1,048,576 | **2.39x** |
| init engine (profile, KV, warmup) | 67.68s (compilation 2.61s) |
| protected prompt block cap | 1,691 blocks/group — pool 16,912 blocks, 5 managers, fraction 0.50, legacy caps 8,192 / 32,768 / 524,288 |
| model | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`, `hf_overrides.architectures=['DeepseekV4VForConditionalGeneration']` |
| config | `max_model_len` 1,048,576, `max_num_seqs` 12, `gpu_memory_utilization` 0.86, `num_speculative_tokens` 5 |

KV pool is within 0.04% of the 2026-09-14 boot's 2,510,942 — no regression.

The start script's own log shows the 2026-09-18 vision auto-detection working in production, which
had not been observed on a boot anyone recorded:

```
Vision-Exp mode: overlaying docker-compose.vision-exp.yml
Vision stage files present on both nodes.
Startup cache reclaim: active on both nodes (stops when API is ready).
```

> **This boot came within ONE watchdog poll of being torn down** — see
> [`INCIDENTS.md`](INCIDENTS.md), "A cold boot reached 7 of 8 watchdog failures". **Fixed the same
> day:** the start script now writes a boot sentinel the watchdog honours, so a future boot of any
> duration cannot be interrupted by a watchdog that did not start it.

> **The `MNT-6a` cap still logs as `Patch 5:` on this boot** — expected. The relabel landed in
> `patches/patch6-single_type_kv_cache_manager.py` on 2026-09-20, and the running process holds the
> copy it imported at 08:58Z. It will read `MNT-6a:` from the next restart onward. This is a useful
> incidental proof that a bind-mounted edit does **not** reach a running engine.

## Boot metrics (2026-09-19 16:04 boot: recovery after the watchdog boot-loop)


| item | value |
| --- | --- |
| Started | 16:04:41 local, API 200 at **16:10:42** (~6 min once the watchdogs were gone) |
| GPU KV cache size | **2,510,942 tokens** |
| Maximum concurrency @ 1,048,576 | **2.39x** |
| init engine (profile, kv cache, warmup) | 68.54 s (compilation 2.57 s) |
| What changed | **nothing** — same image, config and patches; this was a recovery, not a deploy |
| Start used | `start-deepseek-v4-flash-dspark.sh`, invoked by a watchdog |
| Post-boot verification | `verify-server.py` **14/14**, smoke **6/6**, `check-patch4.sh` **OK**, **0 × 5xx**, watchdog count **1** |


## Boot metrics (2026-09-19 14:57 boot: Patch 13 sticky tool set)

| | |
|---|---|
| Started by | `local-ops/deploy-serving-patch.sh --apply` |
| **GPU KV cache size** | **2,506,935 tokens** (2.51M / 2.52M / 2.51M across today's three boots — within the documented ~11% per-boot swing) |
| RestartCount | 0 |
| What changed | Patch 13 (sticky tool set) + `STICKY_TOOLS` / `STICKY_TOOLS_TTL` compose passthrough |
| Verification | `verify-server.py` **14/14** · smoke **6/6** · `check-patch4.sh` OK · 0 × 5xx · watchdog running |

**Patch 13 verified live**, simulating the LSP flap inside one conversation:

| turn | tools the client sent | prompt tokens | hit |
| --- | ---: | ---: | ---: |
| 1 | 23 | 18,347 | 0.0% (cold) |
| 2 | 24 (+LSP) | 18,834 | 0.0% (first appearance — expected, unfixable server-side) |
| 3 | **23 (LSP dropped)** | **18,834** | **99.2%** |
| 4 | 24 (+LSP back) | 18,835 | 99.2% |

Turn 3 is the proof: the client sent 23 tools but the prompt stayed at the 24-tool length, so the
server re-advertised LSP — and the turn hit 99.2% where before Patch 13 it was a full re-prefill.
Exactly one `PATCH 13: … dropped ['LSP']; re-advertising` line was logged.

> **The watchdog did not come back up on its own** after this deploy and had to be started by hand.
> `deploy-serving-patch.sh` runs that as its last step; check `pgrep -f "[w]atchdog-dspark.sh"`
> after every deploy rather than assuming it took.

## Boot metrics (2026-09-19 13:18 boot: Patch 12 tripwire + compose kill-switch passthrough)

| | |
|---|---|
| Started by | `local-ops/deploy-patch12.sh --apply` → `start-deepseek-v4-flash-dspark.sh` detached, `bootmon.sh` alongside |
| Time to HTTP 200 | ~6 min (container `StartedAt` 13:18:37, KV sized 13:24:16) |
| **GPU KV cache size** | **2,515,543 tokens** |
| **Maximum concurrency** (1,048,576 per request) | **2.40x** |
| RestartCount | 0 — no boot loop |
| What changed | Patch 12 (`PREFIX_WATCH` guardrail line) + compose passthrough for the patch kill switches |
| Verification | `check-patch4.sh` OK · 12/12 model ids · smoke **6/6** · `verify-server.py` **14/14** · T0.1 PASS · 0 × 5xx |

Unchanged from the 2026-09-14 boot (2,515,543 vs ~2.51M, 2.40x vs 2.39x) — the guardrail costs no
KV. Watchdog confirmed running after the API answered, per the restart checklist.

> **Stale note corrected in passing.** CLAUDE.md warned that the Mac's `docker-compose.dspark.yml`
> was ahead of the head's on the Patch 5 mount and Patch 9 aliases. Diffed before overwriting: the
> two were **identical** apart from the new kill-switch block. Diff, don't assume.

> **Found while adding this:** the kill switches documented for Patches 8, 9 and 10
> (now `API-8`, `API-9`, `API-10` — see [`../PATCH-REGISTRY.md`](../PATCH-REGISTRY.md))
> (`STRIP_LEAKED_COT`, `MODEL_ALIAS_THINKING`, `CLASSIFIER_NOTHINK`, `TOOL_ARGS_STRICT`) were
> **never passed into the container**, so setting any of them in `.env.dspark` did nothing. They are
> in the compose now, at their existing defaults, so this changed no behaviour — but the documented
> opt-outs only actually work from this boot onward.

## Boot metrics (2026-09-18 13:10 boot: Patch 9 rev 2, vendor aliases)

```
GPU KV cache size: 2,523,706 tokens
Maximum concurrency for 1,048,576 tokens per request: 2.41x
API up at 13:10:26 (27 samples); RestartCount 0 both nodes; 12 model ids served
```

Verified after boot: vendor ladder resolves correctly — haiku/sonnet +0 prompt tokens, opus +79,
fable +92, each echoing its own name; classifier exemption proven by **thinking blocks**, not
token counts (detail: [`../PATCHES-API.md#api-9`](../PATCHES-API.md#api-9)); local `-think-*` aliases unchanged; Patch 8 strip correct; smoke 6/6;
Patch 4 present; watchdog restarted 13:12:22.

**How the classifier exemption was actually proven.** `thinking:true+low` and `thinking:false`
both add zero prompt tokens, so `prompt_tokens` cannot tell them apart — an early check appeared to
pass while proving nothing. The witness is the response shape:

| request | blocks returned | thinking chars |
| --- | --- | ---: |
| `claude-sonnet-5` plain (tier = low) | `['thinking']` | 1,063 |
| `claude-sonnet-5` + classifier system, no tools | `['text']` | **0** |
| `claude-haiku-4-5` (tier = off) | `['text']` | 0 |
| `claude-opus-5` (tier = high) | `['thinking','text']` | 472 |

**Boot monitor false positive, now fixed.** `bootmon.sh` flagged `RESTART_COUNT` on this boot
because the first sample ran before the container existed (`NA`) and the transition `NA → 0` looked
like a change. Ground truth was `RestartCount=0` throughout. The guard now requires both samples to
be real, and `docker inspect` failures yield a single clean token instead of breaking the TSV row.

## Boot metrics (2026-09-18 11:04 boot: Patch 9b)

```
GPU KV cache size: 2,509,606 tokens
Maximum concurrency for 1,048,576 tokens per request: 2.39x
API up at 11:04:05; RestartCount 0 both nodes; boot-loop monitor flagged nothing
```

Verified after boot: all five aliases echo their own name on both streaming and non-streaming
paths, effort prefixes still 5/5/84/97, Patch 8 strip still assistant-only, smoke 6/6, Patch 4
present, watchdog restarted 11:04:54. Loop monitor log:
`local-ops/bootmon/boot-20260918-110024.tsv`; the monitor itself is `local-ops/bootmon.sh`.

## Boot metrics (2026-09-18 boot: Patch 9 + Patch 5 mount, seqs 12, gpu_mem 0.86, capture 72)

```
GPU KV cache size: 2,479,329 tokens
Maximum concurrency for 1,048,576 tokens per request: 2.36x
API up after ~190s; RestartCount 0 on both nodes
```

Recent boots for comparison: 2,521,925 (09-16), 2,506,193 (09-14). A 1.7% spread — per-boot
variance, not a regression. Started with `start-deepseek-v4-flash-dspark.sh`; **GPU clocks were
not re-pinned** (start-cluster.sh needs an interactive sudo password), harmless until a node
reboots. Verified after boot: smoke 6/6, Patch 4 present, Patch 5 mounted and inert, Patch 8
strip correct, Patch 9 aliases all resolving, worker patch sync complete, watchdog restarted.

## Boot metrics (2026-09-16 boot: Patch 8 deployed, seqs 12, gpu_mem 0.86, capture 72)

```
GPU KV cache size: 2,521,925 tokens
Maximum concurrency for 1,048,576 tokens per request: 2.41x
```

Previous boot (2026-09-14) was 2,506,193 / 2.39x — +0.6%, inside the documented per-boot swing.
Started with `start-deepseek-v4-flash-dspark.sh`, **not** `start-cluster.sh`: the latter runs
`sudo nvidia-smi -pm 1` / `-lgc`, which are not in either node's NOPASSWD rules and would block on
a password prompt over non-interactive SSH. Startup cache reclaim still ran (its rule is scoped to
exactly `sysctl -qw vm.drop_caches=3`). **GPU clocks were therefore not re-pinned** — harmless
until a node reboots, since the pin from the previous `start-cluster.sh` survives while the host
is up, but the next start should be `start-cluster.sh` run interactively.

## Reference: the 2026-08-22 config (seqs 4, gpu_mem 0.87, cudagraph profiling on)

```
GPU KV cache size: 3,203,908 tokens
Maximum concurrency for 1,048,576 tokens per request: 3.06x
max_cudagraph_capture_size: 24
MoE backend: B12X Mxfp4
```

Kept for comparison only — **this is a different configuration, not a boot of the current one.**
Its 3.2M KV pool is not a target the present config should be measured against: `max_num_seqs` was
4 (now 12) and `gpu_memory_utilization` 0.87 (now 0.86, and [capped there for two documented
reasons](INCIDENTS.md)).

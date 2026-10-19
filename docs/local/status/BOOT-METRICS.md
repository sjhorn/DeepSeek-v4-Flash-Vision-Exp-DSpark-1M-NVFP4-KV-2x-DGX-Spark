# BOOT-METRICS.md — one section per boot, newest first

Every restart gets a section here: date, the KV pool and concurrency figures straight from the
boot log, what changed, and which start script was used. That is the working agreement in
`CLAUDE.md`, and a missing entry is an incomplete task.

> **KV pool size varies per boot** — unified-memory contention gives an ~11% swing between
> identical boots, documented upstream. A single boot figure is not a constant and not a
> regression. Always read the current boot's own number:
> `docker logs <container> | grep 'GPU KV cache size'`.

> Moved verbatim from `STATUS.md` during the 2026-09-20 doc split.

> 0.32 lane boots before this one are recorded in vllm-proxy `docs/kv/history/`.

## Boot metrics (2026-10-19 12:41Z boot, lane 0.32: the UVM memory-saver trial)

**Restart asked for and approved, in an idle window,** to run the patched `nvidia-uvm` (memory
saver, variant c) as a trial. The engine and its config did not change. Record:
vllm-proxy `docs/future-memsaver.md` "Trial, 2026-10-19".

| | |
|---|---|
| stopped | 12:35Z, `serve-032.sh down` with `~/.engine-hold` (sparkstats also stopped for the module swap) |
| API answering | **12:41Z** |
| **GPU KV cache size** | **2,115,150 tokens** (**2.02x** at 1,048,576), `kv_cache_memory_bytes` 20.29 GiB |
| started by | `serve-032.sh`, detached |
| what changed | `nvidia-uvm` only: srcversion `37A4D127AE60F1F3AE60A02`, `uvm_pack_sysmem_leaf_tables=Y`, both nodes, until their next reboot |

Engine cgroup `kernel`: 3.522 → 0.483 GiB on the head, 3.544 → 0.471 GiB on the worker. One chat
request served. No Xid or UVM error in the engine logs. The kvrace gate has not run on this module.


## Boot metrics (2026-09-21 08:49Z boot: `MNT-10` + the `MNT-6c` code default)

**Restart spent with a specific ask, to stop one long prefill starving every decode behind it.**
Diagnosis and evidence: [`INCIDENTS.md`](INCIDENTS.md) "Decode collapses to ~2 tok/s beside a long
prefill"; mechanism: [`../PATCHES-KV.md`](../PATCHES-KV.md) `MNT-10`.

| | |
|---|---|
| stopped | 08:47Z, both sides, cleanly |
| API answering | **08:52Z — 220s cold boot**, the fastest recorded here |
| **GPU KV cache size** | **2,536,173 tokens** (**2.42x** at 1,048,576) |
| protected block cap | 1,708 blocks/group — pool **17,088** blocks, 5 managers, fraction 0.50 |
| started by | `start-deepseek-v4-flash-dspark.sh`, detached |
| what changed | `MNT-10` (new `v1/core/sched/scheduler.py` mount), `--long-prefill-token-threshold 2048`, and `MNT-6c`'s code default flipped `True`→`False` |

KV pool 2,536,173 against the 15:34Z boot's 2,517,769 — a **0.7% swing**, well inside the
documented ~11% per-boot variance.

**Post-boot checks:** `check-local-patches.sh` **22/22 on both nodes, 0 FAIL** (up from 21 rows;
`MNT-10` added), `check-patch4.sh` OK, smoke test OK, and a 9,011-token prefill confirmed `MNT-6a`
logging for all five KV groups.

**The check that actually mattered:** `docker logs … | grep 'non-default args'` shows
`'long_prefill_token_threshold': 2048`. **This is the only proof the setting took** — vLLM logs the
value only inside a `max_num_partial_prefills > 1` branch, which is false at our settings, so the
boot log is otherwise silent about it. A future boot that skips this grep cannot tell whether
`MNT-10` is armed.

> **`MNT-6a`'s cap lines are NOT emitted at boot — CORRECTED.** `CLAUDE.md` and earlier notes here
> say the boot log "carries" them. It does not: `_max_protected_prompt_blocks()` is called from
> `_protect_prompt_blocks()`, so the five lines appear only after the first prefill large enough to
> protect blocks. A trivial smoke test does not do it; 9,011 tokens did. Absence immediately after a
> boot is **not** evidence the patch is missing — use `check-local-patches.sh` for that.

> **The flags file survived the restart carrying `pin_static_head: 1, swa_recycle: 0`** (mtime
> 08:10Z). It was first recorded here as another session's leftover arm. **That was wrong** — it was
> written by *this* session's own first command, via the `kv-flags.sh` header bug (see
> [`INCIDENTS.md`](INCIDENTS.md), "`kv-flags.sh` fork-bombed the laptop"). Reset to the recommended
> state afterwards and confirmed through `docker exec … cat /etc/vllm-kv-flags/flags.json` on both
> nodes. The durable lesson stands regardless of who wrote it: `/var/tmp` is node-local, the start
> script does not recreate it, so **a restart does not return the flags to the recommended state —
> check them after every boot.**

## Boot metrics (2026-09-20 15:34Z boot: make `MNT-8` / `MNT-9` live for the A/B)

**Restart spent deliberately, with a specific ask, to run arms A and B of `CACHE-TEST.md`.**
Both mechanisms shipped OFF; the restart imported the mounted files so the flags could be flipped
afterwards **without** further restarts.

| | |
|---|---|
| started | 15:34:2xZ head and worker, `RestartCount=0` both |
| API answering | **17:40:18 local (15:40Z)** — ~360s cold boot |
| **GPU KV cache size** | **2,517,769 tokens** (2.40x at 1,048,576) |
| init engine | 67.95s (compilation 3.13s) |
| protected block cap | 1,674 blocks/group — pool 16,741 blocks, 5 managers, fraction 0.50 |
| MNT-9 head-pin cap | 169 blocks/group (`head_pin_fraction` 0.05, same 5 managers) |
| started by | `start-deepseek-v4-flash-dspark.sh`, detached; watchdog stopped first and restarted after, exactly one running |
| what changed | `MNT-8` (new `kv_cache_utils.py` mount + `free_blocks(prepend=)` + `_free_split`), `MNT-9` (static-head pinning), the flags-directory mount |

KV pool 2,517,769 against the 14:33Z boot's 2,484,672 — a **1.3% swing**, inside the documented
~11% per-boot variance and not attributable to the new mounts.

**Post-boot checks, all three, both nodes:** `check-local-patches.sh` **20/20** on head and worker
(up from 17 rows; `MNT-8`, `MNT-8b`, `MNT-9` added), `check-patch4.sh` OK, `verify-server.py`
**14/14**.

> **One check row was wrong, and the boot is what caught it.** `MNT-8` asserted the marker
> `prepend_n(blocks` while the signature is `def prepend_n(self, blocks: ...)`, so it FAILed against
> a node where the mount was correct and loaded (`kv_cache_utils.py:329`). Fixed the same session —
> the mirror image of the false PASS fixed hours earlier, and the reason both were caught is that
> the rows were read against a real boot instead of being trusted.

Results of the arms this boot bought: [`CACHE-TEST.md`](../CACHE-TEST.md) §6, and the
warm-up experiment that corrected them, §7.

## Boot metrics (2026-09-20 14:33Z boot: first boot of `local/main`, boot sentinel proven)

**Deliberate test restart.** Nothing new was deployed — both nodes were already at the pushed
commit; the restart only made the staged files live, and answered whether a *real* cold boot
survives a running watchdog.

| | |
|---|---|
| started | head 14:33:06Z, worker 14:33:05Z, `RestartCount=0` both |
| API answering | 14:39:09Z — **363s cold boot** |
| **GPU KV cache size** | **2,484,672 tokens** (2.37x at 1,048,576) |
| init engine | 68.86s (compilation 3.25s) |
| protected block cap | 1,674 blocks/group — pool 16,741 blocks, 5 managers, fraction 0.50 |
| started by | `start-deepseek-v4-flash-dspark.sh`, detached, **watchdog left running on purpose** |

KV pool 2,484,672 against the 08:58Z boot's 2,510,051 — a 1.0% swing, well inside the documented
~11% per-boot variation. Not a regression.

**What this boot proved:**

- **The boot sentinel works.** `0` failed watchdog polls across a 363s boot, where the previous
  cold boot reached **7 of 8**. The hold-off logged 9s after the sentinel appeared and the failure
  count was reset, so the `stop` that preceded it cost nothing.
- **`MNT-6a` / `MNT-6b` labels are live** — the relabel this branch made, now in the engine log,
  with **0** lines carrying the old `Patch 5:` / `Patch 6:` names. The `MNT-6a` cap line only
  appears on first real prompt allocation, so it took a 40,008-token request to surface.
- **The git-pushed tree loads.** `check-local-patches.sh` 17/17 on both nodes against the fresh
  container, `check-patch4.sh` OK, `PLG-14b` registered at 14:33:20
  (`prefill_collector -> prefill_collector:PrefillCollector`).
- Vision auto-detection, both-node stage preflight and the page-cache reclaim all ran.

> **It also found a real defect — see [`INCIDENTS.md`](INCIDENTS.md), "The boot sentinel survived
> the boot".** The boot was clean; the *cleanup* was not.

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

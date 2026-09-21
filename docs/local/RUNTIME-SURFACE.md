# RUNTIME-SURFACE.md — what can change without a restart, and what cannot

**The question this answers:** before proposing a 250-600s cold boot, which knob am I actually
reaching for, and is there a way to move it live?

Written 2026-09-21, after `MNT-10` turned a boot-per-arm sweep into four arms in one sitting. Every
row below was **verified against the running engine or its real source**, not inferred from docs.
Re-verify before relying on a row; the method is given at the bottom.

## The four tiers

| tier | what it costs to change | examples |
|---|---|---|
| **1 — Live** | nothing. Next request picks it up | per-request params, the KV flags file, GPU clocks |
| **2 — Gateable** | **one** restart to install a gate, then free forever | `PROTECTED_FRACTION`, `max_num_seqs`, chunked-prefill on/off |
| **3 — Boot** | one restart (250-600s), every session interrupted | CLI args, container env, bind-mounted `.py` |
| **4 — Rebuild** | an image rebuild on both nodes, then a restart | `IMG-*` patches baked into the image |

**Tier 2 is the interesting one and the reason this doc exists.** A value that the engine
*re-reads on every step* is only boot-locked because of where it is read **from**. Point that read
at the flags file instead of at `scheduler_config`, and it becomes Tier 1 forever. That is exactly
and only what `MNT-10` did — it changed no scheduling logic at all.

## Tier 1 — live now, no restart

| knob | how | who can do it | evidence |
|---|---|---|---|
| `swa_recycle`, `swa_recycle_cached` (`MNT-6b`/`6c`) | flags file | node shell / ssh | `_flag()` re-reads at most 1×/s |
| `free_queue_prepend_uncached` (`MNT-8`) | ″ | ″ | ″ |
| `pin_static_head`, `head_pin_fraction` (`MNT-9`) | ″ | ″ | ″ |
| `long_prefill_token_threshold` (`MNT-10`) | ″ | ″ | read per step, `scheduler.py:493` and `:764` |
| temperature, `max_tokens`, `top_p`, stop strings | per request | **any client** | request body |
| thinking tier / effort | per request, via the model alias | **any client** | [`THINKING-AND-EFFORT.md`](THINKING-AND-EFFORT.md) |
| tools array, system prompt | per request | **any client** | it *is* the prompt |
| GPU clock pin | `sudo nvidia-smi -lgc 300,2200` | node shell **+ sudo** | does not survive a node reboot |

> **Flags file: write the HOST path, read the CONTAINER path.** The host keeps it at
> `/var/tmp/vllm-kv-flags/flags.json`; the compose mounts that directory read-only at
> `/etc/vllm-kv-flags`. Always confirm with
> `docker exec <container> cat /etc/vllm-kv-flags/flags.json` — that proves what the **engine**
> sees. Getting this backwards silently disabled `MNT-10`'s gate for a whole A/B
> ([`status/INCIDENTS.md`](status/INCIDENTS.md)).

## Tier 2 — boot-locked today, but the value is read per step or per request

**These are candidates, not promises.** Each was confirmed to be re-read in a hot path, so a
flags-gated patch would make it live. None is gated today.

| knob | read where | per | worth gating? |
|---|---|---|---|
| `PROTECTED_FRACTION` (`MNT-6a`) | `patch6:619`, called from `_protect_prompt_blocks` at `:663` | **request** | **Yes.** Already recomputed every request; only the env read pins it. Retention tuning currently costs a boot per value |
| `enable_chunked_prefill` | `scheduler.py:772` | request | Marginal — turning it off at 1M context is not a thing we want |
| `disable_chunked_mm_input` | `scheduler.py:1300` | request | No, vision-only |
| `async_scheduling` | `scheduler.py:1169`, `:1599` | step | Risky — changing it mid-flight would race in-flight batches |
| `max_num_seqs` | cached at `scheduler.py:202` into `self.max_num_running_reqs` | init | **Maybe.** It is a plain attribute compared per step, so a gate could re-read it. Lowering live would shed concurrency without a boot; raising it past the CUDA-graph capture size would not help |

**`max_num_batched_tokens` (`:204`) and `policy` (`:257`) are also cached at init**, but gating
them is not free: the budget is handed to `KVCacheManager` at construction (`:327`), so changing
the attribute alone would desynchronise the two.

## Tier 3 — genuinely needs a restart

| knob | why it cannot be live |
|---|---|
| `GPU_MEMORY_UTILIZATION`, KV pool size | memory is profiled and the pool carved at engine init |
| `MAX_MODEL_LEN` | fixes KV layout and the block tables |
| `--block-size`, `--kv-cache-dtype` | allocation geometry |
| `COMPILATION_CONFIG` / CUDA-graph capture | graphs captured once at startup |
| `--speculative-config` (MTP, k=5) | draft model loaded at init; k must divide `n_predict` |
| tensor-parallel size, `--distributed-executor-backend` | process topology |
| the model itself (text ↔ vision) | different weights |
| **every bind-mounted `.py` (`MNT-*`, `API-*`)** | Python imports the module once; the container holds the inode it imported at boot |
| container env (`VLLM_*`, `PROTECTED_FRACTION`) | a process cannot have its environment changed from outside |
| `--long-prefill-token-threshold` **as a boot default** | it is a CLI arg — but `MNT-10` makes the *effective* value Tier 1 |

> **A `git push` is not a restart.** It replaces files on the node; the running container keeps the
> inode it imported. New patches go live at the next restart, whenever that happens.

## Tier 4 — image rebuild

`IMG-1`…`IMG-4` live in `recipe/overlay/` and are baked in. Changing one means rebuilding the image
on both nodes and then restarting. See [`PATCH-REGISTRY.md`](PATCH-REGISTRY.md).

## What the HTTP API can and cannot do

The engine exposes **23 routes**. Checked 2026-09-21: **none of them reads or writes engine
configuration.** There is no admin endpoint, no `collective_rpc`, no config mutation. So there is
no way to retune the engine over HTTP — which is precisely why the flags file exists.

Two that look promising and are not:

- **`/scale_elastic_ep`** — needs elastic EP, and this deployment reports
  `{"is_scaling_elastic_ep": false}`. Unavailable.
- **`/load`** — read-only server-load gauge (`{"server_load": 0}`).

Useful read-only routes: `/metrics` (preemptions, prefix-cache hits/queries, running/waiting),
`/tokenize`, `/v1/chat/completions/render`, `/v1/messages/count_tokens`.

## Can a local agent do this at runtime?

**Yes for Tier 1, with the access each row needs.** "Local agent" here means one running on the
Mac, the same position we drive the cluster from.

| action | reachable from the Mac? | what it needs |
|---|---|---|
| Change per-request params (temperature, tier, tools) | **Yes** | an SSH tunnel — the API binds `127.0.0.1` on the head |
| Read `/metrics`, `/tokenize`, render endpoints | **Yes** | same tunnel |
| Flip a KV flag (`MNT-6b/6c/8/9/10`) | **Yes** | `ssh shorn@spark-45ea` + write `/var/tmp/vllm-kv-flags/flags.json` on **both** nodes |
| Read the engine's real source | **Yes** | `docker exec` / `docker run --entrypoint cat` over ssh |
| Repin GPU clocks | **Yes** | ssh **+ sudo** |
| Anything Tier 2/3/4 | **No** | needs a restart, which needs a specific per-restart ask (`CLAUDE.md`) |

So an agent with SSH to both nodes can move **every Tier 1 knob** and run a complete A/B without
touching the boot path. It cannot change tiers 2-4 without asking for a restart.

**Two cautions for an agent doing this unattended:**

1. **The flags file is global engine state, not per-session.** Two agents experimenting at once
   silently interleave arms and void both results. Read the flags immediately before *and* after
   every arm and record both; a change between them invalidates that run.
2. **Write every key you depend on, not just the one you are changing.** `kv-flags.sh` merges, so
   an unwritten key keeps whatever the last writer left.

## How to re-verify a row

Nothing here needs cluster downtime:

```bash
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1

# Is a config field read in a hot path (Tier 2) or cached at init (Tier 3)?
ssh shorn@spark-45ea "docker exec $C grep -n 'self.scheduler_config\.' \
  /opt/env/lib/python3.12/site-packages/vllm/v1/core/sched/scheduler.py"
# line inside __init__  -> cached, Tier 3
# line inside a method  -> re-read, Tier 2 candidate

ssh shorn@spark-45ea "curl -s http://127.0.0.1:8888/openapi.json | \
  python3 -c 'import json,sys;[print(p) for p in sorted(json.load(sys.stdin)[\"paths\"])]'"

ssh shorn@spark-45ea "docker logs $C 2>&1 | grep -m1 'non-default args'"
```

**A gate that reads the wrong path looks exactly like a gate with nothing to do.** Any new Tier-2
gate must log once when it first executes, naming the path and whether it exists — otherwise
"armed and idle" and "dead" are indistinguishable, which is how `MNT-10` shipped broken for its
first A/B.

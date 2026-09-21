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

Two different things share this tier, and the difference matters: the rows here are **global** —
they change the engine for every session and need node access — while **Tier 1a** below is
**per request** and needs none.

| knob | how | who can do it | evidence |
|---|---|---|---|
| `swa_recycle`, `swa_recycle_cached` (`MNT-6b`/`6c`) | flags file | node shell / ssh | `_flag()` re-reads at most 1×/s |
| `free_queue_prepend_uncached` (`MNT-8`) | ″ | ″ | ″ |
| `pin_static_head`, `head_pin_fraction` (`MNT-9`) | ″ | ″ | ″ |
| `long_prefill_token_threshold` (`MNT-10`) | ″ | ″ | read per step, `scheduler.py:493` and `:764` |
| **everything in the request body** | per request | **any client, no node access** | full list in **Tier 1a** below |
| GPU clock pin | `sudo nvidia-smi -lgc 300,2200` | node shell **+ sudo** | does not survive a node reboot |

> **Flags file: write the HOST path, read the CONTAINER path.** The host keeps it at
> `/var/tmp/vllm-kv-flags/flags.json`; the compose mounts that directory read-only at
> `/etc/vllm-kv-flags`. Always confirm with
> `docker exec <container> cat /etc/vllm-kv-flags/flags.json` — that proves what the **engine**
> sees. Getting this backwards silently disabled `MNT-10`'s gate for a whole A/B
> ([`status/INCIDENTS.md`](status/INCIDENTS.md)).

## Tier 1a — PER REQUEST: everything a client can change with no node access

**This is the only surface that needs no ssh, no sudo and no restart.** Every row is a field in the
request body, so any client can set it on any single call, and it affects **that call only**. The
rest of Tier 1 (the flags file, GPU clocks) is live but **global** — it changes the engine for
everybody and needs node access.

Declared in `patches/anthropic_protocol_inline_system.py` (`API-0`) and acted on in
`patches/anthropic_serving_inline_system.py`.

### Knobs you set

| field | what it does, in plain words |
|---|---|
| **`model`** | **The biggest one.** The name you send picks whether the model thinks before answering, and how hard. The weights are identical every time — only the thinking changes. See the alias table below. |
| `max_tokens` | The most words the model is allowed to write back. It stops there, even mid-sentence. Required. |
| `temperature` | How adventurous the wording is. `0` gives the same answer every time; our default is `1.0`, which varies. Use `0` when you are measuring something. |
| `top_p`, `top_k` | Two other ways to limit which word it may pick next. Most callers leave these alone. |
| `stop_sequences` | A list of phrases that make it stop writing the instant it says one. |
| `stream` | Send the answer word by word as it is written, instead of all at once at the end. |
| `system` | The standing instructions that sit in front of the whole conversation. |
| `messages` | The conversation so far. |
| `tools` | The list of tools the model is allowed to ask for. **Changing this changes the start of the prompt, which throws away the saved copy** — see the warning below. |
| `tool_choice` | Whether it *must* use a tool, *may* pick one, or *must not*. |
| `thinking` | The client saying outright "do not think on this one" (`{"type": "disabled"}`). Honoured by `API-9d`. (The `CLASSIFIER_NOTHINK=0` kill switch that disables this is an env var, so turning the *feature* off is Tier 3 — but sending the field is per request.) |
| `chat_template_kwargs` | A direct override of thinking and effort, skipping the model-name shortcut. Use when you want the setting without changing the name. |
| `metadata` | A label you attach to the call. We do not act on it. |
| `kv_transfer_params` | For split prefill/decode servers. **We do not run that**, so it does nothing here. |

### Picking a tier with the model name (`API-9`)

Twelve names are served. They all run the same weights; the name only sets thinking and effort.

| name you send | thinking? | effort | in plain words |
|---|---|---|---|
| `claude-haiku-*`, `*-nothink` | **no** | — | Answers straight away. Best for small background jobs like titles and summaries. |
| `claude-sonnet-*`, `*-think-low` | yes | low | The everyday setting. `low` is the *empty* instruction, so thinking happens with **no extra prompt words**. |
| `claude-opus-*`, `*-think-high` | yes | high | Thinks harder. Measured **best** on our maths benchmark: 11/12 correct. |
| `claude-fable-5`, `*-think-max` | yes | max | Thinks hardest — **and scored worse**: 8/12, a third of answers cut off, 1.7x the tokens. Reach for it knowingly, not by default. |

> **`max` is not "better than `high`".** It is slower, costlier and scored lower. `high` is the top
> of the useful range. This is recorded because it is the opposite of what the names suggest.

### Things that happen per request on their own

You do not set these; our patches apply them to every call. Listed so nobody hunts for a knob.

| patch | what it does, in plain words |
|---|---|
| `API-8` | Deletes any leaked "thinking out loud" text from earlier assistant turns before sending them back in. |
| `API-10` | Catches broken tool instructions from the model instead of letting the request crash. |
| `API-11a` | Removes a per-request counter that used to sit near the top of the prompt. Anything that changes up there throws away the saved copy of the whole prompt. |
| `API-11b` | Stops a reminder note being hoisted to the very front on later turns, for the same reason. |
| `API-12` | Writes one `PREFIX_WATCH` line per request with a fingerprint of the prompt's start, so you can see when the start moved. |
| `API-13` | Keeps the tool list steady when a client briefly drops a tool, so one flap does not cost a full re-read. |
| `API-14` | Adds `engine_cached_tokens` to the reply, telling you how much of your prompt was genuinely reused. |

> **The prompt's beginning is precious.** The engine saves its notes on a prompt and reuses them
> next turn. That only works if the **start** of the prompt is byte-for-byte identical. Change the
> tools list, the system text, or anything before them, and the saved copy is worthless — the
> engine re-reads all ~140,000 words, which takes about 14 seconds instead of half a second. Four
> of the seven patches above exist purely to stop the start moving. Check `engine_cached_tokens`
> on the reply to see whether you paid that cost.

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
| `SERVER_TOOL_STREAM`, `SERVER_TOOL_MAX_ROUNDS` (`API-15`) | container env, read at import — the kill switch and round cap for the streamed server-tool turn |
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

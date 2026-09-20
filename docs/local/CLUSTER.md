# CLUSTER.md — our two boxes, and how to drive them

Nodes, the three copies of this repo, the lifecycle scripts, the restart checklist, the watchdog,
and text↔vision switching.

**Read the restart rule in `CLAUDE.md` before restarting anything.** It is deliberately kept in
the file that is always loaded: a restart needs a specific, per-restart confirmation, every time,
and most investigation needs no restart at all.

> Moved verbatim from `CLAUDE.md` and `STATUS.md` during the 2026-09-20 doc split. Where a line was found stale
> on the way across it was corrected in place and the correction is marked **CORRECTED**.

## Our cluster

| Role | Host | SSH | RoCE IP | Mgmt IP |
|---|---|---|---|---|
| **Head** (rank 0) | `spark-45ea` | `ssh shorn@spark-45ea` | `192.168.0.120` | `192.168.1.120` |
| **Worker** (rank 1) | `spark-da08` | `ssh shorn@spark-da08` | `192.168.0.101` | `192.168.1.101` |

Passwordless SSH is set up Mac → both nodes, and head → worker (over the RoCE IP `192.168.0.101`,
which is what `WORKER_HOST` is set to). Both nodes are 2× DGX Spark GB10, TP=2 over RoCE.

Repo path on **both** nodes: `/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark`
HF cache on both nodes: `/home/shorn/.cache/huggingface`
API (head only, localhost-bound): `http://127.0.0.1:8888/v1`, served name `deepseek-v4-flash-dspark`

## Three copies of the repo — know which one you are editing

1. **This Mac checkout** (`/Users/shorn/dev/spark/...`) — authoring copy and git remote tracker.
   Nothing here runs. Changes reach the cluster only by `scp`.
2. **Head `spark-45ea`** — the copy that actually runs. It holds files that exist *nowhere else*:
   `switch-model.sh`, `.env.dspark`, `.env.dspark.text-0731`, `.env.dspark.vision-exp`,
   `docker-compose.vision-exp.yml`, `vision-exp/`, and `~/vision-stage/`.
3. **Worker `spark-da08`** — `start-deepseek-v4-flash-dspark.sh` syncs it automatically on every
   start: `docker-compose.dspark.yml`, `.env.dspark`, `patches/anthropic_*.py`, and (in vision
   mode) `docker-compose.vision-exp.yml`. **`~/vision-stage/` is deliberately not synced** — those
   files are derived from the image each node runs, so they get regenerated per node; the start
   script preflights them on both sides and refuses to boot if any are missing.

> **Drift RESOLVED — re-checked 2026-09-19.** This note used to warn that the Mac's
> `docker-compose.dspark.yml` was ahead of the head's on journald logging,
> `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS` and `NCCL_IB_MERGE_NICS`, and then (2026-09-18) that the
> Patch 5 mount and Patch 9 aliases were Mac-only. **Both claims are now stale.** Diffed the two
> files before the 2026-09-19 deploy: they were **identical** apart from the new kill-switch block,
> which was then copied over. The two copies are in sync. Re-diff rather than trusting this note:
> `ssh shorn@spark-45ea cat <repo>/docker-compose.dspark.yml | diff - docker-compose.dspark.yml`.

## Lifecycle (all from the head node)

```bash
ssh shorn@spark-45ea
cd /home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark

./start-cluster.sh                        # preferred: GPU clock pin + cluster + watchdog (needs sudo)
./start-deepseek-v4-flash-dspark.sh       # cluster only, no clock pin, no watchdog
./stop-deepseek-v4-flash-dspark.sh        # stops BOTH nodes
./status-deepseek-v4-flash-dspark.sh
./logs-deepseek-v4-flash-dspark.sh
./smoke-deepseek-v4-flash-dspark.sh
curl -fsS http://127.0.0.1:8888/v1/models
```

Boot takes ~10 minutes (weight load + CUDA graph capture). `SKIP_OVERLAY_CHECK=1` skips the
image-vs-`recipe/overlay/` staleness check (which otherwise triggers a rebuild).

**Manual restart checklist.** The watchdog fires after 3 failed polls (~180s) while a cold boot
takes 250-600s, so a running watchdog will tear the cluster down mid-boot. Always:

```bash
pkill -fx "bash ./watchdog-dspark.sh"           # see the pgrep warning below
pgrep -cfx "bash ./watchdog-dspark.sh"          # MUST print 0 before going on
./stop-deepseek-v4-flash-dspark.sh
setsid nohup ./start-deepseek-v4-flash-dspark.sh > /tmp/start.log 2>&1 < /dev/null &
setsid nohup ./local-ops/bootmon.sh > /dev/null 2>&1 < /dev/null &   # loop detection
# ... wait for HTTP 200, verify, then:
setsid nohup ./watchdog-dspark.sh >> watchdog.log 2>&1 < /dev/null &
pgrep -afx "bash ./watchdog-dspark.sh"          # confirm exactly ONE
```

> **Count the watchdogs before you do anything else.** More than one is the failure mode: a single
> watchdog's restart is blocking and cannot interrupt its own boot, but instance B's timer expires
> inside instance A's boot and issues `stop` mid-weight-load. Four of them kept the cluster
> boot-looping for two hours on 2026-09-19. The `flock` singleton added that day makes this
> self-correcting, but a pre-singleton instance can still be running from an older session.
>
> **`pgrep -f watchdog-dspark.sh` matches the shell you typed it in**, and so does the `[w]`
> bracket trick when the pattern text sits on the same command line — an inline guard reported
> "2 watchdogs already running" when there were none. Use **`pgrep -fx "bash ./watchdog-dspark.sh"`**,
> and put the check in a **script file** rather than on an `ssh` command line.

`start-cluster.sh` does the clock pin and the watchdog for you, but it needs an interactive sudo
password for `nvidia-smi -pm 1` / `-lgc`, so it cannot be driven over a non-interactive SSH. Use it
when you are at a terminal; use the sequence above otherwise, and remember the GPU clock pin is
**not** reapplied that way (harmless until a node reboots).

**After a reboot of either node: always stop both sides first, then start.** Restarting only the
head leaves the worker holding a dead NCCL connection to the old head.

## After any restart, run all three checks

```bash
bash scripts/check-patch4.sh <head-container> <worker-container>        # IMG-4, baked into the image
REMOTE=shorn@spark-45ea bash scripts/check-local-patches.sh <container> # every bind-mounted patch
REMOTE=shorn@spark-da08 bash scripts/check-local-patches.sh <container> # ... on the worker too
python3 local-ops/verify-server.py                                      # live behaviour, 14 checks
```

`check-local-patches.sh` is the one that catches head/worker drift. The start script syncs
`patches/*.py` to the worker with an `scp` glob, but nothing verified the result afterwards, and a
bind mount to the wrong path fails **silently** — the container starts, the API answers, the smoke
test passes, and the patch is simply not there. Verified 2026-09-20: 14/14 rows OK on both nodes.

Registry of what those rows mean: `docs/local/PATCH-REGISTRY.md`.

## Our local-only files, and where each one lives

Everything below is ours, not upstream's. Upstream has never touched
`vllm/entrypoints/anthropic/*`, which is why the patches have never clashed.

| file | tracked? | purpose |
|---|---|---|
| `start-cluster.sh` | yes (`local/main`) | clock pin + cluster + watchdog. Needs interactive sudo |
| `watchdog-dspark.sh` | yes | `/v1/models` poll, flock singleton |
| `switch-model.sh` | yes | swaps `.env.dspark` between the text and vision variants |
| `docker-compose.vision-exp.yml` | yes | vision overlay; the start script applies it automatically |
| `patches/` | yes | every bind-mounted patch, plus `pristine/` and `generated/` — see [`PATCH-REGISTRY.md`](PATCH-REGISTRY.md) |
| `scripts/check-local-patches.sh` | yes | fail-closed check that every patch is in the file the container imports, on every node |
| `.env.dspark`, `.env.dspark.text-0731`, `.env.dspark.vision-exp` | **NO — head-only on purpose** | they carry `SERPER_API_KEY`. `.gitignore` covers `.env.dspark.*` while keeping `.env.dspark.example`. Never paste the key into a tracked file, a commit message, or any doc |
| `~/vision-stage/` | no, and **deliberately not synced** | derived from the image each node runs, so it is regenerated per node. The start script preflights it on both sides |
| `local-ops/` | **NO — untracked by policy** | index: [`TOOLING.md`](TOOLING.md) |

## Custom scripts

### `start-cluster.sh`

Wrapper around `start-deepseek-v4-flash-dspark.sh`. Applies GPU clock pinning (`nvidia-smi -lgc 300,2200`) on both nodes, starts the cluster, then starts the watchdog. Requires sudo for clock pinning.

```bash
./start-cluster.sh   # preferred start method (from head node)
```

### `watchdog-dspark.sh`

Polls the API every 60 seconds. After 3 consecutive failures, runs `stop + start` to restart both nodes. 15-minute cooldown after restart.

```bash
nohup ./watchdog-dspark.sh >> watchdog.log 2>&1 &
```

Configurable: `POLL_INTERVAL` (60s), `FAIL_THRESHOLD` (3), `RESTART_COOLDOWN` (900s).

## Recovery after a node reboot

If the head (spark-45ea) goes down and comes back up:

1. SSH to the head: `ssh shorn@spark-45ea`
2. Stop both sides cleanly first (the worker will have a stale container):
   ```bash
   cd /home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
   ./stop-deepseek-v4-flash-dspark.sh
   ```
3. Start fresh (preferred):
   ```bash
   ./start-cluster.sh
   ```
4. Wait ~10 minutes for model load + CUDA graph capture.
5. Check firmware-notifier isn't crash-looping: `systemctl --user is-active snap.firmware-updater.firmware-notifier.timer` — should say `inactive`. If active, re-mask: `systemctl --user mask snap.firmware-updater.firmware-notifier.timer snap.firmware-updater.firmware-notifier.service`
6. Re-apply GPU clock pin if not using `start-cluster.sh`: `sudo nvidia-smi -lgc 300,2200` on both nodes.

**Do not** just restart the head container alone — the worker's NCCL connection to the old head is dead, so both sides need to be recycled.

## Startup cache reclaim (local extension, added 2026-09-13)

`start-deepseek-v4-flash-dspark.sh` drops the page cache on **both** nodes every 2s during model
load, and stops as soon as the API answers.

**Why.** CPU, GPU, weights and KV share one memory pool. Reading the 48 safetensors shards fills
the page cache, and vLLM profiles free memory *after* that load to size the KV pool. Reclaiming
across the load window reduces memory pressure at startup and shortens boot. Observed in practice
before it was scripted; the earlier manual version was a hand-run `sudo sh -c 'sync; echo 3 >
/proc/sys/vm/drop_caches'` loop.

**Why bounded.** During serving only ~1.5 GiB is reclaimable (`Cached` ≈ 1.5–1.8 GiB with the
engine up), so a running loop buys nothing and the repeated full-cache walks are pure overhead on a
box already under memory pressure. A continuous loop was running in the final seconds before the
2026-09-13 head hang — not proven causal, but it is not worth running during serving. The loop
therefore self-terminates and is `trap`-killed on script exit.

**A one-shot before `docker compose up` does NOT work** — the cache that competes with KV sizing is
created *during* weight load, so it must be reclaimed across that window.

**Requires passwordless sudo on both nodes** for exactly one command. Without it the script prints
`Startup cache reclaim: SKIPPED` and continues:

The rule ships in `local-ops/dspark-dropcaches` (see below). Install on **both** nodes:

```bash
sudo install -m 0440 -o root -g root \
  local-ops/dspark-dropcaches /etc/sudoers.d/dspark-dropcaches && sudo visudo -c
```

Disable with `DROP_CACHES_ON_START=0 ./start-deepseek-v4-flash-dspark.sh`.

**Caveat when tuning.** Reclaiming makes vLLM see more free memory at profiling time, so it sizes
KV against a cleaner baseline. That interacts with `GPU_MEMORY_UTILIZATION`: a gmu validated
*without* this reclaim is not the same setting *with* it. Re-validate gmu after adopting it, and
treat KV-pool figures measured before 2026-09-13 as not directly comparable.

## Switching text ↔ vision

`switch-model.sh` (head-only) swaps `.env.dspark` between two saved variants:

```bash
./switch-model.sh status     # which config is active
./switch-model.sh text       # deepseek-ai/DeepSeek-V4-Flash-0731  (text only)
./switch-model.sh vision     # deepseek-ai/DeepSeek-V4-Flash-Vision-Exp (multimodal)
```

The two env files differ in exactly two things: `DSPARK_MODEL`, and `HF_OVERRIDES` —
`{"architectures":["DeepseekV4VForConditionalGeneration"]}` for vision, unset for text. The alias
matters because vLLM decides `is_multimodal_model` from a static architecture-name table, not from
the class.

**Currently deployed: Vision-Exp**, at `MAX_MODEL_LEN=1048576`, `MAX_NUM_SEQS=12`,
`GPU_MEMORY_UTILIZATION=0.86`, `COMPILATION_CONFIG={"max_cudagraph_capture_size":72}`,
`PROTECTED_FRACTION=0.50`, `MTP_NUM_TOKENS=5` (k=5 — the earlier k=3 result was measured
without Patch 4; see `vision-exp/README.md`).

> Verified against the running engine's `non-default args` on 2026-09-14. `MAX_NUM_SEQS` and
> `GPU_MEMORY_UTILIZATION` had drifted here (this file still said 4 / 0.87, the 2026-08-22 values);
> `.env.dspark` and the config table were already correct. **[`status/CONFIG.md`](status/CONFIG.md)'s
> config table is the source of truth** — it carries the change history and reasons; this line is a convenience copy. Re-check it
> with `docker logs <container> | grep 'non-default args'` rather than trusting either document.

Vision also needs four ported files bind-mounted from `~/vision-stage/` **on both nodes**
(`ds4v_model.py`, `ds4v_vision.py`, `ds4v_mm.py`, `ds4v_registry.py`), which come from
`docker-compose.vision-exp.yml` as a compose overlay:

```bash
docker compose --env-file .env.dspark \
  -f docker-compose.dspark.yml -f docker-compose.vision-exp.yml up -d
```

You no longer have to run that by hand. `start-deepseek-v4-flash-dspark.sh` (and so
`start-cluster.sh`) now:

- **auto-detects** vision from the active env (`DSPARK_MODEL` / `HF_OVERRIDES`) and overlays
  `docker-compose.vision-exp.yml` itself — override with `COMPOSE_VISION=0` / `=1`;
- **syncs the overlay and `patches/anthropic_*.py`** to the worker, which previously received only
  the base compose and env file;
- **preflights `~/vision-stage/` on both nodes** and aborts with the exact regeneration command if
  a file is missing, instead of failing deep in model load.

So after `./switch-model.sh vision` (or `text`), the restart is just `./start-cluster.sh`.

Regenerate the four staged files on **each** node — they are derived from that node's image, not
checked in, so they cannot drift silently:

```bash
./vision-exp/build-ds4v-files.sh vllm-dspark-runtime:dspark-nvfp4-stage-c ~/vision-stage
```

Verified 2026-09-03: the files currently staged on both nodes regenerate **bit-identically** from
this command, and `vision-exp/port/*.py` here match upstream's merged port exactly.

After changing model interfaces, clear vLLM's cached model inspection:
`$VLLM_CACHE_ROOT/modelinfos/` — a stale entry makes the alias report text-only.

# CLAUDE.md

Operating notes for **our** deployment of this recipe. Upstream docs (README, DEFAULT-CONFIG,
vision-exp/README) describe the recipe in general.

**This file holds only what must be loaded every session: the working agreement below, and the
gotchas at the bottom.** Everything else moved to `docs/local/` on 2026-09-20 — it was an 80 KB
file mixing a runbook, a patch reference, measurement write-ups and investigation logs, and the
same facts were restated in two places and drifted apart.

## Where everything went

| I want to… | read |
|---|---|
| **deploy a change to the cluster** | **"Deploying" below — it is a `git push`, never a copy** |
| restart, stop, check, switch text↔vision | `docs/local/CLUSTER.md` |
| know what is patched, its kill switch, its rollback | `docs/local/PATCH-REGISTRY.md` |
| change an Anthropic-endpoint patch (`API-0`, `API-8`…`API-14`) or the `PLG-14b` plugin | `docs/local/PATCHES-API.md` |
| change a KV / block-pool patch (`MNT-5`, `MNT-6`, `MNT-7`) | `docs/local/PATCHES-KV.md` |
| find out why a session re-prefilled, or measure the cache | `docs/local/PREFIX-CACHE.md` |
| read the investigation that found and fixed the re-prefill (`MNT-6c`) | `docs/local/CACHE-TEST.md` |
| choose a thinking tier or effort level | `docs/local/THINKING-AND-EFFORT.md` |
| pull from upstream, or judge an upstream change | `docs/local/UPSTREAM.md` |
| **know whether a change needs a restart, or can be made live** | `docs/local/RUNTIME-SURFACE.md` |
| find a tool in `local-ops/` | `docs/local/TOOLING.md` |
| **work on the KV manager or the disk tier** | **"KV disk tier" below**, then `~/dev/python/vllm-kvmgr/README.md`; **classify a `kv*` tool before running it**: `local-ops/README.md` |
| know the current config, KV pool, node versions | `docs/local/status/CONFIG.md` |
| compare this boot to the last | `docs/local/status/BOOT-METRICS.md` |
| recognise a failure we have already had | `docs/local/status/INCIDENTS.md` |

Start at `docs/local/README.md` if none of those is obviously right.

## Our divergence is a branch

`main` tracks upstream. **All of our work is on `local/main`**, in coherent commits — `git log` is
now the change history these docs used to carry in prose.

`branch.local/main.pushRemote` is `no-push`, because `origin` is upstream's GitHub repo and shows
the **same URL for push**. Never push this branch there.

The mounted patch files are whole-file copies of vLLM source, so the reviewable delta is the
generated diff:

```bash
bash scripts/regen-local-patches.sh          # patches/pristine/ + patches/*.py -> patches/generated/*.patch
bash scripts/regen-local-patches.sh --check  # non-zero if any diff is stale
```

**`local-ops/` tracks its scripts, never its output.** `.gitignore` denies everything under it and
then allows `*.py`, `*.sh`, `*.md` and `requirements.txt` back. Deny-by-default is deliberate: a new
capture or log format is ignored automatically, while a new script has to be added on purpose.
**Prompt captures contain full conversations — if you add a format, check it is ignored before you
commit.** See `docs/local/TOOLING.md`.

## Deploying — push, never copy

**All three copies of this repo are git checkouts of `local/main`** (Mac, head `spark-45ea`, worker
`spark-da08`), and deploying is one command — the only supported way:

```bash
git push head local/main && git push worker local/main
# and, when kvmgr changed, from ~/dev/python/vllm-kvmgr:
#   git push head main && git push worker main
# then: both nodes must report the new commit and 0 dirty.
# scripts/check-local-patches.sh reports what the RUNNING container has, which a
# push does NOT change — git replaces files, and a single-file bind mount keeps
# the old inode. Expect 24/24 (22 patch rows + 2 plugin rows) only after the
# next restart; before it, new rows FAIL and that is correct.
# See docs/local/status/INCIDENTS.md.
```

Both nodes are `receive.denyCurrentBranch = updateInstead`, so a push updates their **working
tree**, not just the ref. Three rules follow from that:

1. **Never `scp` or `rsync` into a node's repo.** Not style — on 2026-09-20 the head was running
   `API-14`/`PLG-14b`, a live feature in no checkout, and an `scp` of our copy would have silently
   deleted it, its worker sync and both compose mount lines, failing nowhere. A push cannot.
2. **A refused push is information, not an obstacle.** `updateInstead` declines a dirty tree, which
   means something was changed on the node. Find it, bring it into the branch, push. Do not
   `--force` past it, and do not fall back to copying.
3. **A push is not a restart and changes nothing running.** The patches are bind-mounted and the
   container holds the inodes it imported at boot, so a push only stages the next restart.

Narrow exceptions, which do not travel by push: `.env.dspark*` (they carry `SERPER_API_KEY`),
`~/vision-stage/` (regenerated per node from that node's image), and everything `local-ops/`
produces. The start script syncs what the worker needs at boot. Detail: `docs/local/CLUSTER.md`.

## Working agreement — update these docs as part of the work, not after it

**This file and the docs under `docs/local/` are part of the deliverable for any change to the
cluster.** Update them in the same session as the change, before reporting it done. No separate ask
is needed; treat a missing doc update as an incomplete task.

**Evidence lives in exactly one place** — the detail doc for the patch it justifies. The registry
carries one line and a link. Restating the same measurement in two files is what made several notes
in the old monolith drift apart.

Triggers, and what each must record:

| Trigger | Record where | What |
|---|---|---|
| **Any change to a tracked file that runs on a node** | commit, then `git push head local/main && git push worker local/main` | the change is **not deployed until both nodes report the new commit and 0 dirty**. Never `scp` — see "Deploying" above |
| Any restart / deploy | `docs/local/status/BOOT-METRICS.md` | date, KV pool + concurrency from the boot log, what changed, which start script was used |
| New or removed patch / bind-mount | `docs/local/PATCH-REGISTRY.md` **and** the patch's detail doc | registry: one row (id, target, kill switch, rollback, one-line evidence). Detail doc: why, and the measurement that justified it. Then `bash scripts/regen-local-patches.sh` and add a marker row to `scripts/check-local-patches.sh` |
| `git pull` from upstream | `docs/local/UPSTREAM.md` | new commit, what it brings, adopt/skip verdict **per item**, whether a rebuild or restart is implied. If the image changed, re-capture `patches/pristine/` |
| Config value change | `docs/local/status/CONFIG.md` "Key configuration" | old → new, date, the evidence; that table is the source of truth |
| Incident or surprise | `docs/local/status/INCIDENTS.md` | symptom, root cause, fix, and the signature to recognise it next time |
| A measured result | the detail doc for what it measures (`PREFIX-CACHE.md`, `THINKING-AND-EFFORT.md`, `PATCHES-*.md`) | the numbers, the method, sample size, and what is **not** established |

### Restarting the cluster requires a SPECIFIC, per-restart confirmation

**Never restart the inference server without asking first, every single time.** A blanket "yes" to
a plan, or an earlier approval in the same session, does **not** carry over to the next restart.
Ask again.

When asking, state all four:

1. **the goal** — what question the restart answers, or what it deploys;
2. **what changes** — the exact files/settings, and how to roll back;
3. **the cost** — a 250-600s cold boot, plus every session on the cluster interrupted (there is
   regularly a second client on this box);
4. **why it cannot be done without a restart** — see below, because usually it can.

**Most investigation needs no restart at all.** Before proposing one, exhaust:

- reading the image's real source — `docker exec <container> cat <path>`, or
  `docker run --rm --entrypoint cat <image> <path>` for a file we bind-mount over;
- `patches/generated/*.patch` — our delta against stock vLLM, already computed, with
  `patches/pristine/` as the unpatched originals. No cluster access needed at all;
- live probing against the running engine — `local-ops/cache-probe.py`, `/tokenize`,
  `/v1/chat/completions/render`, `/metrics` deltas. The 2026-09-19 prefix-cache investigation
  characterised a defect to the exact token boundary this way, and the ONE restart it did spend
  (swapping MNT-7 for pristine) only confirmed what reading had already suggested.

A restart is genuinely required only to change code that is already imported (bind-mounted `.py`
files) or an env var the container reads at start.

**Before assuming a knob is boot-only, check `docs/local/RUNTIME-SURFACE.md`.** Several values are
boot-locked only because of *where* they are read from, not because the engine cannot change them:
the scheduler re-reads them every step. Pointing that read at the flags file makes them live
forever after, which is all `MNT-10` did. `PROTECTED_FRACTION` is the next such candidate.

**Do not restart merely to "apply" a push.** A push has already put the files in place; they take
effect at the next restart whenever it happens, for whatever reason. If the change genuinely needs
to be live now, that is the goal to state when asking — not "to deploy it".

Two habits that have already paid for themselves here:

- **Re-verify a claim in these docs before acting on it.** Several notes have gone stale — the
  compose "drift", the MNT-5 sync caveat, the README's effort table, and "Patch 9d is not
  deployed" (it was). Diff or measure first; then fix the note in passing.
- **Record the negative results too.** "`max` effort is worse than `high`", "MNT-5 is inert under
  `thinking:false`", "`NCCL_IB_MERGE_NICS` is a non-event" each stop a future repeat of the work.

## KV disk tier (`~/dev/python/vllm-kvmgr`)

Our own KV manager for group 0 plus a disk-backed prefix cache, shipped as one `vllm.general_plugins`
package. **Read that repo's `README.md` first.** The current picture, the measurements and
the dated narrative are in the proxy repo (`~/dev/python/vllm-proxy`): `docs/kv/overview.md`,
`docs/kv/measurements.md`, `docs/kv/history/`. The verbatim long form of every rule below is
`docs/kv/engine-rules.md` there. **Nothing here is a reason to restart without the per-restart
confirmation above.**

**The package is NOT in this repo.** It is its own repo, `~/dev/python/vllm-kvmgr` (full history,
releases tagged `v0.1.0`, `v0.2.0`, …), deployed by push to `/home/shorn/vllm-kvmgr` on **both**
nodes, beside this checkout. The compose mounts `../vllm-kvmgr/src/kvmgr` and its generated
dist-info, and the start script **refuses** unless both nodes hold it at the same commit. So a
deploy that touches kvmgr is a push of **both** repos. Its `--with-dspark-patches` test mode needs
`KVMGR_DSPARK_REPO=<this checkout>`.

**State, 2026-10-13:** store and restore **on by default** from committed
`local-ops/flags.reference.json`; 700K restores in 11s across a restart (598s cold, **54x**); a
conversational prefix comes back at 98.7%; the presence journal survives SIGKILL including
mid-compaction; every key is verified on both ranks at boot; runtime verification RPCs are **0**.

### The non-negotiables

- **`load_ops_max=2048` and `load_inflight_max=1`.** Inflight 4 killed the engine (Xid 32) with ops
  pinned at 2048; 1 and 2 restore 700K in the same 12s, so the safe value is free. Bounding one
  call's descriptors is necessary and **not** sufficient — concurrency is an independent variable.
- **`PYTHONHASHSEED=20261007` in the committed compose default, never changed.** It roots the
  block-hash chain; unset, every boot's hashes differ and the disk is a permanent miss; changed,
  every file is orphaned. sha256 hashing never warns about it.
- **The names `DSparkDiskOffloadingSpec`, `DSPARK_DISK` and `dspark-kv-v1` are frozen.** The root is
  inside the fingerprint path, so renaming it orphans the ~620 GB tier on each node.
- **The boot configuration is `local-ops/flags.reference.json`, installed and diffed by
  `flags-apply.sh`, on BOTH nodes.** Code defaults are inert by design (an empty file behaves as
  upstream), so a box without the file has no KV manager. `flags-apply.sh` **merges**: the file
  also holds operator state such as `gpu_cache_epoch`.
- **A value that matters goes in a committed declaration**, never only in an override or `.env.dspark`.
  `load_inflight_max=1` once lived only as an override while the default was the fatal 4; it was
  also hardcoded as a fallback in three readers, so a zero knob reinstated 4 through the safety
  path. Readers take the declaration, and a test enumerates them from the source.
- **Set a worker-side knob with `POST /kv/knob` on `:8888`, never by editing the file**, and read the
  per-rank answer. The worker's file goes stale (measured a day behind), and the core pushes its own
  file-set knobs to both workers at boot.

### Reading state without lying to yourself

- **Ask what the instrument was pointed at before reading its zero.** The disk index lives in the
  engine core and is served on the stats listener **`:9199`** (`GET /kv`, `POST /kv/verify`);
  `GET /kv` on `:8888` answers `disk: null` because the API server is the wrong process.
  `/kv/workers` and `/kv/knob` are on `:8888`; `:9199` answers `{"error":"not found"}` for them,
  and `(d.get("ranks") or [])` turns that into "zero ranks, idle". Make a reader print
  `unreadable` when a key is absent.
- **Print a response's shape before querying it.** `paused`/`jobs_open` guessed as keys read `None`
  on both ranks, exactly like two idle workers; the real shape is `{rank, knobs, sources,
  handlers}`, with handlers a **list** keyed by `cls`.
- **A field named for a state may report something else.** `policy.disk_store_live` is a boot-time
  fact ("is our spec the one configured?"), not "the store is writing".
- **`source=override` is not evidence of a hand-flip.** The core arms a boot knob sync on its first
  step, so every committed knob reads `override` on a healthy boot (and `file` before the first
  step). Check **values** against `flags.reference.json`.
- **A hit count is not a delivery.** `external_prefix_cache_hits_total` is what `lookup` claimed; it
  read 700,416 for a request that never returned. Pair any restore claim with the request
  completing.
- **A Prometheus `_created` series is a Unix timestamp** that reads as a plausible 1.79 GB; it
  corrupted the 700K read figure. Byte counters are integers; `_created` is a 17-digit float.
- **An edge-triggered knob's `ok:true` means set, not done.** `gpu_cache_epoch` acts at the next
  step in another process; the only witness is `reset OK` in the engine log.
- **`journal_compactions` counts compactions DUE, not snapshots written** (it increments before the
  busy check). With the journal on, `manifest_writes 0` is designed; the witness that the store ran
  is `journal_appends`.
- **`/v1/models` is not a liveness check** — the API server answers it with the core wedged. Use a
  one-token completion, and check elapsed time against the known cold range (430–795s for ~700K)
  before diagnosing a hang.
- **A walk looking in the wrong place reports like a walk with nothing to find.** The numpy walk
  searched a stale root because the core's output loop makes **two** encode calls on two threads;
  both are wrapped now, with separate roots.
- **Read a tool's first line before running it as a check.** Several `kv*` tools restart, kill or
  delete; `local-ops/README.md` classifies each one.

### Integrating with vLLM's framework

- **A callback that fans out hands you ids that are not yours.** `OffloadingWorker.wait` passes every
  job id to every handler; filter to what you hold and bound the wait well under the caller's
  patience.
- **A framework callback that consumes is not one you may call yourself.** `get_finished()` pops the
  job and is upstream's only input to `mark_completed()`; calling it from our `wait()` ate the
  completions and fenced blocks forever. Separate collecting from reporting, with one drain.
- **Two sentinels that both mean "nothing" need not mean the same thing.** `prepare_store` returning
  `None` means "cannot" and is retried every step forever; an empty output means "nothing new".
- **A field the framework gates on is not optional.** `record_transfer` needs `transfer_time`,
  `transfer_size` and `transfer_type` all truthy, or the Prometheus series never exists — and its
  absence is what proves a path never ran.
- **A framework that asserts instead of handling turns your refusal into its crash.**
  `offloading/worker.py:273` is a bare `assert transfer_result.success`, so any failed load or store
  kills the worker. Make failure impossible by construction: the boot check verifies every file on
  both ranks, a load holds a **counted** eviction hold, and self-heal condemns missing files before
  any load reaches them.
- **Anything handed to a framework to serialise must be a builtin.** A numpy scalar killed the core's
  **output thread** (not the engine): requests completed, nothing returned, the core idled. It was
  not a "~1M token ceiling". The producer was our own ledger's `min(bids)`; coerce at the producer.
- **Any name used in an annotation a framework introspects must be bound at module level.**
  `from __future__ import annotations` made FastAPI resolve `Request` against module globals, and
  five routes answered `Field required` for a query parameter that does not exist.
- **You cannot wrap the function that loads you.** `EngineCore.__init__` runs the plugin loader, so a
  wrap from inside the plugin lands after the frame that mattered. Hook `EngineCore.step` as a
  one-shot, and set the one-shot flag **before** doing the work.
- **The scheduler step runs only when there are requests.** Anything riding it does no work on an
  idle engine; a background rate is a rate of a **busy** engine. (Upstream does drive the connector
  on zero-token steps via `kv_connector_no_forward`, so a deferred request does not starve the pump.)
- **Deferring a lookup is catastrophic for a sliding-window group.** `_sliding_window_lookup` keeps
  scanning past a deferred key, so one deferring pass walked ~175,000 keys and the restore returned
  zero tokens. Verify at boot; never defer on the hot path.
- **A `collective_rpc` timeout is unrecoverable and silent.** It does not set `is_failed` and leaves
  the reply on an ordered queue, so every later dequeue is off by one. Make timeouts generous and
  fatal, never `None`. A blocking RPC with an `execute_model` future outstanding is ordered and safe,
  but it moves a sync point inside the step — which is why the **runtime** RPC rate is 0.
- **A fingerprint computed in two processes must be logged as fields, never as a hash.** The engine
  core mutates `cache_config.block_size` to the hybrid GCD and the worker does not; the store and the
  lookup diverged and 552 keys were pruned with the files present. Derive from inputs both share.
- **Fingerprint the content, not the version string.** Two HF snapshots here share every safetensors
  blob; a commit-keyed fingerprint would have orphaned 400 GB for a docs bump. Guard an accidental
  format change **offline**, with a pinned hash of the layout functions, comments stripped.
- **Two directions that look symmetric need not be.** `view[:] = buf` fails on restore (`'b'` vs
  `'B'` memoryview formats) and was fine on store because store only reads. Name the risky line.
- **A flag that governs nothing must not be reported as though it did**, and a refusal is driven from
  the table of blocked things, not from whichever fields a response carries.

### Faults: Xid, fences, NCCL

- **A copy kernel does not validate its indices; it faults asynchronously** (Xid 13, `unspecified
  launch failure` at an unrelated call). Bound every block id and staging slot in Python and
  **refuse** rather than submit; keep the transfer ledger of index ranges, because it is the only
  thing an async fault leaves.
- **A copy batch has an undocumented size limit**: ~256 blocks in one `transfer_async` faulted, ~64
  did not, independent of buffer sharing. `_pump` bounds the batch.
- **"Idle" by request count is not idle by transfer, and idle by scheduler job set is not idle by
  worker transfer.** A store job outlives its request; dropping the GPU cache under one gave Xid 32.
  The drop asks every rank (`kvmgr_snapshot`) and refuses when the answer is unreadable. The lever
  stays gated off (`gpu_cache_drop_allowed=False`).
- **A fence can deadlock the engine, and the symptom is silence.** A store job that never completes
  defers everything behind `jobs_to_flush`; the engine logs nothing because it is allowed to do
  nothing. When the cause is dead hardware the job can never finish, so `stall_fail_after_s=240`
  fails it with our line naming it — legibility, not recovery.
- **NCCL's watchdog is a 600s deadline nothing in our code can see**, and the abort is C++ with no
  Python traceback. The tell is repeated `shm_broadcast: No available shared memory broadcast block`
  and then nothing. The head can instead die on its own **dequeue** deadline (29 min) when the
  worker process is gone.
- **Xid 32 on the first large restore after a boot, twice**, each ~10s after the boot check, one
  33-block transfer, every index in range. **Not proven ours.** The untested common factor is the
  boot check's RPC traffic sharing the executor with the first `execute_model`.
- **The store and restore paths must not both run at full tilt in one pass**: a restore took 574.9s
  with the store live and 3.3s paused, both sharing a saturated staging pool. Measure a read with
  writes off. (Separate 256-slot load and store pools are deployed now.)
- **Docker's auto-restart cannot recover a two-node engine.** A head restarted alone hangs in NCCL
  init forever; the tell is the worker's much older uptime. Recovery is `down` on both, then the
  start script.
- **Make a hang dumpable before you need it**: `faulthandler.register(SIGUSR1)` needs no ptrace,
  but `chain=True` chains to SIGUSR1's default action, which is TERMINATE. **And verify the target
  pid is present and armed before signalling** — a pid from a log prefix killed the core once.

### Hot reload (diagnostic, opt-in)

Hot reload lives in `kvmgr.diag` and is **off by default**; these are why it is dangerous.

- **A reload destroys module-level state** (re-executed module) **and class attributes** (a new class
  object). `_PRESERVE` and `_PRESERVE_CLASS` are tables audited against the package by a test,
  never hand-written lists; mutate containers in place.
- **A reload never runs `__init__`.** `rebind` swaps `__class__`, so every attribute added for
  observability must be read with `getattr` and initialised lazily — an `AttributeError` there is
  fatal to the scheduler. A lint enforces it.
- **A module absent from the reload tuple is a module no change is ever hot for**, and idempotent
  re-arms hide it. Every module and every `_install_*` must be in the tuple or exempt with a reason;
  the audit parses the tuple and asserts it was found.
- **A shim installed once per process needs a restart to change**: re-installs unwrap and re-wrap,
  carrying the original on the wrapper.
- **The reloader is itself the old version** — a change to it takes two reloads to verify. And
  `docker exec … python3` imports the FILE, not the engine's loaded code: compare the container's
  `StartedAt` with the file's mtime instead.

### Boot, disk and budget

- **The boot walk is most of the boot and cannot be skipped.** Every key is `stat`ed on both ranks
  because `worker.py:273` would otherwise kill the engine on a vanished file. ~400s of a ~620s boot
  at ~920K keys, superlinear in the index; `/v1/models` answers 000 throughout. Batching to 24 RPCs
  saved 13.8% (I/O-bound). **`DROP_CACHES_ON_START` stays at 3**: no value gives both a fast walk and
  swap protection, because the walk's locality is in page-cached directory blocks.
- **The budget bounds the index, not the disk**, and eviction is demand-driven: it runs only from
  `prepare_store`, so a budget change on an engine with nothing new to store does nothing at all. A
  budget far below what is held evicts the whole gap in one call — walk it down. Size a budget
  against `du`, not a figure in a document.
- **Tail-first eviction orders by position in the PREFIX**, not in the store batch (`keys`, not
  `todo`). The wrong index evicted heads and stranded 300 GB.
- **A feature's off switch must not discard data the feature persisted**: `journal_enabled` gates
  writing, never replay. **An absent snapshot is an empty base**, not an early return.
- **A mechanism gets a hot off switch before it gets a feature.** A knob whose off state needs a
  boot is not a knob.
- **A measurement taken with hand-flipped knobs says nothing about what a fresh boot does.** Ask what
  the file says.
- **The engine publishes container paths** (`/kvoffload/...`); the host sees `~/kvoffload/...`, and
  the files are root-owned, so deletes run inside the container with `docker exec -i`.
- **A vLLM logger named `__name__` is dropped**: use `init_logger("vllm." + __name__)`.

### Capture and harness discipline

- **Capture before you recover, and re-arm the capture after every restart.** `docker logs -f` dies
  with the container. `kvstream.sh all-start` / `all-check` covers four streams (faults and producer
  on both nodes), exits non-zero per dead stream, and the restart tools call it. Check the FILE
  growing, not the process existing.
- **`pgrep` needs `-f` for an `exec -a` tag, and `-c` hides the emptiness `-a` would show**; a
  pattern can match its own command line or the script's filename.
- **A destructive script must refuse to run off its own host** (`hostname -s`), and `source` runs
  every side effect — it is not a way to borrow a function.
- **Clear `__pycache__` after restoring a mutated file**, or the restored tree reports the mutation.
- **A feature that measures well at its purpose can regress something nobody measured.** The store
  path stalled the stream ~1.1s; only the proxy's `test-meter.sh` section 1 saw it (A/B/A 1.109 /
  0.111 / 1.067 against 0.102s). The cause was the O(index) manifest flush and the journal removed
  it. That section is the guard for any change to the store path.
- **A suite can fail because another suite ran**: a 40 MiB `{"model":"x"}` body from one suite made
  a model-coverage check in the other report a model that never reached the engine.

## Gotchas worth remembering

> The numbers in this list are convenience copies. `docs/local/status/CONFIG.md` carries the
> configuration change history and is the source of truth; when they disagree, re-measure against
> the engine and fix this list in passing.

- **KV pool is the binding constraint.** **2.51M tokens on the 2026-09-14 boot** (vLLM reports
  `Maximum concurrency for 1,048,576 tokens per request: 2.39x`), against 3.2M measured on the
  2026-08 config — do not treat either as a constant, see the next bullet. Two 1M-context Claude
  Code sessions use ~80% of the current pool. Past ~99% the decode collapses to 0.1–0.2 tok/s with
  0% draft acceptance and repeated output. Comfortable: 3–4 sessions under 500K; hard limit:
  2 sessions at 1M. Read the boot's real figure from
  `docker logs <container> | grep 'GPU KV cache size'`.
- **KV pool size varies per boot** (unified memory contention) — an 11% swing between identical
  boots is documented upstream. Don't treat a single boot figure as a regression.
- **`GPU_MEMORY_UTILIZATION` is 0.86 and must not be raised.** Two distinct failures sit above it:
  0.90 exhausted system RAM overnight (2026-08-06), and 0.87 with CUDA-graph capture at 144 hung the
  host outright (NVRM `NV_ERR_NO_MEMORY` 4s after engine start, physical power cycle required —
  2026-09-13). At 0.86 with capture capped at 72 the graph-pool estimator over-reserves, which is
  the safe direction.
- **Spec-decode acceptance: read `Mean acceptance length`, not the percentage.** vLLM's
  `Avg Draft acceptance rate` divides by all k drafted tokens including positions already dead after
  an earlier rejection, so `mean_accept_len = 1 + k x rate`. At k=5, 40-50% = 3.0-3.5 tokens/step of
  max 6 — healthy, roughly 2.5-2.9x over non-spec. Normal live range on mixed agent traffic is
  20-73%, swinging with content entropy and with temperature (default 1.0; temp 0 measures ~0.97).
  Real faults look different: missing IMG-4 pins accept ratio near 0.542, and KV exhaustion takes
  it to 0%. Check `scripts/check-patch4.sh <container>` and KV usage before touching config — and
  note k is locked at 5 (must be a multiple of `n_predict=5`; 7 is rejected at boot, 10 crashes).
- GPU clock pin does **not** survive reboot; only `start-cluster.sh` reapplies it.
- API is bound to `127.0.0.1`. Reaching it from the Mac needs an SSH tunnel.
- Default temperature is 1.0 (`--generation-config vllm`); pass `"temperature": 0` for determinism.
- If `firmware-notifier` comes back after an update it crash-loops every 12s — re-mask
  `snap.firmware-updater.firmware-notifier.{timer,service}` (user units).
- **Slow decode with KV well under 90% is NOT a KV problem.** If decode sits at 0.2-2 tok/s while
  `GPU KV cache usage` reads 45-70%, `vllm:num_preemptions_total` is 0 and the hit rate is ~94%,
  it is one long prefill taking the whole scheduler `token_budget` and starving everything behind
  it — not exhaustion, not cache loss. The tell is `Drafted: 10 tokens` across a 10s window
  (= two engine steps in ten seconds). Tune it **live**, no restart:
  `bash local-ops/kv-flags.sh long_prefill_token_threshold 1024`. See `MNT-10` in
  `docs/local/status/INCIDENTS.md`.
- **Currently deployed: Vision-Exp**, `MAX_MODEL_LEN=1048576`, `MAX_NUM_SEQS=12`,
  `GPU_MEMORY_UTILIZATION=0.86`, `COMPILATION_CONFIG={"max_cudagraph_capture_size":72}`,
  `PROTECTED_FRACTION=0.50`, `MTP_NUM_TOKENS=5`, `LONG_PREFILL_TOKEN_THRESHOLD=1024` in the
  compose — but the **running** engine booted with `2048` and keeps it until the next
  restart (verified 2026-09-21 against the container's command line; the two measured the
  same on real traffic, so this is a bookkeeping note, not a regression).
  **`MNT-8`/`MNT-9` are mounted but OFF** —
  they are gated on `/var/tmp/vllm-kv-flags/flags.json`, not on env, so an arm can be flipped
  without a restart (`bash local-ops/kv-flags.sh`); see `docs/local/CACHE-TEST.md`. Re-check with
  `docker logs <container> | grep 'non-default args'` rather than trusting this line;
  `docs/local/status/CONFIG.md` carries the change history.
- **A bind mount to the wrong path fails SILENTLY** — the container starts, the API answers, the
  smoke test passes, and the patch is not there. After any restart run all three checks in
  `docs/local/CLUSTER.md`, not just the smoke test.
- **Never edit a file directly on a node.** It will block the next deploy (`updateInstead` refuses
  a dirty tree) and, until someone notices, the node is silently ahead of the branch — which is
  exactly how `API-14`/`PLG-14b` came to exist in no checkout. Edit on the Mac, commit, push.

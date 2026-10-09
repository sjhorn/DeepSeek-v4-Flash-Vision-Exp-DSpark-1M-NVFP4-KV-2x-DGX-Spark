# Findings about vLLM's `kv_offload`, worth reporting upstream

Five things found while building a disk-backed prefix cache against
`vllm/v1/kv_offload` (developed on `0.21.1rc1.dev339+g1967a5627bc3`). Each is
stated as what was **measured**, what the code does, and what a fix would look
like — separated so a maintainer can disagree with the conclusion without
re-deriving the observation.

Topology here, because three of the five depend on it: **two nodes, one GPU
each, `tensor_parallel_size=2`, so `world_size=2, local_world_size=1`.** A
hybrid-attention model with five KV groups whose block sizes are
`(256, 64, 64, 4, 8)`.

---

## 1. The CPU tier is node-local, and nothing refuses a cross-node TP

**Severity: silent data corruption, if restore is enabled.**

`tiering/spec.py` builds the primary CPU region as **shared memory**, sized
`page × world_size`, with `rank=None` and `num_workers=world_size`
(spec.py:97–107), sized `cpu_page_size_per_worker * world_size * num_blocks`.
Secondary tiers are created only inside `get_manager()` (spec.py:80), in the
loop at spec.py:124 that logs *"Created secondary tier #%d"* — scheduler-side,
one process. The worker-side entry is `create_handlers` (spec.py:168). On a
single host every rank maps the same `/dev/shm` and the scheduler can see all
of it.

*Line numbers are against `0.21.1rc1.dev339+g1967a5627bc3` and were each
checked against the installed source rather than quoted from memory; a findings
document with wrong citations is worse than none.*

With one rank per node, rank 1 maps a **different kernel's** `/dev/shm`, and
nothing on that node has a secondary tier to cascade to.

**Measured.** Only rank 0 ever wrote. The second node had no tier directory at
all, despite having both the bind mount and `KV_TRANSFER_CONFIG`. Every file on
disk was the whole `page × world_size` with the second half zero — six of six
sampled:

	size=2,103,552   1st half non-zero = 652,923 … 1,017,803   2nd half = 0

So the disk held **half a cache**, and a restore would have loaded zeros into
half the KV: plausible tensors, no crash, wrong output.

**The documentation states the assumption** — *"each device holds a shard of the
KV cache, and the framework consolidates all shards into a single shared host
memory region"* — so this is arguably working as designed. The gap is that
**`kv_offload` carries no guard**: `world_size` only *sizes* the region and
nothing asserts the workers are local, so the combination is silently wrong
rather than refused.

**And the fingerprint does not protect against it.** `_compute_base_path`
includes `tp_size`, so the path *claims* a TP=2 cache and another TP=2 boot
would restore it happily. The fingerprint catches a changed **config**, not a
structurally **incomplete capture** — a distinction worth carrying, because the
fingerprint is otherwise what makes this safe.

**Suggested fix:** assert `local_world_size == world_size` in
`TieringOffloadingSpec` (or refuse with a named reason), since the shared-memory
region cannot be correct otherwise.

---

## 2. `FileMapper.from_offloading_spec` forks the fingerprint between processes
   on a hybrid layout

**Severity: the cache silently never hits; data is written where nothing looks.**

`from_offloading_spec` reads `vllm_config.cache_config.block_size`
(file_mapper.py:87). On a hybrid layout **the engine core rewrites that
attribute** to the resolved GCD of the group block sizes, while the worker keeps
the value from the command line.

**Measured.** The worker wrote every file under one fingerprint directory while
the engine core's manifest prune looked under another and discarded all 552 keys
as *"the file is gone"* — with the files sitting right there. The two
fingerprints differed in exactly one field: `hash_block_size`, **256 in the
worker against 4 in the engine core**.

This is correct for a uniform model, which is why nothing upstream trips on it.

**Suggested fix:** derive it from the spec's own `self.hash_block_size`, which
`base.py:360` resolves with `resolve_kv_cache_block_sizes` from the
`kv_cache_config` — the same input in both processes, so the same answer in
both.

**Diagnostic note worth more than the fix:** printing the `fields` **dict**
rather than the resulting hash named the one differing key in a single boot,
instead of one boot per guess. A fingerprint computed independently in two
processes should be logged as fields, never as a digest.

---

## 3. `update_connector_output` asserts on a failed transfer

**Severity: one disk error takes the engine down.**

`distributed/kv_transfer/kv_connector/v1/offloading/worker.py:273`:

	for transfer_result in self.worker.get_finished():
	    # we currently do not support job failures
	    job_id = transfer_result.job_id
	    assert transfer_result.success

`TransferResult` has a `success` field, so a handler can report failure — and
reporting it raises `AssertionError` in the worker's output path. Any `EIO`,
`ENOSPC` or missing file therefore stops the engine rather than degrading to a
cache miss, and because it lands in the output path the presentation is a hang
rather than an error.

**Suggested fix:** treat a failed transfer as a miss — drop the key from the
index and continue. Until then, a handler's only safe option is to make failure
impossible by construction, which is not always available to it.

---

## 4. `prepare_store` returning `None` and returning an empty output are
   different, and the docstring does not say so

**Severity: a progress bug that worsens as the cache fills.**

In the offloading connector's `scheduler.py` (the `if store_output is None`
branch at :741), `None` means *"I cannot"* and leaves
the scheduler's stored index put — so **the same blocks are retried every step,
for ever** — while an empty output means *"nothing new"* and lets the request
progress. The two branches are six lines apart.

A manager's commonest nothing-to-do case is *every key is already on disk*, and
that case **gets commoner as the cache fills**. Returning `None` for it is a
progress bug that grows with use. Two of our own tests had asserted the
sentinel as though it were a virtue before we understood the difference.

**Suggested fix:** say it in `prepare_store`'s docstring. The behaviour is
reasonable; the ambiguity is not.

---

## 5. `OffloadingWorker.wait` fans a job-id set out to every handler

**Severity: a 600 s stall on the engine's critical path.**

`wait` passes the whole job-id set to **every** registered handler, so a store
handler is asked to wait for the load handler's jobs — and for jobs whose
completion it has already reported and popped. Neither can ever be seen again.

**Measured.** A naive `while remaining:` loop spun its full deadline on the
engine's critical path, and the symptom was the worker going **deaf** rather
than a slow store. Upstream's own code skips an unknown id in one line
(`if event is not None`), which is the shape a handler must copy.

**Suggested fix:** filter to the handler's own jobs inside `wait`, or document
that a handler must.

### And a caution for anyone writing a handler

`get_finished()` both **pops** the completed job and is the **only** input to
`mark_completed()`. Calling it to *inspect* progress destroys the report: the
scheduler never hears it, `pending_count` stays at `num_workers` for ever, and
the job fences its blocks permanently. That cost us a 7%-indexed cache, a linear
convergence of +13,312 tokens per pass, 9,300 fenced blocks and eventually an
NCCL watchdog kill. **Separate collecting from reporting**, and keep a single
drain on the path the framework reads.

---

## What we did instead, and why it needed no upstream change

The extension points are public and sufficient: `LoadStoreSpec.medium()` is
abstract so DISK is a first-class medium, `OffloadingSpec.get_handlers()` yields
`(src_spec, dst_spec, handler)` so a GPU↔DISK pair is in contract,
`OffloadingSpecFactory.register_spec` is a public registry, and
`OffloadingConnectorMetadata` already ships the scheduler's decisions to every
worker on both nodes. `prepare_load`'s own docstring says it returns *"a
LoadStoreSpec that can be used by a **worker** to locate and load"* — the
framework already intends the worker to do the locating.

So tiering's node-locality is **tiering's choice**, stated in its own comment,
not a framework limit. A spec that transfers worker-side needs no patched
upstream file.

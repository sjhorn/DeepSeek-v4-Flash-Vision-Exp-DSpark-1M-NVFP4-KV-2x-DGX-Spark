# KV manager of our own — Phase 0: what the reading settled

Phase 0 of the plan to replace the KV cache subsystem (own managers, own
eviction policy, disk-backed prefix restore). Its job was to read what could not
be read yet, inventory the MNT-* behaviours, and build a harness that makes
manager logic testable with no GPU.

All three are done. **Four findings change the plan**, and one of them changes a
headline number.

## The blocker dissolved: both "unread" files were already here

The plan blocks Phase 0 on `v1/core/kv_cache_coordinator.py` and
`v1/core/kv_cache_manager.py`, unread because the LAN was down. **They are in
`patches/pristine/`**, captured 2026-09-20 from the runtime image, and the
MANIFEST says why in its own words: the two were added *"reference-only, so that
the coordinator and manager can be read and ported without cluster access"*.

The LAN is still down (SSH to both Sparks times out; the menubar bridge answers,
so the internet path is fine). It did not matter.

**The caveat that does matter**: `pristine/` is only trustworthy while
`image_id` matches the running image. It records
`vllm-dspark-runtime:dspark-nvfp4-stage-c`,
`sha256:4035bb5a…`, vLLM `0.21.1rc1.dev339+g1967a5627bc3`. Nothing has rebuilt
the image since (overlay last touched 2026-08-12, image 2026-08-23, 0 stale at
the last check), so these should be current — **but that is an inference, not a
check, and the check needs the box.** Re-assert it with
`scripts/regen-local-patches.sh --check` when the LAN returns.

## FINDING 1 — `find_longest_cache_hit` is a CLASSMETHOD, and disk restore cannot be group-0-only

Two consequences, and the second contradicts the plan's rollout.

**It has no instance state.** The coordinator calls it on the *class*:

	hit_blocks = manager_cls.find_longest_cache_hit(
	    block_hashes=…, max_length=…, kv_cache_group_ids=group_ids,
	    block_pool=self.block_pool, kv_cache_spec=spec,
	    use_eagle=…, alignment_tokens=self.lcm_block_size)

`manager_cls` comes from `self.single_type_managers[i].__class__`, so registering
our class in `spec_manager_map` *does* route the hook to us — but there is no
`self`, so **no per-manager disk index and no counters on the instance.** The
Phase 4/5 index has to be module-level (or hang off the `block_pool`, which the
hook does receive and which is how a restore can allocate at all).

**And the hit length is a fixed point across all five groups.**
`HybridKVCacheCoordinator.find_longest_cache_hit` loops until no group reduces
the candidate length: each group either accepts the current length or lowers it.
So the realised hit is effectively the **minimum across groups**.

> **Restoring only group 0 from disk buys nothing.** The other four groups would
> return their short hits and the fixed point would converge back down to them.

The plan's rollout — *"own group 0's manager first and leave the other four on
upstream behaviour, since group 0 is the only one whose cap binds"* — is right
for the **cap** (Phases 1–3) and **wrong for restore** (Phases 4–5). Phase 5
needs all five spec types registered, or it is a no-op. Worth knowing before
Phase 4 is built around a group-0 index.

Related, and the reason hits are coarse: `lcm_block_size = lcm(256, 64, 64, 4, 8)`
= **256**, and every hit is a multiple of it.

## FINDING 2 — the by-need gain is 2.25x, not the plan's 4.2x

`_max_protected_prompt_blocks` returns `min(legacy, pool_cap)`, and the plan only
reasons about `pool_cap`. The legacy term is
`2 * cdiv(max_model_len, block_size)`, which for group 0 at `max_model_len`
1,048,576 and `block_size` 256 is **8,192 blocks = 2,097,152 tokens**.

| | group 0 cap | tokens |
|---|---|---|
| today, fraction 0.75, `/5` equal split | 3,643 blocks | 932,608 |
| `protect_alloc=by_need`, same fraction | **clamped to 8,192 blocks** | **2,097,152** |

So the reachable improvement is **2.25x, not 4.2x**, and the plan's "~3.9M
tokens" is unreachable without also raising `max_model_len` or dropping the
legacy term. **It is still ample** — 2,097,152 is exactly 2x the 1M context
ceiling, so it covers the 740,315-token session with room — but the figure in the
plan is wrong and the binding constraint under `by_need` is the legacy cap rather
than the fraction.

Found by breaking the harness: removing the `/num_managers` division made group
0's cap read 8,192 rather than the expected 18,216, which is the legacy clamp
showing itself.

## FINDING 3 — MNT-5 is not a KV mechanism at all

The plan lists MNT-5 as *"present in `patch6`; purpose to be confirmed"*. It is
confirmed and it is out of scope: patch6's own header says *"NOT the detokenizer
patch -- that is MNT-5"*, i.e. the only mention of MNT-5 in patch6 is a line
disclaiming it. MNT-5 is `patches/patch5-detokenizer.py`. **Nothing to carry
forward.**

The rest of the inventory:

| | what it is | carry-forward |
|---|---|---|
| MNT-6a | protected prompt blocks + the cap | the thing being replaced |
| MNT-6b | SWA/compressor groups recycle skipped pages into the same request instead of the global LRU (`swa_recycle`), with a finer arm (`swa_recycle_cached`) that recycles only pages carrying no prefix value | preserve both flags |
| MNT-6c | not a mechanism — it is the **decision that `swa_recycle_cached` defaults False**, i.e. the fix is on unless turned off. It was True until 2026-09-21, carried only by node-local `/var/tmp` state outside git, so a rebuilt node silently restored the bug | preserve the default, and the reason |
| MNT-8 | free-queue ordering: uncached scratch to the front, cached prefix to the back (`free_queue_prepend_uncached`) | preserve |
| MNT-9 | `pin_static_head` + `_head_pins`, LRU over whole heads in a budget reserved from MNT-6a's | **reuse** — it is already the per-prefix handle Phase 3 needs |

## FINDING 4 — `_num_managers` is a process-global counter that is never decremented

`SingleTypeKVCacheManager._num_managers` is a **class** attribute incremented in
`__init__` (patch6:231) and read by both cap functions. Every cap is therefore
divided by *however many managers this process has ever constructed*.

It is correct today because the engine builds the five once. It is a trap for
everything downstream: anything that constructs a second set — a probe, a
profiling pass, a test, or our own plugin if it ever instantiates to inspect —
**halves every cap in the running engine, silently.** The harness has to reset it
between cases (`harness.reset_manager_count()`) or the tests measure each other,
which is exactly how it was discovered. Any replacement should take the group
count from `kv_cache_config.kv_cache_groups` instead.

## Everything the plan asserted that IS confirmed

Checked against the real patched code, not re-derived:

- the `/num_managers` equal split, and that all five groups get the same **block**
  count: `[3643] * 5` at fraction 0.75
- the 64x extent spread — `[932608, 233152, 233152, 14572, 29144]` tokens
- that raising the fraction cannot fix it: at 1.00, group 0 reaches 1,243,392
- **protection is never refreshed on reuse** — re-protecting an already-protected
  block is a no-op on the queue, so order stays "first protected"
- **eviction pops from the left**, so the victim is the longest-held, and it is
  the *head* block, which is what makes the loss total rather than proportional
- **Trap 2**: `protected_fraction` is read straight off `os.environ`, so the
  flags file cannot move it — while a `_flag()`-routed knob
  (`head_pin_fraction`) moves live
- **Trap 1**: `VLLM_<NAME>` wins over the file
- bad or absent JSON falls back to defaults, never a crash
- the 1 s TTL is real: within it the cached value stands; after it the new value
  is picked up with no restart
- `spec_manager_map` substitution works, because the factory reads the dict at
  call time — an import-time mutation is enough

## The harness

`local-ops/kvharness/` — **59 assertions, no GPU, no cluster, ~1 s**.

	python3.12 local-ops/kvharness/test_phase0.py

It is **not** a reimplementation. `vllm_stubs.py` fakes only the leaves patch6/7/8
touch (a logger, dtype sizes, the kv-event dataclasses, the metrics collector,
`Request`, and the KV cache specs), then `harness.py` loads the **real**
`patch8` → `patch7` → `patch6` under their canonical module names. Everything
that decides a block's fate is the code that runs on the box. A reimplementation
would be a second copy of the thing under test, which is how two tables
describing one wire end up disagreeing.

**Why not `local-ops/kv-mech-tests.py`**: that one stages the patched files into
the container and runs them there — stronger when the cluster is up, worthless
when it is down, which is the state this was written in. They are complements,
not replacements.

Three things about it worth not rediscovering:

- **Load order is the whole trick.** patch8 must be in `sys.modules` as
  `vllm.v1.core.kv_cache_utils` *before* patch7 imports that name, and patch7 as
  `vllm.v1.core.block_pool` before patch6 imports it. Out of order you silently
  get the stub and every assertion is about nothing. `load()` asserts the object
  identities afterwards rather than trusting the order.
- **`python3.12`, not the system python.** The patches use `X | None` in
  evaluated annotations with no `from __future__ import annotations`, so 3.9
  fails at import. 3.12 is what the container runs.
- **`harness.Flags` invalidates the TTL cache rather than sleeping.** One
  `time.sleep(1)` per assertion is how a suite stops being run. The one test that
  must prove the TTL is real does sleep, once.

**What it cannot tell you**: anything about tensors, CUDA, or the pool *sizer*.
`num_gpu_blocks` is an input here (24,288 is passed in), so **boot-line parity is
still a box check**.

## Verified by breaking it

Removing the `/num_managers` division fails 8 assertions by name and restoring
returns 59/59 — which is also how Finding 2 surfaced. The harness is live, not
vacuous.

## What Phase 1 should know before it starts

- subclass the patched `MLAAttentionManager` and **import `_flag` from patch6's
  module** rather than copying the mechanism: one flags cache, one TTL, no drift
- the knob table's `protected_fraction` must keep honouring
  `VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION` for boot-pinning, and that name must
  come **out of `.env.dspark`** (it is set to 0.75 there on both nodes) or the
  file can never move it
- delivery is a `vllm.general_plugins` entry point, as
  `patches/safetensors_e8m0_plugin/` already does — a new module plus a
  `.dist-info`, bind-mounted. Not another whole-file overlay.
- take the group count from `kv_cache_config`, not `_num_managers` (Finding 4)

# Patches

The complete chain applied on top of
`aidendle94/sparkrun-vllm-ds4-gb10:production-3.7` to reach the
dedupe+boundfix state used in the retention benchmarks. Apply in order
(`01` → `04`); each script is idempotent, asserts its anchors, and
`py_compile`s its target. `image/apply-patches.sh` does all of this in a
throwaway container.

All paths are relative to `VLLM_PYTHON_DIR`
(default `/opt/venv/lib/python3.12/site-packages/vllm` — the venv layout
of the aidenle image).

| # | patch | target(s) | what |
|---|-------|-----------|------|
| 01 | `01-reffix.py` | `tokenizers/deepseek_v4_encoding.py` | Per-effort reasoning system prompts (`low`/`high`/`max`) instead of a single hard-coded `max` template |
| 02 | `02-schedfix.py` | `v1/core/sched/scheduler.py` | Scheduler admission cap + decode-fairness floor (ported from Anemll #27/#43) |
| 03 | `03-dedupe.py` | `v1/core/block_pool.py` | Commit-time duplicate eviction: keep one physical block per (hash, group) |
| 04 | `04-boundfix.py` | `v1/core/single_type_kv_cache_manager.py`, `v1/core/kv_cache_coordinator.py` | Make the sparse-retention replay-boundary tail reachable and committed |

## 01-reffix — reasoning-effort prompts

**Original work.** The DS4 chat encoder only supported `max` reasoning
effort (one constant, asserted into the system prompt). This generalizes it
to a per-effort table: `high` keeps the old "absolute maximum" text, `max`
gets a distinct "beyond maximum" prompt, `low` adds nothing. Extracted
verbatim from the `production-3.7-reffix` image — the diff vs `production-3.7`
is exactly these two hunks, and the output byte-matches that image.

## 02-schedfix — scheduler hotfixes

**Port of Anemll / MiaAI upstream fixes** — credit:
[Anemll / MiaAI vLLM fork](https://github.com/Anemll) (issues #27 and #43),
adapted to the production-3.7 DS4 tree (v0.26 scheduler).

- **#27** — enforce `max_num_partial_prefills` on admission (the field was
  parsed but never read, so concurrent partial prefills could starve
  decode).
- **#43 A3** — bounded decode service: reserve at least one decode step of
  token budget for every decode-active lane behind the current request.
- **#43 A4** — zero-token skip record (diagnostic).

`02-schedfix.py --status` prints whether #27/#43 are applied.

## 03-dedupe — commit-time duplicate eviction

**Original work.** Every request re-computes ~20 already-cached positions
(hit-path drop / spec-decode boundary); each re-commit inserts a SECOND
block with the same content hash into the map, and hits always return the
first copy — so the older copies are never touched again (~16% of the map
at 100K tokens / 31 requests, measured). Before inserting a block's hash,
evict the old block holding the same (hash, group): both are byte-identical
content, so no hit capability is lost.

## 04-boundfix — replay-boundary tail

**Original work.** With sparse retention (`VLLM_PREFIX_CACHE_RETENTION_INTERVAL`),
two defects made the replay tail unreachable for some prompt geometries:

- The eagle hit run's rightmost block must START on an alignment boundary
  and be FULL; when `num_prompt % alignment < block_size` the peek block is
  partial and no valid run exists. The retreat is now UNIFORM across
  sliding groups (slack = largest sub-alignment block size, from the
  coordinator) since the hit is the min over groups.
- `cache_blocks` only commits the current step's range, and the coordinator
  caps this manager's `num_tokens` below the prompt end for small block
  sizes — so mask-kept tail blocks were never committed. A final
  tail-commit pass now runs when the request's blocks first cover the full
  prompt, committing any mask-kept full block still uncommitted.

## Validation

The retained-tokens benchmark is in the companion repo
[`cache-pressure`](https://github.com/co-l/cache-pressure). Measured on
2x DGX Spark (2026-09-05):

| image state | retained | % capacity |
|---|---|---|
| `production-3.7-reffix-schedfix` (pre-fix, retention 4096) | 34/80 x 39K (1.32M tok) | 65.4% |
| + dedupe + boundfix (retention 0) | 79/80 x 39K (3.08M tok) | 147.4% |

The fixed image also passes a needle-in-haystack retrieval sweep at
50K–450K (5/5 exact-code hits) and benchmarks at parity with the pre-fix
image. Full story: see the repo README.

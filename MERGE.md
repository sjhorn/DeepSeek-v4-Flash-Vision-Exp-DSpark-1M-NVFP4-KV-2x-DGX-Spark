# MERGE — unify the prefill/prefix-cache observability stack across three repos

> **Status: PROPOSAL, for review. Nothing in here has been executed.** No restart has been taken,
> no compose or patch file has been edited, and nothing in `~/dev/python/vllm-proxy` has been
> touched. Written 2026-09-20.
>
> Repos in scope: this one (engine patches), `~/dev/spark/sparkstats` (on-box agent),
> `~/dev/python/vllm-proxy` (proxy, dashboard, identity).

## Context

We spent a full session chasing why Claude Code sessions lose the prefill cache, and kept hitting
the same wall: **every instrument we had could see that a turn re-prefilled, but not why.** Patch 12
(`PREFIX_WATCH`) hashes the prompt but not the model, so a tier switch is invisible. `/metrics` is
engine-wide, so nothing attributes a stall to a request. The result was a conclusion ("eviction, not
invalidation") that had to be walked back twice.

Meanwhile two sibling projects already solve most of this:

- **`~/dev/python/vllm-proxy`** — `meter/reqscan.go` captures the requested `model` (our Patch 12
  blind spot, *with no restart*); `meter/prefix.go` computes a per-KB divergence **index**, which is
  exactly the eviction-vs-rewrite discriminator we lacked; the in-flight `meter/convo.go` rebuilds
  conversations keyed on verified client identity the engine can never have. `admin/dashboard.html`
  is already absorbing sparkstats' UI (Phase 6 of 7 done).
- **`~/dev/spark/sparkstats`** — a 1 Hz on-box sampler with a metric registry, bounded SQLite,
  rollups, retention and a series/stream API. Already being demoted to a headless data agent.

The goal is to finish that convergence and add the one thing neither has: **the engine's own account
of which KV blocks left the cache and why.**

**Thermal check first, because it gated this work:** spark-45ea is *not* hot from instrumentation.
Over 5 days both nodes rose identically (`temp_max_c` +8.2 °C on 45ea, +7.7 °C on da08; power +16.6 W
vs +16.1 W), they track within 0.4 °C, and `throttle_hw_thermal` is **0.0 for the whole window on
both**. Instrumentation runs only on the head, so it would appear as divergence — it doesn't. The
rise is symmetric TP=2 inference load. sparkstats costs 1.6 % of one core over 5 days.

## Decisions taken

1. **vllm-proxy anchors** presentation + identity. sparkstats is the engine/host agent. This repo
   remains source-of-truth for engine-side patches.
2. **Enable `enable_kv_cache_events`**, consumed **on-box by sparkstats**; raw events never cross the
   tunnel.
3. **The proxy becomes the primary prefix instrument**; Patch 12 is kept as an engine-side
   cross-check. `local-ops/prefill-attribute.py` is demoted to ad-hoc use — no further investment.
4. **Touch nothing in `vllm-proxy`** — another agent owns that tree (uncommitted `meter/convo.go`,
   `meter/main.go`, `meter/reqscan.go` on `prefill-screen`). This plan produces the contract it
   consumes.

## The safety property that shapes everything

`BlockStored` carries **`token_ids: list[int]`** — raw prompt tokens, fully detokenizable. Both
sibling repos state "never log request or response bodies, not even truncated"; a KV event stream is
that rule's hardest test.

Two non-negotiables:

- **Bind the publisher to a Unix socket, never the default.** vLLM's default is
  `tcp://*:5557`, and `KVEventPublisher` **binds** on any endpoint containing `*` — that would
  publish prompt tokens on every interface. Use `ipc:///var/run/dspark/kv-events.sock`, host-mounted,
  filesystem-permission scoped. The `ipc://` prefix also takes the bind path, so behaviour is
  unchanged.
- **`token_ids` is dropped at parse, in the decoder, before any other code sees the event.** Never
  stored, never logged, never in an API response. The counters we need come from `BlockRemoved`,
  which carries only block hashes, medium and `group_idx` — **no content at all**.

A bonus falls out for free: `BlockStored.extra_keys` carries `cache_salt` per block, which settles
the salt question we could only disprove indirectly.

## Architecture

```
spark-45ea (head)                          knxpi (Pi, 1.8GB, SD card)
┌─────────────────────────────────┐        ┌──────────────────────────────┐
│ vLLM  ──ipc:// kv-events.sock──┐ │        │ meter   identity, model,     │
│   Patch 12 PREFIX_WATCH (log)  │ │        │         conv/turn, prefix    │
│                                │ │        │         divergence index    │
│ sparkstats                     │ │        │ admin   dashboard, joins     │
│   collect/kv_events.py  ◄──────┘ │        │ spark   SSE relay, 1h ring   │
│   drops token_ids at parse       │◄──SSE──┤                              │
│   registry → SQLite → /api/series│ tunnel └──────────────────────────────┘
└─────────────────────────────────┘
```

**The join is on TIME, not request id.** vLLM publishes no per-request attribution — both sibling
repos already document this, and KV events reference block hashes, not requests. The dashboard may
place a proxy record beside an engine episode; it must never claim one caused the other. This has to
be stated in the UI, exactly as `phases()` already refuses on non-stream records.

## Work

### Phase 1 — engine side, this repo (needs ONE restart)

Bundle both changes into a single cold boot; ask for approval per `CLAUDE.md`'s four-point rule.

- `docker-compose.dspark.yml` — add `--kv-events-config` with an `ipc://` endpoint and a
  host-mounted socket dir. Keep `enable_kv_cache_events` behind an env toggle defaulting **off**, so
  rollback is an env flip plus a restart, not an edit. Save the pre-change file to
  `/tmp/docker-compose.dspark.yml.pre-kvevents` on the head.
- `patches/anthropic_serving_inline_system.py` — add `model=` (and the resolved
  `chat_template_kwargs` tier) to the `PREFIX_WATCH` line. This closes the blind spot that made the
  tier-switch question unanswerable. Guard it exactly like the existing slice hashing: never raises.
- Follow the manual restart checklist: watchdog down (`pgrep -cfx` must read 0), stop, start detached
  with `local-ops/bootmon.sh`, poll `/v1/models`, `local-ops/verify-server.py` (expect 14/14), smoke
  6/6, `scripts/check-patch4.sh`, exactly one watchdog back up.

**Before wiring any consumer, measure the event rate.** Subscribe with a throwaway script for ~5
minutes under real load, record events/sec and bytes/sec, and write the figure into `STATUS.md`. If
it is large, the consumer is sampled or filtered to `BlockRemoved` only — design follows the
measurement, not the reverse.

### Phase 2 — sparkstats: the KV-events collector

- `src/sparkstats/collect/kv_events.py` — **new**. ZMQ `SUB` on its own thread, mirroring the
  pattern `collect/vllm.py` already establishes (stateful, own cadence, never in the 1 Hz sample
  path). A `msgspec` decoder that **omits `token_ids`**. Maintains counters only:
  blocks stored/removed per second, `AllBlocksCleared` count, distinct `group_idx` seen, and a
  `cache_salt_present` indicator derived from `extra_keys`.
- `src/sparkstats/metrics.py` — register the new series. Per that file's own docstring, "adding a
  series means adding one entry here and nothing else", so storage, rollup, retention and the API
  follow automatically. Every metric needs a `desc` (a test enforces it).
- `src/sparkstats/events.py` — an episode for sustained eviction pressure. Heed the repo's rule: **a
  signal that is permanently true tells you nothing.** Use a *rate* (blocks removed/sec sustained
  above a threshold), corroborated by KV utilisation, not a state.
- Tests: `tests/test_collect_kv_events.py` with a captured event batch in `tests/fixtures/` — TDD,
  fixture first, and it must pass on macOS where there is no ZMQ publisher.
- `docs/metrics.md` is generated — run `uv run python scripts/gen_docs.py`.
- Run `scripts/deploy.sh spark-45ea -- "sparkstats bench"` and keep the whole sample under ~10 ms.
  The subscriber is off the sample path, so the figure should not move; if it does, that is the bug.

### Phase 3 — the contract for vllm-proxy (we write it; the other agent implements)

A short spec document in this repo, `local-ops/OBSERVABILITY-CONTRACT.md`, naming:

- the new sparkstats series and their units, so `admin/` can chart them via the existing
  `/admin/spark/*` relay — **no new transport**;
- the time-join rule and the wording the UI must use so correlation is never presented as causation;
- what the proxy owns and the engine cannot see (client identity, requested model, conversation,
  divergence index) and vice versa (block-level eviction, salt, per-group behaviour).

### Phase 4 — retire the duplication

- Demote `local-ops/prefill-attribute.py`: keep it, mark it ad-hoc in `CLAUDE.md`, stop developing it.
- Keep Patch 12 as the cross-check, and record *why*: it sees the prompt **after** our server-side
  patches transform it, which the proxy structurally cannot. That difference is what catches
  Patch 11a/11b/13 regressions.
- Retire `local-ops/prefix-watch.py`'s alerting role in favour of the proxy's divergence index, but
  keep the documented `user0` collision warning — it burned us yesterday.

## Open defect found while exploring (verify, do not assume)

`sticky_conversation_key` (Patch 13, `anthropic_serving_inline_system.py:679`) hashes
`anthropic_request.system` **raw** — `_sha12((system or "")[:2048])` — while `normalize_system_prompt`
only runs later, at conversion (`:950`). The proxy agent reports this re-keys every turn on
spark-45ea (2026-09-20), which would mean sticky tools never stick.

**It does not reproduce in our captures:** 16 turns of `ts-false-b.jsonl` and 10 of
`nolsp-false-b.jsonl` give **one** distinct key each, and one distinct raw `system[:2048]`. So the
trigger is interactive-only. Prime suspect is the billing header inside those first 2048 bytes —
`x-anthropic-billing-header: … cch=00000;` — which our own `CLAUDE.md` calls "a per-request hash that
defeats prefix caching" and which reads `00000` in every headless capture. Verify with one tapped
**interactive** session before changing anything; the fix (hash the normalised system, or drop the
billing header first) is two lines but must not be made on an unreproduced report.

## Verification

1. **No restart until asked**, and the restart asks for all four points in `CLAUDE.md`.
2. Post-restart: `verify-server.py` 14/14, smoke 6/6, `check-patch4.sh` passes on both nodes, exactly
   one watchdog, `RestartCount=0`.
3. **Safety, tested not asserted**: a test proves the decoder yields no `token_ids`; `ss -lntp` on
   the head shows **nothing listening on 5557**; `grep -r token_ids` over sparkstats' store and API
   returns nothing.
4. **Budget**: `sparkstats bench` whole-sample under ~10 ms; event-rate figure recorded in
   `STATUS.md`; `temp_max_c` and `pwr_sys_total_w` compared across **both** nodes 24 h before and
   after — a head-only rise is the signal that we have cost something.
5. **It answers the original question**: replay the failing case and show, for one turn, whether the
   blocks left via `BlockRemoved` (eviction) or the prompt diverged at chunk 0 (rewrite).
6. `CLAUDE.md` and `STATUS.md` updated in the same session, negative results included.

## Out of scope

- Any edit under `~/dev/python/vllm-proxy` — the other agent owns it.
- Moving the reasoning-effort prefix to the prompt tail. The pilot (n=3) showed it lands but ran away
  on the hard problem (54,318 think chars, hit the cap, no answer, vs 14,142 and correct at the
  front). That needs the full 12-problem run with the `low` control before anyone touches it.

## Evidence behind this plan (all gathered read-only, 2026-09-20)

| claim | how it was established |
| --- | --- |
| Thermals are workload, not instrumentation | sparkstats `/api/series`, 5 d, both nodes, `res=1h` |
| `BlockStored` carries `token_ids` | `docker exec … sed -n 60,120p vllm/distributed/kv_events.py` |
| Default endpoint binds wide | same file: "Heuristic: bind if wildcard / * present" |
| `BlockRemoved` is content-free | same file: `block_hashes`, `medium`, `group_idx` only |
| `extra_keys` carries `cache_salt` | `BlockStored.extra_keys` docstring |
| Proxy sees the model | `meter/reqscan.go` — `Model` at JSON depth 1 |
| Proxy computes a divergence index | `meter/prefix.go` — cumulative per-KB chain, `commonPrefix()` |
| Patch 13 hashes raw system | `anthropic_serving_inline_system.py:679-713` vs `:950` |
| Patch 13 does not re-key in our captures | replayed the key function over 26 captured turns |

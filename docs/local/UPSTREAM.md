# UPSTREAM.md — our relationship with `tonyd2wild/…`

What we track, what we carry on top, the per-item verdict on the last pull, and the two topology
notes (one cable, not two; the `NCCL_IB_GID_INDEX` non-issue) that keep getting re-litigated.

> **Since 2026-09-20 our divergence is a real branch, not a dirty working tree.** Local work lives
> on `local/main`; `main` tracks upstream. `branch.local/main.pushRemote` is set to `no-push`
> because `origin` is upstream's repo and `git remote -v` shows the same URL for push — this
> branch must never be pushed there.
>
> The update flow is therefore no longer stash/pull/pop:
>
> ```bash
> git checkout main && git pull            # fast-forward upstream
> git checkout local/main && git rebase main
> bash scripts/regen-local-patches.sh --check   # do our patches still apply to the new tree?
> git push head local/main && git push worker local/main   # deploy (no restart)
> ```
>
> A rebase rewrites history, so the nodes cannot fast-forward to it. `updateInstead` will refuse
> the push; that is correct, not a problem to force past. Either `git push --force-with-lease` to
> each node (their trees are clean and carry nothing of their own — that is the whole point of the
> branch), or `git fetch && git reset --hard local/main` on each. Re-run
> `scripts/check-local-patches.sh` on both afterwards.
>
> If `recipe/overlay/` changed, rebuild the runtime image on both nodes — and then **re-capture
> `patches/pristine/`**, because every generated diff is computed against the old image. The image
> id in `patches/pristine/MANIFEST.txt` exists to make that failure loud.

## Drift found on import (2026-09-20) — the head was AHEAD of every checkout

Putting the fork on a branch turned up drift in the direction nobody checks for. The rule in
`CLUSTER.md` has always been "the Mac authors, the head runs". On 2026-09-20 the head was running
**a whole feature that existed in no checkout**:

| file | who was ahead | what |
|---|---|---|
| `docker-compose.dspark.yml` | **head**, by 21 lines | the two `PLG-14b` mount lines |
| `start-deepseek-v4-flash-dspark.sh` | **head**, by 10 lines | `scp -r patches/prefill_plugin` to the worker — `patches/*.py` is a glob that does **not** match a directory |
| `patches/anthropic_serving_inline_system.py` | **head**, by ~50 lines | `API-14` |
| `patches/anthropic_protocol_inline_system.py` | **head**, by 1 line | `engine_cached_tokens` |
| `patches/prefill_plugin/` | **head only** | `PLG-14b`, did not exist here at all |

It was deployed by the 08:58Z boot and was live and loaded — the engine log shows
`prefill_collector -> prefill_collector:PrefillCollector` registered at 08:58:20.

**This was caught only because the deploy of an unrelated change diffed before copying.** The
near-miss is the lesson: `scp`-ing our copy over would have silently deleted a live patch, the
worker sync for it, and both mount lines — and the next restart would have come up without them,
with nothing failing loudly.

Two habits, both now enforced by something other than memory:

1. **Diff before you copy, in BOTH directions.** The head is not only a deployment target; it is
   where changes are sometimes made first.
2. **`scripts/check-local-patches.sh` is the backstop.** `PLG-14b` now has two rows in it (the
   module *and* its `.dist-info`, because without the metadata the entry point is never discovered
   and the module is a silent no-op). Had the clobber happened, the next run would have said
   `FAIL PLG-14b` on both nodes instead of nothing at all.

> **The compose "drift RESOLVED" note in `CLUSTER.md` is about a 2026-09-19 check and was true
> then.** It went stale within a day. Treat any "in sync" claim in these docs as a timestamp, not a
> property, and re-diff:
>
> ```bash
> R=/home/shorn/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
> for f in docker-compose.dspark.yml start-deepseek-v4-flash-dspark.sh watchdog-dspark.sh \
>          patches/anthropic_serving_inline_system.py patches/anthropic_protocol_inline_system.py; do
>   ssh shorn@spark-45ea "cat $R/$f" | diff -q - "$f" >/dev/null || echo "DIFFERS: $f"
> done
> ```

> Moved verbatim from `CLAUDE.md` during the 2026-09-20 doc split. Where a line was found stale
> on the way across it was corrected in place and the correction is marked **CORRECTED**.

## Upstream relationship

Origin is `tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark`. We track `main` and
carry the local extensions above as uncommitted working-tree changes — upstream has never touched
`vllm/entrypoints/anthropic/*`, so the patches have not clashed. Standard update is
`git stash` → `git pull` → `git stash pop`, then rebuild the runtime image on both nodes if
`recipe/overlay/` changed.

**This Mac checkout is 18 commits behind `origin/main`** (last pull `0fec808`, 2026-08-23).
Assessed 2026-09-03; pulled to `d841fdb` (local only, cluster not restarted). Upstream does **not**
touch `start-deepseek-v4-flash-dspark.sh`, and its `docker-compose.dspark.yml` changes sit in
different hunks from ours, so the stash/pull/pop merged cleanly.

**No `recipe/overlay/` files changed, so this pull needs no image rebuild.** Of everything in it,
exactly two items justify a restart: the journald logging driver and
`VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS`. Both are compose-only, and the compose already defaults the
timeout to 1800, so neither needs an `.env.dspark` edit. Everything else is docs, tooling, a
different vLLM branch, or already-default behaviour.

What it brings, in priority order:

| Change | Verdict for us |
|---|---|
| **Do not pin `NCCL_IB_GID_INDEX`** (#38) — GID indexes drift, and a stale pin fails on one HCA only. | **No action needed; we already comply.** Upstream's *reason* is wrong, though — see below. |
| **`NCCL_IB_MERGE_NICS` compose passthrough** — upstream notes the var reached the launcher shell but never the container. | **Harmless, but expect no gain.** NCCL's default is already `1` — see the topology note below. |
| **`VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800`** (#8) — vLLM's 300s default is shorter than a cold mid-inference JIT, so the worker blocks and the engine is shut down. | **Adopt.** Matches the anatomy of our unexplained overnight engine deaths. |
| **journald logging driver** for the container. | **Adopt.** Our watchdog restarts via `down`, which destroys json-file logs — we lose the evidence of why it restarted, every time. |
| `scripts/check-patch4.sh` — fail-closed check that the DSpark shared-expert loader fix is live (its absence silently halves decode at unchanged quality). | **Adopt.** Run against both containers after every boot. Verified 2026-09-03: **Patch 4 present on both nodes.** |
| `vision-exp/build-ds4v-files.sh` + `launchers/`, `CURRENT.md`, `VISION-EXP-DEFAULT-CONFIG.md` | **Adopt.** The generator already reproduces our staged files bit-identically. |
| **`fix(nvfp4)`: widen decode dispatch to `nvfp4_ds_mla` in `flashmla_sparse` (#37)** — narrow `==` check makes decode silently fall back to `_forward_bf16_kv`. | **Not our code path — no action.** The fix lands in `patches/official-main-b12x-nvfp4-python.patch`, which our build never applies. Our image *does* carry the narrow check at `flashmla_sparse.py:1014`, but we never execute it: decode runs `sparse_mla_sm120_decode_dsv4` (`SparseMlaDecodeV3Runner`), and `flashmla_sparse` appears **zero** times in the boot log. Re-check this if the attention backend ever changes. |
| Patch 5 port for vLLM **0.25.x** (stop strings firing inside reasoning) | **Not applicable.** Our runtime is **vLLM 0.21.1rc1.dev339+g1967a5627bc3**, not a 0.25.x tree, and we serve `{"thinking":false}` by default so the guard is inert anyway. **CORRECTED 2026-09-20:** this row used to say "we do not mount Patch 5" — we do; `MNT-5` has been mounted since 2026-09-18 (verify: `scripts/check-local-patches.sh`). The verdict is unchanged. |
| `validate-dspark-config.sh` default `MTP_NUM_TOKENS` 3 → 5 | Cosmetic; we already run k=5. |
| TP4 launchers / four-Spark topology in `CURRENT.md`; `MODEL_DIR` pointing at an abliterated build | **Not applicable.** We are two nodes on the official checkpoint. |

## Upstream **vLLM** (not the fork) — vllm#43447, prefix-cache retention (assessed 2026-09-20)

`tonyd2wild` is not the only upstream that matters; the vLLM tree our image is built from is the
other one. [vllm#43447](https://github.com/vllm-project/vllm/pull/43447) ("DeepSeek-V4 prefix cache
retention", confirmed on 0.22.1rc1) is **not in our 0.21.1rc1.dev339 runtime**.

| half of the PR | verdict |
|---|---|
| **Free-queue ordering** — `prepend_n()`, `free_blocks(prepend=True)`, scratch blocks reused before cached ones, in `remove_skipped_blocks()` *and* `SlidingWindowManager.free()` | **Applies — port it.** It is the missing end-of-request half of `MNT-6b`, and the first mechanism that predicts multi-turn prefix decay while a single-turn head survives. Not yet implemented or measured. |
| **`VLLM_PREFIX_CACHE_RETENTION_INTERVAL`** — sparse SWA checkpointing (`0`, or a multiple of the 256-token alignment such as `32768`) | **Applies in principle, second in line.** Our SWA groups cache densely *regardless* of any interval, because `kv_cache_coordinator.py:515` disables the mask under MTP. Adopting it means replacing that fork-local bail-out with upstream's eagle-aware mask — a live A/B, where a mistake reads as 0% hit. |

Full analysis, the per-group block-size table, the porting surface and the test plan:
[`CACHE_TEST.md`](../../CACHE_TEST.md).

> **Cable topology — we have ONE cable, not two (checked 2026-09-03).** "Dual-HCA" here does not
> mean two links. `rocep1s0f0` and `roceP2p1s0f0` report **the same `sys_image_guid`**
> (`4cbb:4703:002c:45eb`) on different PCI addresses (`0000:01:00.0`, `0002:01:00.0`) — one
> ConnectX-7 ASIC reached over two PCIe paths, not two cards. Both show ACTIVE / 200 Gb/s and both
> subnets (`192.168.0.x`, `192.168.2.x`) reach the peer, because both ride the **same single wire**.
> Do not read two ACTIVE ports as two cables, and do not expect the aggregate of the two rates.
>
> **`NCCL_IB_MERGE_NICS` is therefore a non-event for us.** NCCL source: `NCCL_PARAM(IbMergeNics,
> "IB_MERGE_NICS", 1)` — the default is **already 1**, so "unset" and "=1" behave identically and the
> passthrough changes nothing. Merging multi-PCI-path devices like ours is exactly what it does, and
> it is already on. The earlier "98 → 161 Gb/s" note in this file was upstream's figure quoted
> without checking the default; it is not a win available to us. Confirming NCCL actually merges our
> two paths would need one `NCCL_DEBUG=INFO` boot (look for a merged device name like `dev0+dev1`) —
> not yet done, and not worth a restart on its own.

> **Resolved 2026-09-03 — our empty `NCCL_IB_GID_INDEX` is correct; do not "fix" it.**
> Upstream's `.env.dspark.example` warns that "an EMPTY STRING parses as 0, which selects the fe80
> link-local GID and is worse than the pin." **That claim is wrong.** Checked against NCCL source
> (we run NCCL 2.28.9):
>
> - `ncclLoadParam` guards parsing with `if (str && strlen(str) > 0)` — a zero-length value is
>   never passed to `strtoll`, so it cannot become `0`; the default is used.
> - `NCCL_PARAM(IbGidIndex, "IB_GID_INDEX", -1)` — that default is `-1`.
> - `-1` puts `ncclIbGetGidIndex()` into auto-select, which defaults to RoCE **v2** + `AF_INET`.
>
> On our HCAs that resolves to GID index 3 (RoCE v2, `…ffff:c0a8:0078` = 192.168.0.120), which is
> exactly what we want — index 0 is the RoCE v1 `fe80` link-local one we must avoid. So an empty
> value and an unset value behave identically here, and we already follow upstream's real advice
> (never pin the index). No restart or NCCL_DEBUG boot is needed to settle this.

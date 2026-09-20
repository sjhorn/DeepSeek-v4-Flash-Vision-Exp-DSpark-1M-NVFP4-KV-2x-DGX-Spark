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
> ```
>
> If `recipe/overlay/` changed, rebuild the runtime image on both nodes — and then **re-capture
> `patches/pristine/`**, because every generated diff is computed against the old image. The image
> id in `patches/pristine/MANIFEST.txt` exists to make that failure loud.

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

# docs/local/ — our fork, documented

Upstream's docs (`README.md`, `DEFAULT-CONFIG.md`, `vision-exp/README.md`, `docs/PATCHES.md`)
describe the recipe in general. **This directory describes our two boxes, our patches, and what we
have measured on them.** Nothing here is upstream's and nothing here should be sent upstream
unedited.

## Which doc do I want

| I want to… | read |
|---|---|
| restart, stop, check, or switch text↔vision | [`CLUSTER.md`](CLUSTER.md) |
| know what is patched, how to switch it off, how to roll it back | [`PATCH-REGISTRY.md`](PATCH-REGISTRY.md) |
| understand or change an Anthropic-endpoint patch | [`PATCHES-API.md`](PATCHES-API.md) |
| understand or change a KV / block-pool patch | [`PATCHES-KV.md`](PATCHES-KV.md) |
| find out why a session re-prefilled, or measure the cache | [`PREFIX-CACHE.md`](PREFIX-CACHE.md) |
| read the investigation that found and fixed it (`MNT-6c`), and what is still open | [`CACHE-TEST.md`](CACHE-TEST.md) |
| choose a thinking tier or an effort level | [`THINKING-AND-EFFORT.md`](THINKING-AND-EFFORT.md) |
| pull from upstream, or judge an upstream change | [`UPSTREAM.md`](UPSTREAM.md) |
| **know if a change needs a restart, or can go live** | [`RUNTIME-SURFACE.md`](RUNTIME-SURFACE.md) |
| find a tool in `local-ops/` | [`TOOLING.md`](TOOLING.md) |
| know the current config, KV pool, or node versions | [`status/CONFIG.md`](status/CONFIG.md) |
| compare this boot to the last one | [`status/BOOT-METRICS.md`](status/BOOT-METRICS.md) |
| recognise a failure we have already had | [`status/INCIDENTS.md`](status/INCIDENTS.md) |

`CLAUDE.md` at the repo root keeps only what must be loaded every session: the working agreement
(the doc-update triggers and the per-restart confirmation rule) and the gotchas list. Everything
else is here.

## How these docs are kept

Three rules, all of which exist because they were broken:

1. **Evidence lives in exactly one place.** A measurement belongs in the detail doc for the patch
   it justifies. The registry carries one line and a link. Restating the same number in two files
   is what made the compose "drift" note, the MNT-5 sync caveat and the README effort table all
   go stale in different directions.
2. **`status/CONFIG.md` is the source of truth for configuration**, and `patches/pristine/` +
   `patches/generated/` are the source of truth for what a patch actually changes. Convenience
   copies elsewhere are allowed and are expected to lose.
3. **Re-verify before acting, and record the negative results.** Diff or measure first, then fix
   the note in passing. "`max` effort is worse than `high`", "`MNT-5` is inert under
   `thinking:false`", "`NCCL_IB_MERGE_NICS` is a non-event" each stop a future repeat of the work.

The working agreement in `CLAUDE.md` says which trigger updates which file. A missing doc update
is an incomplete task, not a follow-up.

## Where our divergence lives

Since 2026-09-20 it is a real branch:

| | |
|---|---|
| `main` | tracks `origin/main` — upstream's repo |
| `local/main` | everything of ours, in coherent commits |

`branch.local/main.pushRemote` is set to `no-push`: `origin` is upstream's GitHub repo and
`git remote -v` shows the **same URL for push**. This branch must never be pushed there.

`local-ops/` tracks its **scripts** and ignores everything they produce — see [`TOOLING.md`](TOOLING.md).

## Open proposals

`MERGE.md` at the repo root is a **proposal, not a record** — unifying the prefill/prefix-cache
observability stack across this repo, `sparkstats` and `vllm-proxy`. Nothing in it has been
executed. It is tracked so the proposal does not evaporate; move anything that gets built into the
doc for the thing it changes.

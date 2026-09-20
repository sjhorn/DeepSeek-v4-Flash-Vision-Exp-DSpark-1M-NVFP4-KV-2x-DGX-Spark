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
| restart, stop, check, switch text↔vision | `docs/local/CLUSTER.md` |
| know what is patched, its kill switch, its rollback | `docs/local/PATCH-REGISTRY.md` |
| change an Anthropic-endpoint patch (`API-0`, `API-8`…`API-13`) | `docs/local/PATCHES-API.md` |
| change a KV / block-pool patch (`MNT-5`, `MNT-6`, `MNT-7`) | `docs/local/PATCHES-KV.md` |
| find out why a session re-prefilled, or measure the cache | `docs/local/PREFIX-CACHE.md` |
| choose a thinking tier or effort level | `docs/local/THINKING-AND-EFFORT.md` |
| pull from upstream, or judge an upstream change | `docs/local/UPSTREAM.md` |
| find a tool in `local-ops/` | `docs/local/TOOLING.md` |
| know the current config, KV pool, node versions | `docs/local/status/CONFIG.md` |
| compare this boot to the last | `docs/local/status/BOOT-METRICS.md` |
| recognise a failure we have already had | `docs/local/status/INCIDENTS.md` |

Start at `docs/local/README.md` if none of those is obviously right.

## Our divergence is a branch

`main` tracks upstream. **All of our work is on `local/main`**, in coherent commits — `git log` is
now the change history these docs used to carry in prose.

`branch.local/main.pushRemote` is `no-push`, because `origin` is upstream's GitHub repo and shows
the **same URL for push**. Never push this branch there.

**Both nodes are git checkouts of `local/main` too (since 2026-09-20), so deploying is a push:**

```bash
git push head local/main && git push worker local/main
```

They are set `receive.denyCurrentBranch = updateInstead`, so this updates their working trees and
**refuses if a node's tree is dirty** — investigate rather than override. A push stages the next
restart; it never performs one, and never changes the running engine. Details:
`docs/local/CLUSTER.md`.

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

Two habits that have already paid for themselves here:

- **Re-verify a claim in these docs before acting on it.** Several notes have gone stale — the
  compose "drift", the MNT-5 sync caveat, the README's effort table, and "Patch 9d is not
  deployed" (it was). Diff or measure first; then fix the note in passing.
- **Record the negative results too.** "`max` effort is worse than `high`", "MNT-5 is inert under
  `thinking:false`", "`NCCL_IB_MERGE_NICS` is a non-event" each stop a future repeat of the work.

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
- **Currently deployed: Vision-Exp**, `MAX_MODEL_LEN=1048576`, `MAX_NUM_SEQS=12`,
  `GPU_MEMORY_UTILIZATION=0.86`, `COMPILATION_CONFIG={"max_cudagraph_capture_size":72}`,
  `PROTECTED_FRACTION=0.50`, `MTP_NUM_TOKENS=5`. Re-check with
  `docker logs <container> | grep 'non-default args'` rather than trusting this line;
  `docs/local/status/CONFIG.md` carries the change history.
- **A bind mount to the wrong path fails SILENTLY** — the container starts, the API answers, the
  smoke test passes, and the patch is not there. After any restart run all three checks in
  `docs/local/CLUSTER.md`, not just the smoke test.

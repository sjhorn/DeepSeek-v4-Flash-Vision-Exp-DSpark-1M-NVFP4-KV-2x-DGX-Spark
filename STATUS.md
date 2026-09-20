# Cluster Status — index

**This file is now an index.** It was 1,381 lines mixing the current configuration, a boot-by-boot
log, seventeen incidents, and the measurement write-ups that justify individual patches. Split on
2026-09-20 so each part can be read — and kept current — on its own.

| you want | it is in |
|---|---|
| what is deployed right now; the **key configuration table that is the source of truth**; node firmware/driver versions; network layout | [`docs/local/status/CONFIG.md`](docs/local/status/CONFIG.md) |
| one section per boot: KV pool, concurrency, what changed, which start script | [`docs/local/status/BOOT-METRICS.md`](docs/local/status/BOOT-METRICS.md) |
| what went wrong, why, and the signature to recognise it next time; plus the live known issues | [`docs/local/status/INCIDENTS.md`](docs/local/status/INCIDENTS.md) |

The measurement write-ups that used to live here moved next to the patch each one justifies, so
the evidence and the code are read together:

| write-up | moved to |
|---|---|
| the Anthropic-endpoint patches (`API-0`, `API-8`…`API-13`) — leaked CoT, model aliases, the classifier, tool-argument handling | [`docs/local/PATCHES-API.md`](docs/local/PATCHES-API.md) |
| prefix-cache stability measured end to end, and the cross-session investigation | [`docs/local/PREFIX-CACHE.md`](docs/local/PREFIX-CACHE.md) |
| reasoning effort — `high` vs `max`, HMMT Feb 2026 | [`docs/local/THINKING-AND-EFFORT.md`](docs/local/THINKING-AND-EFFORT.md) |
| the KV patches (`MNT-5`, `MNT-6`, `MNT-7`) and the co-l assessment | [`docs/local/PATCHES-KV.md`](docs/local/PATCHES-KV.md) |
| every patch in one table, with kill switches and rollbacks | [`docs/local/PATCH-REGISTRY.md`](docs/local/PATCH-REGISTRY.md) |
| lifecycle, restart checklist, recovery after a reboot | [`docs/local/CLUSTER.md`](docs/local/CLUSTER.md) |

Start at [`docs/local/README.md`](docs/local/README.md).

## Two corrections made during the split

- **The "Patch 5" collision was a real error, not just sloppiness.** The protected-block cap and
  the detokenizer stop-string guard were both called Patch 5. The cap is `MNT-6a`, the guard is
  `MNT-5`; the cap's own `logger.info` label was relabelled with it.
- **"Patch 9d — STAGED, not deployed"** was stale: verified live in the running container on
  2026-09-20. The compose bind-mount block that said `patch5-detokenizer.py` was "not yet mounted"
  was stale too — read `docker-compose.dspark.yml`, or run
  `bash scripts/check-local-patches.sh`, rather than any prose copy of the mount list.

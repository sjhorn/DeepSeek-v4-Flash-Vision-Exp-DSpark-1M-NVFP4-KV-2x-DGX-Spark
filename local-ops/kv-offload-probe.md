# KV disk-offload probe — prepared 2026-09-13, RUN TOMORROW (not deployed)

## What we found (no guessing needed — read from our own image)

Our vLLM **0.21.1rc1.dev339 already ships a native disk tier**. No fork, no version bump.

```
vllm/v1/kv_offload/
  cpu/        CPUOffloadingSpec        (default)
  tiering/    TieringOffloadingSpec    <-- multi-tier: CPU primary + secondary tiers
  tiering/fs/ FileSystemTierManager    <-- registered as secondary tier type "fs_python"
```

- `OffloadingSpecFactory` picks the spec from `kv_connector_extra_config.spec_name`
  (default `CPUOffloadingSpec`). Registered: `CPUOffloadingSpec`, `TieringOffloadingSpec`.
- `SecondaryTierFactory` registered tier types: `example`, **`fs_python`**.
- `FileSystemTierManager(root_dir, n_read_threads=16, n_write_threads=16)`.
- On-disk layout: `<base_path>_r<rank>/<hhh>/<hh>_g<group_idx>/<hash_hex>.bin`, written to
  `<dest>.tmp` then `os.replace`d. **Per-rank directories**, which is exactly the multi-node
  hazard the nacyot fork had to solve by hand — here it is built in.
- Connector to use: `OffloadingConnector` (registered; implements `SupportsHMA`).
- CLI: `--kv-transfer-config` (exposed in `engine/arg_utils.py`).

## THE question this probe answers

Does the offload path accept our **`nvfp4_ds_mla`** sparse-MLA KV layout, or does it assume
standard paged KV? That is the one blocker. Everything else is plumbing we already have.

Answer is visible within ~2 minutes of engine init — no need to run a full load test.

## Probe config

Modest sizes on purpose: this is a "does it initialise" test, not a performance test.

```json
{
  "kv_connector": "OffloadingConnector",
  "kv_role": "kv_both",
  "kv_connector_extra_config": {
    "spec_name": "TieringOffloadingSpec",
    "cpu_bytes_to_use": 4294967296,
    "eviction_policy": "lru",
    "secondary_tiers": [
      { "type": "fs_python",
        "root_dir": "/kvoffload/ds4f",
        "n_read_threads": 8,
        "n_write_threads": 8 }
    ]
  }
}
```

Notes:
- `cpu_bytes_to_use` 4 GiB is the CPU *primary* tier and is **zero-sum on unified memory** —
  it comes straight out of the KV pool. Expect the GPU KV pool to shrink by roughly this much.
  That is the cost of the gateway; only the fs tier adds real capacity.
- `root_dir` must exist on **both** nodes and be writable by the container (bind-mount needed,
  see below). Per-rank subdirs mean a shared mount is NOT required for the probe.
- Keep `MAX_NUM_SEQS=12`, `cap 72`. Change only this one thing.

## Steps (tomorrow)

1. Compose passthrough (already staged on the Mac, **NOT yet copied to the head**):
   `KV_TRANSFER_CONFIG` env + `$${KV_TRANSFER_CONFIG:+--kv-transfer-config "$$KV_TRANSFER_CONFIG"}`.
   Copy `docker-compose.dspark.yml` to the head only when ready to restart.
2. Bind-mount a host dir into the container on both nodes, e.g. add to the compose service:
   `- /home/shorn/kvoffload:/kvoffload`  and `mkdir -p /home/shorn/kvoffload` on both nodes.
   Put it on the fastest local disk; it is NOT the HF cache mount.
3. Set in `.env.dspark` (single-quote wrap, same as HF_OVERRIDES — unquoted JSON gets its inner
   quotes eaten by env-file parsing):
   `KV_TRANSFER_CONFIG='{"kv_connector":"OffloadingConnector", ... }'`
4. `./start-deepseek-v4-flash-dspark.sh`  (startup cache reclaim is now live)
5. Watch for the verdict.

## Reading the result

PASS signals:
- `OffloadingConnector` / `TieringOffloadingSpec` / `FileSystemTierManager` appear in the log
- engine reaches `Application startup complete`
- `GPU KV cache size:` still printed (smaller than 2.8M — the CPU tier is taken from it)
- files appear under `/home/shorn/kvoffload/*_r0/` and `*_r1/` after some traffic

FAIL signals (the layout blocker):
- assertion/exception mentioning `nvfp4`, `mla`, `head_size`, `block_shape`, `strides`,
  `CanonicalKVCaches`, or `primary_kv_view`
- `Unknown secondary tier type` (wrong `type` string)
- engine dies during `create_spec` / connector init

Useful greps:
```
docker logs <container> 2>&1 | grep -iE "offload|tiering|fs_python|FileSystemTier|kv_connector"
docker logs <container> 2>&1 | grep -iE "Traceback|assert|nvfp4|mla|not supported|Unknown"
```

## Rollback

Delete the `KV_TRANSFER_CONFIG` line from `.env.dspark` and restart. The flag is opt-in; with it
unset the serving path is byte-identical to today. Also `rm -rf /home/shorn/kvoffload/*`.

## If it PASSES

Then measure what actually matters, in this order:
1. KV pool delta (how much the CPU primary tier cost)
2. Whether a 250K-token session survives eviction and restores from disk, and how long that takes
   (fork's reference: 12-18s restore vs 435s full reprefill)
3. Steady-state throughput with offloading on vs off (fork claims store overhead is noise)
4. Disk growth rate — the fork warns a 450K prefill can write ~16 GiB; needs a retention policy

## If it FAILS on the layout

Then the nacyot fork's `nvfp4_ds_mla` serialisation work is genuinely required, and that means a
0.27.1 port — a separate project, not an incremental change. Record the exact exception; it tells
us how deep the incompatibility goes.

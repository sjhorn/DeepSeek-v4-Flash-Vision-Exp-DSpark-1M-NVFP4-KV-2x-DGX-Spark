# The vLLM 0.31 boot gate: runbook (step 3, item 1)

The goal is one window that answers whether DeepSeek V4 + DSpark boots and
serves correctly on stock vLLM v0.31.0 across both GB10 nodes, and what it
costs in KV capacity and speed against the 0.21 engine. Nothing here changes
production. The gate runs from its own compose (`docker-compose.dspark-031.yml`),
as its own service, on its own port and cache.

**Who:** whoever runs the window, the user or the vllm-proxy session. DSpark's
`CLAUDE.md` governs the engine, and its stop/start scripts are the only way
production is stopped and started.

**Budget:** about half a day, both nodes down.

| part | time |
|---|---|
| stop production, pull the image (both nodes in parallel) | 15–20 min |
| first boot, 262K | 20–40 min (first 0.31 boot compiles kernels) |
| checks at 262K | 30–45 min |
| 1M boot and checks, concurrency | about 1 h |
| optional: dispram, kvmgr | 30–60 min |
| rollback to production | 20–30 min |

## Before the window (no downtime)

1. **The garble capture exists on the head:** `ls -la /var/tmp/garble_tap/all.jsonl`.
   If not, record one against production first:
   `UPSTREAM=http://127.0.0.1:8888 PORT=8890 python3 benchmarks/garble_tap.py`,
   with an agent pointed at :8890 for a while. Without a real ~18–20K-token
   agent request, the cold-start garble check (below) cannot run, and the gate
   would prove nothing about it.
2. **Get this branch onto both nodes WITHOUT touching the production
   checkout:** push the branch only (`git push head vllm-0.31`,
   `git push worker vllm-0.31`), then on each node
   `git -C ~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark worktree add ~/dspark031 vllm-0.31`.
   - A non-checked-out branch push does not change the working tree, and the
     worktree is a separate directory.
   - Both nodes must be at the same commit.
3. **b12x, on both nodes.** The stock image lacks it (vLLM's optional
   `b12x==1.3.0` extra). Install it beside the image:
   `mkdir -p ~/dspark031-deps && docker run --rm -v ~/dspark031-deps:/out --entrypoint pip vllm/vllm-openai:v0.31.0 install -q --no-deps --target /out/b12x-1.3.0 b12x==1.3.0`.
   - 1.3.0 pins CUTLASS DSL 4.6.2 and the image has 4.7.1. Both 1.3.0 and
     1.5.0 (which pins 4.7.1) pass 0.31's b12x device check on GB10. If 1.3.0
     fails at kernel compile, set `B12X_DIR_031=~/dspark031-deps/b12x-1.5.0`.
4. **Record today's numbers to compare against,** from the running engine's
   log (`logs-deepseek-v4-flash-dspark.sh`):
   - `GPU KV cache size: N tokens` (3,377,409 on 2026-10-16, 1M lane, `KV_CACHE_MEMORY_BYTES=21789705851`);
   - decode tok/s from a normal request.

## In the window

### 0. Stop production, hold the supervisor (head)

```sh
touch ~/.engine-hold          # engine-supervisor must not "recover" the gate
./stop-deepseek-v4-flash-dspark.sh   # per DSpark CLAUDE.md, both nodes
```

Then confirm on both nodes that no engine container exists and
`nvidia-smi` shows no processes.

### 1. Pull the image (both nodes, in parallel)

```sh
docker pull vllm/vllm-openai:v0.31.0     # ~10 GB, ~10 min incl. extraction
```

### 2. Boot at 262K (worker first, then head)

```sh
cd ~/dspark031
E=~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark
# worker (spark-da08):
NODE_RANK=1 HEADLESS=1 docker compose -f docker-compose.dspark-031.yml --env-file $E up -d
# head (spark-45ea):
NODE_RANK=0 docker compose -f docker-compose.dspark-031.yml --env-file $E up -d
docker compose -f docker-compose.dspark-031.yml logs -f    # watch
```

- **Production's env file is safe to reuse.** The gate reads its own
  `*_031` names for anything that must differ: `MAX_MODEL_LEN_031` (default
  262144), `KV_CACHE_DTYPE_031` (fp8), `VLLM_PORT_031` (18888),
  `MOE_BACKEND_031` (b12x), `JIT_CACHE_DIR_031`. It never reads
  `KV_TRANSFER_CONFIG`, so kvmgr is off.
- **If `.env.dspark` sets `MASTER_ADDR` and `NODE_RANK`,** keep its values;
  the lines above only make the roles explicit.

**Boot pass/fail, from the head's log:**
- `Using DeepSeek's fp8_ds_mla KV cache format`;
- model runner V2 and the DSpark speculator initialised (`dspark`, `V2`);
- the plugins armed: `dspark031: KV-7 armed`, `MNT-10 armed`, the E8M0 and
  prefill-collector plugins discovered;
- no `Traceback`; `/health` answers on 127.0.0.1:18888.

**Walls already known, and what to try:**

| symptom | likely cause | try |
|---|---|---|
| stalls at "Loading safetensors" 0%, CPU 100%, GPU idle | 64K-page lazy loader | confirm `--safetensors-load-strategy eager` is in the serve line |
| DSV4 attention init fails on SM12x | FlashInfer without #4380 | `pip show flashinfer-python` in the container should be 0.7.0.post1, which contains it; else image problem, so fall back (below) |
| DeepGEMM / `fp8_einsum` error at the output projection | DeepGEMM SM12x JIT | check `DG_JIT_NVCC_COMPILER` exists in the image (`/usr/local/cuda/bin/nvcc`); else fall back |
| `KeyError: 'F8_E8M0'` | E8M0 plugin not loaded | check its mount and the dist-info |
| any other kernel wall | the stock image on sm_121 | fall back to `DSPARK031_IMAGE=eugr/spark-vllm:latest` (built for 12.1a). Note: a vLLM `main` commit that differs from v0.31.0 in DSV4 attention, `block_pool` and `scheduler`; good for "does DSV4+DSpark run on 0.31-era code", not as the final base |

### 3. Checks at 262K (head)

Run them in this order; the first failure decides whether to go on.

1. **Smoke:** `CHAT_URL=http://127.0.0.1:18888/v1/chat/completions ./smoke-deepseek-v4-flash-dspark.sh`
   (`CHAT_URL`, not `VLLM_PORT`: the script sources `.env.dspark` after, and that
   sets production's port).
2. **KV capacity:** the `GPU KV cache size` line. Compare it with the 0.21
   number at the same `--gpu-memory-utilization`. This decides fp8_ds_mla vs
   our 0.21 "nvfp4" (port README, decision 2).
3. **Cold-start garble.** Patch 3 is dropped on 0.31 because V2 sizes drafts
   itself; this is the check that proves it:
   `URL=http://127.0.0.1:18888/v1 N=10 COLD=1 python3 benchmarks/replay_hermes.py`.
   - Pass is 0/10 failures (0.21 without Patch 3 was 11/12).
4. **Speed:** decode tok/s and DSpark acceptance (the log's spec-decode
   metrics), against step "Before the window" 4.
5. **The Anthropic endpoint:** a Claude Code turn through it with tools, and
   a thinking-alias request (`claude-opus-5`). Check that `usage` has
   `engine_cached_tokens` on the second identical request.

### 4. 1M boot, then concurrency

```sh
docker compose -f docker-compose.dspark-031.yml down     # both nodes
MAX_MODEL_LEN_031=1048576 ... up -d                      # as in step 2
```

- **Concurrency:**
  `python3 benchmarks/keys-concurrency/bench_concurrent.py http://127.0.0.1:18888 2,4,6`
  (positional: base URL, sweep). Run the cold garble replay alongside it for
  mixed prefill + decode. This is where upstream DSpark's
  parity with our 0.21 Keys concurrency fix is decided.
- **Garble again:** repeat the cold-start garble replay under concurrency.

### 5. Optional, one at a time

- **dispram** (+2 GiB KV): add the two dispram mounts and
  `PYTHONPATH=/opt/dspark031:/opt/dispram`. Its plugin targets a 0.21-era
  `gpu_worker`, so expect it to stand aside or fail. Record which.
- **kvmgr's 0.31 line (0.5.0)** needs its branch on the nodes too, and a cold
  tier (`KVOFFLOAD_DIR` pointed at a NEW directory, never `~/kvoffload`). This
  is a separate step, possibly a separate window.

### 6. Roll back (always)

```sh
docker compose -f docker-compose.dspark-031.yml down      # both nodes
./start-deepseek-v4-flash-dspark.sh                         # production, per DSpark CLAUDE.md
rm ~/.engine-hold                                           # only once production is healthy
```

Check that production's smoke test passes and `/v1/models` answers on :8888.

## Write down (for the port README)

| item | to record |
|---|---|
| image | which one booted, and any wall hit |
| boot | time to `/health` |
| KV | GPU KV cache size, 262K and 1M, against 0.21 |
| garble | cold failures at 262K and at 1M under concurrency |
| speed | decode tok/s, DSpark acceptance |
| concurrency | 2/4/6 results |
| dispram, kvmgr | if tried |

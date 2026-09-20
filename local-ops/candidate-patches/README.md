# ds4-prefix-cache-fixes

Cache-management fixes for the DeepSeek-V4-Flash vLLM fork (the
`aidendle94/sparkrun-vllm-ds4-gb10` image family on 2x DGX Spark / GB10).

**The number that matters: the prefix cache retains ~147% of its advertised
capacity under pressure instead of ~65%.**

## The problem

I went to the deep end on cache management for vLLM. Something felt "off":
I didn't feel the 2M-token cache was properly managed. The symptom: going
back to an "old" session after spending time in another one felt like
russian roulette. Sometimes cache hit, sometimes cache miss.

So I started investigating (5 days of work). First I built a visualizer to
see how blocks were allocated. I noticed a lot of blocks allocated that
were never read again, putting pressure on older blocks from older
contexts since their LRU was older. Two concrete defects:

1. **Duplicate dead weight.** Every request re-computes ~20 already-cached
   positions (hit-path drop / spec-decode boundary). Each re-commit
   inserts a *second* physical block with the same content hash into the
   map — and hits always return the first copy, so the older copies are
   never touched again. At 100K tokens / 31 requests that was ~16% of the
   map, growing with request count.
2. **Unreachable replay tails.** With sparse retention, the sliding groups
   only commit checkpointed segments. For prompts ending less than one
   block past an alignment boundary, the replay tail was never committed —
   an exact replay of a cached conversation silently recomputed 6–58s of
   prefill instead of hitting in ~0.4s.

## The paradigm

The engine's advertised "GPU KV cache size" is an **active-request planning
budget**, not a ceiling on cacheable content. Hybrid layouts (MLA +
sparse-attention + constant-size recurrent-state groups) pack cached blocks
denser than that reservation, and cache-management defects waste the
headroom. So the real question is: **how much context does the cache
retain when it's under pressure?** That's what this repo's benchmark
measures, and what these patches improve.

## The protocol

The retention-under-pressure benchmark
([`cache-pressure`](https://github.com/co-l/cache-pressure) companion repo):

- Hydrate **80 truly random ~40K-token contexts** in sequence (3.2M tokens
  against a 2M-token advertised cache — yes, deliberately overflowing).
  A cold prefill takes ~20s (TTFT), a full cache hit ~0.5s.
- Re-send each context **in reverse order** (newest first) and find the
  first one that misses = the oldest evicted context = the real retained
  capacity.

## Results

`aidendle94/sparkrun-vllm-ds4-gb10:production-3.7-reffix-schedfix`
(pre-fix image, retention 4096):

```
── Retention under pressure ──
capacity:           2,023,924 tokens
retained contexts:  27/80
retained tokens:    1,052,025
retained % capacity: 51.98%
oldest evicted:     context #52 (older contexts evicted)
```

With the dedupe + boundfix patches applied (retention 0):

```
── Retention under pressure ──
capacity:           2,047,043 tokens
retained contexts:  77/80
retained tokens:    3,000,048
retained % capacity: 146.56%
oldest evicted:     context #2 (older contexts evicted)
```

| image state | retained | % capacity |
|---|---|---|
| pre-fix (retention 4096) | 34/80 x 39K (1.32M tok) | 65.4% |
| + dedupe + boundfix (retention 0) | 79/80 x 39K (3.08M tok) | 147.4% |

That's **~2.3x more cacheable context under pressure**, and it is
deterministic (the fixed image repeated the run byte-identical; the pre-fix
image was noisy: 27/80 then 34/80 — sparse retention leaves the
replay-boundary tail uncommitted, so survival depends on per-boot
allocation luck).

Why >100% is real, not a bug: the advertised capacity reserves worst-case
per-token storage for active requests; cached content packs denser
(constant-size Mamba state, bounded sliding-window groups, deduplicated
blocks), so the cache physically holds more context than the budget
implies. The fixes make that headroom actually usable.

### Not broken: correctness

Retention is worthless if the engine is broken. A needle-in-haystack sweep
(50K/100K/200K/300K/450K contexts, needle at 0.8 depth) on the fixed image:
**5/5 exact-code retrievals**, TTFT linear at ~1,900 tps prefill. Benchmarks
vs the pre-fix image (llama-benchy c1, real-agent session): **parity or
better** — the fixes are performance-neutral-to-positive on top of the
retention win.

## Reproduce it

```bash
# 1. Build the patched image (applies patches/01..04 on production-3.7)
./image/apply-patches.sh

# 2. Launch with the reference recipe (adjust the NCCL block to your nodes)
#    — point container: at the tag you just built
#    (see recipe/README.md)

# 3. Measure retention under pressure
git clone https://github.com/co-l/cache-pressure
python3 cache-pressure/bench/cache_pressure.py --ssh-host <node> --output fix.json

#    Run the same on the pre-fix image for the A/B:
python3 cache-pressure/bench/cache_pressure.py --compare fix.json control.json
```

## Layout

```
patches/   01-reffix · 02-schedfix · 03-dedupe · 04-boundfix  (the full chain)
image/     apply-patches.sh — build a patched image tag from production-3.7
recipe/    reference launch recipe (sanitized, node-specific bits marked)
```

The retention benchmark (`cache_pressure.py`) and the correctness sweep
(`needle_test.py`) live in the separate, deployment-agnostic
[`cache-pressure`](https://github.com/co-l/cache-pressure) repo.

## Licensing & attribution

MIT. `02-schedfix.py` is a port of the
[Anemll / MiaAI](https://github.com/Anemll) scheduler hotfixes (#27, #43)
— see `patches/README.md` for per-patch provenance. Everything else is
original work.

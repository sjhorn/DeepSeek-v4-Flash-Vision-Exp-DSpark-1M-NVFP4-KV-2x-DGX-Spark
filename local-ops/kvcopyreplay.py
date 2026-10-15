#!/usr/bin/env python3
"""kvcopyreplay.py -- replay a faulting disk->GPU load copy OUTSIDE vLLM, thousands of times.

    python3 local-ops/kvcopyreplay.py launch --dumps A.json [B.json ...] [--jobs 5000] [--order alt]
    python3 local-ops/kvcopyreplay.py check  --dumps A.json [B.json ...]   # host side, no GPU
    python3 local-ops/kvcopyreplay.py --selftest                            # offline, no torch

CLASS: ACTUATOR -- ISSUES RAW GPU COPIES, and a reproduction is an Xid on this
node's GPU. `launch` REFUSES while the DSpark engine container exists on this
host: the engine holds nearly all GPU memory, and an Xid here would kill it. So
it needs the engine DOWN, which is a planned restart (hold file, ask first).
Run it on either node; each node is independent.

WHY. Class B (2026-10-15): a load in a step with NO forward pass, the last
full-size copy (33 blocks, 2,046 descriptors) of a 66-block group-0 job, Xid 32
at ~1 in a few hundred such jobs. The copydumps prove the descriptors are legal.
If the same copies fault here, with no vLLM, no NCCL and no model, the fault is
in CUDA's batched copy, the driver or the GPU, and this is the report for
NVIDIA. If they never fault, the engine's context is part of the trigger.

WHAT IT DOES, as close to upstream's `CpuGpuOffloadingHandler.transfer_async`
(vllm/v1/kv_offload/cpu/gpu_worker.py) as a standalone script can be:
  - one pinned host buffer and one GPU buffer per tensor, at the dump's sizes;
  - every descriptor REBASED from the dump's addresses onto these buffers, and
    bounds-checked (a descriptor outside its buffer refuses the whole run);
  - a "job" is the dumps in order (2 by default, like a 66-block job's two
    rounds), each one `torch.ops._C_cache_ops.swap_blocks_batch` on a pooled
    stream between timing events, the next waiting on the previous end event;
  - `is_src_access_order_any`: upstream passes True for EVERY load (the driver
    may prefetch source bytes out of order) and False for every store. Stores
    have never faulted. `--order any|stream|alt` tests that difference directly;
  - between jobs, an idle gap (`--gap-ms lo:hi`), since class B had no compute;
  - completion is POLLED (`end_event.query()`), never an unbounded sync: a copy
    open longer than `--stuck-s` is a HANG and stops the run;
  - every `--verify-every` jobs, sampled destination rows are read back and
    compared with the seeded host pattern (proves the copies land).

Verdicts: clean | xid | hang | mismatch | refused. The Xid count is read off the
kernel log before and after, and an unreadable count is an ERROR, not a zero.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import subprocess
import sys
import time

COLS = ("ref", "tensor", "block", "slot", "src", "dst", "size")
IMAGE = os.environ.get("DSPARK_VLLM_IMAGE", "vllm-dspark-runtime:dspark-nvfp4-stage-c")
ENGINE = os.environ.get("ENGINE_CONTAINER",
                        "deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1")


# ---------------------------------------------------------------- pure part

def load_dump(path: str) -> dict:
    d = json.load(open(path))
    if d.get("kind") != "load":
        raise ValueError(f"{path}: kind={d.get('kind')!r}, want 'load'")
    if tuple(d.get("descriptor_cols") or ()) != COLS:
        raise ValueError(f"{path}: descriptor_cols {d.get('descriptor_cols')} != {COLS}")
    if d.get("descriptors_kept") != d.get("n_descriptors") or len(d["descriptors"]) != d["n_descriptors"]:
        raise ValueError(f"{path}: descriptors truncated ({len(d['descriptors'])} of {d.get('n_descriptors')})")
    d["_path"] = path
    return d


def geometry(dumps: list) -> dict:
    """{tensor: (gpu_bytes, host_bytes)} -- the max over dumps, so one set of
    buffers serves them all. Geometry differs only if the engine config did."""
    g: dict = {}
    for d in dumps:
        for t, v in d["tensors"].items():
            gb = int(v["gpu_alloc_bytes"])
            hb = int(v["host_stride"]) * int(v["host_rows"])
            og, oh = g.get(int(t), (0, 0))
            g[int(t)] = (max(og, gb), max(oh, hb))
    return g


def rebase(d: dict, host_new: dict, gpu_new: dict, geo: dict):
    """(src, dst, size) lists on the new buffers. Raises on ANY descriptor
    outside its tensor's buffer: replaying a wrong copy proves nothing."""
    T = d["tensors"]
    src, dst, size = [], [], []
    for row in d["descriptors"]:
        r = dict(zip(COLS, row))
        t = int(r["tensor"])
        v = T[str(t)]
        so = int(r["src"]) - int(v["host_base"])
        do = int(r["dst"]) - int(v["gpu_alloc_base"])
        n = int(r["size"])
        gb, hb = geo[t]
        if not (0 <= so and so + n <= hb):
            raise ValueError(f"{d['_path']}: src outside host buffer t={t} off={so} n={n} cap={hb}")
        if not (0 <= do and do + n <= gb):
            raise ValueError(f"{d['_path']}: dst outside gpu buffer t={t} off={do} n={n} cap={gb}")
        src.append(host_new[t] + so)
        dst.append(gpu_new[t] + do)
        size.append(n)
    return src, dst, size


def synthesize(d: dict, side: str = "both") -> dict:
    """Same tensors, same sizes, same descriptor count -- but each tensor's
    copies packed sequentially from offset 0 on both sides. Separates "these
    addresses" from "this call, this shape"."""
    T = d["tensors"]
    nxt_s: dict = {}
    nxt_d: dict = {}
    out = []
    for row in d["descriptors"]:
        r = dict(zip(COLS, row))
        t = str(int(r["tensor"]))
        n = int(r["size"])
        so, do = nxt_s.get(t, 0), nxt_d.get(t, 0)
        nxt_s[t], nxt_d[t] = so + n, do + n
        if side in ("both", "src"):
            r["src"] = int(T[t]["host_base"]) + so
        if side in ("both", "dst"):
            r["dst"] = int(T[t]["gpu_alloc_base"]) + do
        out.append([r[c] for c in COLS])
    return dict(d, descriptors=out)


_CUDART = None


def loop_copy(bs, bd, bn, stream) -> None:
    """One cudaMemcpyAsync per descriptor, on the same stream."""
    global _CUDART
    import ctypes
    import glob
    if _CUDART is None:
        import torch
        libs = sorted(glob.glob(os.path.join(os.path.dirname(torch.__file__), "..", "nvidia", "cu*", "lib", "libcudart.so*"))
                      + glob.glob(os.path.join(os.path.dirname(torch.__file__), "..", "nvidia", "cuda_runtime", "lib", "libcudart.so*"))
                      + glob.glob("/usr/local/cuda/lib64/libcudart.so*"))
        if not libs:
            raise RuntimeError("libcudart not found for --api loop")
        _CUDART = ctypes.CDLL(libs[0])
        _CUDART.cudaMemcpyAsync.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_void_p]
    h = ctypes.c_void_p(stream.cuda_stream)
    for s_, d_, n_ in zip(bs.tolist(), bd.tolist(), bn.tolist()):
        rc = _CUDART.cudaMemcpyAsync(d_, s_, n_, 4, h)      # cudaMemcpyDefault
        if rc:
            raise RuntimeError(f"cudaMemcpyAsync rc={rc}")


def order_for(arm: str, job: int) -> bool:
    """is_src_access_order_any for this job."""
    if arm == "any":
        return True
    if arm == "stream":
        return False
    return job % 2 == 0          # alt


def parse_gap(s: str):
    lo, hi = (int(x) for x in s.split(":"))
    if lo < 0 or hi < lo:
        raise ValueError(f"--gap-ms {s}: want lo:hi with 0 <= lo <= hi")
    return lo, hi


# ---------------------------------------------------------------- host side

def xid_count():
    try:
        out = subprocess.run(["bash", "-c", "journalctl -k --no-pager | grep -c Xid"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode not in (0, 1):     # grep -c exits 1 on zero: that IS a count
            return None
        return int(out.stdout.strip().splitlines()[-1])
    except Exception:
        return None


def engine_present() -> bool | None:
    out = subprocess.run(["docker", "ps", "-a", "--filter", f"name=^{ENGINE}$", "--format", "{{.Names}}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return bool(out.stdout.strip())


def cmd_check(a) -> int:
    dumps = [load_dump(p) for p in a.dumps]
    geo = geometry(dumps)
    fake_h = {t: 1 << 40 for t in geo}
    fake_g = {t: 1 << 41 for t in geo}
    for d in dumps:
        s, _, n = rebase(d, fake_h, fake_g, geo)
        print(f"{os.path.basename(d['_path'])}: job {d.get('job')} {d['n_blocks']} blocks, "
              f"{len(s)} descriptors, {sum(n):,} bytes, rebase OK")
    print(f"buffers: {len(geo)} tensors, gpu {sum(g for g, _ in geo.values())/1e9:.2f} GB, "
          f"pinned host {sum(h for _, h in geo.values())/1e6:.1f} MB")
    return 0


def cmd_launch(a) -> int:
    def refuse(why):
        print(f"REFUSED: {why}", flush=True)
        print(json.dumps({"verdict": "refused", "why": why}), flush=True)
        return 2
    p = engine_present()
    if p is None:
        return refuse("cannot read docker state")
    if p:
        return refuse(f"the engine container {ENGINE} exists on {socket.gethostname()} -- "
                      "this needs the engine DOWN (planned restart, hold file, ask first)")
    rc = cmd_check(a)
    if rc:
        return rc
    x0 = xid_count()
    if x0 is None:
        return refuse("kernel Xid count unreadable -- a reproduction could not be seen")
    here = os.path.dirname(os.path.abspath(__file__))
    mounts, inner = [], []
    for i, p_ in enumerate(a.dumps):
        mounts += ["-v", f"{os.path.abspath(p_)}:/dumps/{i}.json:ro"]
        inner.append(f"/dumps/{i}.json")
    cmd = ["docker", "run", "--rm", "--gpus", "all", "--ipc=host", "--ulimit", "memlock=-1",
           "--name", "kvcopyreplay",
           "-v", f"{here}/kvcopyreplay.py:/kvcopyreplay.py:ro", *mounts,
           "--entrypoint", "python3", IMAGE, "-u", "/kvcopyreplay.py", "replay",
           "--dumps", *inner, "--jobs", str(a.jobs), "--order", a.order,
           "--gap-ms", a.gap_ms, "--stuck-s", str(a.stuck_s),
           "--verify-every", str(a.verify_every), "--seed", str(a.seed),
           "--max-desc", str(a.max_desc), "--api", a.api, "--skip", str(a.skip)] \
        + (["--synthetic", a.synthetic] if a.synthetic else []) \
        + (["--fresh"] if a.fresh else []) + (["--shuffle"] if a.shuffle else [])
    print(f"{time.strftime('%H:%M:%S')} launch on {socket.gethostname()}: Xid lines {x0}; {' '.join(cmd)}", flush=True)
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    last = None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if line.startswith("{"):
            try:
                last = json.loads(line)
            except Exception:
                pass
    rc = proc.wait()
    x1 = xid_count()
    res = dict(last or {})
    res.update({"host": socket.gethostname(), "rc": rc, "xid_start": x0, "xid_end": x1,
                "minutes": round((time.time() - t0) / 60, 1)})
    if x1 is None:
        res["verdict"] = "error"
        res["why"] = "Xid count unreadable after the run"
    elif x1 > x0:
        res["verdict"] = "xid"
        res["why"] = f"Xid lines {x0}->{x1}"
    elif res.get("verdict") is None:
        res["verdict"] = "error"
        res["why"] = f"replay exited rc={rc} with no verdict"
    print(json.dumps(res), flush=True)
    return 0 if res["verdict"] == "clean" else 1


# ---------------------------------------------------------------- GPU side

def cmd_replay(a) -> int:
    import torch
    import vllm._custom_ops as ops      # noqa: F401 -- registers torch.ops._C_cache_ops

    rng = random.Random(a.seed)
    lo, hi = parse_gap(a.gap_ms)
    dumps = [load_dump(p) for p in a.dumps]
    geo = geometry(dumps)
    host, gpu, host_new, gpu_new = {}, {}, {}, {}
    for t, (gb, hb) in sorted(geo.items()):
        h = torch.empty(hb, dtype=torch.uint8, pin_memory=True)
        g = torch.empty(gb, dtype=torch.uint8, device="cuda")
        gen = torch.Generator().manual_seed(a.seed * 1000 + t)
        h.copy_(torch.randint(0, 256, (hb,), dtype=torch.uint8, generator=gen))
        host[t], gpu[t] = h, g
        host_new[t], gpu_new[t] = h.data_ptr(), g.data_ptr()
    plans = []
    for d in dumps:
        if a.synthetic:
            d = synthesize(d, a.synthetic)
        if a.shuffle:
            dd_ = list(d["descriptors"])
            random.Random(a.seed).shuffle(dd_)
            d = dict(d, descriptors=dd_)
        if a.skip:
            d = dict(d, descriptors=d["descriptors"][a.skip:], n_descriptors=len(d["descriptors"]) - a.skip)
        if a.max_desc:
            d = dict(d, descriptors=d["descriptors"][:a.max_desc], n_descriptors=min(a.max_desc, len(d["descriptors"])))
        s, dd, n = rebase(d, host_new, gpu_new, geo)
        plans.append((torch.tensor(s, dtype=torch.int64), torch.tensor(dd, dtype=torch.int64),
                      torch.tensor(n, dtype=torch.int64),
                      [dict(zip(COLS, r)) for r in d["descriptors"]], d))
    torch.cuda.synchronize()
    print(f"{time.strftime('%H:%M:%S')} replay: {len(plans)} copies per job "
          f"({', '.join(str(len(p[3])) for p in plans)} descriptors), {len(geo)} tensors, "
          f"torch {torch.__version__} cuda {torch.version.cuda}, device {torch.cuda.get_device_name()}, "
          f"order={a.order}, gap {lo}-{hi} ms", flush=True)

    streams, events = [], []
    counts = {"any": 0, "stream": 0}
    t0 = time.time()

    def verify(plan) -> str | None:
        _, _, _, rows, d = plan
        T = d["tensors"]
        for r in rng.sample(rows, min(64, len(rows))):
            t = int(r["tensor"])
            so = int(r["src"]) - int(T[str(t)]["host_base"])
            do = int(r["dst"]) - int(T[str(t)]["gpu_alloc_base"])
            n = int(r["size"])
            if not torch.equal(gpu[t][do:do + n].cpu(), host[t][so:so + n]):
                return f"tensor {t} block {r['block']} slot {r['slot']}"
        return None

    try:
        return _jobs(a, plans, rng, lo, hi, streams, events, counts, t0, verify)
    except RuntimeError as e:          # an Xid surfaces here as a CUDA error
        print(json.dumps({"verdict": "cuda_error", "why": str(e)[:300], "jobs": counts["any"] + counts["stream"],
                          "counts": counts, "last_order_any": _STATE.get("any"),
                          "last_copy": _STATE.get("copy")}), flush=True)
        os._exit(5)                      # the context is poisoned; never sync


_STATE: dict = {}


def _jobs(a, plans, rng, lo, hi, streams, events, counts, t0, verify) -> int:
    import torch
    last_end = None
    for job in range(a.jobs):
        any_ = order_for(a.order, job)
        _STATE["any"] = any_
        counts["any" if any_ else "stream"] += 1
        for i, (bs, bd, bn, _, _) in enumerate(plans):
            _STATE["copy"] = i + 1
            if a.fresh:
                stream, start, end = torch.cuda.Stream(), torch.Event(enable_timing=True), torch.Event(enable_timing=True)
                last_end = None
            else:
                stream = streams.pop() if streams else torch.cuda.Stream()
                start = events.pop() if events else torch.Event(enable_timing=True)
                end = events.pop() if events else torch.Event(enable_timing=True)
            if last_end is not None:
                stream.wait_event(last_end)
            with torch.cuda.stream(stream):
                start.record(stream)
                if a.api == "batch":
                    torch.ops._C_cache_ops.swap_blocks_batch(bs, bd, bn, any_)
                else:
                    loop_copy(bs, bd, bn, stream)
                end.record(stream)
            t_sub = time.time()
            while not end.query():
                if time.time() - t_sub > a.stuck_s:
                    res = {"verdict": "hang", "why": f"job {job} copy {i + 1}/{len(plans)} open {a.stuck_s}s",
                           "jobs": job, "order_any": any_, "counts": counts}
                    print(json.dumps(res), flush=True)
                    os._exit(3)              # never sync on a wedged stream
                time.sleep(0.0005)
            streams.append(stream)
            events += [start, end]
            last_end = end
        if a.verify_every and (job + 1) % a.verify_every == 0:
            bad = verify(plans[rng.randrange(len(plans))])
            if bad:
                print(json.dumps({"verdict": "mismatch", "why": bad, "jobs": job + 1, "counts": counts}), flush=True)
                return 4
            print(f"{time.strftime('%H:%M:%S')} job {job + 1}/{a.jobs} ok, verified; "
                  f"any={counts['any']} stream={counts['stream']}", flush=True)
        time.sleep(rng.uniform(lo, hi) / 1000.0)
    print(json.dumps({"verdict": "clean", "jobs": a.jobs, "copies": a.jobs * len(plans), "counts": counts,
                      "replay_minutes": round((time.time() - t0) / 60, 1)}), flush=True)
    return 0


# ---------------------------------------------------------------- selftest

def selftest() -> int:
    fails = 0

    def ok(name, cond):
        nonlocal fails
        print(f"{'PASS' if cond else 'FAIL'}  {name}")
        fails += 0 if cond else 1

    def mk(desc, tensors=None):
        return {"kind": "load", "descriptor_cols": list(COLS), "n_descriptors": len(desc),
                "descriptors_kept": len(desc), "descriptors": desc, "n_blocks": 1, "_path": "t",
                "tensors": tensors or {"0": {"gpu_alloc_base": 1000, "gpu_alloc_bytes": 400,
                                             "host_base": 50, "host_stride": 10, "host_rows": 8}}}
    d = mk([[0, 0, 7, 2, 70, 1100, 10], [0, 0, 8, 3, 80, 1390, 10]])
    geo = geometry([d])
    ok("geometry = gpu bytes, host stride x rows", geo == {0: (400, 80)})
    s, dd, n = rebase(d, {0: 5000}, {0: 9000}, geo)
    ok("rebase keeps offsets", s == [5020, 5030] and dd == [9100, 9390] and n == [10, 10])
    for name, bad in (("dst past the end refused", [0, 0, 8, 3, 80, 1391, 10]),
                      ("dst before the base refused", [0, 0, 8, 3, 80, 999, 10]),
                      ("src past the end refused", [0, 0, 8, 3, 121, 1100, 10])):
        try:
            rebase(mk([bad]), {0: 0}, {0: 0}, geo)
            ok(name, False)
        except ValueError:
            ok(name, True)
    sy = synthesize(mk([[0, 0, 7, 2, 70, 1300, 10], [0, 0, 8, 3, 90, 1100, 10]]))
    sd = synthesize(mk([[0, 0, 7, 2, 70, 1300, 10]]), "dst")
    ok("synthetic dst keeps src", sd["descriptors"][0][4] == 70 and sd["descriptors"][0][5] == 1000)
    ok("synthetic packs from 0", [r[4] for r in sy["descriptors"]] == [50, 60]
       and [r[5] for r in sy["descriptors"]] == [1000, 1010])
    ok("order any", order_for("any", 1) is True)
    ok("order stream", order_for("stream", 0) is False)
    ok("order alt alternates", [order_for("alt", j) for j in range(4)] == [True, False, True, False])
    try:
        parse_gap("5:1")
        ok("gap lo>hi refused", False)
    except ValueError:
        ok("gap lo>hi refused", True)
    t = mk([[0, 0, 7, 2, 70, 1100, 10]])
    t["descriptors_kept"] = 0
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(t, f)
    try:
        load_dump(f.name)
        ok("truncated dump refused", False)
    except ValueError:
        ok("truncated dump refused", True)
    os.unlink(f.name)
    print(f"{'GREEN' if not fails else 'RED'}: {fails} failed")
    return 1 if fails else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("launch", "check", "replay"):
        p = sub.add_parser(name)
        p.add_argument("--dumps", nargs="+", required=True)
        p.add_argument("--jobs", type=int, default=5000)
        p.add_argument("--order", choices=("any", "stream", "alt"), default="alt")
        p.add_argument("--gap-ms", default="0:1500")
        p.add_argument("--stuck-s", type=float, default=10.0)
        p.add_argument("--verify-every", type=int, default=100)
        p.add_argument("--seed", type=int, default=20261015)
        p.add_argument("--max-desc", type=int, default=0, help="replay only the first N descriptors")
        p.add_argument("--api", choices=("batch", "loop"), default="batch",
                       help="batch = swap_blocks_batch (cuMemcpyBatchAsync); loop = one cudaMemcpyAsync each")
        p.add_argument("--synthetic", nargs="?", const="both", choices=("both", "src", "dst"), default=None,
                       help="same sizes and tensors, but sequential addresses from 0 on that side")
        p.add_argument("--shuffle", action="store_true", help="the same descriptors in a seeded random order")
        p.add_argument("--skip", type=int, default=0, help="drop the first N descriptors")
        p.add_argument("--fresh", action="store_true", help="a new stream and events per copy, no wait chain")
    a = ap.parse_args()
    return {"launch": cmd_launch, "check": cmd_check, "replay": cmd_replay}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

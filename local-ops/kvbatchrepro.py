#!/usr/bin/env python3
"""kvbatchrepro.py -- class B with NOTHING but libcuda: ctypes -> cuMemcpyBatchAsync.

    python3 local-ops/kvbatchrepro.py suite --dumps A.json [B.json] [--out F.jsonl]   # all arms
    python3 local-ops/kvbatchrepro.py run   --dumps A.json [B.json] --mode batch ...   # one arm
    python3 local-ops/kvbatchrepro.py --selftest                                      # offline

CLASS: ACTUATOR -- RAW GPU COPIES ON THE HOST; a reproduction is an Xid on this
node. REFUSES while the DSpark engine container exists (it needs the engine
DOWN: planned restart, hold file, ask first). Runs on the HOST's python3 and the
host's libcuda.so.1 -- no Docker, no torch, no vLLM -- so a fault here belongs
to the driver. This is the artefact for an NVIDIA report.

WHY. kvcopyreplay.py (2026-10-15) reproduced class B in seconds through vLLM's
`swap_blocks_batch` op, and the same descriptors one copy at a time never
faulted. This removes the op and torch, and answers what the research left open:

  --idx scalar|array   vLLM passes attrsIdxs as ONE entry (numAttrs=1), which
                       cuda.h says is correct; vllm PRs #53971/#53860 claim the
                       driver reads `count` entries. `array` passes `count`
                       zeros. If that alone stops the faults, the driver reads
                       past numAttrs.
  --abi 12080|13000    the 12.8 entry point vLLM resolves (with failIdx) vs the
                       CUDA 13 `_v2` one (without).
  --order any|stream|during   CUmemcpyAttributes.srcAccessOrder.
  --flags 0|1          1 = CU_MEMCPY_FLAG_PREFER_OVERLAP_WITH_COMPUTE.
  --mode batch|chunk|loop   one call for the whole copy | calls of --chunk K |
                       one cuMemcpyAsync per descriptor (the kvmgr ask9 idea).

Mirrors upstream's transfer: one non-blocking stream, timing events around each
copy, the next copy waiting on the previous end event, completion POLLED
(cuEventQuery), never synchronised -- a copy open past --stuck-s is a HANG.
Destinations are sampled and compared with the host bytes every --verify-every
jobs, and the per-copy GPU time (cuEventElapsedTime) is reported, so the
mitigation's cost is measured, not guessed.
"""

from __future__ import annotations

import argparse
import ctypes as C
import importlib.util
import json
import os
import random
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("kvcopyreplay", os.path.join(HERE, "kvcopyreplay.py"))
kcr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kcr)          # pure helpers only; its main() is guarded

ORDER = {"stream": 1, "during": 2, "any": 3}
NOT_READY = 600


class Loc(C.Structure):
    _fields_ = [("type", C.c_int), ("id", C.c_int)]


class Attr(C.Structure):               # CUmemcpyAttributes_v1, cuda.h 4574
    _fields_ = [("srcAccessOrder", C.c_int), ("srcLocHint", Loc), ("dstLocHint", Loc), ("flags", C.c_uint)]


# ---------------------------------------------------------------- pure part

def chunks(n: int, k: int):
    """[(start, count)] covering 0..n in order, each count <= k (k<=0: one)."""
    if k <= 0 or k >= n:
        return [(0, n)]
    return [(i, min(k, n - i)) for i in range(0, n, k)]


ARMS = [
    # (label, reps, jobs, extra args). Rate through raw libcuda is ~1 per 1-250 jobs of
    # this content, so a clean arm needs >=1,000 jobs to mean anything.
    ("vllm-exact batch idx=scalar order=any abi=12080", 3, 1000, ["--mode", "batch"]),
    ("batch idx=ARRAY (PR #53971 claim)", 3, 1000, ["--mode", "batch", "--idx", "array"]),
    ("batch order=stream", 2, 1000, ["--mode", "batch", "--order", "stream"]),
    ("batch order=during", 1, 1000, ["--mode", "batch", "--order", "during"]),
    ("batch abi=13000 (_v2)", 2, 1000, ["--mode", "batch", "--abi", "13000"]),
    ("batch flags=PREFER_OVERLAP_WITH_COMPUTE", 1, 1000, ["--mode", "batch", "--flags", "1"]),
    ("chunk 1024", 2, 2000, ["--mode", "chunk", "--chunk", "1024"]),
    ("chunk 256", 2, 2000, ["--mode", "chunk", "--chunk", "256"]),
    ("chunk 64", 2, 2000, ["--mode", "chunk", "--chunk", "64"]),
    ("chunk 1 (batch API, one descriptor per call)", 1, 1000, ["--mode", "chunk", "--chunk", "1"]),
    ("loop cuMemcpyAsync (ask9)", 2, 3000, ["--mode", "loop"]),
    ("vllm-exact again (still faulting?)", 2, 1000, ["--mode", "batch"]),
]


# ---------------------------------------------------------------- GPU side

def _cu():
    lib = C.CDLL("libcuda.so.1")

    def ck(rc, what):
        if rc:
            raise RuntimeError(f"{what} -> CUresult {rc}")
    return lib, ck


def cmd_run(a) -> int:
    lib, ck = _cu()
    rng = random.Random(a.seed)
    dumps = [kcr.load_dump(p) for p in a.dumps]
    geo = kcr.geometry(dumps)

    ck(lib.cuInit(0), "cuInit")
    dev = C.c_int()
    ck(lib.cuDeviceGet(C.byref(dev), 0), "cuDeviceGet")
    ctx = C.c_void_p()
    ck(lib.cuDevicePrimaryCtxRetain(C.byref(ctx), dev), "cuDevicePrimaryCtxRetain")
    ck(lib.cuCtxSetCurrent(ctx), "cuCtxSetCurrent")
    ver = C.c_int()
    lib.cuDriverGetVersion(C.byref(ver))

    host, gpu = {}, {}
    for t, (gb, hb) in sorted(geo.items()):
        d = C.c_uint64()
        ck(lib.cuMemAlloc_v2(C.byref(d), C.c_size_t(gb)), f"cuMemAlloc {gb}")
        h = C.c_void_p()
        ck(lib.cuMemHostAlloc(C.byref(h), C.c_size_t(hb), C.c_uint(a.host_flags)), f"cuMemHostAlloc {hb}")
        C.memmove(h, random.Random(a.seed * 1000 + t).randbytes(hb), hb)
        host[t], gpu[t] = h.value, d.value

    plans = []
    for d in dumps:
        s, dd, n = kcr.rebase(d, host, gpu, geo)
        cnt = len(s)
        plans.append({"n": cnt, "src": (C.c_uint64 * cnt)(*s), "dst": (C.c_uint64 * cnt)(*dd),
                      "size": (C.c_size_t * cnt)(*n), "rows": d["descriptors"], "d": d})

    attr = Attr(ORDER[a.order], Loc(0, 0), Loc(0, 0), a.flags)
    fail = C.c_size_t(0)
    fnp = C.c_void_p()
    st = C.c_int()
    ck(lib.cuGetProcAddress_v2(b"cuMemcpyBatchAsync", C.byref(fnp), a.abi, C.c_uint64(0), C.byref(st)),
       "cuGetProcAddress")
    if not fnp.value:
        raise RuntimeError(f"cuMemcpyBatchAsync not resolved at abi {a.abi} (status {st.value})")
    if a.abi >= 13000:
        batch = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p, C.c_void_p, C.c_size_t, C.c_void_p,
                            C.c_void_p, C.c_size_t, C.c_void_p)(fnp.value)
    else:
        batch = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p, C.c_void_p, C.c_size_t, C.c_void_p,
                            C.c_void_p, C.c_size_t, C.c_void_p, C.c_void_p)(fnp.value)
    maxn = max(p["n"] for p in plans)
    idx_scalar = C.c_size_t(0)
    idx_array = (C.c_size_t * maxn)()

    def submit(p, stream):
        if a.mode == "loop":
            for i in range(p["n"]):
                rc = lib.cuMemcpyAsync(C.c_uint64(p["dst"][i]), C.c_uint64(p["src"][i]), C.c_size_t(p["size"][i]), stream)
                if rc:
                    return rc, i
            return 0, None
        k = a.chunk if a.mode == "chunk" else 0
        base_s, base_d, base_n = C.addressof(p["src"]), C.addressof(p["dst"]), C.addressof(p["size"])
        for off, cnt in chunks(p["n"], k):
            idx = C.addressof(idx_array) if a.idx == "array" else C.addressof(idx_scalar)
            args = [base_d + 8 * off, base_s + 8 * off, base_n + 8 * off, cnt, C.addressof(attr), idx, 1]
            rc = batch(*args, C.addressof(fail), stream) if a.abi < 13000 else batch(*args, stream)
            if rc:
                return rc, off + fail.value
        return 0, None

    stream = C.c_void_p()
    ck(lib.cuStreamCreate(C.byref(stream), 1), "cuStreamCreate")        # CU_STREAM_NON_BLOCKING, like torch
    evs = []
    for _ in range(2 * len(plans)):
        e = C.c_void_p()
        ck(lib.cuEventCreate(C.byref(e), 0), "cuEventCreate")          # timing on, like torch.Event(enable_timing=True)
        evs.append(e)

    print(f"{time.strftime('%H:%M:%S')} kvbatchrepro {socket.gethostname()}: driver {ver.value}, "
          f"{len(plans)} copies/job ({', '.join(str(p['n']) for p in plans)} desc), mode={a.mode}"
          f"{' chunk=' + str(a.chunk) if a.mode == 'chunk' else ''} idx={a.idx} order={a.order} "
          f"abi={a.abi} flags={a.flags} host_flags={a.host_flags}", flush=True)

    gpu_ms, sub_ms, last_end = [], [], None
    t0 = time.time()
    for job in range(a.jobs):
        for i, p in enumerate(plans):
            start, end = evs[2 * i], evs[2 * i + 1]
            if last_end is not None:
                ck(lib.cuStreamWaitEvent(stream, last_end, 0), "cuStreamWaitEvent")
            ck(lib.cuEventRecord(start, stream), "cuEventRecord")
            ts = time.perf_counter()
            rc, at = submit(p, stream)
            sub_ms.append((time.perf_counter() - ts) * 1000)
            if rc:
                print(json.dumps({"verdict": "api_error", "rc": rc, "at": at, "jobs": job, "copy": i + 1}), flush=True)
                os._exit(6)
            ck(lib.cuEventRecord(end, stream), "cuEventRecord")
            tq = time.time()
            while True:
                q = lib.cuEventQuery(end)
                if q == 0:
                    break
                if q != NOT_READY:
                    print(json.dumps({"verdict": "cuda_error", "rc": q, "jobs": job, "copy": i + 1}), flush=True)
                    os._exit(5)                                          # context poisoned; never sync
                if time.time() - tq > a.stuck_s:
                    print(json.dumps({"verdict": "hang", "jobs": job, "copy": i + 1}), flush=True)
                    os._exit(3)
                time.sleep(0.0002)
            ms = C.c_float()
            if lib.cuEventElapsedTime(C.byref(ms), start, end) == 0:
                gpu_ms.append(ms.value)
            last_end = end
        if a.verify_every and (job + 1) % a.verify_every == 0:
            p = plans[rng.randrange(len(plans))]
            T = p["d"]["tensors"]
            for r in rng.sample(p["rows"], min(64, len(p["rows"]))):
                r = dict(zip(kcr.COLS, r))
                t, n = int(r["tensor"]), int(r["size"])
                do = int(r["dst"]) - int(T[str(t)]["gpu_alloc_base"])
                so = int(r["src"]) - int(T[str(t)]["host_base"])
                buf = C.create_string_buffer(n)
                ck(lib.cuMemcpyDtoH_v2(buf, C.c_uint64(gpu[t] + do), C.c_size_t(n)), "cuMemcpyDtoH")
                if buf.raw != C.string_at(host[t] + so, n):
                    print(json.dumps({"verdict": "mismatch", "jobs": job + 1, "tensor": t, "block": r["block"]}), flush=True)
                    return 4
        if a.gap_ms:
            time.sleep(a.gap_ms / 1000.0)

    def p50(xs):
        return round(sorted(xs)[len(xs) // 2], 3) if xs else None
    print(json.dumps({"verdict": "clean", "jobs": a.jobs, "copies": a.jobs * len(plans),
                      "gpu_ms_p50": p50(gpu_ms), "submit_ms_p50": p50(sub_ms),
                      "wall_s": round(time.time() - t0, 1)}), flush=True)
    return 0


# ---------------------------------------------------------------- host side

def engine_present():
    out = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return any("dspark" in n for n in out.stdout.split())


def one(a, extra, jobs):
    x0 = kcr.xid_count()
    cmd = [sys.executable, "-u", os.path.abspath(__file__), "run", "--dumps", *a.dumps,
           "--jobs", str(jobs), "--stuck-s", str(a.stuck_s), "--seed", str(a.seed), *extra]
    t0 = time.time()
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=a.arm_timeout_s)
        text, rc = out.stdout + out.stderr, out.returncode
    except subprocess.TimeoutExpired as e:
        text, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout"
    x1 = kcr.xid_count()
    res = {}
    for line in text.splitlines():
        if line.startswith("{"):
            try:
                res = json.loads(line)
            except Exception:
                pass
    if not res and rc != 0:
        res = {"verdict": "error", "tail": text.strip().splitlines()[-3:]}
    if x0 is None or x1 is None:
        res["verdict"] = "error"
        res["why"] = "Xid count unreadable"
    elif x1 > x0:
        res["xid_seen"] = res.get("verdict")
        res["verdict"] = "xid"
    res.update({"rc": rc, "xid": [x0, x1], "secs": round(time.time() - t0, 1)})
    return res


def cmd_suite(a) -> int:
    p = engine_present()
    if p is None or p:
        print(f"REFUSED: engine container {'present' if p else 'state unreadable'} -- needs the engine DOWN", flush=True)
        return 2
    kcr.cmd_check(a)
    log = open(a.out, "a") if a.out else None
    for label, reps, jobs, extra in ARMS:
        if a.only and not any(s in label for s in a.only):
            continue
        for r in range(reps):
            res = one(a, extra, jobs)
            res.update({"arm": label, "rep": r + 1, "host": socket.gethostname(), "ts": time.strftime("%H:%M:%S")})
            print(f"{res['ts']} [{label}] #{r + 1}: {res['verdict']} jobs={res.get('jobs')} copy={res.get('copy')} "
                  f"gpu_ms_p50={res.get('gpu_ms_p50')} submit_ms_p50={res.get('submit_ms_p50')} "
                  f"xid {res['xid'][0]}->{res['xid'][1]} ({res['secs']}s)", flush=True)
            if log:
                log.write(json.dumps(res) + "\n")
                log.flush()
    return 0


def selftest() -> int:
    fails = 0

    def ok(name, cond):
        nonlocal fails
        print(f"{'PASS' if cond else 'FAIL'}  {name}")
        fails += 0 if cond else 1
    ok("chunks covers in order", chunks(10, 4) == [(0, 4), (4, 4), (8, 2)])
    ok("chunks k>=n is one call", chunks(10, 10) == [(0, 10)] and chunks(10, 0) == [(0, 10)])
    ok("chunks k=1", chunks(3, 1) == [(0, 1), (1, 1), (2, 1)])
    ok("chunks sum to n", sum(c for _, c in chunks(2046, 256)) == 2046)
    ok("Attr is 24 bytes like CUmemcpyAttributes_v1", C.sizeof(Attr) == 24)
    ok("Attr field offsets 0/4/12/20", (Attr.srcAccessOrder.offset, Attr.srcLocHint.offset,
                                         Attr.dstLocHint.offset, Attr.flags.offset) == (0, 4, 12, 20))
    ok("order values from cuda.h (4537-4541)", (ORDER["stream"], ORDER["during"], ORDER["any"]) == (1, 2, 3))
    ok("every arm parses", all(isinstance(r, int) and isinstance(j, int) for _, r, j, _ in ARMS))
    print(f"{'GREEN' if not fails else 'RED'}: {fails} failed")
    return 1 if fails else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "suite"):
        p = sub.add_parser(name)
        p.add_argument("--dumps", nargs="+", required=True)
        p.add_argument("--jobs", type=int, default=300)
        p.add_argument("--mode", choices=("batch", "chunk", "loop"), default="batch")
        p.add_argument("--chunk", type=int, default=256)
        p.add_argument("--idx", choices=("scalar", "array"), default="scalar")
        p.add_argument("--order", choices=tuple(ORDER), default="any")
        p.add_argument("--abi", type=int, default=12080)
        p.add_argument("--flags", type=int, default=0)
        p.add_argument("--host-flags", type=int, default=0, help="cuMemHostAlloc flags (torch pins with 0)")
        p.add_argument("--gap-ms", type=float, default=0.0)
        p.add_argument("--stuck-s", type=float, default=10.0)
        p.add_argument("--verify-every", type=int, default=100)
        p.add_argument("--seed", type=int, default=20261015)
        p.add_argument("--out", default=None)
        p.add_argument("--only", nargs="*", default=None, help="suite: run only arms whose label contains one of these")
        p.add_argument("--arm-timeout-s", type=float, default=600)
    a = ap.parse_args()
    return {"run": cmd_run, "suite": cmd_suite}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

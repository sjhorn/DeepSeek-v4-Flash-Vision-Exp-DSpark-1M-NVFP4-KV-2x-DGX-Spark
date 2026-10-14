#!/usr/bin/env python3
"""kvrace.py -- reproduce the 2026-10-14 load Xid/wedge ON DEMAND: disk restores under live compute.

    python3 local-ops/kvrace.py build [--n 30] [--tokens 100000]
    python3 local-ops/kvrace.py run   [--loads 1000] [--arm on|off|asis] [--decoders 3]
    python3 local-ops/kvrace.py status
    python3 local-ops/kvrace.py --selftest          # offline, against a fake engine

CLASS: ACTUATOR. `build` and `run` saturate the engine; `run` sets the hot knob
`load_wait_compute` for its arm (and restores the previous value at the end); an
arm that reproduces the fault KILLS OR WEDGES THE ENGINE, after which the
supervisor recovers it (~15 min). Ask before running it. Run on the HEAD.
It is deliberately NOT in the supervisor's actuator-hold list: when it causes a
crash, the supervisor's restart is the intended recovery, and this script stops
at the first incident rather than sending more traffic into a dead engine.

WHY. Every one of the day's six incidents (5 x Xid 32, 1 wedge) was a disk->GPU
load into group 0, at a measured ~1 per 143 loads -- but traffic decides when
loads happen, so every hypothesis cost hours and an outage. The boot self-test
(kvmgr v0.4.2) proved the failing copies complete byte-exact on an IDLE GPU, so
the trigger needs live compute alongside the load. This makes both on purpose:
  - build: N distinct synthetic prefixes (nonce FIRST, so no two share a token),
    totalling more than group 0's GPU capacity (~2.1M tokens), cold-prefilled
    once so the disk tier stores them.
  - run: D decode streams keep compute busy while the pool is visited in order.
    Cycling through more than the cache holds makes every visit an LRU miss, so
    every visit is a disk restore: ~24 group-0 loads per 100K-token prefix.
  - it counts loads from the kvmgr ledger, and STOPS at the first incident:
    an Xid on either node, a non-200 response, an open load older than
    --stuck-s, a request slower than --slow-s, or the engine not answering.

Statistics, for reading a clean run: at the day's base rate (1 per 143 loads),
P(no incident in 1,000 loads) = exp(-1000/143) ~ 0.1%. An arm that is clean for
1,000 loads is strong evidence; an arm that fails is a reproduction.

Traps carried in, each from this repo's CLAUDE.md:
  - an HTTP status is CHECKED, never `-o /dev/null` (a 400 once read as a result);
  - prompt_tokens is CHECKED against the target -- token count is a property of
    the vocabulary, not the byte count (5.11 chars/token for this filler);
  - the Xid count is read on BOTH nodes, and an unreadable count is an ERROR,
    not a zero (`grep -c ... || echo 0` prints two zeros);
  - a run that cannot create its condition (no restores seen) REFUSES to report
    a clean verdict rather than printing a plausible number.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

API = os.environ.get("KVRACE_API", "http://127.0.0.1:8888")
HOME = os.path.expanduser("~")
DIR = os.environ.get("KVRACE_DIR", os.path.join(HOME, "kvdiag", "kvrace"))
LEDGER = os.environ.get("KVRACE_LEDGER", "/home/shorn/kvoffload/diag/ledger-r0.jsonl")
MODEL = os.environ.get("KVRACE_MODEL", "claude-opus-5")
CHARS_PER_TOKEN = 5.11          # measured for FILLER (kvscale.sh)
FILLER = "alpha beta gamma delta epsilon zeta eta theta "
# *** NOT a constant, and the first version's was wrong. *** It assumed 2,097,152
# (group 0's manager cap from CLAUDE.md), built a 3.0M-token pool, and the first
# live run restored all 30 prefixes once and then hit the GPU on every revisit:
# the engine's actual KV cache is 3,377,409 tokens ("GPU KV cache size" in its
# boot log). The run stopped creating its condition after one pass. The pool
# must exceed the REAL capacity, so it is read from the engine each time.
GROUP0_CAP_TOKENS = None        # set by kv_capacity_tokens(); the selftest overrides it
POOL_OVER_CAP = 1.5             # pool >= 1.5x capacity, so other users' prefixes cannot make it fit
ENGINE_TAG = "dspark-vllm-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1"


def kv_capacity_tokens():
    """The engine's GPU KV cache size in tokens, from its most recent boot log
    line; None if it cannot be read (and then build/run refuse)."""
    if GROUP0_CAP_TOKENS is not None:
        return GROUP0_CAP_TOKENS
    try:
        out = subprocess.run(["bash", "-c", f"journalctl -a -t {ENGINE_TAG} --since=-24h --no-pager -o cat "
                              "| grep -o 'GPU KV cache size: [0-9,]* tokens' | tail -1"],
                             capture_output=True, text=True, timeout=60).stdout
        return int(out.split(":")[1].split("tokens")[0].replace(",", "").strip())
    except Exception:
        return None


# ---------------------------------------------------------------- pure parts
def body(i: int, tokens: int) -> dict:
    """Prefix i. The nonce is the FIRST thing in the prompt, so no two pool
    members share even one block, and it is fixed, so a body is byte-identical
    across builds and runs (same block hashes, so the disk tier can serve it)."""
    n = int(tokens * CHARS_PER_TOKEN)
    text = f"kvrace-pool-{i:03d} " + (FILLER * (n // len(FILLER) + 2))[:n]
    return {"model": MODEL, "max_tokens": 1,
            "messages": [{"role": "user", "content": text}]}


def tokens_ok(got, want: int, tol: float = 0.10) -> bool:
    try:
        return abs(int(got) - want) <= tol * want
    except (TypeError, ValueError):
        return False


def verdict(*, loads: int, target: int, xid0: tuple, xid: tuple, last_status,
            open_load_age, stuck_s: float, slow, slow_s: float, restores_seen: int,
            visits: int, visits_since_restore: int = 0, pool: int = 30) -> tuple[str, str]:
    """(state, why). state: continue | clean | xid | stuck | slow | http | unreadable | nocondition.
    Order matters: an incident outranks reaching the target in the same tick."""
    if xid is None or xid0 is None or None in xid or None in xid0:
        return "unreadable", "an Xid count could not be read on one node -- refusing to call it clean"
    if xid[0] > xid0[0] or xid[1] > xid0[1]:
        return "xid", f"Xid lines head {xid0[0]}->{xid[0]}, worker {xid0[1]}->{xid[1]}"
    if open_load_age is not None and open_load_age >= stuck_s:
        return "stuck", f"a load has been open {open_load_age:.0f}s (>= {stuck_s:.0f}s): wedge"
    if last_status is not None and last_status != 200:
        return "http", f"a request returned HTTP {last_status}"
    if slow is not None and slow >= slow_s:
        return "slow", f"a restore request took {slow:.0f}s (>= {slow_s:.0f}s)"
    if loads >= target:
        if restores_seen == 0:
            return "nocondition", "target reached but no restore was observed -- the run did not create its condition"
        return "clean", f"{loads} loads with no incident"
    if visits >= 2 * pool and restores_seen == 0:
        return "nocondition", f"{visits} visits and no loads -- the pool is not being restored (still on GPU?)"
    # *** RESTORES THAT STOP are the same failure, later. *** The first live run
    # restored the whole pool once, then a full pass added +0 loads -- the pool
    # fit in the GPU -- and this check did not exist, so it would have looped
    # for ever reporting nothing. A full pass with no restore ends the run.
    if visits_since_restore >= pool:
        return "nocondition", (f"{visits_since_restore} visits (a full pass of the pool) without a restore -- "
                               "the pool fits in the GPU cache; build a larger one")
    return "continue", ""


class Ledger:
    """Tail the kvmgr ledger from a starting offset: count load submits, track
    the oldest still-open load. Keyed on (boot, inner)."""

    def __init__(self, path: str):
        self.path = path
        self.pos = os.path.getsize(path) if os.path.exists(path) else 0
        self.loads = 0
        self.g0 = 0
        self.wait_true = self.wait_false = self.wait_none = 0
        self.open: dict = {}

    def poll(self) -> None:
        if not os.path.exists(self.path):
            return
        size = os.path.getsize(self.path)
        if size < self.pos:          # rotated
            self.pos = 0
        with open(self.path) as f:
            f.seek(self.pos)
            for ln in f:
                if not ln.endswith("\n"):
                    break            # a torn line: read it next time
                self.pos += len(ln.encode())
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if r.get("kind") != "load":
                    continue
                k = (r.get("boot") or ("pid", r.get("pid")), r.get("inner"))
                if r.get("ev") == "submit":
                    self.loads += 1
                    self.g0 += 1 if r.get("group") == 0 else 0
                    w = r.get("wait_compute")
                    if w is True:
                        self.wait_true += 1
                    elif w is False:
                        self.wait_false += 1
                    else:
                        self.wait_none += 1
                    self.open[k] = r.get("ts", time.time())
                elif r.get("ev") == "done":
                    self.open.pop(k, None)

    def oldest_open_age(self):
        return (time.time() - min(self.open.values())) if self.open else None


# ---------------------------------------------------------------- side effects
def post(path: str, payload: dict, timeout: float):
    """(status, json|None, seconds). Never raises; a dead engine is a status."""
    t = time.time()
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null"), time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, None, time.time() - t
    except Exception:
        return 0, None, time.time() - t       # 0 = no answer at all


def get(path: str, timeout: float = 20):
    try:
        with urllib.request.urlopen(API + path, timeout=timeout) as r:
            return json.loads(r.read())
    except Exception:
        return None


def xid_counts():
    """(head, worker) Xid line counts, or None for a node that cannot be read.
    Overridable for the selftest via KVRACE_FAKE_XID=<file with 'h w'>."""
    fake = os.environ.get("KVRACE_FAKE_XID")
    if fake:
        try:
            h, w = open(fake).read().split()
            return int(h), int(w)
        except Exception:
            return None, None

    def count(cmd):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if out.returncode not in (0, 1):     # grep -c exits 1 on zero: that IS a count
                return None
            return int(out.stdout.strip().splitlines()[-1])
        except Exception:
            return None
    head = count(["bash", "-c", "journalctl -k --no-pager | grep -c Xid"])
    worker = count(["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                    os.environ.get("WORKER_HOST", "192.168.0.101"),
                    "journalctl -k --no-pager | grep -c Xid"])
    return head, worker


def knob_values(name: str):
    d = get("/kv/workers")
    if not d or "ranks" not in d:
        return None
    return [((r.get("knobs") or {}).get(name)) for r in d["ranks"]]


def set_knob(name: str, value) -> bool:
    st, _, _ = post("/kv/knob", {"name": name, "value": str(value)}, 60)
    vals = knob_values(name)
    return st == 200 and vals is not None and all(str(int(v)) == str(value) for v in vals if v is not None) \
        and len(vals) >= 1 and None not in vals


def log(fp, msg: str) -> None:
    line = time.strftime("%H:%M:%S ", time.gmtime()) + msg
    print(line, flush=True)
    fp.write(line + "\n"); fp.flush()


# ---------------------------------------------------------------- commands
def cmd_build(a) -> int:
    os.makedirs(os.path.join(DIR, "bodies"), exist_ok=True)
    total = a.n * a.tokens
    fp = open(os.path.join(DIR, "build.log"), "a")
    cap = kv_capacity_tokens()
    if cap is None:
        log(fp, "REFUSING: cannot read the engine's GPU KV cache size from its log"); return 2
    log(fp, f"build: {a.n} prefixes x {a.tokens} tokens = {total:,} (engine GPU KV cache {cap:,} tokens)")
    if total < cap * POOL_OVER_CAP:
        need = int(cap * POOL_OVER_CAP / a.tokens) + 1
        log(fp, f"REFUSING: the pool must be >= {POOL_OVER_CAP}x the GPU cache or revisits hit the GPU, "
                f"not disk -- use --n {need} or more")
        return 2
    meta = {"n": a.n, "tokens": a.tokens, "prefixes": []}
    for i in range(a.n):
        b = body(i, a.tokens)
        p = os.path.join(DIR, "bodies", f"p{i:03d}.json")
        json.dump(b, open(p, "w"))
        st, js, sec = post("/v1/chat/completions", b, a.timeout)
        pt = ((js or {}).get("usage") or {}).get("prompt_tokens")
        ok = st == 200 and tokens_ok(pt, a.tokens)
        log(fp, f"  p{i:03d}: HTTP {st}, prompt_tokens {pt}, {sec:.1f}s {'ok' if ok else '*** FAILED ***'}")
        if not ok:
            log(fp, "REFUSING to continue: a pool member that did not prefill at its size is not a pool member")
            return 3
        meta["prefixes"].append({"i": i, "prompt_tokens": pt, "build_s": round(sec, 1)})
    json.dump(meta, open(os.path.join(DIR, "pool.json"), "w"), indent=1)
    log(fp, f"build done: {a.n} prefixes stored. Give the store path a minute to flush before `run`.")
    return 0


def cmd_run(a) -> int:
    meta_p = os.path.join(DIR, "pool.json")
    if not os.path.exists(meta_p):
        print("REFUSING: no pool -- run `build` first"); return 2
    meta = json.load(open(meta_p))
    bodies = [json.load(open(os.path.join(DIR, "bodies", f"p{p['i']:03d}.json"))) for p in meta["prefixes"]]
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = os.path.join(DIR, f"run-{ts}-{a.arm}")
    os.makedirs(out, exist_ok=True)
    fp = open(os.path.join(out, "run.log"), "w")

    st, _, _ = post("/v1/chat/completions", {"model": MODEL, "max_tokens": 1,
                    "messages": [{"role": "user", "content": "x"}]}, 120)
    if st != 200:
        log(fp, f"REFUSING: engine not answering (HTTP {st})"); return 2
    xid0 = xid_counts()
    if None in xid0:
        log(fp, f"REFUSING: Xid count unreadable at start {xid0}"); return 2
    prev = knob_values("load_wait_compute")
    if prev is None:
        log(fp, "REFUSING: /kv/workers unreadable -- cannot set or verify the arm"); return 2
    if a.arm in ("on", "off"):
        want = 1 if a.arm == "on" else 0
        if not set_knob("load_wait_compute", want):
            log(fp, f"REFUSING: could not set load_wait_compute={want} on every rank (read {knob_values('load_wait_compute')})")
            return 2
    arm_vals = knob_values("load_wait_compute")
    log(fp, f"run: arm={a.arm} load_wait_compute per rank {arm_vals} (was {prev}); target {a.loads} loads; "
            f"{len(bodies)} pool x {meta['tokens']} tokens; {a.decoders} decoders; Xid head={xid0[0]} worker={xid0[1]}")

    led = Ledger(a.ledger)
    stop = threading.Event()
    dec_stats = {"n": 0, "bad": 0}

    def decoder(k: int) -> None:
        it = 0
        while not stop.is_set():
            it += 1
            st, _, _ = post("/v1/chat/completions", {"model": MODEL, "max_tokens": a.decode_tokens,
                            "messages": [{"role": "user", "content":
                                          f"kvrace decoder {k}.{it} {random.random()}: count upward from 1, one number per line, forever."}]},
                            a.slow_s + 60)
            dec_stats["n"] += 1
            if st != 200:
                dec_stats["bad"] += 1
                if not stop.is_set():
                    time.sleep(2)
    threads = [threading.Thread(target=decoder, args=(k,), daemon=True) for k in range(a.decoders)]
    for t in threads:
        t.start()
    time.sleep(3)

    cap = kv_capacity_tokens()
    pool_tokens = len(bodies) * meta["tokens"]
    if cap is not None and pool_tokens < cap * POOL_OVER_CAP and getattr(a, "allow_small_pool", False):
        log(fp, f"NOTE: pool {pool_tokens:,} tokens < {POOL_OVER_CAP}x the GPU cache ({cap:,}); running anyway "
                "(--allow-small-pool: other traffic is expected to hold enough of the cache). The "
                "restores-stopped check ends the run if revisits start hitting the GPU.")
    elif cap is None or pool_tokens < cap * POOL_OVER_CAP:
        log(fp, f"REFUSING: pool {pool_tokens:,} tokens vs GPU KV cache {cap} -- must be >= {POOL_OVER_CAP}x; "
                "rebuild with a larger --n")
        stop.set()
        if a.arm in ("on", "off") and prev and prev[0] is not None:
            set_knob("load_wait_compute", prev[0])
        return 2
    visits = restores = since_restore = 0
    state, why = "continue", ""
    walls = []
    t0 = time.time()
    try:
        while state == "continue":
            b = bodies[visits % len(bodies)]
            before = led.loads
            st, js, sec = post("/v1/chat/completions", b, a.slow_s + 60)
            visits += 1
            led.poll()
            got = led.loads - before
            if got > 0:
                restores += 1
                since_restore = 0
                walls.append(sec)
            else:
                since_restore += 1
            if visits % 10 == 0 or st != 200:
                log(fp, f"  visit {visits}: HTTP {st} {sec:.1f}s, +{got} loads (total {led.loads}, g0 {led.g0}), "
                        f"restores {restores}, decoders ok/bad {dec_stats['n']-dec_stats['bad']}/{dec_stats['bad']}")
            state, why = verdict(loads=led.loads, target=a.loads, xid0=xid0, xid=xid_counts(),
                                 last_status=st, open_load_age=led.oldest_open_age(), stuck_s=a.stuck_s,
                                 slow=sec, slow_s=a.slow_s, restores_seen=restores, visits=visits,
                                 visits_since_restore=since_restore, pool=len(bodies))
    finally:
        stop.set()
        restored = None
        if a.arm in ("on", "off") and state not in ("xid", "stuck"):
            # put the knob back -- unless the engine is dead or wedged, where a
            # POST would hang or mean nothing; the boot default restores it
            restored = set_knob("load_wait_compute", prev[0]) if prev and prev[0] is not None else None
        walls.sort()
        res = {"arm": a.arm, "arm_values": arm_vals, "verdict": state, "why": why,
               "loads": led.loads, "group0_loads": led.g0, "visits": visits, "restores": restores,
               "wait_compute": {"true": led.wait_true, "false": led.wait_false, "unknown": led.wait_none},
               "restore_wall_p50_s": walls[len(walls)//2] if walls else None,
               "minutes": round((time.time()-t0)/60, 1), "xid_start": xid0, "xid_end": xid_counts(),
               "decoders": dec_stats, "knob_restored": restored, "prev_knob": prev}
        json.dump(res, open(os.path.join(out, "result.json"), "w"), indent=1)
        log(fp, f"VERDICT {state.upper()}: {why}")
        log(fp, json.dumps(res))
        if state in ("xid", "stuck"):
            log(fp, "The engine is likely dead or wedged; the supervisor recovers it (crash path, or "
                    "wedge capture then NCCL's ~11 min timeout). Evidence: ~/kvdiag/supervisor/, ~/kvdiag/wedge-*/")
    return {"clean": 0, "xid": 10, "stuck": 11, "http": 12, "slow": 13}.get(state, 2)


def cmd_status(a) -> int:
    p = os.path.join(DIR, "pool.json")
    print("pool:", json.load(open(p)) if os.path.exists(p) else "none (run build)")
    runs = sorted(d for d in os.listdir(DIR) if d.startswith("run-")) if os.path.isdir(DIR) else []
    for d in runs[-6:]:
        r = os.path.join(DIR, d, "result.json")
        if os.path.exists(r):
            j = json.load(open(r))
            print(f"  {d}: {j['verdict']} -- {j['loads']} loads ({j['group0_loads']} g0), {j['restores']} restores, "
                  f"wait_compute {j['wait_compute']}, {j['why']}")
    return 0


# ---------------------------------------------------------------- selftest
def selftest() -> int:
    """The whole tool against a fake engine, fake ledger and fake Xid counts."""
    import http.server
    import tempfile

    T = 0

    def eq(name, got, want):
        nonlocal T
        ok = got == want
        T |= not ok
        print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"  got {got!r} want {want!r}"))

    # ---- pure verdict. Called through v() so a guard whose removal makes verdict
    # RAISE fails a named check instead of aborting the suite (a mutation that
    # aborts detects the bug while saying nothing about it).
    def v(**kw):
        try:
            return verdict(**kw)
        except Exception as e:
            return ("EXC:" + type(e).__name__, str(e))

    base = dict(loads=10, target=100, xid0=(5, 5), xid=(5, 5), last_status=200, open_load_age=None,
                stuck_s=60, slow=1.0, slow_s=120, restores_seen=3, visits=5)
    eq("running, nothing wrong -> continue", v(**base)[0], "continue")
    eq("*** a worker Xid -> xid ***", v(**{**base, "xid": (5, 7)})[0], "xid")
    eq("a head Xid -> xid", v(**{**base, "xid": (6, 5)})[0], "xid")
    eq("*** unreadable worker count -> unreadable, never clean ***",
       v(**{**base, "xid": (5, None), "loads": 500})[0], "unreadable")
    eq("*** a load open 90s -> stuck (wedge) ***", v(**{**base, "open_load_age": 90})[0], "stuck")
    eq("a load open 10s is normal", v(**{**base, "open_load_age": 10})[0], "continue")
    eq("HTTP 500 -> http", v(**{**base, "last_status": 500})[0], "http")
    eq("no answer (0) -> http", v(**{**base, "last_status": 0})[0], "http")
    eq("a 130s restore -> slow", v(**{**base, "slow": 130})[0], "slow")
    eq("target reached -> clean", v(**{**base, "loads": 100})[0], "clean")
    eq("*** an Xid in the same tick as the target outranks clean ***",
       v(**{**base, "loads": 100, "xid": (5, 6)})[0], "xid")
    eq("*** target reached with NO restores -> nocondition, not clean ***",
       v(**{**base, "loads": 100, "restores_seen": 0})[0], "nocondition")
    eq("60 visits and no loads -> nocondition", v(**{**base, "visits": 60, "restores_seen": 0, "loads": 0})[0], "nocondition")
    eq("*** restores that STOP: a full pass with none -> nocondition (the first live run) ***",
       v(**{**base, "visits": 60, "restores_seen": 30, "visits_since_restore": 30, "pool": 30})[0], "nocondition")
    eq("a partial pass without a restore is normal", v(**{**base, "visits_since_restore": 12, "pool": 30})[0], "continue")
    eq("prompt_tokens within 10% ok", tokens_ok(104000, 100000), True)
    eq("prompt_tokens 30% off refused", tokens_ok(130000, 100000), False)
    eq("prompt_tokens missing refused", tokens_ok(None, 100000), False)
    b0, b1 = body(0, 1000), body(1, 1000)
    eq("pool members differ in their FIRST characters (no shared block)",
       b0["messages"][0]["content"][:16] != b1["messages"][0]["content"][:16], True)
    eq("a body is byte-identical across calls", json.dumps(body(3, 1000)) == json.dumps(body(3, 1000)), True)

    # ---- the whole tool against a fake engine
    tmp = tempfile.mkdtemp(prefix="kvrace-")
    ledger = os.path.join(tmp, "ledger.jsonl")
    xidf = os.path.join(tmp, "xid")
    open(ledger, "w").close()
    open(xidf, "w").write("5 5")
    state = {"knob": 1, "visits": 0, "fail_at": None, "fail": None, "inner": 0}
    lock = threading.Lock()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def _send(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path == "/kv/workers":
                return self._send(200, {"ok": True, "ranks": [{"knobs": {"load_wait_compute": state["knob"]}},
                                                             {"knobs": {"load_wait_compute": state["knob"]}}]})
            self._send(404, {})

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/kv/knob":
                state["knob"] = int(req["value"]); return self._send(200, {"ok": True})
            content = req["messages"][0]["content"]
            if content.startswith("kvrace-pool-"):
                with lock:
                    state["visits"] += 1
                    v = state["visits"]
                    # a restore = 3 loads written to the ledger, each closed unless failing
                    with open(ledger, "a") as f:
                        for _ in range(3):
                            state["inner"] += 1
                            i = state["inner"]
                            f.write(json.dumps({"ev": "submit", "kind": "load", "inner": i, "group": 0,
                                                "boot": "b1", "ts": time.time(),
                                                "wait_compute": bool(state["knob"])}) + "\n")
                            if not (state["fail"] == "stuck" and v >= (state["fail_at"] or 1e9)):
                                f.write(json.dumps({"ev": "done", "kind": "load", "inner": i, "boot": "b1",
                                                    "ts": time.time(), "ok": True}) + "\n")
                    if state["fail"] == "xid" and v >= state["fail_at"]:
                        open(xidf, "w").write("5 6")
                    if state["fail"] == "http" and v >= state["fail_at"]:
                        return self._send(500, {})
                tok = int(len(content) / CHARS_PER_TOKEN)
                return self._send(200, {"usage": {"prompt_tokens": tok}})
            return self._send(200, {"usage": {"prompt_tokens": 5}})

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    global API, DIR
    API = f"http://127.0.0.1:{srv.server_address[1]}"
    DIR = os.path.join(tmp, "kvrace")
    os.environ["KVRACE_FAKE_XID"] = xidf

    def args(**kw):
        d = dict(n=5, tokens=1000, timeout=30, loads=30, arm="off", decoders=1, decode_tokens=4,
                 stuck_s=1.0, slow_s=30, ledger=ledger)
        d.update(kw); return argparse.Namespace(**d)

    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        global GROUP0_CAP_TOKENS
        cap, GROUP0_CAP_TOKENS = GROUP0_CAP_TOKENS, 1000
        rc_small = cmd_build(args(n=1, tokens=1000))
    eq("*** build REFUSES a pool under 1.5x the GPU cache ***", rc_small, 2)
    with contextlib.redirect_stdout(io.StringIO()):
        eq("build: 5 x 1000 tokens against a 1000-token cap succeeds", cmd_build(args()), 0)

        state.update(fail=None, fail_at=None, knob=1)
        rc = cmd_run(args(arm="off", loads=30))
    r = json.load(open(sorted(os.path.join(DIR, d, "result.json") for d in os.listdir(DIR) if d.startswith("run-"))[-1]))
    eq("*** clean arm: verdict clean at the target ***", (rc, r["verdict"]), (0, "clean"))
    eq("...it set the arm: every load recorded wait_compute False", r["wait_compute"]["true"], 0)
    eq("...and put the knob back to its previous value (1)", state["knob"], 1)
    eq("...and saw restores", r["restores"] > 0, True)

    time.sleep(1.1)
    with contextlib.redirect_stdout(io.StringIO()):
        state.update(fail="xid", fail_at=state["visits"] + 4)
        rc = cmd_run(args(arm="off", loads=10_000))
    r = json.load(open(sorted(os.path.join(DIR, d, "result.json") for d in os.listdir(DIR) if d.startswith("run-"))[-1]))
    eq("*** an injected worker Xid stops the run: verdict xid ***", (rc, r["verdict"]), (10, "xid"))
    eq("...and the knob is NOT touched after an Xid (engine presumed dead)", state["knob"], 0)
    open(xidf, "w").write("5 6"); state["knob"] = 1

    time.sleep(1.1)
    with contextlib.redirect_stdout(io.StringIO()):
        state.update(fail="stuck", fail_at=state["visits"] + 3)
        orig_sleep = time.sleep
        rc = cmd_run(args(arm="on", loads=10_000, stuck_s=0.0001))
    r = json.load(open(sorted(os.path.join(DIR, d, "result.json") for d in os.listdir(DIR) if d.startswith("run-"))[-1]))
    eq("*** a load that never completes: verdict stuck ***", (rc, r["verdict"]), (11, "stuck"))

    time.sleep(1.1)
    with contextlib.redirect_stdout(io.StringIO()):
        state.update(fail="http", fail_at=state["visits"] + 2)
        rc = cmd_run(args(arm="asis", loads=10_000, stuck_s=1e9))
    r = json.load(open(sorted(os.path.join(DIR, d, "result.json") for d in os.listdir(DIR) if d.startswith("run-"))[-1]))
    eq("an injected HTTP 500 stops the run: verdict http", (rc, r["verdict"]), (12, "http"))

    open(xidf, "w").write("5 x")
    time.sleep(1.1)
    with contextlib.redirect_stdout(io.StringIO()):
        state.update(fail=None)
        v0, k0 = state["visits"], state["knob"]
        rc = cmd_run(args(arm="off"))
    eq("*** an unreadable Xid count at start: REFUSES (exit 2) ***", rc, 2)
    eq("*** ...and sent NO pool traffic and touched NO knob (exit 2 alone could be a run that stopped late) ***",
       (state["visits"] - v0, state["knob"]), (0, k0))
    GROUP0_CAP_TOKENS = cap
    srv.shutdown()
    print("SELFTEST " + ("GREEN" if T == 0 else "RED"))
    return T


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("--n", type=int, default=30)
    b.add_argument("--tokens", type=int, default=100_000); b.add_argument("--timeout", type=float, default=1200)
    r = sub.add_parser("run"); r.add_argument("--loads", type=int, default=1000)
    r.add_argument("--arm", choices=("on", "off", "asis"), default="asis")
    r.add_argument("--decoders", type=int, default=3); r.add_argument("--decode-tokens", type=int, default=2048)
    r.add_argument("--stuck-s", type=float, default=60); r.add_argument("--slow-s", type=float, default=180)
    r.add_argument("--ledger", default=LEDGER)
    r.add_argument("--allow-small-pool", action="store_true",
                   help="run with a pool under 1.5x the GPU cache, when other traffic occupies enough of it")
    sub.add_parser("status")
    a = ap.parse_args()
    if a.cmd != "status" and os.uname().nodename.split(".")[0] != "spark-45ea" and not os.environ.get("KVRACE_API"):
        print("refusing: run on the head (spark-45ea) -- it reads the head's ledger and drives localhost:8888")
        return 1
    return {"build": cmd_build, "run": cmd_run, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

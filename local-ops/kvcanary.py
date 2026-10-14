#!/usr/bin/env python3
"""kvcanary.py -- does a DISK RESTORE give the model the right KV? A semantic check.

    python3 local-ops/kvcanary.py prime            # send once (fresh compute); must echo
    python3 local-ops/kvcanary.py check            # send again; PASS needs echo AND a restore
    python3 local-ops/kvcanary.py check --evict    # first push the canary off the GPU via the kvrace pool
    python3 local-ops/kvcanary.py --selftest       # offline, against a fake engine

CLASS: PROBE for `prime` and `check` (one ~7K-token request each). `check --evict`
is an ACTUATOR: it visits the whole kvrace pool (52 x 100K tokens, ~7 min of
load) so the canary's prefix leaves the GPU and the next send must come from
disk. Run on the HEAD.

WHY (kvmgr session's ask1, from sparkcache's semantic gate). Every restore check
here measured that bytes moved or how fast; none checked that the restored KV
makes the model say the RIGHT thing. Wrong-but-right-sized KV (a shifted block
pairing, the F8_E8M0 class) passes all of them. So:
  - a FIXED ~7K-token prompt (kvcanary/prompt.txt, committed, sha-pinned below,
    never generated at run time) with a sentinel near the START and the
    question at the END -- the model can only answer from KV of the early
    blocks;
  - temperature 0, exact echo (sparkcache found arithmetic answers changed
    between async and sync scheduling, so they are not a stable oracle);
  - PASS = the reply contains the sentinel exactly AND the request was served
    from a restore: vllm:external_prefix_cache_hits_total (the `_total` series --
    the `_created` one is a timestamp that reads as a plausible number) moved by
    at least --min-hit-frac of the prompt, AND kvmgr's load handler
    blocks_to_gpu (/kv/workers, summed over ranks) moved. A correct answer
    with no restore proves nothing about restores, so it is NOT a pass: it is
    `norestore`.

Verdicts: pass | wrong (restored and the echo is wrong: the thing this exists to
catch) | norestore | error. `prime` must echo on fresh compute, or the
canary itself is not usable on this model and every later verdict is moot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request

API = os.environ.get("KVCANARY_API", "http://127.0.0.1:8888")
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kvcanary")
OUT = os.environ.get("KVCANARY_OUT", os.path.expanduser("~/kvdiag/kvcanary"))
MODEL = os.environ.get("KVCANARY_MODEL", "claude-opus-5")
PROMPT_SHA = "780b3d81520d730a"     # sha256[:16] of kvcanary/prompt.txt -- refuse anything else
KVRACE_DIR = os.path.expanduser("~/kvdiag/kvrace")


def load_prompt():
    text = open(os.path.join(HERE, "prompt.txt")).read()
    sentinel = open(os.path.join(HERE, "sentinel.txt")).read().strip()
    sha = hashlib.sha256(text.encode()).hexdigest()[:16]
    if sha != PROMPT_SHA:
        raise SystemExit(f"REFUSING: prompt.txt sha {sha} != pinned {PROMPT_SHA} -- the canary must be the SAME text every time")
    if sentinel not in text.split("\n\n")[0]:
        raise SystemExit("REFUSING: the sentinel is not in the prompt's opening -- the test would not reach early blocks")
    return text, sentinel


def verdict(*, echo_ok: bool, hits_delta, blocks_delta, prompt_tokens, min_hit_frac: float, status: int):
    """(verdict, why). Pure."""
    if status != 200:
        return "error", f"HTTP {status}"
    if hits_delta is None or blocks_delta is None:
        return "error", "a restore counter could not be read -- absent is not zero"
    restored = blocks_delta > 0 and prompt_tokens and hits_delta >= min_hit_frac * prompt_tokens
    if not restored:
        return "norestore", (f"no restore proven (external hits +{hits_delta} of {prompt_tokens} prompt tokens, "
                             f"load blocks +{blocks_delta}) -- a correct echo here says nothing about the disk tier")
    if not echo_ok:
        return "wrong", f"RESTORED (hits +{hits_delta}, blocks +{blocks_delta}) and the echo is WRONG -- restored KV is not the KV that was stored"
    return "pass", f"restored (hits +{hits_delta} of {prompt_tokens}, blocks +{blocks_delta}) and echoed exactly"


# ---------------------------------------------------------------- engine I/O
def _get(path, timeout=20):
    with urllib.request.urlopen(API + path, timeout=timeout) as r:
        return r.read().decode()


def ext_hits():
    try:
        for ln in _get("/metrics").splitlines():
            if ln.startswith("vllm:external_prefix_cache_hits_total"):
                return float(ln.rsplit(" ", 1)[1])
    except Exception:
        return None
    return None


def load_blocks():
    try:
        d = json.loads(_get("/kv/workers"))
        tot = 0
        for rk in d["ranks"]:
            hs = [h for h in rk.get("handlers") or [] if "blocks_to_gpu" in h]
            if not hs:
                return None
            tot += sum(int(h["blocks_to_gpu"]) for h in hs)
        return tot
    except Exception:
        return None


def ask(text: str, timeout=600):
    body = {"model": MODEL, "max_tokens": 64, "temperature": 0,
            "messages": [{"role": "user", "content": text}]}
    req = urllib.request.Request(API + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            js = json.loads(r.read())
            reply = js["choices"][0]["message"].get("content") or ""
            return 200, reply, (js.get("usage") or {}).get("prompt_tokens"), time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, "", None, time.time() - t
    except Exception:
        return 0, "", None, time.time() - t


def evict_via_pool(log) -> int:
    """Visit the kvrace pool once (it is >1.5x the GPU cache), so LRU pushes the
    canary's prefix out and the next send must come from disk."""
    meta = json.load(open(os.path.join(KVRACE_DIR, "pool.json")))
    n = 0
    for p in meta["prefixes"]:
        b = json.load(open(os.path.join(KVRACE_DIR, "bodies", f"p{p['i']:03d}.json")))
        req = urllib.request.Request(API + "/v1/chat/completions", data=json.dumps(b).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=900).read(); n += 1
        except Exception as e:
            log(f"  evict visit p{p['i']:03d} failed: {e!r}")
    return n


def run(mode: str, a) -> int:
    text, sentinel = load_prompt()
    os.makedirs(OUT, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    lines = []

    def log(m):
        line = time.strftime("%H:%M:%S ", time.gmtime()) + m
        print(line, flush=True); lines.append(line)

    if mode == "check" and a.evict:
        log("evicting: one pass of the kvrace pool (actuator, ~7 min)")
        log(f"  {evict_via_pool(log)} pool visits done")
    h0, b0 = ext_hits(), load_blocks()
    st, reply, pt, sec = ask(text)
    h1, b1 = ext_hits(), load_blocks()
    echo_ok = sentinel in reply
    hd = None if None in (h0, h1) else int(h1 - h0)
    bd = None if None in (b0, b1) else int(b1 - b0)
    if mode == "prime":
        v, why = (("pass", "fresh compute echoed exactly -- the canary is usable") if st == 200 and echo_ok
                  else ("error", f"PRIME FAILED (HTTP {st}, reply {reply[:80]!r}) -- the model does not echo; the canary is unusable"))
    else:
        v, why = verdict(echo_ok=echo_ok, hits_delta=hd, blocks_delta=bd, prompt_tokens=pt,
                         min_hit_frac=a.min_hit_frac, status=st)
    res = {"mode": mode, "verdict": v, "why": why, "echo_ok": echo_ok, "reply": reply[:200],
           "prompt_tokens": pt, "seconds": round(sec, 2), "ext_hits_delta": hd, "load_blocks_delta": bd,
           "prompt_sha": PROMPT_SHA, "evicted": bool(getattr(a, "evict", False))}
    log(f"{mode.upper()} {v.upper()}: {why}")
    log(json.dumps(res))
    json.dump(res, open(os.path.join(OUT, f"{stamp}-{mode}.json"), "w"), indent=1)
    return {"pass": 0, "norestore": 3, "wrong": 4}.get(v, 2)


# ---------------------------------------------------------------- selftest
def selftest() -> int:
    import http.server, threading, tempfile, contextlib, io
    T = 0

    def eq(name, got, want):
        nonlocal T
        ok = got == want; T |= not ok
        print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"  got {got!r} want {want!r}"))

    V = lambda **k: verdict(**{**dict(echo_ok=True, hits_delta=6000, blocks_delta=40, prompt_tokens=7000,
                                      min_hit_frac=0.5, status=200), **k})[0]
    eq("restored + exact echo -> pass", V(), "pass")
    eq("*** restored + WRONG echo -> wrong (the thing it exists to catch) ***", V(echo_ok=False), "wrong")
    eq("*** correct echo but NO restore (hits 0) -> norestore, not pass ***", V(hits_delta=0, blocks_delta=0), "norestore")
    eq("hits moved but no load blocks (GPU hit) -> norestore", V(blocks_delta=0), "norestore")
    eq("blocks moved but hits under half the prompt -> norestore", V(hits_delta=1000), "norestore")
    eq("*** unreadable counter -> error, never pass ***", V(hits_delta=None), "error")
    eq("HTTP 500 -> error", V(status=500), "error")
    text, sentinel = load_prompt()
    eq("the committed prompt matches its pinned sha", hashlib.sha256(text.encode()).hexdigest()[:16], PROMPT_SHA)
    eq("the sentinel is in the opening and the question at the end",
       (sentinel in text[:400], "canary code" in text[-300:]), (True, True))

    # fake engine: restore-or-not and correct-or-wrong are switchable
    state = {"hits": 0.0, "blocks": 0, "restore": True, "correct": True}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _s(self, code, body, ctype="application/json"):
            b = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def do_GET(self):
            if self.path == "/metrics":
                return self._s(200, "vllm:external_prefix_cache_hits_created 1.79e+09\n"
                                    f"vllm:external_prefix_cache_hits_total {state['hits']}\n", "text/plain")
            if self.path == "/kv/workers":
                return self._s(200, json.dumps({"ranks": [{"handlers": [{"files": 1}, {"blocks_to_gpu": state["blocks"]}]},
                                                          {"handlers": [{"files": 1}, {"blocks_to_gpu": state["blocks"]}]}]}))
            self._s(404, "{}")
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0); json.loads(self.rfile.read(n))
            if state["restore"]:
                state["hits"] += 6900; state["blocks"] += 30
            reply = sentinel if state["correct"] else "c4n4ry-0000"
            self._s(200, json.dumps({"choices": [{"message": {"content": reply}}], "usage": {"prompt_tokens": 7000}}))

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    global API, OUT
    API = f"http://127.0.0.1:{srv.server_address[1]}"; OUT = tempfile.mkdtemp(prefix="kvcanary-")
    args = argparse.Namespace(evict=False, min_hit_frac=0.5)
    with contextlib.redirect_stdout(io.StringIO()):
        r1 = run("prime", args)
        state.update(restore=True, correct=True); r2 = run("check", args)
        state.update(restore=False, correct=True); r3 = run("check", args)
        state.update(restore=True, correct=False); r4 = run("check", args)
    eq("integrated: prime with an echo -> 0", r1, 0)
    eq("integrated: restored + echo -> pass (0)", r2, 0)
    eq("*** integrated: no restore -> norestore (3), even with a correct echo ***", r3, 3)
    eq("*** integrated: restored + wrong echo -> wrong (4) ***", r4, 4)
    eq("...and the `_created` series was not read as hits (the documented trap)",
       ext_hits() == state["hits"], True)
    srv.shutdown()
    print("SELFTEST " + ("GREEN" if T == 0 else "RED"))
    return T


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prime")
    c = sub.add_parser("check"); c.add_argument("--evict", action="store_true")
    c.add_argument("--min-hit-frac", type=float, default=0.5)
    a = ap.parse_args()
    if not hasattr(a, "min_hit_frac"):
        a.min_hit_frac = 0.5; a.evict = False
    return run(a.cmd, a)


if __name__ == "__main__":
    sys.exit(main())

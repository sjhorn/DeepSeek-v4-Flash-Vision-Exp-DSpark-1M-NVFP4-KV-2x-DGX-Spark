#!/usr/bin/env python3
"""kvcanary.py -- does a DISK RESTORE give the model the right KV? A semantic check.

    python3 local-ops/kvcanary.py prime            # send once (fresh compute); must echo
    python3 local-ops/kvcanary.py check            # send again; PASS needs echo AND a restore
    python3 local-ops/kvcanary.py check --evict    # first push the canary off the GPU via the kvrace pool
    python3 local-ops/kvcanary.py locate           # the canary's group-0 keys and each rank's file (kvmgr >= 0.4.7)
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
STATS = os.environ.get("KVCANARY_STATS", "http://127.0.0.1:9199")   # kvmgr_stats_port, engine core
HOST_TIER = os.environ.get("KVCANARY_HOST_TIER", "/home/shorn/kvoffload")  # the host side of /kvoffload


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
            ask.last_id = js.get("id")
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
           "response_id": getattr(ask, "last_id", None),
           "prompt_tokens": pt, "seconds": round(sec, 2), "ext_hits_delta": hd, "load_blocks_delta": bd,
           "prompt_sha": PROMPT_SHA, "evicted": bool(getattr(a, "evict", False))}
    log(f"{mode.upper()} {v.upper()}: {why}")
    log(json.dumps(res))
    json.dump(res, open(os.path.join(OUT, f"{stamp}-{mode}.json"), "w"), indent=1)
    return {"pass": 0, "norestore": 3, "wrong": 4}.get(v, 2)


# ---------------------------------------------------------------- locate (Gate B)
def pick_request(requests: list, want_tokens: int, tol: float = 0.05):
    """The most recent request within tol of the canary's prompt size. Pure.
    The list is the engine core's (live first, then finished newest-last), so
    the LAST match is the newest."""
    hits = [r for r in requests if isinstance(r.get("num_tokens"), int)
            and abs(r["num_tokens"] - want_tokens) <= tol * want_tokens]
    return hits[-1] if hits else None


def candidates(group: dict) -> list:
    """Three blocks to corrupt, by position: the sentinel's (earliest), the
    middle, and the last. Pure. Host paths for the WORKER (rank 1)."""
    rows = group.get("keys") or []
    if not rows:
        return []
    picks = {"early (holds the sentinel)": rows[0], "middle": rows[len(rows) // 2], "last": rows[-1]}
    out = []
    for why, r in picks.items():
        wp = (r.get("path") or {}).get("1")
        out.append({"which": why, "i": r.get("i"), "tokens": r.get("tokens"), "key": r.get("key"),
                    "worker_path_container": wp,
                    "worker_path_host": wp.replace("/kvoffload", HOST_TIER, 1) if wp else None,
                    "in_index": r.get("in_index"), "verified": r.get("verified")})
    return out


def locate(want_tokens: int = 8449) -> int:
    try:
        lst = json.loads(urllib.request.urlopen(STATS + "/kv/keys", timeout=20).read())
    except Exception as e:
        print(f"UNREADABLE: GET {STATS}/kv/keys failed ({e!r}) -- needs kvmgr >= 0.4.7 with diag_request_keys")
        return 2
    req = pick_request(lst.get("requests") or [], want_tokens)
    if not req:
        print(f"NOT FOUND: no request within 5% of {want_tokens} tokens among "
              f"{[(r.get('req'), r.get('num_tokens')) for r in (lst.get('requests') or [])][-8:]} -- run `prime` first")
        return 3
    try:
        det = json.loads(urllib.request.urlopen(f"{STATS}/kv/keys?req={req['req']}&group=0", timeout=20).read())
    except Exception as e:
        print(f"UNREADABLE: the request's keys ({e!r})"); return 2
    g = next((x for x in det.get("groups") or [] if x.get("group") == 0), None)
    if not g:
        print("NO GROUP 0 in the answer:", json.dumps(det)[:300]); return 2
    out = {"req": req["req"], "num_tokens": det.get("num_tokens"), "group": 0,
           "block_tokens": g.get("block_tokens"), "num_keys": g.get("num_keys"),
           "truncated": g.get("truncated"), "candidates": candidates(g)}
    print(json.dumps(out, indent=1))
    return 0


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
    # locate: pure parts
    rq = [{"req": "a", "num_tokens": 120000}, {"req": "canary-old", "num_tokens": 8449},
          {"req": "b", "num_tokens": 900}, {"req": "canary-new", "num_tokens": 8450}]
    eq("pick_request: the NEWEST request near the canary's size", pick_request(rq, 8449)["req"], "canary-new")
    eq("pick_request: none near the size -> None", pick_request([{"req": "x", "num_tokens": 100}], 8449), None)
    grp = {"keys": [{"i": i, "tokens": [i * 256, (i + 1) * 256], "key": "k%d" % i,
                     "path": {"0": "/kvoffload/dspark-kv-v1/h/k%d" % i, "1": "/kvoffload/dspark-kv-v1/w/k%d" % i},
                     "in_index": True, "verified": True} for i in range(33)]}
    c = candidates(grp)
    eq("candidates: early, middle, last by block index", [x["i"] for x in c], [0, 16, 32])
    eq("*** candidates name the WORKER's file (rank 1), on the host side of the mount ***",
       c[1]["worker_path_host"], "/home/shorn/kvoffload/dspark-kv-v1/w/k16")
    eq("candidates of an empty group -> []", candidates({"keys": []}), [])
    print("SELFTEST " + ("GREEN" if T == 0 else "RED"))
    return T


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prime")
    sub.add_parser("locate")
    c = sub.add_parser("check"); c.add_argument("--evict", action="store_true")
    c.add_argument("--min-hit-frac", type=float, default=0.5)
    a = ap.parse_args()
    if not hasattr(a, "min_hit_frac"):
        a.min_hit_frac = 0.5; a.evict = False
    if a.cmd == "locate":
        return locate()
    return run(a.cmd, a)


if __name__ == "__main__":
    sys.exit(main())

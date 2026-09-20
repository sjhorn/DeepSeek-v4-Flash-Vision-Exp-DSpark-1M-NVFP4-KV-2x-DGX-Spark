#!/usr/bin/env python3
"""What the CLIENT sends, arm by arm: does the beta path or a beta header
poison cross-session prefix reuse?

Original job (kept as the DIRECT/PROXY arms): same body over the SSH tunnel vs
the tap -> mTLS -> proxy path. Both reused at 99.7%, so transport is acquitted.

The gap that remained was never the transport -- it was that every replay so
far sent a bare `/v1/messages` with two minimal headers, while a real Claude
Code session sends `/v1/messages?beta=true` with a full header set including
`anthropic-beta`. That matters because `cache_salt` is mixed into the FIRST
block's extra keys and chains through every later block hash
(kv_cache_utils.py:524-532): a salt that varies per session would give exactly
the observed signature -- flawless reuse inside a session, 0% across sessions,
with byte-identical prompts.

So: prime one head, then send the SAME body with a fresh tail down four arms,
all DIRECT to the engine so transport is held constant and only the path and
the headers vary:

    control      /v1/messages          minimal headers       (known: 99.7%)
    beta-path    /v1/messages?beta=true  minimal headers
    beta-header  /v1/messages          + captured anthropic-beta
    full-live    /v1/messages?beta=true  full captured header set

An arm that drops to ~0% names the cause. Rows where queries != input_tokens
are contaminated by the co-tenant and are retried, never reported.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import subprocess
import time
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_LO = os.path.join(_HERE, "..")
_REPO = os.path.join(_LO, "..")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_LO, fname))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


cp = _load("cache_probe", "cache-probe.py")
BASE = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888").rstrip("/")
PROFILE = os.environ.get("VLLM_PROFILE",
                         os.path.expanduser("~/.config/vllm-proxy/claude-latest-local.json"))


def post(url, body, headers, timeout=1800):
    """POST and drain; return (input_tokens, seconds, status, error)."""
    t0 = time.time()
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers=headers, method="POST")
    it, status, err = None, 200, None
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        if body.get("stream"):
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("data:") and it is None:
                    try:
                        ev = json.loads(line[5:].strip())
                    except ValueError:
                        continue
                    u = (ev.get("message") or {}).get("usage") or ev.get("usage") or {}
                    if u.get("input_tokens"):
                        it = u["input_tokens"]
        else:
            it = ((json.load(r).get("usage")) or {}).get("input_tokens")
    except Exception as e:                                        # noqa: BLE001
        status, err = -1, repr(e)[:200]
    return it, time.time() - t0, status, err


def measure(url, body, headers):
    q0, h0, _ = cp.cache_counters(BASE)
    it, secs, status, err = post(url, body, headers)
    q1, h1, _ = cp.cache_counters(BASE)
    dq, dh = q1 - q0, h1 - h0
    blend = (dq / it) if (it and dq) else 0.0
    return {"status": status, "error": err, "seconds": secs, "input_tokens": it,
            "queries": dq, "hits": dh,
            "hit_pct": (100.0 * dh / dq) if dq > 0 else None,
            "blend": blend, "contended": bool(blend) and not (0.95 <= blend <= 1.05)}


def turns(path):
    out = []
    for l in open(path):
        if l.strip():
            r = json.loads(l)
            if r["body"].get("max_tokens", 0) > 1:
                out.append(r["body"])
    return out


def fresh(b, n):
    b = copy.deepcopy(b)
    blk = b["messages"][0]["content"]
    if isinstance(blk, str):
        b["messages"][0]["content"] = blk + f"\n(t {n})"
    else:
        blk[-1]["text"] = blk[-1]["text"] + f"\n(t {n})"
    return b


HOP_BY_HOP = {"host", "content-length", "connection", "accept-encoding",
              "transfer-encoding", "keep-alive", "upgrade", "te", "trailer",
              "proxy-connection"}


def captured_headers(path):
    """Real headers from a prompt-tap capture (already credential-redacted).

    Hop-by-hop headers are dropped: urllib sets them for the connection it
    actually makes, and replaying a stale Content-Length would truncate the body.
    """
    for l in open(path):
        if not l.strip():
            continue
        r = json.loads(l)
        h = r.get("headers")
        if h and r["body"].get("max_tokens", 0) > 1:
            return {k: v for k, v in h.items() if k.lower() not in HOP_BY_HOP}, r["path"]
    raise SystemExit(f"no headers in {path} -- recapture with the header-recording tap")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture",
                    default=os.path.join(_LO, "toolsearch-matrix/a3single.jsonl"),
                    help="tap capture providing both the body and the real headers")
    ap.add_argument("--tries", type=int, default=4)
    ap.add_argument("--out", default=os.path.join(_HERE, "beta-arms.json"))
    a = ap.parse_args()

    head = turns(a.capture)[0]
    hdrs, real_path = captured_headers(a.capture)
    beta = hdrs.get("anthropic-beta") or hdrs.get("Anthropic-Beta")
    print(f"capture      {a.capture}")
    print(f"real path    {real_path}")
    print(f"anthropic-beta  {beta}")
    print()

    MIN = {"Content-Type": "application/json", "anthropic-version": "2023-06-01"}
    arms = [
        ("control      /v1/messages",           f"{BASE}/v1/messages",           dict(MIN)),
        ("beta-path    ?beta=true",             f"{BASE}/v1/messages?beta=true", dict(MIN)),
        ("beta-header  anthropic-beta",         f"{BASE}/v1/messages",           {**MIN, "anthropic-beta": beta or ""}),
        ("full-live    ?beta=true + headers",   f"{BASE}/v1/messages?beta=true", dict(hdrs)),
    ]

    results = {}
    for label, url, headers in arms:
        got = None
        for i in range(a.tries):
            cp.send(head)                                    # keep the head hot
            body = fresh(head, f"{int(time.time())}-{i}")
            body["max_tokens"] = 32000
            body["stream"] = True                            # the live shape
            m = measure(url, body, headers)
            state = ("http %s %s" % (m["status"], (m["error"] or "")[:90])
                     if m["status"] != 200
                     else "BLENDED x%.1f" % m["blend"] if m["contended"] else "clean")
            hp = "  n/a" if m["hit_pct"] is None else f"{m['hit_pct']:5.1f}%"
            print(f"  {label:<34s} hit {hp} = {m['hits']:>8,.0f} tok "
                  f"in={m['input_tokens'] or 0:>7,} {m['seconds']:6.2f}s [{state}]", flush=True)
            if state == "clean":
                got = m
                break
            time.sleep(4)
        results[label] = got
        print()

    with open(a.out, "w") as f:
        json.dump({k: v for k, v in results.items()}, f, indent=2)

    print("-" * 78)
    missing = [k for k, v in results.items() if not v]
    if missing:
        print("INCONCLUSIVE -- no clean row for: " + ", ".join(m.split()[0] for m in missing))
    else:
        dead = [k for k, v in results.items() if v["hit_pct"] is not None and v["hit_pct"] <= 5]
        if dead:
            print("CONVICTED: these arms lose the prefix cache -> " +
                  ", ".join(d.split()[0] for d in dead))
        else:
            print("ACQUITTED: all four arms reuse the head. The beta path, the\n"
                  "           anthropic-beta header and the full live header set are\n"
                  "           NOT what kills cross-session reuse.")
    print(f"-> {a.out}")
    print("-" * 78)


if __name__ == "__main__":
    main()

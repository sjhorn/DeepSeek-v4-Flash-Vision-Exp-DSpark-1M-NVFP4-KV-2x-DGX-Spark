#!/usr/bin/env python3
"""Ground truth for prefix-cache behaviour: the server's own accounting.

`prefix-diff.py` *models* the server's transforms and tells you WHY a prompt
head moved. This file does not model anything -- it sends a request and reads
`vllm:prefix_cache_{queries,hits}_total` either side of it, so the hit ratio it
prints is what the engine actually did. When the two disagree, this one is
right (prefix-diff has already been wrong once, before Patch 11b).

    # T0.1 -- does prefix-diff agree with the engine on three known answers?
    python3 local-ops/cache-probe.py --selftest

    # replay a prompt-tap capture, one line per request
    python3 local-ops/cache-probe.py --replay prompt-tap.jsonl

Needs the API reachable at --base-url (from the Mac: an SSH tunnel to the head).
Measurements assume a QUIET server -- the /metrics counters are global, so a
concurrent request lands in the same delta. Concurrency is checked per send and
flagged in the output; treat flagged rows as unmeasured, not as evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

import importlib.util

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "prefix_diff", os.path.join(_HERE, "prefix-diff.py"))
_pd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pd)                  # the hyphen blocks a plain import

DEFAULT_BASE = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888")
PROBE_MODEL = os.environ.get("DSPARK_PROBE_MODEL", "deepseek-v4-flash-dspark-nothink")


# ── metrics ─────────────────────────────────────────────────────────

def _scrape(base):
    txt = urllib.request.urlopen(base + "/metrics", timeout=60).read().decode()
    out = {}
    for line in txt.splitlines():
        if not line or line.startswith("#"):
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        try:
            val = float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            continue
        out[name] = out.get(name, 0.0) + val
    return out


def cache_counters(base):
    m = _scrape(base)
    return (m.get("vllm:prefix_cache_queries_total", 0.0),
            m.get("vllm:prefix_cache_hits_total", 0.0),
            m.get("vllm:num_requests_running", 0.0) + m.get("vllm:num_requests_waiting", 0.0))


# ── one measured request ────────────────────────────────────────────

def send(body, base=DEFAULT_BASE, timeout=1800):
    """POST one Anthropic body; return a measurement dict.

    max_tokens is forced small and streaming off: we are measuring PREFILL,
    and decode time would swamp the signal for no benefit.
    """
    b = dict(body)
    b["max_tokens"] = 4
    b.pop("stream", None)

    q0, h0, busy0 = cache_counters(base)
    t0 = time.time()
    req = urllib.request.Request(
        base + "/v1/messages",
        data=json.dumps(b).encode(),
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
        method="POST")
    status, data, err = 200, None, None
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        data = json.load(r)
    except urllib.error.HTTPError as e:
        status, err = e.code, e.read().decode()[:400]
    except Exception as e:                                  # noqa: BLE001
        status, err = -1, repr(e)[:400]
    dt = time.time() - t0
    q1, h1, busy1 = cache_counters(base)

    dq, dh = q1 - q0, h1 - h0
    usage = (data or {}).get("usage") or {}
    it = usage.get("input_tokens")
    # vLLM queries the prefix cache once per prompt token, so a delta that
    # belongs to exactly ONE request has queries == input_tokens. Anything else
    # means another client's tokens are inside our window -- and this cluster
    # does carry concurrent external traffic.
    #
    # The obvious check -- num_requests_running -- is NOT usable: the gauge is
    # refreshed only on the engine's logging interval, so it reads busy for
    # nearly every request, including from the one being measured. It is kept
    # as a hint and never as the flag.
    blend = (dq / it) if (it and dq) else 0.0
    return {
        "status": status, "error": err, "seconds": dt,
        "input_tokens": it,
        "output_tokens": usage.get("output_tokens"),
        "queries": dq, "hits": dh,
        "hit_pct": (100.0 * dh / dq) if dq > 0 else None,
        "blend": blend,
        "contended": bool(blend) and not (0.95 <= blend <= 1.05),
        "engine_busy": bool(busy0 or busy1),
    }


def fmt(label, m):
    if m["status"] != 200:
        return f"  {label:<34s} HTTP {m['status']}  {m['error']}"
    hp = "  n/a" if m["hit_pct"] is None else f"{m['hit_pct']:5.1f}%"
    tok = m["input_tokens"]
    return (f"  {label:<34s} {m['seconds']:6.2f}s  in={tok if tok is None else format(tok, ',')!s:>8s}"
            f"  cache {m['hits']:>8,.0f}/{m['queries']:>8,.0f} = {hp} hit"
            + ("   [BLENDED x%.1f]" % m["blend"] if m["contended"] else ""))


# ── T0.1 agreement test ─────────────────────────────────────────────

_FILLER_UNIT = ("The repository conventions are stable and must be followed "
                "exactly; prefer small diffs and never invent APIs. ")


def _synthetic(nonce, filler_units=400):
    """A body whose system block is one long STATIC paragraph.

    One paragraph, no blank lines, and no wording that trips
    `_PROMPT_CACHE_DYNAMIC_MARKERS` -- so `normalize_system_prompt` passes it
    through unchanged and the only variable is what this function varies.
    """
    return {
        "model": PROBE_MODEL,
        "system": [{"type": "text", "text": f"SESSION{nonce}. " + _FILLER_UNIT * filler_units}],
        "messages": [{"role": "user", "content": "Reply with the single word OK."}],
    }


def selftest(base):
    nonce = hashlib.sha256(str(time.time()).encode()).hexdigest()[:10]
    print(f"T0.1 agreement test  (nonce {nonce}, base {base})")
    print("    Each pair is sent cold-then-warm against a nonce nobody has seen,")
    print("    so the engine's hit ratio has a known right answer.\n")

    cases = []

    # 1. identical bodies -> full reuse
    a = _synthetic(nonce + "A")
    cases.append(("identical", a, json.loads(json.dumps(a)), "high"))

    # 2. tail appended (a conversation growing by one exchange) -> full reuse
    a = _synthetic(nonce + "B")
    b = json.loads(json.dumps(a))
    b["messages"] = [a["messages"][0],
                     {"role": "assistant", "content": "OK"},
                     {"role": "user", "content": "Reply with the single word OK again."}]
    cases.append(("tail appended", a, b, "high"))

    # 3. one byte changed at the head -> nothing downstream survives
    a = _synthetic(nonce + "C")
    b = json.loads(json.dumps(a))
    t = b["system"][0]["text"]
    b["system"][0]["text"] = t[:7] + ("X" if t[7] != "X" else "Y") + t[8:]
    cases.append(("head byte changed", a, b, "low"))

    ok = True
    for name, first, second, expect in cases:
        v = _pd.verdict(first, second)
        m1 = send(first, base)
        m2 = send(second, base)
        print(f"--- {name}")
        print(fmt("A (cold)", m1))
        print(fmt("B (after A)", m2))
        print(f"      prefix-diff: {v['kind']}  shared {v['shared_chars']:,}/{v['total_chars']:,} chars "
              f"({100*v['shared_frac']:.0f}%)  {v['detail'][:90]}")

        if m2["status"] != 200 or m2["hit_pct"] is None:
            print("      RESULT: UNMEASURED (request failed)")
            ok = False
            continue
        if m2["contended"]:
            print("      RESULT: UNMEASURED (another client's tokens in the delta "
                  f"-- queries/input = {m2['blend']:.2f}; rerun on a quiet window)")
            ok = False
            continue

        measured_high = m2["hit_pct"] >= 95.0
        measured_low = m2["hit_pct"] <= 5.0
        # prefix-diff's own prediction, expressed on the same axis
        predicts_high = v["kind"] in ("identical", "strict-prefix") or v["shared_frac"] >= 0.95
        agree = (predicts_high and measured_high) or (not predicts_high and measured_low)
        expected = (expect == "high" and measured_high) or (expect == "low" and measured_low)
        verdict = "PASS" if (agree and expected) else "FAIL"
        ok &= (agree and expected)
        print(f"      RESULT: {verdict}  (expected {expect}, measured {m2['hit_pct']:.1f}%, "
              f"prefix-diff predicts {'high' if predicts_high else 'low'})")
        print()

    print("T0.1:", "PASS -- prefix-diff agrees with the engine on all three"
          if ok else "FAIL -- fix prefix-diff before trusting any verdict it gives")
    return 0 if ok else 1


# ── replay ──────────────────────────────────────────────────────────

def replay(path, base, model=None, limit=None):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    if limit:
        rows = rows[:limit]
    print(f"replaying {len(rows)} captured requests against {base}\n")
    prev = None
    results = []
    for i, r in enumerate(rows):
        body = r["body"]
        if model:
            body = dict(body, model=model)
        v = _pd.verdict(prev, body) if prev is not None else None
        m = send(body, base)
        m["index"] = i
        m["ts"] = r.get("ts")
        m["model"] = body.get("model")
        m["n_tools"] = len(body.get("tools") or [])
        m["verdict"] = v["kind"] if v else "(first)"
        m["diverges_at"] = v["label_b"] if v else None
        m["shared_frac"] = v["shared_frac"] if v else None
        results.append(m)
        print(fmt(f"[{i}] {m['model']} tools={m['n_tools']}", m))
        if v:
            print(f"      prefix-diff: {v['kind']}"
                  + (f" at {v['label_a']} -> {v['label_b']}" if v["kind"] == "diverges" else "")
                  + f"  shared {100*v['shared_frac']:.0f}%")
        prev = body
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=DEFAULT_BASE)
    ap.add_argument("--selftest", action="store_true", help="T0.1 agreement test")
    ap.add_argument("--replay", help="prompt-tap.jsonl capture to replay in order")
    ap.add_argument("--model", help="override the model on every replayed request")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--output", help="write replay results as JSON")
    a = ap.parse_args()

    if a.selftest:
        sys.exit(selftest(a.base_url.rstrip("/")))
    if a.replay:
        res = replay(a.replay, a.base_url.rstrip("/"), a.model, a.limit)
        if a.output:
            with open(a.output, "w") as f:
                json.dump(res, f, indent=2)
            print(f"\nwrote {a.output}")
        sys.exit(0)
    ap.error("pass --selftest or --replay")


if __name__ == "__main__":
    main()

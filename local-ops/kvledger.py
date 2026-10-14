#!/usr/bin/env python3
"""kvledger.py -- read kvmgr's write-ahead transfer ledger. READ-ONLY.

    python3 local-ops/kvledger.py ~/kvoffload/diag/ledger-r0.jsonl
    python3 local-ops/kvledger.py FILE --xid "2026-10-14 10:12:17.387186"   # UTC
    python3 local-ops/kvledger.py FILE --pid 126
    python3 local-ops/kvledger.py --selftest

CLASS: READ-ONLY. Reads a file, prints, exits. Pure stdlib, runs on either node
or the laptop.

Answers the three questions the 2026-10-14 Xids raised, which were answered
by hand the first time:

  1. CONCURRENCY -- how many transfers of each kind were on the GPU when each
     one was submitted. `load_inflight_max=1` should make the load maximum 1;
     on 2026-10-14 it was 7, which is how the knob was found not to bound the
     GPU stage. Run this after any change to that path.
  2. OVERLAPS -- submits whose `overlap` field is set (a GPU block shared with
     an in-flight transfer where either side is a load).
  3. AT A FAULT (--xid) -- the open entries (submitted, never seen done) for
     the process, timed against the Xid, plus every record in the 20 s before.
     Take the Xid time from `journalctl -k -o short-precise` -- the default
     output is second-resolution, and the loads at 10:12:17 were 17-20 ms
     before the line, which a whole second would have hidden.

An entry's span is submit to OBSERVED completion (polled once per scheduler
step), so "on the GPU" means "not yet seen done". An idle engine leaves its
last submit open, so read open entries against the Xid time, never as a bare
count. Files from kvmgr >= 0.3.1 also carry `gpu_loads`/`gpu_stores`/`ops`
on each submit; those are printed when present and not reconstructed.

Records are grouped by pid, because a restarted process numbers its transfers
from 0 again and appends to the same file.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import sys
import tempfile


def load(path: str) -> list[dict]:
    out = []
    with open(path) as f:
        for ln in f:
            try:
                out.append(json.loads(ln))
            except ValueError:
                continue            # a torn last line after a death is expected
    return out


def concurrency(recs: list[dict]) -> dict:
    """Per kind: histogram of 'transfers of this kind open at submit,
    including itself', its max, and how many submits had company. Pure."""
    open_: dict = {}
    hist = {"load": collections.Counter(), "store": collections.Counter()}
    for r in recs:
        k = (r.get("kind"), r.get("inner"))
        if r.get("ev") == "submit":
            open_[k] = r
            kind = r.get("kind")
            if kind in hist:
                hist[kind][sum(1 for (kk, _i) in open_ if kk == kind)] += 1
        elif r.get("ev") == "done":
            open_.pop(k, None)
    out = {}
    for kind, h in hist.items():
        n = sum(h.values())
        out[kind] = {"submits": n, "max": max(h) if h else 0,
                     "with_company": sum(c for d, c in h.items() if d > 1),
                     "hist": dict(sorted(h.items()))}
    return out


def open_entries(recs: list[dict]) -> list[dict]:
    open_: dict = {}
    for r in recs:
        k = (r.get("kind"), r.get("inner"))
        if r.get("ev") == "submit":
            open_[k] = r
        elif r.get("ev") == "done":
            open_.pop(k, None)
    return sorted(open_.values(), key=lambda r: r.get("ts", 0))


def parse_xid(s: str) -> float:
    try:
        return float(s)
    except ValueError:
        pass
    s = s.strip().replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return dt.datetime.strptime(s, fmt).replace(
                tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            continue
    raise SystemExit(f"cannot parse --xid {s!r}: give UTC 'YYYY-MM-DD HH:MM:SS[.ffffff]' or epoch")


def fmt(r: dict, t0: float | None) -> str:
    rel = "%+9.3fs" % (r["ts"] - t0) if t0 is not None and "ts" in r else \
        dt.datetime.fromtimestamp(r.get("ts", 0), dt.timezone.utc).strftime("%H:%M:%S.%f")[:-3]
    if r.get("ev") == "done":
        return f"  {rel} done   {r.get('kind'):5} inner={r.get('inner')} ok={r.get('ok')}"
    extra = ""
    for k in ("gpu_loads", "gpu_stores", "ops"):
        if k in r:
            extra += f" {k}={r[k]}"
    return (f"  {rel} submit {r.get('kind'):5} inner={r.get('inner')} job={r.get('job')} "
            f"g={r.get('group')} n={r.get('n')} bids={(r.get('bids') or [])[:3]}"
            f"{extra} overlap={r.get('overlap')}")


def report(recs: list[dict], xid: float | None, pid: int | None) -> None:
    pids = collections.Counter(r.get("pid") for r in recs)
    print(f"records {len(recs)}; by pid: {dict(pids)}")
    if pid is None:
        if xid is not None:
            before = [r for r in recs if r.get("ts", 0) <= xid + 1]
            pid = before[-1].get("pid") if before else None
        else:
            pid = recs[-1].get("pid") if recs else None
    sel = [r for r in recs if r.get("pid") == pid]
    print(f"pid {pid}: {len(sel)} records")
    if not sel:
        print("  ABSENT: no records for that pid -- not a clean run, nothing was read")
        return
    for kind, c in concurrency(sel).items():
        print(f"  {kind:5} submits={c['submits']} max_on_gpu={c['max']} "
              f"with_company={c['with_company']} hist={c['hist']}")
    ov = [r for r in sel if r.get("overlap")]
    print(f"  overlaps: {len(ov)} of {sum(1 for r in sel if r.get('ev') == 'submit')} submits")
    for r in ov[-10:]:
        print(fmt(r, xid))
    if xid is not None:
        at = [r for r in sel if r.get("ts", 0) <= xid + 1]
        op = open_entries(at)
        print(f"\nOPEN at the Xid ({len(op)}), times relative to it:")
        for r in op:
            print(fmt(r, xid))
        win = [r for r in at if xid - 20 <= r.get("ts", 0)]
        print(f"\nevery record in [-20 s, +1 s] ({len(win)}), last 30:")
        for r in win[-30:]:
            print(fmt(r, xid))


def selftest() -> int:
    """The analysis against a ledger whose answers are known. Exits non-zero."""
    def sub(i, kind, ts, pid=1, ov=None):
        return {"ev": "submit", "kind": kind, "inner": i, "ts": ts, "pid": pid,
                "job": 1, "group": 0, "n": 1, "bids": [[i, i]], "overlap": ov}

    def done(i, kind, ts, pid=1):
        return {"ev": "done", "kind": kind, "inner": i, "ts": ts, "pid": pid, "ok": True}

    recs = [sub(1, "load", 1), sub(2, "load", 2), sub(3, "load", 3),   # 3 at once
            done(1, "load", 4), sub(1, "store", 4.5),                    # store inner 1 != load inner 1
            done(2, "load", 5), done(3, "load", 6),
            sub(4, "load", 7, ov=[["store", 1]]), done(1, "store", 8)]
    c = concurrency(recs)
    T = 0

    def eq(name, got, want):
        nonlocal T
        ok = got == want
        T |= not ok
        print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"  got {got!r} want {want!r}"))

    eq("load max on the GPU is 3", c["load"]["max"], 3)
    eq("load histogram", c["load"]["hist"], {1: 2, 2: 1, 3: 1})
    eq("two loads had company", c["load"]["with_company"], 2)
    eq("a store does not count toward loads (kind-separated inner ids)",
       c["store"]["max"], 1)
    eq("open entries at the end: load 4 only", [(r["kind"], r["inner"]) for r in open_entries(recs)],
       [("load", 4)])
    eq("open entries before t=3.5: loads 1,2,3",
       [r["inner"] for r in open_entries([r for r in recs if r["ts"] <= 3.5])], [1, 2, 3])
    eq("--xid parses the short-precise form",
       parse_xid("2026-10-14 10:12:17.387186"), 1791972737.387186)
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
        f.write('{"ev":"sub')                    # torn final line
    eq("a torn final line is skipped", len(load(f.name)), len(recs))
    os.unlink(f.name)
    print("SELFTEST " + ("GREEN" if T == 0 else "RED"))
    return T


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--xid", help="Xid time, UTC 'YYYY-MM-DD HH:MM:SS.ffffff' or epoch")
    ap.add_argument("--pid", type=int)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.file:
        ap.error("a ledger file is required")
    if not os.path.exists(a.file):
        print(f"ABSENT: {a.file} does not exist -- not an empty ledger")
        return 1
    report(load(a.file), parse_xid(a.xid) if a.xid else None, a.pid)
    return 0


if __name__ == "__main__":
    sys.exit(main())

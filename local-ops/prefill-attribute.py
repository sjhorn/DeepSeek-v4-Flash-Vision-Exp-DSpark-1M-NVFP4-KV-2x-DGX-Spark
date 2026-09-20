#!/usr/bin/env python3
"""Attribute full-prefill MISSES to a live conversation, from the server log alone.

Why this exists: `prompt-tap.py` can only measure a session that was LAUNCHED
through it -- ANTHROPIC_BASE_URL is fixed at process start, so a session already
in flight can never be tapped. But Patch 12 is already logging every request
server-side, and the engine already logs prompt throughput every 10s. Together
they are enough to say, per turn, "this one re-prefilled from cold".

It answers the question the tripwire cannot: `prefix-watch.py` reports whether
the HEAD MOVED (invalidation). This reports whether the turn was RECOMPUTED.
A turn with a stable head that still pays a full prefill was EVICTED -- a
pool-pressure problem, not a prompt problem. The two tools are complements.

    ssh shorn@spark-45ea 'docker logs -t --since 90m <container>' \\
      | grep -E "PREFIX_WATCH|Avg prompt throughput" > live.log
    python3 local-ops/prefill-attribute.py --file live.log            # list conversations
    python3 local-ops/prefill-attribute.py --file live.log --conv fe9a3621a5e6

Or LIVE, which is the point of --follow: a miss is only diagnosable with the
concurrency that caused it, and that context is gone by the time you notice the
stall. This adds nothing to the server beyond one read-only `docker logs -f`.

    ssh -o ServerAliveInterval=30 shorn@spark-45ea \
        'docker logs -f -t --since 5m <container>' \
      | python3 -u local-ops/prefill-attribute.py --follow

A request is judged once the engine has logged past its 30s window, so each
verdict lands ~30-40s after the turn. Only MISS and partial turns print (plus
head moves); --all prints every turn.

CAVEATS, because this is an inference and not a measurement:

  * `Avg prompt throughput` is a GLOBAL 10s-sampled gauge. Another
    conversation's prefill lands in the same window, so rows are flagged with
    how many other-conversation requests were nearby; a row with a nonzero flag
    is suggestive, never evidence. Only unflagged rows should carry weight.
  * chars->tokens uses a fixed ~3.6 chars/token ratio measured on this repo's
    Claude Code traffic (e.g. 351,530 chars -> 97,647 tokens). It is a
    ballpark, so the verdict thresholds are deliberately coarse.
  * Conversations are keyed on Patch 12's `user0` (hash of the first user
    message), which COLLIDES when two sessions open with the same short
    message -- probe traffic in particular. Check that a conversation's `len`
    grows monotonically before trusting it as one session.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import re

PW = re.compile(r"^(?P<ts>\S+)\s.*PREFIX_WATCH\s+head=(?P<head>\w+)\s+tools=(?P<tools>\w+)\s+"
                r"sys=(?P<sys>\w+)\s+user0=(?P<u>\w+)\s+len=(?P<len>\d+)")
TP = re.compile(r"^(?P<ts>\S+)\s.*Avg prompt throughput: (?P<tp>[\d.]+) tokens/s"
                r".*KV cache usage: (?P<kv>[\d.]+)%")
CHARS_PER_TOKEN = 3.6
SAMPLE_SECONDS = 10          # the engine's logging interval
WINDOW_SECONDS = 30          # how long after a request its prefill may still be sampled


def _ts(s):
    # docker -t prints 9-digit nanoseconds; fromisoformat accepts at most 6.
    return datetime.datetime.fromisoformat(
        re.sub(r"\.(\d{6})\d*", r".\1", s).replace("Z", "+00:00"))


def parse(path):
    reqs, tps = [], []
    for line in open(path):
        line = line.strip()
        m = PW.match(line)
        if m:
            reqs.append({"t": _ts(m["ts"]), "u": m["u"], "len": int(m["len"]),
                         "head": m["head"], "tools": m["tools"], "sys": m["sys"]})
            continue
        m = TP.match(line)
        if m:
            tps.append((_ts(m["ts"]), float(m["tp"]), float(m["kv"])))
    return reqs, tps


def follow(stream, conv=None, show_all=False):
    """Classify turns as the log arrives. Never blocks on a turn still in flight."""
    pending: list[dict] = []
    tps: list[tuple] = []
    shapes: dict[str, tuple] = {}
    seen = collections.Counter()
    stats = collections.Counter()

    def flush(now):
        """Judge every request whose 30s sampling window has fully elapsed."""
        keep = []
        for r in pending:
            if (now - r["t"]).total_seconds() <= WINDOW_SECONDS:
                keep.append(r)
                continue
            tot = sum(tp * SAMPLE_SECONDS for tt, tp, _ in tps
                      if 0 <= (tt - r["t"]).total_seconds() <= WINDOW_SECONDS)
            kv = [k for tt, _, k in tps
                  if 0 <= (tt - r["t"]).total_seconds() <= WINDOW_SECONDS]
            near = sum(1 for o in pending + judged_recent
                       if o["u"] != r["u"]
                       and abs((o["t"] - r["t"]).total_seconds()) <= WINDOW_SECONDS)
            approx = r["len"] / CHARS_PER_TOKEN
            frac = tot / approx if approx else 0.0
            verdict = ("MISS (full prefill)" if frac > 0.6
                       else "partial" if frac > 0.15 else "HIT (cached)")
            stats[verdict.split()[0]] += 1
            if show_all or frac > 0.15:
                print(f"{r['t']:%H:%M:%S} {r['u']} {r['len']:>8,}c "
                      f"~{approx:>7,.0f}tok  prefill {tot:>9,.0f}  "
                      f"KV {max(kv) if kv else 0:>5.1f}%  {verdict}"
                      + (f"  [{near} other-conv nearby -- not clean]" if near else ""),
                      flush=True)
            judged_recent.append(r)
        del judged_recent[:-40]
        pending[:] = keep
        # samples older than any pending request can never be needed again
        cutoff = min([r["t"] for r in pending], default=now)
        tps[:] = [x for x in tps
                  if (cutoff - x[0]).total_seconds() <= WINDOW_SECONDS + SAMPLE_SECONDS]

    judged_recent: list[dict] = []
    print("following the server log -- MISS and partial turns print ~30-40s after the turn",
          flush=True)
    print(f"{'turn':>8} {'conversation':<13} {'chars':>9} {'tokens':>8}  "
          f"{'prefill':>9}  {'KV':>6}  verdict", flush=True)
    for line in stream:
        line = line.strip()
        m = PW.match(line)
        if m:
            r = {"t": _ts(m["ts"]), "u": m["u"], "len": int(m["len"]),
                 "head": m["head"], "tools": m["tools"], "sys": m["sys"]}
            if conv and r["u"] != conv:
                continue
            shape = (r["head"], r["tools"], r["sys"])
            if r["u"] in shapes and shapes[r["u"]] != shape and seen[r["u"]] > 0:
                changed = [n for n, i in (("head", 0), ("tools", 1), ("sys", 2))
                           if shapes[r["u"]][i] != shape[i]]
                print(f"{r['t']:%H:%M:%S} {r['u']} !! HEAD MOVED ({'+'.join(changed)}) "
                      f"-- invalidation, not eviction; see prefix-watch.py", flush=True)
            shapes[r["u"]] = shape
            seen[r["u"]] += 1
            pending.append(r)
            continue
        m = TP.match(line)
        if m:
            now = _ts(m["ts"])
            tps.append((now, float(m["tp"]), float(m["kv"])))
            flush(now)
    print(f"\nstream ended -- {stats['MISS']} MISS, {stats['partial']} partial, "
          f"{stats['HIT']} HIT", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="saved log; omit with --follow to read stdin")
    ap.add_argument("--conv", help="user0 hash; omit to list conversations")
    ap.add_argument("--follow", action="store_true",
                    help="stream from stdin and judge turns as they complete")
    ap.add_argument("--all", action="store_true",
                    help="--follow: print every turn, not just MISS/partial")
    a = ap.parse_args()

    if a.follow:
        import sys
        follow(open(a.file) if a.file else sys.stdin, conv=a.conv, show_all=a.all)
        return
    if not a.file:
        raise SystemExit("--file is required without --follow")

    reqs, tps = parse(a.file)
    if not reqs:
        raise SystemExit("no PREFIX_WATCH lines -- is Patch 12 live (PREFIX_WATCH=0 disables it)?")

    if not a.conv:
        print(f"{len(reqs)} requests, {len(tps)} engine samples\n")
        print(f"{'conversation':<14} {'reqs':>5} {'first':>9} {'last':>9} "
              f"{'len first':>10} {'len last':>10}  head-stable?")
        for u, n in collections.Counter(r["u"] for r in reqs).most_common():
            rs = [r for r in reqs if r["u"] == u]
            stable = len({(r["head"], r["tools"], r["sys"]) for r in rs}) == 1
            print(f"{u:<14} {n:>5} {rs[0]['t']:%H:%M:%S} {rs[-1]['t']:%H:%M:%S} "
                  f"{rs[0]['len']:>10,} {rs[-1]['len']:>10,}  "
                  f"{'yes' if stable else 'NO -- head moved'}")
        print("\nRe-run with --conv <hash> for the per-turn breakdown.")
        return

    rs = [r for r in reqs if r["u"] == a.conv]
    if not rs:
        raise SystemExit(f"no requests for conversation {a.conv}")
    shapes = {(r["head"], r["tools"], r["sys"]) for r in rs}
    print(f"conversation {a.conv}: {len(rs)} requests, "
          f"{rs[0]['t']:%H:%M:%S}-{rs[-1]['t']:%H:%M:%S}")
    print(f"head/tools/sys shapes seen: {len(shapes)} "
          f"({'STABLE -- any miss below is EVICTION, not invalidation' if len(shapes) == 1 else 'CHANGED -- run prefix-watch.py, the head moved'})\n")
    print(f"{'turn':>8} {'chars':>8} {'~tok':>7} {'prefill tok':>12}  verdict")

    miss = partial = hit = 0
    for r in rs:
        tot = sum(tp * SAMPLE_SECONDS for tt, tp, _ in tps
                  if 0 <= (tt - r["t"]).total_seconds() <= WINDOW_SECONDS)
        near = sum(1 for o in reqs if o["u"] != a.conv
                   and abs((o["t"] - r["t"]).total_seconds()) <= WINDOW_SECONDS)
        approx = r["len"] / CHARS_PER_TOKEN
        frac = tot / approx if approx else 0.0
        if frac > 0.6:
            v, _b = "MISS (full prefill)", miss
            miss += 1
        elif frac > 0.15:
            v = "partial"
            partial += 1
        else:
            v = "HIT (cached)"
            hit += 1
        print(f"{r['t']:%H:%M:%S} {r['len']:>8,} {approx:>7,.0f} {tot:>12,.0f}  {v}"
              + (f"  [{near} other-conv req nearby -- not clean]" if near else ""))

    print(f"\n{miss} full-prefill MISS, {partial} partial, {hit} cached HIT")
    if miss and len(shapes) == 1:
        print("\nHead never moved, yet turns re-prefilled => EVICTION under pool pressure.\n"
              "Check concurrent conversations above and `GPU KV cache usage` in the log.")


if __name__ == "__main__":
    main()

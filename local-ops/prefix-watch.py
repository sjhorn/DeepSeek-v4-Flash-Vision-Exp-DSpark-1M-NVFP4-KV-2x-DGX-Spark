#!/usr/bin/env python3
"""Phase 5 tripwire: notice when the prompt HEAD moves under a live conversation.

Reads the guardrail line the server emits once per request and flags the one
event that costs minutes: a conversation we have seen before arriving with a
different tools- or system- or first-user-turn hash. Everything after the
changed byte is re-prefilled, and a cold 54K prefill measured 194s here.

    # live, on the head node
    journalctl -fu docker --since now | python3 local-ops/prefix-watch.py
    # or against a container
    ssh shorn@spark-45ea 'docker logs -f <container>' | python3 local-ops/prefix-watch.py

    # or after the fact
    python3 local-ops/prefix-watch.py --file saved.log

The server line looks like:

    PREFIX_WATCH head=ab12cd34ef56 tools=0011aabb2233 sys=44556677
                 user0=99aabbccddee len=54321

Memory is a rolling 1-HOUR window, trimmed on write and size-capped, so a
long-running watcher cannot grow without bound. ALERTS are kept separately and
never rotated: they are rare, and they are the entire point.

Conversations are keyed on `user0` -- the hash of the FIRST USER MESSAGE.
The obvious key, `head` (the first 2KB of the rendered prompt), does not work:
that slice is Claude Code's own system-prompt header, which is byte-identical
across every session, so all concurrent sessions collapse into one group and
each one's tool set reads as the other's head moving. Measured: a tier-switch
test raised 3 alerts, 2 of them purely the other client interleaving.

Alerts are split by confidence, on whether the rendered prompt GREW:

  CONFIRMED  len increased -- a real conversation only ever appends, so this is
             the same conversation continuing with a different head.
  ambiguous  len stayed the same or shrank -- more likely two different
             conversations that happen to open with the same user message.
             (Found by running this against live traffic: `cache-probe.py
             --selftest` sends probes whose first user message is always
             "Reply with the single word OK.", and all seven reads of it
             collided into one group.)

Known limit: if the first user message itself mutates, that conversation reads
as a NEW one rather than as an alert. Claude Code only does this with
ENABLE_TOOL_SEARCH=true, which puts the deferred-tool name list inside msg[0]
-- and measurement rejected that mode anyway (see CLAUDE.md). Under the mode we
run, msg[0] is stable for the life of the conversation.
"""
from __future__ import annotations

import argparse
import collections
import re
import sys
import time

LINE = re.compile(
    r"PREFIX_WATCH\s+head=(?P<head>\w+)\s+tools=(?P<tools>\w+)\s+"
    r"sys=(?P<sys>\w+)\s+user0=(?P<user0>\w+)\s+len=(?P<len>\d+)")

WINDOW = 3600          # seconds of history kept
MAX_GROUPS = 5000      # hard cap so a pathological stream cannot grow memory


class Watcher:
    def __init__(self, window=WINDOW):
        self.window = window
        self.seen = collections.OrderedDict()   # user0 -> (ts, tools, sys, head, len)
        self.alerts = []                        # never rotated
        self.n = 0

    def _trim(self, now):
        cutoff = now - self.window
        for conv in [h for h, v in self.seen.items() if v[0] < cutoff]:
            del self.seen[conv]
        while len(self.seen) > MAX_GROUPS:
            self.seen.popitem(last=False)

    def feed(self, m, now=None):
        now = time.time() if now is None else now
        self.n += 1
        conv = m["user0"]
        cur = (now, m["tools"], m["sys"], m["head"], int(m["len"]))
        prev = self.seen.get(conv)
        alert = None
        if prev:
            changed = [k for k, i in (("tools", 1), ("system", 2), ("prompt-head", 3))
                       if prev[i] != cur[i]]
            if changed:
                alert = {
                    "when": time.strftime("%H:%M:%S"),
                    "head": conv,
                    "changed": changed,
                    "was": {"tools": prev[1], "sys": prev[2], "head": prev[3], "len": prev[4]},
                    "now": {"tools": cur[1], "sys": cur[2], "head": cur[3], "len": cur[4]},
                    "age_s": round(now - prev[0], 1),
                    "confirmed": cur[4] > prev[4],
                }
                self.alerts.append(alert)
        self.seen[conv] = cur
        self.seen.move_to_end(conv)
        self._trim(now)
        return alert


def render(a):
    tag = "!! HEAD MOVED " if a["confirmed"] else "?  possible move"
    return (f"\n{tag}  {a['when']}  conversation {a['head']}  "
            f"({', '.join(a['changed'])} changed, {a['age_s']}s since last seen)\n"
            f"     was  tools={a['was']['tools']} sys={a['was']['sys']} "
            f"head={a['was']['head']} len={a['was']['len']:,}\n"
            f"     now  tools={a['now']['tools']} sys={a['now']['sys']} "
            f"head={a['now']['head']} len={a['now']['len']:,}\n"
            f"     everything after the changed part re-prefills"
            + ("" if a["confirmed"] else
               "   (did not grow -- more likely a second conversation with the "
               "same opening message)"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="read from a file instead of stdin")
    ap.add_argument("--window", type=int, default=WINDOW,
                    help="seconds of conversation history to remember (default 3600)")
    ap.add_argument("--quiet", action="store_true", help="print alerts only")
    a = ap.parse_args()

    w = Watcher(a.window)
    src = open(a.file) if a.file else sys.stdin
    t0 = time.time()
    try:
        for line in src:
            m = LINE.search(line)
            if not m:
                continue
            alert = w.feed(m.groupdict())
            if alert and (alert["confirmed"] or not a.quiet):
                print(render(alert), flush=True)
            elif not a.quiet and w.n % 50 == 0:
                print(f"   .. {w.n} requests, {len(w.seen)} conversations tracked, "
                      f"{len(w.alerts)} alerts", flush=True)
    except KeyboardInterrupt:
        pass

    confirmed = [x for x in w.alerts if x["confirmed"]]
    print(f"\n{w.n} guardrail lines over {round(time.time()-t0)}s: "
          f"{len(confirmed)} head-moved alert(s)"
          + (f", {len(w.alerts) - len(confirmed)} ambiguous" if len(w.alerts) > len(confirmed)
             else ""))
    return 1 if confirmed else 0


if __name__ == "__main__":
    sys.exit(main())

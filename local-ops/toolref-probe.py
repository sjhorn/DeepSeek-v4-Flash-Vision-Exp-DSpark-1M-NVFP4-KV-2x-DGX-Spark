#!/usr/bin/env python3
"""T2.1 -- exercise the `tool_reference` block, which has never run in anger.

Adopting ENABLE_TOOL_SEARCH means trusting a protocol path we have observed
ZERO times in the wild. Reading the server:

  * `serving.py:882` -- a TOP-LEVEL tool_reference block hits a bare `pass`.
    Accepted by the protocol model, then silently dropped.
  * `serving.py:947-981` -- a tool_reference INSIDE a tool_result becomes a
    second `role:"tool"` message whose `content` is a LIST OF DICTS
    `[{"type": "tool_reference", "name": X}]`, carrying the tool NAME and no
    schema. A list of non-text parts on a tool message is the shape most
    likely to be rejected downstream, and losing the schema is the shape most
    likely to be accepted and then useless.

So the three questions, in the order they matter:
  Q1  does it 200 or 500?              -- a 500 is a hard blocker
  Q2  does any schema survive?         -- name-only means the model is guessing
  Q3  can the model then CALL it?      -- the only outcome that matters

    python3 local-ops/toolref-probe.py [--base-url http://127.0.0.1:8888]

Run on a QUIET engine: it is cheap, but it is still traffic.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8888"
MODEL = "deepseek-v4-flash-dspark-nothink"

# The tool under reference. Deliberately non-obvious: a model that "calls" it
# from prior knowledge rather than from a surviving schema will get the
# argument names wrong, and that difference is what Q2 actually measures.
SECRET_TOOL = {
    "name": "kvpool_inspect",
    "description": "Inspect the KV cache pool of a running vLLM engine.",
    "input_schema": {
        "type": "object",
        "properties": {
            "engine_rank": {"type": "integer", "description": "TP rank to inspect"},
            "include_blocks": {"type": "boolean", "description": "list block ids"},
        },
        "required": ["engine_rank"],
    },
}


def post(base, body, timeout=600):
    req = urllib.request.Request(
        base + "/v1/messages", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
        method="POST")
    try:
        return 200, json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:1500]
    except Exception as e:                                   # noqa: BLE001
        return -1, repr(e)[:400]


def tool_uses(resp):
    if not isinstance(resp, dict):
        return []
    return [b for b in (resp.get("content") or []) if b.get("type") == "tool_use"]


def text_of(resp):
    if not isinstance(resp, dict):
        return str(resp)[:300]
    return " ".join(b.get("text", "") for b in (resp.get("content") or [])
                    if b.get("type") == "text")[:300]


def case(name, body, base, expect_call=None):
    status, resp = post(base, body)
    calls = tool_uses(resp)
    print(f"\n--- {name}")
    print(f"    HTTP {status}")
    if status != 200:
        print(f"    body: {str(resp)[:600]}")
        return {"case": name, "status": status, "calls": 0, "ok": False}
    print(f"    stop_reason={resp.get('stop_reason')}  tool_use blocks={len(calls)}")
    for c in calls:
        print(f"      -> {c.get('name')}({json.dumps(c.get('input'))})")
    if not calls:
        print(f"    text: {text_of(resp)!r}")
    ok = True
    if expect_call is not None:
        got = bool(calls) and calls[0].get("name") == expect_call
        args_ok = bool(calls) and "engine_rank" in (calls[0].get("input") or {})
        print(f"    Q3 called {expect_call}? {'YES' if got else 'NO'}"
              + (f"   schema-shaped args? {'YES' if args_ok else 'NO'}" if got else ""))
        ok = got
    return {"case": name, "status": status, "calls": len(calls), "ok": ok,
            "names": [c.get("name") for c in calls]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=BASE)
    a = ap.parse_args()
    base = a.base_url.rstrip("/")
    ask = ("Inspect the KV pool of TP rank 0, including block ids. "
           "Use a tool; do not answer in prose.")
    out = []

    print("T2.1 tool_reference probe")
    print("=" * 72)

    # CONTROL -- the tool is declared the ordinary way. If this does not call,
    # nothing below means anything: the failure would be the model, not the
    # tool_reference path.
    out.append(case(
        "CONTROL: tool declared in `tools`",
        {"model": MODEL, "max_tokens": 512, "tools": [SECRET_TOOL],
         "messages": [{"role": "user", "content": ask}]},
        base, expect_call="kvpool_inspect"))

    # Q1a -- top-level tool_reference block (serving.py:882, bare `pass`)
    out.append(case(
        "SHAPE A: top-level tool_reference in an assistant turn",
        {"model": MODEL, "max_tokens": 512, "tools": [],
         "messages": [
             {"role": "user", "content": "Find me a tool for inspecting a KV pool."},
             {"role": "assistant", "content": [
                 {"type": "text", "text": "Here is the tool you asked for."},
                 {"type": "tool_reference", "tool_name": "kvpool_inspect",
                  "name": "kvpool_inspect"}]},
             {"role": "user", "content": ask}]},
        base, expect_call="kvpool_inspect"))

    # Q1b/Q2 -- tool_reference inside a tool_result (serving.py:947-981).
    # This is the shape a real ToolSearch result would take.
    out.append(case(
        "SHAPE B: tool_reference inside a tool_result",
        {"model": MODEL, "max_tokens": 512,
         "tools": [{"name": "ToolSearch", "description": "Find tools by keyword.",
                    "input_schema": {"type": "object",
                                     "properties": {"query": {"type": "string"}},
                                     "required": ["query"]}}],
         "messages": [
             {"role": "user", "content": "Find me a tool for inspecting a KV pool."},
             {"role": "assistant", "content": [
                 {"type": "tool_use", "id": "toolu_probe_1", "name": "ToolSearch",
                  "input": {"query": "kv pool inspect"}}]},
             {"role": "user", "content": [
                 {"type": "tool_result", "tool_use_id": "toolu_probe_1",
                  "content": [
                      {"type": "text", "text": "Found 1 tool."},
                      {"type": "tool_reference", "tool_name": "kvpool_inspect"}]}]},
             {"role": "user", "content": ask}]},
        base, expect_call="kvpool_inspect"))

    # Q2 control -- same as SHAPE B but the schema is ALSO declared. Isolates
    # "the reference did nothing" from "the model cannot call it at all".
    out.append(case(
        "SHAPE B + schema declared (isolates reference vs schema)",
        {"model": MODEL, "max_tokens": 512,
         "tools": [{"name": "ToolSearch", "description": "Find tools by keyword.",
                    "input_schema": {"type": "object",
                                     "properties": {"query": {"type": "string"}},
                                     "required": ["query"]}},
                   SECRET_TOOL],
         "messages": [
             {"role": "user", "content": "Find me a tool for inspecting a KV pool."},
             {"role": "assistant", "content": [
                 {"type": "tool_use", "id": "toolu_probe_2", "name": "ToolSearch",
                  "input": {"query": "kv pool inspect"}}]},
             {"role": "user", "content": [
                 {"type": "tool_result", "tool_use_id": "toolu_probe_2",
                  "content": [
                      {"type": "text", "text": "Found 1 tool."},
                      {"type": "tool_reference", "tool_name": "kvpool_inspect"}]}]},
             {"role": "user", "content": ask}]},
        base, expect_call="kvpool_inspect"))

    print("\n" + "=" * 72)
    print("VERDICT")
    for r in out:
        print(f"  {r['case']:<52} HTTP {r['status']:<5} calls={r['calls']} "
              f"{'OK' if r['ok'] else 'no'}")
    blocker = any(r["status"] not in (200,) for r in out)
    print("\n  Q1 transport:", "BROKEN -- a tool_reference shape errors" if blocker
          else "fine -- every shape returns 200")
    print("  Q2 schema:   ", "survives" if out[2]["ok"]
          else "does NOT survive -- a reference carries the NAME only")
    print("  Q3 callable: ", "yes" if out[2]["ok"] else "no, not from a reference alone")
    return 1 if blocker else 0


if __name__ == "__main__":
    sys.exit(main())

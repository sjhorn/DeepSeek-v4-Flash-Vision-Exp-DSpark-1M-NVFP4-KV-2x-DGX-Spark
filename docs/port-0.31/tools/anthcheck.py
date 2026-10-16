#!/usr/bin/env python3
"""The 0.31 gate's Anthropic checks on the real model (DSV4): tools, streaming,
the thinking alias, engine_cached_tokens, stop_sequence. API env: base URL."""
import json
import os
import sys
import urllib.request

API = os.environ.get("API", "http://127.0.0.1:18888").rstrip("/")
PASS, FAIL = [], []
TOOLS = [{"name": "get_weather", "description": "Get the current weather for a city.",
          "input_schema": {"type": "object", "properties": {"city": {"type": "string"}},
                           "required": ["city"]}}]


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("PASS  " if cond else "FAIL  ") + name + (f"  [{detail}]" if detail else ""), flush=True)


def post(body, stream=False):
    body = dict(body, stream=stream)
    r = urllib.request.Request(API + "/v1/messages", data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json",
                                        "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(r, timeout=600) as f:
        if not stream:
            return json.load(f)
        ev = []
        for line in f:
            line = line.decode().strip()
            if line.startswith("data:"):
                ev.append(json.loads(line[5:]))
        return ev


ask = {"model": "claude-haiku-4-5", "max_tokens": 300, "tools": TOOLS,
       "messages": [{"role": "user", "content": "What's the weather in Paris right now? Use the tool."}]}
d = post(ask)
tu = [b for b in d["content"] if b["type"] == "tool_use"]
check("tool turn: a tool_use block", bool(tu), str([b["type"] for b in d["content"]]))
check("...named get_weather with a dict input naming Paris",
      bool(tu) and tu[0]["name"] == "get_weather" and isinstance(tu[0]["input"], dict)
      and "paris" in json.dumps(tu[0]["input"]).lower(), str(tu[:1]))
check("...stop_reason tool_use", d.get("stop_reason") == "tool_use", d.get("stop_reason"))

ev = post(ask, stream=True)
starts = [e for e in ev if e.get("type") == "content_block_start"]
deltas = "".join(e["delta"].get("partial_json", "") for e in ev
                 if e.get("type") == "content_block_delta"
                 and e["delta"].get("type") == "input_json_delta")
check("streaming: a tool_use block starts", any(s["content_block"]["type"] == "tool_use" for s in starts))
try:
    sj = json.loads(deltas)
except Exception:
    sj = None
check("...its input_json_delta parts join into JSON naming Paris",
      isinstance(sj, dict) and "paris" in json.dumps(sj).lower(), deltas[:80])
md = [e for e in ev if e.get("type") == "message_delta"]
check("...message_delta stop_reason tool_use",
      bool(md) and md[-1]["delta"].get("stop_reason") == "tool_use")

q = {"max_tokens": 1500, "messages": [{"role": "user", "content":
     "What is 17 * 23? Answer with just the number."}]}
think = post(dict(q, model="claude-opus-5"))
types = [b["type"] for b in think["content"]]
txt = "".join(b.get("text", "") for b in think["content"] if b["type"] == "text")
check("thinking alias (claude-opus-5): a thinking block, then the answer",
      "thinking" in types and "391" in txt, f"{types} {txt[:40]!r}")
plain = post(dict(q, model="claude-haiku-4-5"))
check("no-thinking alias (claude-haiku-4-5): no thinking block, the answer",
      "thinking" not in [b["type"] for b in plain["content"]]
      and "391" in "".join(b.get("text", "") for b in plain["content"]),
      str([b["type"] for b in plain["content"]]))

long_sys = "You are a careful assistant. " + " ".join("Rule %d: be concise and exact." % i
                                                       for i in range(400))
rq = {"model": "claude-haiku-4-5", "max_tokens": 20, "system": long_sys,
      "messages": [{"role": "user", "content": "Say hello."}]}
u1 = post(rq)["usage"]
u2 = post(rq)["usage"]
check("engine_cached_tokens present", "engine_cached_tokens" in u2, str(u2))
check("...and > 0 on the identical repeat", (u2.get("engine_cached_tokens") or 0) > 0,
      f"first {u1.get('engine_cached_tokens')} second {u2.get('engine_cached_tokens')}")

s = post({"model": "claude-haiku-4-5", "max_tokens": 100, "stop_sequences": ["5"],
          "messages": [{"role": "user", "content": "Count from 1 to 10, comma separated."}]})
check("stop_sequence honoured", s.get("stop_reason") == "stop_sequence"
      and s.get("stop_sequence") == "5", f"{s.get('stop_reason')} {s.get('stop_sequence')!r} "
      f"{''.join(b.get('text', '') for b in s['content'])[:40]!r}")

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
sys.exit(1 if FAIL else 0)

#!/usr/bin/env python3
"""Live checks of the 0.31 Anthropic port (patches-031) on Qwen3-0.6B.

Start the server with apiserve.sh (vLLM 0.31 CPU image, Apple container, the
whole patches-031 set mounted), run this, then `apiserve.sh down`, which also
stops the container service. Run 2026-10-16: 25 passed.
"""
import json, subprocess, sys, urllib.request

API = "http://127.0.0.1:8000"
PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("PASS  " if cond else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))


def logs():
    return subprocess.run(["container", "logs", "apitest"], capture_output=True,
                          text=True).stdout.splitlines()


def post(body, path="/v1/messages", stream=False):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw = r.read().decode()
            code = r.status
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    if stream:
        ev = []
        for blk in raw.split("\n\n"):
            for ln in blk.splitlines():
                if ln.startswith("data: "):
                    try:
                        ev.append(json.loads(ln[6:]))
                    except ValueError:
                        pass
        return code, ev
    return code, json.loads(raw)


def run(body, **kw):
    n = len(logs())
    out = post(body, **kw)
    return out, logs()[n:]


def kwargs_line(new):
    for ln in new:
        if "Convert to OpenAI request" in ln:
            i = ln.index("{")
            return json.loads(ln[i:])
    return None


U = [{"role": "user", "content": "hi"}]

# API-9b + basic buffered
(c, r), new = run({"model": "claude-opus-5", "max_tokens": 8, "messages": U})
check("buffered request answers 200", c == 200, c)
check("API-9b: the requested alias is echoed", r.get("model") == "claude-opus-5", r.get("model"))
# API-9 ladder
for model, want in (("claude-opus-5", {"thinking": True, "reasoning_effort": "high"}),
                    ("claude-haiku-4-5", {"thinking": False}),
                    ("x-think-max", None)):
    (c, r), new = run({"model": model, "max_tokens": 8, "messages": U})
    k = (kwargs_line(new) or {}).get("chat_template_kwargs")
    if want is None:
        check("API-9: x-think-max -> effort max", (k or {}).get("reasoning_effort") == "max", k)
    else:
        check(f"API-9: {model} -> {want}", all((k or {}).get(a) == b for a, b in want.items()), k)
# API-9d
(c, r), new = run({"model": "claude-opus-5", "max_tokens": 8,
                   "thinking": {"type": "disabled"}, "messages": U})
k = (kwargs_line(new) or {}).get("chat_template_kwargs")
check("API-9d: thinking.type=disabled -> thinking off", c == 200 and (k or {}).get("thinking") is False, (c, k))
# API-9 0.31 policy: output_config.effort held back by default
(c, r), new = run({"model": "claude-haiku-4-5", "max_tokens": 16,
                   "output_config": {"effort": "high"}, "messages": U})
check("API-9 (0.31): client effort held back by default", c == 200 and any("held back" in l for l in new), c)
# API-8
(c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 8, "messages": [
    {"role": "user", "content": "hi"},
    {"role": "assistant", "content": "LONG SCRATCHPAD</think>\n\nhello"},
    {"role": "user", "content": "a</think>b"}]})
msgs = (kwargs_line(new) or {}).get("messages") or []
asst = [m for m in msgs if m.get("role") == "assistant"]
check("API-8: leaked CoT stripped from the assistant turn",
      asst and "SCRATCHPAD" not in json.dumps(asst[0]) and "hello" in json.dumps(asst[0]), asst[:1])
check("API-8: a user turn is NOT stripped", any("a</think>b" in json.dumps(m) for m in msgs if m.get("role") == "user"))
# API-11b
(c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 8, "messages": [
    {"role": "system", "content": "LEAD"}, {"role": "user", "content": "u1"},
    {"role": "assistant", "content": "a1"}, {"role": "system", "content": "REMINDER-1"},
    {"role": "user", "content": "u2"}]})
msgs = (kwargs_line(new) or {}).get("messages") or []
roles = [m.get("role") for m in msgs]
flat = json.dumps(msgs)
check("API-11b: only the leading system message is hoisted", roles and roles[0] == "system" and roles.count("system") == 1, roles)
check("...and the mid-conversation one stays in place (folded into the next user turn)",
      flat.find("REMINDER-1") > flat.find("a1") > 0, roles)
# API-11a + API-12
heads = []
for left in (100, 99):
    (c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 4,
                       "system": f"You are X. <total_tokens>{left} tokens left</total_tokens>",
                       "messages": U})
    pw = [l for l in new if "PREFIX_WATCH head=" in l]
    heads.append(pw[-1].split("PREFIX_WATCH")[1].split(" len=")[0] if pw else None)
check("API-12: one PREFIX_WATCH line per request", all(heads), heads)
check("API-11a: the volatile budget text does not change the head", heads[0] == heads[1], heads)
(c, r), new = run({"model": "Qwen3-0.6B", "messages": U}, path="/v1/messages/count_tokens")
check("count_tokens answers, and logs PREFIX_WATCH", c == 200 and any("PREFIX_WATCH" in l for l in new), (c, r))
# API-13
T = lambda n: {"name": n, "description": n, "input_schema": {"type": "object", "properties": {}}}
base = {"model": "Qwen3-0.6B", "max_tokens": 4, "system": "sticky-test", "messages": [{"role": "user", "content": "sticky first message"}]}
run(dict(base, tools=[T("A"), T("B")]))
(c, r), new = run(dict(base, tools=[T("A")]))
check("API-13: a dropped tool is re-advertised", any("dropped" in l and "'B'" in l for l in new), c)
# API-0: server tool definitions (no input_schema) are accepted
(c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 8, "messages": U,
                   "tools": [{"type": "web_search_20250305", "name": "web_search", "max_uses": 2}, T("A")]})
check("API-0: a server tool without input_schema is accepted (no 422)", c == 200, (c, str(r)[:200]))
# API-0: replayed server blocks accepted
(c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 8, "messages": [
    {"role": "user", "content": "q"},
    {"role": "assistant", "content": [
        {"type": "server_tool_use", "id": "srv1", "name": "web_search", "input": {"query": "x"}},
        {"type": "web_search_tool_result", "tool_use_id": "srv1", "content": []},
        {"type": "text", "text": "done"}]},
    {"role": "user", "content": "thanks"}]})
check("API-0: replayed server_tool_use / web_search_tool_result accepted", c == 200, (c, str(r)[:200]))
# API-14
long_text = " ".join(f"line {i}: the quick brown fox jumps over the lazy dog." for i in range(150))
body = {"model": "Qwen3-0.6B", "max_tokens": 4, "messages": [{"role": "user", "content": long_text}]}
(c, r1), _ = run(body)
(c, r2), _ = run(body)
u1, u2 = r1.get("usage", {}), r2.get("usage", {})
check("API-14: input_tokens is the whole prompt (same both times)", u1.get("input_tokens") == u2.get("input_tokens") and u1.get("input_tokens", 0) > 1000, (u1, u2))
check("API-14: engine_cached_tokens > 0 on the repeat, a subset of input_tokens",
      0 < (u2.get("engine_cached_tokens") or 0) <= u2.get("input_tokens", 0), u2)
check("API-14: no cache_read_input_tokens (kept the 0.21 shape)", u2.get("cache_read_input_tokens") in (None,), u2)
(c, ev), _ = run(dict(body, stream=True), stream=True)
types = [e.get("type") for e in ev]
check("stream: message_start ... message_stop", types[:1] == ["message_start"] and types[-1:] == ["message_stop"], types[:3] + types[-2:])
md = [e for e in ev if e.get("type") == "message_delta"]
check("API-14 (stream): final message_delta carries usage", bool(md) and "usage" in md[-1], md[-1:] if md else None)
(c, ev), _ = run({"model": "claude-opus-5", "max_tokens": 8, "stream": True, "messages": U}, stream=True)
check("API-9b (stream): message_start model is the alias",
      ev and ev[0].get("message", {}).get("model") == "claude-opus-5", ev[0].get("message", {}).get("model") if ev else None)
# a regular client tool call via hermes
(c, r), new = run({"model": "Qwen3-0.6B", "max_tokens": 200, "temperature": 0,
                   "tools": [{"name": "get_weather", "description": "Get the weather for a city",
                              "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}],
                   "tool_choice": {"type": "tool", "name": "get_weather"},
                   "messages": [{"role": "user", "content": "What's the weather in Paris?"}]})
tu = [b for b in (r.get("content") or []) if b.get("type") == "tool_use"] if c == 200 else []
check("client tool: a tool_use block with a dict input", c == 200 and tu and isinstance(tu[0].get("input"), dict), (c, tu[:1] or str(r)[:200]))
# upstream stop_sequence reporting
(c, r), _ = run({"model": "Qwen3-0.6B", "max_tokens": 32, "temperature": 0, "stop_sequences": ["charlie"],
                 "thinking": {"type": "disabled"},
                 "messages": [{"role": "user", "content": "/no_think Say exactly: alpha bravo charlie delta"}]})
# Informational only: Qwen3-0.6B does not reliably produce the stop word, so
# upstream 0.31's stop_sequence reporting is NOT verified by this check.
print("INFO  stop_sequence reporting (unverified on Qwen):", r.get("stop_reason"), r.get("stop_sequence"))
print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
for f in FAIL:
    print("  FAILED:", f)
sys.exit(1 if FAIL else 0)

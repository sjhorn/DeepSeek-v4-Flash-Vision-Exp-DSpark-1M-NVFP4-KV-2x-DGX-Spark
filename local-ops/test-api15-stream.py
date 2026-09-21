"""API-15 unit test -- the streamed server-tool turn, without the cluster.

WHY IT RUNS IN THE CONTAINER AND NOT ON THE MAC. The code under test builds
real vLLM/pydantic objects (ChatCompletionStreamResponse, AnthropicStreamEvent),
so the test needs the image's site-packages. It does NOT need the engine, a
restart, or a GPU: it imports the patch file as a standalone module from /tmp
and feeds it scripted engine streams.

    C=<container>
    scp patches/anthropic_serving_inline_system.py shorn@spark-45ea:/tmp/api15_serving.py
    scp local-ops/test-api15-stream.py             shorn@spark-45ea:/tmp/test_api15.py
    ssh shorn@spark-45ea "docker cp /tmp/api15_serving.py $C:/tmp/api15_serving.py &&
                          docker cp /tmp/test_api15.py    $C:/tmp/test_api15.py &&
                          docker exec $C python3 /tmp/test_api15.py"

It imports from /tmp deliberately: the bind-mounted path inside the container
still resolves to the inode the engine imported at boot, so testing "the file in
the container" would test the OLD code and say nothing about the change.

What it pins (31 checks): one message_start/message_delta/message_stop per turn
however many engine segments it took; block indices continuous and monotonic
across segments; server_tool_use + result emitted IN LINE where the call
happened; no raw tool_use for a server tool ever reaching the client; the tool
executed exactly once; output tokens summed while input/cached stay the turn's;
the round cap yielding pause_turn; a client-side tool ending the turn instead of
resuming; malformed arguments degrading to a recoverable tool failure with a
string body; and a text_delta whose bytes look like the index field surviving
re-indexing intact (the regex approach the old wrapper used corrupts it).
"""
import asyncio, importlib.util, json, sys, types

spec = importlib.util.spec_from_file_location("api15_serving", "/tmp/api15_serving.py")
m = importlib.util.module_from_spec(spec)
sys.modules["api15_serving"] = m
spec.loader.exec_module(m)

S = m.AnthropicServingMessages


def chunk(**delta_kw):
    d = {"id": "cmpl-1", "object": "chat.completion.chunk", "created": 1,
         "model": "test", "choices": [{"index": 0, "delta": delta_kw,
                                       "finish_reason": None}]}
    return "data: " + json.dumps(d) + "\n\n"


def finish(reason):
    d = {"id": "cmpl-1", "object": "chat.completion.chunk", "created": 1,
         "model": "test", "choices": [{"index": 0, "delta": {},
                                       "finish_reason": reason}]}
    return "data: " + json.dumps(d) + "\n\n"


def usage(prompt, completion, cached=None):
    u = {"prompt_tokens": prompt, "completion_tokens": completion,
         "total_tokens": prompt + completion}
    if cached is not None:
        u["prompt_tokens_details"] = {"cached_tokens": cached}
    d = {"id": "cmpl-1", "object": "chat.completion.chunk", "created": 1,
         "model": "test", "choices": [], "usage": u}
    return "data: " + json.dumps(d) + "\n\n"


def head():
    return usage(0, 0)


def text_seg(parts, fin="stop", p=100, c=10, cached=None):
    out = [head()]
    for t in parts:
        out.append(chunk(content=t))
    out.append(finish(fin))
    out.append(usage(p, c, cached))
    out.append("data: [DONE]\n\n")
    return out


def tool_seg(pre_text, name, args, p=100, c=10, cached=None, tool_id="call_1"):
    out = [head()]
    for t in pre_text:
        out.append(chunk(content=t))
    out.append(chunk(tool_calls=[{"index": 0, "id": tool_id, "type": "function",
                                  "function": {"name": name, "arguments": ""}}]))
    out.append(chunk(tool_calls=[{"index": 0, "function": {"arguments": args}}]))
    out.append(finish("tool_calls"))
    out.append(usage(p, c, cached))
    out.append("data: [DONE]\n\n")
    return out


def make(segments, executed):
    self = object.__new__(S)
    self.stop_reason_map = {"stop": "end_turn", "length": "max_tokens",
                            "tool_calls": "tool_use"}
    queue = list(segments)

    async def fake_create_chat_completion(req, raw):
        seg = queue.pop(0)

        async def gen():
            for item in seg:
                yield item
        return gen()

    self.create_chat_completion = fake_create_chat_completion
    self._execute_server_tool = lambda n, a: (
        executed.append((n, a)) or {"type": "web_search_tool_result",
                                    "content": [{"title": "T", "url": "U",
                                                 "encrypted_content": "S"}]})
    return self


async def run(segments, executed=None, tool_choice="auto"):
    executed = executed if executed is not None else []
    self = make(segments, executed)
    req = types.SimpleNamespace(model="claude-opus-5")
    chat_req = types.SimpleNamespace(stream=True, stream_options=None,
                                     messages=[{"role": "user", "content": "hi"}],
                                     tool_choice=tool_choice)
    events = []
    async for item in self._stream_server_tool_turn(chat_req, req, None):
        ev, payload = m._sse_parts(item)
        events.append((ev, payload))
    return events, executed, chat_req


async def _collect(self, chat_req):
    req = types.SimpleNamespace(model="claude-opus-5")
    return [x async for x in self._stream_server_tool_turn(chat_req, req, None)]


def summarise(events):
    return [(e, (p or {}).get("index"),
             ((p or {}).get("content_block") or {}).get("type")
             or ((p or {}).get("delta") or {}).get("stop_reason"))
            for e, p in events]


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail and not cond else ""))
    return bool(cond)


ok = True
loop = asyncio.new_event_loop()

# --- 1. no tool call: one segment, one message, nothing re-run --------------
events, executed, _ = loop.run_until_complete(run([text_seg(["hello ", "world"], p=100, c=7, cached=96)]))
kinds = [e for e, _ in events]
ok &= check("1 no-tool: one message_start", kinds.count("message_start") == 1)
ok &= check("1 no-tool: one message_delta", kinds.count("message_delta") == 1)
ok &= check("1 no-tool: one message_stop", kinds.count("message_stop") == 1)
ok &= check("1 no-tool: no tool executed", executed == [])
md = [p for e, p in events if e == "message_delta"][0]
ok &= check("1 no-tool: stop_reason end_turn", md["delta"]["stop_reason"] == "end_turn", str(md))
ok &= check("1 no-tool: usage passthrough",
            md["usage"]["input_tokens"] == 100 and md["usage"]["output_tokens"] == 7, str(md["usage"]))
ok &= check("1 no-tool: engine_cached_tokens kept",
            md["usage"].get("engine_cached_tokens") == 96, str(md["usage"]))

# --- 2. server tool: in-line blocks, stitched message, continuous indices ---
executed = []
events, executed, chat_req = loop.run_until_complete(run(
    [tool_seg(["let me look. "], "web_search", '{"query": "x"}', p=100, c=20, cached=90),
     text_seg(["the answer"], p=140, c=30, cached=130)], executed))
kinds = [e for e, _ in events]
ok &= check("2 tool: one message_start", kinds.count("message_start") == 1, str(kinds))
ok &= check("2 tool: one message_delta", kinds.count("message_delta") == 1, str(kinds))
ok &= check("2 tool: one message_stop", kinds.count("message_stop") == 1, str(kinds))
ok &= check("2 tool: executed once", executed == [("web_search", {"query": "x"})], str(executed))
starts = [(p["index"], p["content_block"]["type"]) for e, p in events if e == "content_block_start"]
ok &= check("2 tool: in-line ordering + continuous indices",
            starts == [(0, "text"), (1, "server_tool_use"), (2, "web_search_tool_result"), (3, "text")],
            str(starts))
ok &= check("2 tool: no raw tool_use leaked to client",
            not any(t == "tool_use" for _, t in starts), str(starts))
idxs = [p["index"] for e, p in events if e and e.startswith("content_block")]
ok &= check("2 tool: indices never go backwards", idxs == sorted(idxs), str(idxs))
md = [p for e, p in events if e == "message_delta"][0]
ok &= check("2 tool: output tokens summed", md["usage"]["output_tokens"] == 50, str(md["usage"]))
ok &= check("2 tool: input tokens are the TURN's", md["usage"]["input_tokens"] == 100, str(md["usage"]))
ok &= check("2 tool: stop_reason end_turn", md["delta"]["stop_reason"] == "end_turn", str(md))
roles = [x["role"] for x in chat_req.messages]
ok &= check("2 tool: continuation appended assistant+tool",
            roles == ["user", "assistant", "tool"], str(roles))
ok &= check("2 tool: tool result text is the shared formatter",
            "Title: T" in chat_req.messages[-1]["content"], chat_req.messages[-1]["content"])

# --- 3. round cap -> pause_turn ---------------------------------------------
m._SERVER_TOOL_MAX_ROUNDS = 2
executed = []
segs = [tool_seg([], "web_search", '{"query": "a"}', tool_id="c1"),
        tool_seg([], "web_search", '{"query": "b"}', tool_id="c2"),
        tool_seg([], "web_search", '{"query": "c"}', tool_id="c3")]
events, executed, _ = loop.run_until_complete(run(segs, executed))
md = [p for e, p in events if e == "message_delta"][0]
ok &= check("3 cap: pause_turn", md["delta"]["stop_reason"] == "pause_turn", str(md))
ok &= check("3 cap: stopped at the cap", len(executed) == 2, str(executed))
m._SERVER_TOOL_MAX_ROUNDS = 10

# --- 4. client-side tool alongside: end the turn, do not resume -------------
executed = []
seg = [head(),
       chunk(tool_calls=[{"index": 0, "id": "s1", "type": "function",
                          "function": {"name": "web_search", "arguments": ""}}]),
       chunk(tool_calls=[{"index": 0, "function": {"arguments": '{"query":"q"}'}}]),
       chunk(tool_calls=[{"index": 1, "id": "c1", "type": "function",
                          "function": {"name": "Read", "arguments": ""}}]),
       chunk(tool_calls=[{"index": 1, "function": {"arguments": '{"f":"x"}'}}]),
       finish("tool_calls"), usage(100, 12), "data: [DONE]\n\n"]
events, executed, _ = loop.run_until_complete(run([seg], executed))
kinds = [e for e, _ in events]
md = [p for e, p in events if e == "message_delta"][0]
ok &= check("4 mixed: turn ends", kinds.count("message_stop") == 1, str(kinds))
ok &= check("4 mixed: stop_reason tool_use", md["delta"]["stop_reason"] == "tool_use", str(md))
starts = [(p["index"], p["content_block"]["type"]) for e, p in events if e == "content_block_start"]
ok &= check("4 mixed: client tool_use still reaches the client",
            any(t == "tool_use" for _, t in starts), str(starts))

# --- 5. malformed tool arguments: a tool failure, not a 500 -----------------
executed = []
events, executed, _ = loop.run_until_complete(run(
    [tool_seg([], "web_search", '{"query": '), text_seg(["recovered"])], executed))
kinds = [e for e, _ in events]
ok &= check("5 bad args: no error event", "error" not in kinds, str(kinds))
ok &= check("5 bad args: tool not executed", executed == [], str(executed))
ok &= check("5 bad args: message still completes", kinds.count("message_stop") == 1, str(kinds))
_self = make([tool_seg([], "web_search", '{"query": '), text_seg(["r"])], [])
_cr = types.SimpleNamespace(stream=True, stream_options=None,
                            messages=[{"role": "user", "content": "hi"}], tool_choice="auto")
loop.run_until_complete(_collect(_self, _cr))
_tool_msgs = [x for x in _cr.messages if x["role"] == "tool"]
ok &= check("5 bad args: model-facing tool body is a string",
            all(isinstance(x["content"], str) for x in _tool_msgs), str(_tool_msgs))
ok &= check("5 bad args: model told how to recover",
            any("Re-issue" in x["content"] for x in _tool_msgs), str(_tool_msgs))

# --- 6. text_delta containing the bytes of an index field is not corrupted --
evil = '{"index":0} and "index":7 too'
events, _, _ = loop.run_until_complete(run(
    [tool_seg(["a"], "web_search", '{"query":"x"}'), text_seg([evil])]))
texts = [p["delta"]["text"] for e, p in events
         if e == "content_block_delta" and (p.get("delta") or {}).get("type") == "text_delta"]
ok &= check("6 evil text: payload survives re-indexing", evil in texts, str(texts))

print("\nALL PASS" if ok else "\nFAILURES ABOVE")
sys.exit(0 if ok else 1)

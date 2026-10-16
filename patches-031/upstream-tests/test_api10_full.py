# SPDX-License-Identifier: Apache-2.0
"""API-10, non-streaming: a malformed tool call must not 500 the turn."""

import pytest

from vllm.entrypoints.anthropic.serving import AnthropicServingMessages
from vllm.entrypoints.openai.chat_completion.protocol import (
    ChatCompletionResponse, ChatCompletionResponseChoice, ChatMessage,
    FunctionCall, ToolCall)
from vllm.entrypoints.serve.engine.protocol import UsageInfo


def _resp(args):
    return ChatCompletionResponse(
        id="x", model="m", created=0,
        choices=[ChatCompletionResponseChoice(
            index=0, finish_reason="tool_calls",
            message=ChatMessage(role="assistant", content=None, tool_calls=[
                ToolCall(id="t1", function=FunctionCall(name="get_weather",
                                                        arguments=args))]))],
        usage=UsageInfo(prompt_tokens=5, completion_tokens=3, total_tokens=8))


def _convert(args):
    srv = AnthropicServingMessages.__new__(AnthropicServingMessages)
    return srv.messages_full_converter(_resp(args))


def test_good_arguments_pass_through():
    r = _convert('{"city": "Paris"}')
    tu = [b for b in r.content if b.type == "tool_use"]
    assert tu and tu[0].input == {"city": "Paris"}


@pytest.mark.parametrize("bad", ["\\n\\nI will search for it", '{"city": "Par', ""])
def test_malformed_arguments_become_empty_input(bad):
    r = _convert(bad)
    tu = [b for b in r.content if b.type == "tool_use"]
    assert tu and tu[0].input == {}, r
    assert r.stop_reason == "tool_use"

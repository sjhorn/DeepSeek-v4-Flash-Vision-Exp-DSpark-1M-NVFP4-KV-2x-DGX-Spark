# SPDX-License-Identifier: Apache-2.0
"""IMG-EFFORT: the DeepSeek V4 thinking / reasoning-effort policy on 0.31.

Renders through 0.31's real DeepSeek V4 wrapper and encoder (Qwen3's HF
tokenizer underneath; only the rendered text is checked). The effort text
appears only in thinking mode, so it shows which policy ran.
"""

import os

import pytest
from transformers import AutoTokenizer

import vllm.tokenizers.deepseek_v4 as dsv4

PATCHED = os.environ.get("EFFORT_POLICY", "ours") == "ours"
HIGH, MAX = "Absolute maximum", "Beyond maximum"


@pytest.fixture(scope="module")
def tok():
    return dsv4.get_deepseek_v4_tokenizer(AutoTokenizer.from_pretrained("Qwen/Qwen3-0.6B"))


def render(tok, **kw):
    return tok.apply_chat_template([{"role": "user", "content": "hi"}],
                                   tokenize=False, **kw)


def effort(text):
    return "max" if MAX in text else "high" if HIGH in text else "low/none"


CASES = [  # kwargs, ours, upstream 0.31
    ({}, "low/none", "high"),                                  # thinking default
    ({"thinking": True}, "low/none", "high"),                  # missing effort
    ({"thinking": True, "reasoning_effort": "xhigh"}, "max", "high"),
    ({"thinking": True, "reasoning_effort": "max"}, "max", "max"),
    ({"thinking": True, "reasoning_effort": "high"}, "high", "high"),
    ({"thinking": True, "reasoning_effort": "low"}, "low/none", "low/none"),
    ({"thinking": True, "reasoning_effort": "medium"}, "low/none", "low/none"),
    ({"thinking": True, "reasoning_effort": "turbo"}, "low/none", "high"),
    ({"thinking": True, "reasoning_effort": "none"}, "low/none", "low/none"),
    ({"thinking": False, "reasoning_effort": "high"}, "low/none", "low/none"),
]


@pytest.mark.parametrize("kw,ours,upstream", CASES)
def test_policy(tok, kw, ours, upstream):
    assert effort(render(tok, **kw)) == (ours if PATCHED else upstream), kw


def test_no_kwargs_is_chat_mode_on_ours(tok):
    """Ours: no thinking kwarg renders the CHAT prompt, identical to an
    explicit thinking=False."""
    if not PATCHED:
        pytest.skip("upstream turns thinking on by default")
    assert render(tok) == render(tok, thinking=False)

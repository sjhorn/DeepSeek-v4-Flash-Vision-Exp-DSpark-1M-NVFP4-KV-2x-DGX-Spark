#!/usr/bin/env python3
"""Reasoning-effort system-prompt fix (# [kvfix-reffix]).

The DS4 chat encoder only supported `max` reasoning effort: a single
REASONING_EFFORT_MAX constant was asserted into the system prompt whenever
reasoning_effort == "max", and any other value was rejected. This patch
generalizes it to a per-effort prompt table: "high" keeps the old
"absolute maximum" text, "max" gets a distinct "beyond maximum" prompt,
"low" adds nothing. Requests with reasoning_effort in (low, high, max)
now receive distinct system prompts.

Target: vllm/tokenizers/deepseek_v4_encoding.py. Extracted verbatim from
the production-3.7-reffix image (diff vs production-3.7: exactly these two
hunks in this file, nothing else in the vendored tree). The patch is
idempotent: each replacement text doubles as its own "already applied"
marker, and no marker comment is injected — the output byte-matches the
production-3.7-reffix file. Exit 0/1.
"""
import os
import py_compile
import sys

BASE = os.environ.get(
    "VLLM_PYTHON_DIR",
    "/opt/venv/lib/python3.12/site-packages/vllm",
)
ENCODER = f"{BASE}/tokenizers/deepseek_v4_encoding.py"


def _frag(*lines):
    return "".join(l + "\n" for l in lines)


ANCHOR_CONST = _frag(
    'REASONING_EFFORT_MAX = (',
    '    "Reasoning Effort: Absolute maximum with no shortcuts permitted.\\n"',
    '    "You MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.\\n"',
    '    "Explicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.\\n\\n"',
    ')',
)

REPL_CONST = _frag(
    'REASONING_EFFORT_PROMPTS: dict[str, str] = {',
    '    "low": "",',
    '    "high": (',
    '        "Reasoning Effort: Absolute maximum with no shortcuts permitted.\\n"',
    '        "You MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.\\n"',
    '        "Explicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.\\n\\n"',
    '    ),',
    '    "max": (',
    '        "Reasoning Effort: Beyond maximum \u2014 exhaustive, relentless, and uncompromising.\\n"',
    '        "You MUST reason with the utmost depth and rigor, leaving absolutely nothing to chance: exhaustively decompose the problem into its most fundamental components, trace every causal chain to its root, and resolve the underlying cause rather than any surface symptom.\\n"',
    '        "Do not stop reasoning until you have independently verified the solution from multiple angles and are certain that no assumption remains unchecked and no error remains undiscovered.\\n\\n"',
    '    ),',
    '}',
)

ANCHOR_LOGIC = _frag(
    '    # Reasoning effort prefix (only at index 0 in thinking mode with max effort)',
    "    assert reasoning_effort in ['max', None, 'high'], f\"Invalid reasoning effort: {reasoning_effort}\"",
    "    if index == 0 and thinking_mode == \"thinking\" and reasoning_effort == 'max':",
    '        prompt += REASONING_EFFORT_MAX',
)

REPL_LOGIC = _frag(
    '    assert reasoning_effort is None or reasoning_effort in REASONING_EFFORT_PROMPTS, \\',
    '        f"Invalid reasoning effort: {reasoning_effort}"',
    '    if index == 0 and thinking_mode == "thinking" and reasoning_effort in ("high", "max"):',
    '        prompt += REASONING_EFFORT_PROMPTS[reasoning_effort]',
)


def _apply(src, anchor, repl, label):
    if repl in src:
        return src, True
    if anchor not in src:
        print(f"[kvfix-reffix] ANCHOR MISSING: {label}")
        return src, False
    return src.replace(anchor, repl, 1), True


def main():
    src = open(ENCODER).read()
    ok = True
    src, ok1 = _apply(src, ANCHOR_CONST, REPL_CONST, "REASONING_EFFORT_PROMPTS table")
    ok &= ok1
    src, ok1 = _apply(src, ANCHOR_LOGIC, REPL_LOGIC, "reasoning-effort injection")
    ok &= ok1
    if not ok:
        sys.exit(1)
    open(ENCODER, "w").write(src)
    py_compile.compile(ENCODER, doraise=True)
    print("[kvfix-reffix] PATCHED + py_compile OK")
    sys.exit(0)


if __name__ == "__main__":
    main()

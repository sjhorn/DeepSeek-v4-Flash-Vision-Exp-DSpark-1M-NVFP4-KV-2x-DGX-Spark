#!/usr/bin/env python3
"""Find where consecutive requests stop sharing a prefix.

Prefix caching keys on the rendered prompt, so ANY byte that changes before
position N throws away the cache for everything after it. This flattens each
captured request the way the server sees it -- system blocks, then each message
in order -- and reports the first divergence between consecutive requests.

    python3 local-ops/prefix-diff.py prompt-tap.jsonl
"""
import hashlib, json, os, re, sys

# Model the server-side transforms so we diff what actually gets TOKENIZED,
# not what the client sent. Without this the billing header (which our
# converter drops) shows up as a divergence it never causes.
_PATCH = os.environ.get(
    "SERVING_PATCH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "patches", "anthropic_serving_inline_system.py"))
_ns = {}
try:
    _src = open(_PATCH).read()
    _chunk = _src[_src.index("_PROMPT_CACHE_STRIP_PATTERNS"):_src.index("class _HTMLTextExtractor")]
    exec(compile("import re\nfrom typing import Any\n" + _chunk, "xf", "exec"), _ns)
    _chunk2 = _src[_src.index("_STRIP_LEAKED_COT ="):_src.index("def strip_leaked_reasoning") + _src[_src.index("def strip_leaked_reasoning"):].index("\n\n\n")]
    exec(compile("import os, re, logging\nfrom typing import Any\n"
                 "logger = logging.getLogger('x')\n" + _chunk2, "xf2", "exec"), _ns)
    TRANSFORMS = True
except Exception as e:                     # fall back to raw diffing
    print(f"(!) could not load serving transforms: {e}", file=sys.stderr)
    TRANSFORMS = False

def _normalize_system(text):
    return _ns["normalize_system_prompt"](text) if TRANSFORMS else text

def _strip_cot(text, role):
    return _ns["strip_leaked_reasoning"](text, role) if TRANSFORMS else text


def flatten(body):
    """Return [(label, text), ...] in prompt order."""
    out = []
    # Tools are rendered INTO the first system message by the deepseek_v4
    # encoder, so a changed tool set rewrites the prompt head and invalidates
    # the whole conversation. Claude Code surfaces deferred tools on demand
    # (ToolSearch), so this changes mid-session -- observed 24 -> 25 when LSP
    # appeared. Tracked here as its own part so the diff attributes it.
    tools = body.get("tools") or []
    if tools:
        out.append(("tools", json.dumps(
            [{"name": t.get("name"), "schema": t.get("input_schema")} for t in tools],
            sort_keys=True)))

    # system: drop billing-header blocks (the converter does), merge, normalise
    s = body.get("system")
    blocks = s if isinstance(s, list) else ([{"text": s}] if s else [])
    sys_parts = []
    for b in blocks:
        t = b.get("text", "") if isinstance(b, dict) else str(b)
        if t.startswith("x-anthropic-billing-header"):
            continue                      # skipped server-side
        sys_parts.append(t)
    # Claude Code also sends role:"system" INSIDE messages. Since Patch 11b the
    # server hoists ONLY the leading run; later ones are folded into the
    # following user turn and stay in place. Modelling the old hoist-everything
    # behaviour here made per-turn reminders look like prompt-head churn when
    # they no longer are.
    msgs = body.get("messages", [])
    lead = 0
    for m in msgs:
        if m.get("role") != "system":
            break
        lead += 1
    for m in msgs[:lead]:
        c = m.get("content")
        if isinstance(c, str):
            sys_parts.append(c)
        else:
            for blk in c or []:
                if isinstance(blk, dict) and blk.get("type") == "text":
                    t = blk.get("text", "")
                    if not t.startswith("x-anthropic-billing-header"):
                        sys_parts.append(t)
    if sys_parts:
        out.append(("system(normalised)", _normalize_system("".join(sys_parts))))
    pending = []
    for i, m in enumerate(msgs):
        if m.get("role") == "system":
            if i >= lead:                 # folded into the next user turn
                c0 = m.get("content")
                pending.append(c0 if isinstance(c0, str) else "".join(
                    b.get("text", "") for b in (c0 or []) if isinstance(b, dict)))
            continue
        c = m.get("content")
        role = m.get("role")
        if pending and role == "user":
            out.append((f"msg[{i}].folded_system", "".join(pending)))
            pending = []
        if isinstance(c, str):
            out.append((f"msg[{i}].{role}", _strip_cot(c, role)))
        else:
            for j, blk in enumerate(c or []):  # role captured above
                if not isinstance(blk, dict):
                    continue
                t = blk.get("type")
                if t == "text":
                    txt = _strip_cot(blk.get("text", ""), role)
                elif t == "tool_use":
                    txt = f"<tool_use {blk.get('name')} {json.dumps(blk.get('input'), sort_keys=True)}>"
                elif t == "tool_result":
                    inner = blk.get("content")
                    txt = inner if isinstance(inner, str) else json.dumps(inner, sort_keys=True)
                elif t == "thinking":
                    txt = f"<thinking {len(blk.get('thinking') or '')} chars>"
                else:
                    txt = f"<{t}>"
                out.append((f"msg[{i}].{m.get('role')}.{t}[{j}]", txt))
    return out


def first_divergence(a, b):
    """Compare two flattened requests; return (index, label_a, label_b, detail)."""
    for i in range(min(len(a), len(b))):
        (la, ta), (lb, tb) = a[i], b[i]
        if la != lb or ta != tb:
            if ta == tb:
                return i, la, lb, "same text, different label (structure shifted)"
            # locate the differing byte
            k = 0
            while k < min(len(ta), len(tb)) and ta[k] == tb[k]:
                k += 1
            return i, la, lb, (f"text differs at char {k} of {len(ta)}/{len(tb)}: "
                               f"{ta[k:k+70]!r} vs {tb[k:k+70]!r}")
    if len(a) != len(b):
        return min(len(a), len(b)), "(end)", "(appended)", "shorter request is a strict prefix — IDEAL"
    return None, None, None, "identical"


def verdict(body_a, body_b):
    """Machine-readable comparison of two request bodies.

    Exposed for `cache-probe.py --selftest`, which checks this MODEL of the
    server against the server's own cache accounting. Keep the return shape
    stable: the Phase 1 matrix records `kind` and `label_b` per turn.

    kind is one of:
      identical     -- same rendered parts, byte for byte
      strict-prefix -- one is the other plus appended parts (the ideal shape
                       for a growing conversation: new content lands at the
                       END, so nothing cached is invalidated)
      diverges      -- they differ at part `part_index`; everything from there
                       on is re-prefilled
    """
    fa, fb = flatten(body_a), flatten(body_b)
    idx, la, lb, detail = first_divergence(fa, fb)
    total = sum(len(t) for _, t in fb)
    if idx is None:
        kind, shared = "identical", total
    elif la == "(end)":
        kind = "strict-prefix"
        shared = sum(len(t) for _, t in fa[:idx])
    else:
        kind = "diverges"
        shared = sum(len(t) for _, t in fa[:idx])
    return {
        "kind": kind,
        "part_index": idx,
        "shared_chars": shared,
        "total_chars": total,
        "shared_frac": shared / total if total else 1.0,
        "label_a": la,
        "label_b": lb,
        "detail": detail,
        "parts_a": len(fa),
        "parts_b": len(fb),
    }


def part_hashes(body):
    """sha256 (12 hex) of the tools part and the normalised system part.

    These are the two slices the Phase 5 guardrail watches: if either changes
    under an existing conversation, the prompt head moved.
    """
    out = {"tools": None, "system": None}
    for label, text in flatten(body):
        if label == "tools":
            out["tools"] = hashlib.sha256(text.encode()).hexdigest()[:12]
        elif label == "system(normalised)":
            out["system"] = hashlib.sha256(text.encode()).hexdigest()[:12]
    return out


def main(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    print(f"{len(rows)} captured requests\n")
    prev = None
    for r in rows:
        b = r["body"]
        flat = flatten(b)
        chars = sum(len(t) for _, t in flat)
        tag = f"[{r['ts']}] {b.get('model')} parts={len(flat)} chars={chars:,}"
        if prev is None:
            print(tag + "   (first)")
        else:
            idx, la, lb, detail = first_divergence(prev[1], flat)
            if idx is None:
                print(tag + "   identical to previous")
            else:
                shared = sum(len(t) for _, t in prev[1][:idx])
                pct = 100 * shared / max(chars, 1)
                print(tag)
                print(f"      shares first {idx} parts / {shared:,} chars (~{pct:.0f}% of this request)")
                print(f"      diverges at part {idx}: {la} -> {lb}")
                print(f"      {detail}")
        prev = (b, flat)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "prompt-tap.jsonl")

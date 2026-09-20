#!/usr/bin/env python3
"""Effort-level A/B on HMMT Feb 2026 (MathArena gold answers).

Three arms against the same server: thinking off, thinking+high, thinking+max.
Objective grading: last \boxed{...} vs gold answer, normalised.
"""
import json, re, sys, time, urllib.request

URL = "http://127.0.0.1:8888/v1/messages"
PROBLEMS = json.load(open("/tmp/hmmt.json"))[:12]
MAXTOK = 24000
ARMS = [
    ("off",  None),
    ("high", {"thinking": True, "reasoning_effort": "high"}),
    ("max",  {"thinking": True, "reasoning_effort": "max"}),
]

import re, math

def _expand_frac(s):
    # \frac72 -> \frac{7}{2}; \frac{7}2 and \frac7{2} too
    s = re.sub(r"\\frac\{([^{}]+)\}(\d)", r"\\frac{\1}{\2}", s)
    s = re.sub(r"\\frac(\d)\{([^{}]+)\}", r"\\frac{\1}{\2}", s)
    s = re.sub(r"\\frac(\d)(\d)", r"\\frac{\1}{\2}", s)
    return s

def norm(s):
    s = s.strip()
    for a, b in (("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\left", ""),
                 ("\\right", ""), ("\\!", ""), ("\\,", ""), ("\;", ""),
                 ("$", ""), ("^\\circ", ""), ("\\%", "")):
        s = s.replace(a, b)
    s = re.sub(r"\\text\{([^}]*)\}", r"\1", s)
    s = _expand_frac(s)
    s = s.replace(" ", "").rstrip(".")
    return s

def _read_group(s, i):
    """Read a brace group or single token at s[i:]; return (content, next_index)."""
    if i < len(s) and s[i] == "{":
        depth, j = 1, i + 1
        while j < len(s) and depth:
            if s[j] == "{": depth += 1
            elif s[j] == "}":
                depth -= 1
                if not depth: return s[i+1:j], j + 1
            j += 1
        return s[i+1:], len(s)
    m = re.match(r"\\?[A-Za-z0-9.]", s[i:])
    if m: return m.group(0), i + len(m.group(0))
    return "", i

def _expand_cmds(s):
    """Expand \\frac and \\sqrt with proper brace matching, innermost-out."""
    for _ in range(12):
        out, i, changed = [], 0, False
        while i < len(s):
            if s.startswith("\\frac", i):
                a, j = _read_group(s, i + 5)
                b, k = _read_group(s, j)
                out.append(f"(({_expand_cmds(a)})/({_expand_cmds(b)}))"); i = k; changed = True
            elif s.startswith("\\sqrt", i):
                a, j = _read_group(s, i + 5)
                out.append(f"(({_expand_cmds(a)})**0.5)"); i = j; changed = True
            else:
                out.append(s[i]); i += 1
        s = "".join(out)
        if not changed: break
    return s

def to_py(s):
    """Best-effort LaTeX -> python expression."""
    s = norm(s)
    s = _expand_cmds(s)
    s = s.replace("\\cdot", "*").replace("\\times", "*")
    s = s.replace("{", "(").replace("}", ")").replace("^", "**")
    s = re.sub(r"(\d)\(", r"\1*(", s)
    s = re.sub(r"\)(\()", r")*\1", s)
    return s

def numeric(s):
    try:
        v = eval(to_py(s), {"__builtins__": {}}, {"sqrt": math.sqrt})
        return float(v)
    except Exception:
        return None

def correct(pred, gold):
    if pred is None: return False
    if norm(pred) == norm(gold): return True
    a, b = numeric(pred), numeric(gold)
    if a is None or b is None: return False
    return abs(a - b) <= 1e-6 * max(1.0, abs(b))


def boxed(text):
    hits = []
    for m in re.finditer(r"\\boxed\{", text):
        i = m.end(); depth = 1; out = []
        while i < len(text) and depth:
            c = text[i]
            if c == "{": depth += 1
            elif c == "}":
                depth -= 1
                if not depth: break
            out.append(c); i += 1
        hits.append("".join(out))
    return hits[-1] if hits else None

def ask(problem, ctk):
    body = {"model": "deepseek-v4-flash-dspark", "max_tokens": MAXTOK, "temperature": 0,
            "messages": [{"role": "user",
                          "content": problem + "\n\nPut your final answer in \\boxed{}."}]}
    if ctk: body["chat_template_kwargs"] = ctk
    r = urllib.request.Request(URL, data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    t0 = time.time(); d = json.load(urllib.request.urlopen(r, timeout=3600)); dt = time.time() - t0
    blocks = d.get("content", [])
    txt = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
    thk = "".join(b.get("thinking", "") for b in blocks if b.get("type") == "thinking")
    return dict(secs=dt, out=d["usage"]["output_tokens"], inp=d["usage"]["input_tokens"],
                stop=d.get("stop_reason"), pred=boxed(txt) or boxed(thk),
                think_chars=len(thk), text_chars=len(txt))

results = {}
for arm, ctk in ARMS:
    rows = []
    for p in PROBLEMS:
        try:
            r = ask(p["problem"], ctk)
            r.update(idx=p["idx"], gold=p["answer"], ok=correct(r["pred"], p["answer"]))
        except Exception as e:
            r = dict(idx=p["idx"], gold=p["answer"], ok=False, err=str(e)[:120],
                     out=0, secs=0, stop="error", pred=None, think_chars=0)
        rows.append(r)
        print(f"[{arm:4s}] p{r['idx']:>2} ok={str(r['ok']):5s} pred={str(r['pred'])[:22]:24s} "
              f"gold={r['gold'][:18]:20s} out={r['out']:6d} {r['secs']:6.1f}s stop={r['stop']}",
              flush=True)
        json.dump(results | {arm: rows}, open("/tmp/hmmt_eval24.json", "w"))
    results[arm] = rows
    n = len(rows); acc = sum(r["ok"] for r in rows)
    tr = sum(1 for r in rows if r["stop"] == "max_tokens")
    grad = [r for r in rows if r["stop"] != "max_tokens"]
    ga = sum(r["ok"] for r in grad)
    print(f"=== {arm}: {acc}/{n} correct overall | {ga}/{len(grad)} of gradable "
          f"(truncated={tr}) | {sum(r['out'] for r in rows):,} output tokens, "
          f"{sum(r['secs'] for r in rows)/60:.1f} min\n", flush=True)

print("SUMMARY  arm   correct   out_tokens    minutes   truncated")
for arm, _ in ARMS:
    rs = results[arm]
    print(f"        {arm:5s}  {sum(r['ok'] for r in rs):>2}/{len(rs):<5} "
          f"{sum(r['out'] for r in rs):>10,} {sum(r['secs'] for r in rs)/60:>9.1f} "
          f"{sum(1 for r in rs if r['stop']=='max_tokens'):>10}")
json.dump(results, open("/tmp/hmmt_eval24.json", "w"))

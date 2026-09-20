#!/usr/bin/env python3
"""Phase 3 -- does deferring tools cost tool-SELECTION quality?

Cache stability is worthless if it is bought with a worse agent. Each prompt
here needs exactly one DEFERRED tool (one Claude Code hides behind ToolSearch),
and is scored the same way under ENABLE_TOOL_SEARCH=true and =false:

    chose the right tool?   how many turns did it take?   did the task finish?

Motivation, from an earlier ad-hoc probe: the model IGNORED a tool that was
described outside the declared tool list when the instruction was mild, and
used it only when pushed hard. Deferral is a different mechanism, but the same
failure shape -- "the tool exists but the model never reaches for it" -- is
exactly what this measures.

    python3 local-ops/toolquality.py --mode true   --out tq-true.json
    python3 local-ops/toolquality.py --mode false  --out tq-false.json
    python3 local-ops/toolquality.py --compare tq-true.json tq-false.json

Budget ~30-60 min of GPU per mode; run detached (see CLAUDE.md's bootmon
pattern) and mirror results into local-ops/.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
PROFILE = os.path.expanduser(
    os.environ.get("VLLM_PROFILE", "~/.config/vllm-proxy/claude-latest-local.json"))

# Each case: the prompt, and the tool that is the RIGHT answer. Kept offline
# and side-effect-free -- a case that needs the network would be measuring the
# network. `alt` names tools that are an acceptable substitute, so a model that
# solves the task a different legitimate way is not scored as a miss.
CASES = [
    {"id": "notebook", "tool": "NotebookEdit", "alt": [],
     "prompt": "Edit the single code cell of local-ops/toolsearch-matrix/probe.ipynb so it "
               "prints CACHEPROBE. Use the dedicated notebook-editing tool, not a text edit "
               "and not Bash."},
    {"id": "websearch", "tool": "WebSearch", "alt": ["WebFetch"],
     "prompt": "Search the web for the current stable release version of vLLM. "
               "Report just the version string."},
    {"id": "webfetch", "tool": "WebFetch", "alt": ["WebSearch"],
     "prompt": "Fetch https://raw.githubusercontent.com/vllm-project/vllm/main/README.md "
               "and quote its first heading."},
    {"id": "lsp", "tool": "LSP", "alt": [],
     "prompt": "Using language-server tooling (not grep), find the definition of the "
               "function normalize_system_prompt in this repository and report its file "
               "and line number."},
    {"id": "plan", "tool": "EnterPlanMode", "alt": [],
     "prompt": "Enter plan mode so we can design a change to local-ops/prefix-diff.py "
               "before writing any code."},
    {"id": "monitor", "tool": "Monitor", "alt": ["Bash"],
     "prompt": "Wait until the file /tmp/tq-monitor-sentinel exists, checking "
               "periodically, then say FOUND. Give up after 30 seconds."},
    {"id": "worktree", "tool": "EnterWorktree", "alt": [],
     "prompt": "Put me in an isolated git worktree so I can experiment without touching "
               "the working tree."},
    {"id": "cronlist", "tool": "CronList", "alt": [],
     "prompt": "List my scheduled agents / cron routines."},
    {"id": "agents", "tool": "ListAgents", "alt": [],
     "prompt": "List the agents I could send a message to right now."},
    {"id": "taskoutput", "tool": "TaskOutput", "alt": ["Bash"],
     "prompt": "Show me the output of background task id bp0000000 (it may not exist; "
               "use the dedicated task-output tool to check)."},
]


def run_case(case, mode, model, timeout=900):
    """One headless session, one case. Returns what the model actually did.

    --output-format stream-json is the only way to see WHICH tools were called;
    the plain result text reports the answer, not the route taken.
    """
    env = dict(os.environ)
    token = json.loads(pathlib.Path(PROFILE).read_text())["apiKey"]
    profile = json.loads(pathlib.Path(PROFILE).read_text())
    env.update({
        "ANTHROPIC_BASE_URL": profile["baseUrl"],
        "ANTHROPIC_AUTH_TOKEN": token,
        "API_TIMEOUT_MS": "1800000",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_TELEMETRY": "1", "DISABLE_INSTALLATION_CHECKS": "1",
        "DISABLE_AUTOUPDATER": "1", "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
    })
    cache = pathlib.Path(os.path.expanduser("~/.cache/vllm-proxy")) / profile["name"]
    env.update({"NODE_EXTRA_CA_CERTS": str(cache / "ca.pem"),
                "CLAUDE_CODE_CLIENT_CERT": str(cache / "client.crt"),
                "CLAUDE_CODE_CLIENT_KEY": str(cache / "client.key")})
    if mode != "unset":
        env["ENABLE_TOOL_SEARCH"] = mode

    t0 = time.time()
    try:
        p = subprocess.run(
            ["claude", "-p", "--model", model, "--permission-mode", "bypassPermissions",
             "--output-format", "stream-json", "--verbose", case["prompt"]],
            cwd=str(REPO), env=env, capture_output=True, text=True, timeout=timeout)
        out = p.stdout
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
    dt = time.time() - t0

    tools_called, turns, result_text, searched = [], 0, "", False
    for line in out.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "assistant":
            turns += 1
            for b in (ev.get("message") or {}).get("content") or []:
                if b.get("type") == "tool_use":
                    tools_called.append(b.get("name"))
                    if b.get("name") == "ToolSearch":
                        searched = True
        elif ev.get("type") == "result":
            result_text = (ev.get("result") or "")[:400]

    accepted = [case["tool"]] + case["alt"]
    return {
        "id": case["id"], "want": case["tool"], "mode": mode,
        "tools_called": tools_called,
        "correct": case["tool"] in tools_called,
        "acceptable": any(t in accepted for t in tools_called),
        "used_toolsearch": searched,
        "turns": turns, "seconds": round(dt, 1),
        "completed": bool(result_text),
        "result": result_text,
    }


def summarise(rows, label):
    n = len(rows)
    if not n:
        return
    correct = sum(r["correct"] for r in rows)
    acceptable = sum(r["acceptable"] for r in rows)
    completed = sum(r["completed"] for r in rows)
    turns = sum(r["turns"] for r in rows)
    print(f"\n  {label}: correct {correct}/{n}   acceptable {acceptable}/{n}   "
          f"completed {completed}/{n}   total turns {turns}   "
          f"ToolSearch used in {sum(r['used_toolsearch'] for r in rows)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["true", "false", "unset"])
    ap.add_argument("--model", default="claude-sonnet-5")
    ap.add_argument("--out")
    ap.add_argument("--only", help="comma-separated case ids")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    a = ap.parse_args()

    if a.compare:
        A = json.load(open(a.compare[0]))
        B = json.load(open(a.compare[1]))
        by = {r["id"]: r for r in B}
        print(f"{'case':<14} {'want':<16} {A[0]['mode']:>10} {B[0]['mode']:>10}   delta turns")
        for r in A:
            o = by.get(r["id"])
            if not o:
                continue
            f = lambda x: "OK " if x["correct"] else ("~  " if x["acceptable"] else "MISS")
            print(f"{r['id']:<14} {r['want']:<16} {f(r):>10} {f(o):>10}   "
                  f"{r['turns']:>3} vs {o['turns']:<3}")
        summarise(A, f"mode={A[0]['mode']}")
        summarise(B, f"mode={B[0]['mode']}")
        ca = sum(x["correct"] for x in A)
        cb = sum(x["correct"] for x in B)
        print(f"\n  PARITY: {'yes' if abs(ca - cb) <= 1 else 'NO -- ' + str(abs(ca-cb)) + ' case gap'}"
              "   (within one case is noise at this n; a wider gap is a real regression)")
        return

    if not a.mode:
        ap.error("--mode is required unless --compare")
    cases = CASES
    if a.only:
        want = set(a.only.split(","))
        cases = [c for c in CASES if c["id"] in want]

    rows = []
    for i, c in enumerate(cases, 1):
        print(f"[{i}/{len(cases)}] {c['id']} (want {c['tool']}) ...", flush=True)
        r = run_case(c, a.mode, a.model)
        rows.append(r)
        print(f"        called={r['tools_called']} correct={r['correct']} "
              f"turns={r['turns']} {r['seconds']}s", flush=True)
        if a.out:                                   # checkpoint every case
            pathlib.Path(a.out).write_text(json.dumps(rows, indent=2))
    summarise(rows, f"mode={a.mode}")
    if a.out:
        print(f"\nwrote {a.out}")


if __name__ == "__main__":
    sys.exit(main())

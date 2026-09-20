#!/usr/bin/env python3
"""Does the reasoning-effort instruction still WORK when moved to the end?

The cache case is settled (`/tokenize`, no GPU): the `high` text is 79 tokens,
and at position 0 it shares a 1-token prefix with `low` while at the tail it
shares 24,854 of 24,857 -- a mid-conversation tier switch costs 24,856 tokens
today and 3 if moved. What is NOT settled is whether the model still OBEYS the
instruction from the tail. Everything measured so far (HMMT: high 11/12 vs off
5/12) used position 0, which is where DeepSeek's reference encoder puts it.

Tested WITHOUT a patch or a restart. `reasoning_effort: "low"` maps to the
empty string, so the encoder injects nothing; we then append the `high` text
ourselves to the end of the user message. Renders to the same 24,936 tokens as
`high`, just at the other end of the prompt.

  high-front  ctk={thinking, high}          encoder puts the text at position 0
  high-tail   ctk={thinking, low} + text    we put the same text at the end
  low         ctk={thinking, low}           CONTROL: what high-tail becomes if ignored
  off         no ctk                        baseline (thinking disabled)

Read `think_chars`, not just correctness. high-tail ~ high-front means the
instruction landed from the tail; high-tail ~ low means it was ignored. Without
the `low` arm the tail result is unattributable.

Grading is the EXISTING grader from hmmt_eval24.py, imported rather than
copied, so numbers are directly comparable to the 2026-09-16 run.

  python3 hmmt_tail.py --n 12 --arms high-front,high-tail
  python3 hmmt_tail.py --n 3  --arms high-front,high-tail   # cheap pilot

COST: this is real decode load. The 2026-09-16 `high` arm spent 90,682 output
tokens over 12 problems. Budget roughly 30-50 min of decode contention per
12-problem arm on a cluster that is also serving someone.
"""
import argparse, json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("DSPARK_BASE_URL", "http://127.0.0.1:8888") + "/v1/messages"

# The exact `high` text from the image's REASONING_EFFORT_PROMPTS table
# (deepseek_v4_encoding.py:77). Must stay byte-identical or the arms are not
# comparable -- verify with --verify-text before trusting a run.
HIGH_TEXT = (
    "Reasoning Effort: Absolute maximum with no shortcuts permitted.\n"
    "You MUST be very thorough in your thinking and comprehensively decompose the problem "
    "to resolve the root cause, rigorously stress-testing your logic against all potential "
    "paths, edge cases, and adversarial scenarios.\n"
    "Explicitly write out your entire deliberation process, documenting every intermediate "
    "step, considered alternative, and rejected hypothesis to ensure absolutely no assumption "
    "is left unchecked.\n\n"
)

# Reuse the existing grader: exec the original up to its run section so norm(),
# boxed() and the equivalence fallback are the SAME code, not a copy that can drift.
_src = open(os.path.join(HERE, "hmmt_eval24.py")).read()
_cut = _src.index("results = {}")
_g: dict = {"os": os}
exec(compile(_src[:_cut].replace('json.load(open("/tmp/hmmt.json"))',
                                 'json.load(open(os.path.join(%r,"hmmt.json")))' % HERE),
             "hmmt_eval24.py", "exec"), _g)
norm, boxed = _g["norm"], _g["boxed"]
equiv = _g.get("equiv") or _g.get("same") or (lambda a, b: norm(a) == norm(b))

ARMS = {
    "off":        (None, ""),
    # THE CONTROL THAT MATTERS: thinking on, `low` (= empty prefix), no tail text.
    # This is exactly what "high-tail" degrades to if the model IGNORES an
    # instruction placed at the end. Without it, a low think volume in the tail
    # arm is unattributable -- it could mean "ignored" or "the problem was easy".
    "low":        ({"thinking": True, "reasoning_effort": "low"}, ""),
    "high-front": ({"thinking": True, "reasoning_effort": "high"}, ""),
    "high-tail":  ({"thinking": True, "reasoning_effort": "low"}, HIGH_TEXT),
    "max-front":  ({"thinking": True, "reasoning_effort": "max"}, ""),
}


def ask(problem, ctk, tail, maxtok):
    content = problem + "\n\nPut your final answer in \\boxed{}."
    if tail:
        content += "\n\n" + tail          # the whole point: instruction at the END
    body = {"model": "deepseek-v4-flash-dspark", "max_tokens": maxtok,
            "temperature": 0, "messages": [{"role": "user", "content": content}]}
    if ctk:
        body["chat_template_kwargs"] = ctk
    r = urllib.request.Request(URL, data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"})
    t0 = time.time()
    d = json.load(urllib.request.urlopen(r, timeout=3600))
    dt = time.time() - t0
    blocks = d.get("content", [])
    txt = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
    thk = "".join(b.get("thinking", "") for b in blocks if b.get("type") == "thinking")
    return dict(secs=dt, out=d["usage"]["output_tokens"], inp=d["usage"]["input_tokens"],
                stop=d.get("stop_reason"), pred=boxed(txt) or boxed(thk),
                think_chars=len(thk), text_chars=len(txt))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--arms", default="high-front,high-tail")
    ap.add_argument("--maxtok", type=int, default=24000)
    ap.add_argument("--out", default=os.path.join(HERE, "hmmt_tail.json"))
    ap.add_argument("--verify-text", action="store_true",
                    help="check HIGH_TEXT still matches the image, then exit")
    a = ap.parse_args()

    if a.verify_text:
        import subprocess
        got = subprocess.run(
            ["ssh", "shorn@spark-45ea",
             "docker exec deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1 "
             "python3 -c \"from vllm.tokenizers.deepseek_v4_encoding import "
             "REASONING_EFFORT_PROMPTS as P; import sys; sys.stdout.write(P['high'])\""],
            capture_output=True, text=True).stdout
        print("MATCH" if got == HIGH_TEXT else
              f"MISMATCH\n--- image ---\n{got!r}\n--- ours ---\n{HIGH_TEXT!r}")
        return

    problems = json.load(open(os.path.join(HERE, "hmmt.json")))[:a.n]
    arms = [x.strip() for x in a.arms.split(",")]
    results = {}
    for arm in arms:
        ctk, tail = ARMS[arm]
        rows = []
        print(f"\n=== arm {arm}  ({len(problems)} problems, max_tokens={a.maxtok})", flush=True)
        for p in problems:
            try:
                r = ask(p["problem"], ctk, tail, a.maxtok)
            except Exception as e:                                   # noqa: BLE001
                print(f"  #{p['idx']:>2} ERROR {e!r}"[:160], flush=True)
                continue
            r["idx"], r["gold"] = p["idx"], p["answer"]
            r["ok"] = bool(r["pred"]) and equiv(r["pred"], p["answer"])
            rows.append(r)
            print(f"  #{p['idx']:>2} {'OK ' if r['ok'] else 'X  '} "
                  f"out={r['out']:>6} think={r['think_chars']:>7} {r['secs']:>6.1f}s "
                  f"stop={r['stop']:<12} pred={str(r['pred'])[:28]}", flush=True)
            json.dump(results | {arm: rows}, open(a.out, "w"), indent=2)
        results[arm] = rows
        json.dump(results, open(a.out, "w"), indent=2)

    print("\n" + "=" * 86)
    print(f"{'arm':<12} {'correct':>8} {'of gradable':>12} {'truncated':>10} "
          f"{'out tokens':>11} {'think chars':>12}")
    for arm, rows in results.items():
        if not rows:
            continue
        tr = sum(1 for r in rows if r["stop"] == "max_tokens")
        grad = [r for r in rows if r["stop"] != "max_tokens"]
        print(f"{arm:<12} {sum(1 for r in rows if r['ok']):>4}/{len(rows):<3} "
              f"{sum(1 for r in grad if r['ok']):>6}/{len(grad):<5} {tr:>10} "
              f"{sum(r['out'] for r in rows):>11,} {sum(r['think_chars'] for r in rows):>12,}")
    print(f"\n-> {a.out}")
    print("Read think_chars as well as correctness: if the tail arm reasons as much as the\n"
          "front arm, the instruction landed. If it collapses toward `off`, it was ignored.")


if __name__ == "__main__":
    main()

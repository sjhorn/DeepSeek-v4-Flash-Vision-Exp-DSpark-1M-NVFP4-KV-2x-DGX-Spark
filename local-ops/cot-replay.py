#!/usr/bin/env python3
"""Patch 8 A/B harness: prompt-token cost of leaked CoT in replayed history.

Replays a FIXED set of real leaked assistant turns (cot-replay-samples.json)
as three-message conversations [user, assistant, follow-up] with max_tokens=1,
and records input_tokens per turn.  Deterministic: same samples -> same prompt,
so a run before and after Patch 8 is directly comparable.

  python3 local-ops/cot-replay.py --out local-ops/cot-replay-baseline.json
  python3 local-ops/cot-replay.py --compare A.json B.json
"""
import argparse, json, sys, urllib.request, urllib.error

FOLLOWUP = "Continue from where you left off."

def measure(base_url, samples):
    url = base_url.rstrip('/') + '/messages'
    rows = []
    for i, s in enumerate(samples):
        body = json.dumps({
            "model": "deepseek-v4-flash-dspark", "max_tokens": 1,
            "messages": [
                {"role": "user", "content": s["user"]},
                {"role": "assistant", "content": s["assistant"]},
                {"role": "user", "content": FOLLOWUP},
            ],
        }).encode()
        req = urllib.request.Request(url, data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            d = json.load(urllib.request.urlopen(req, timeout=300))
            rows.append({"i": i, "input_tokens": d["usage"]["input_tokens"],
                         "assistant_chars": len(s["assistant"])})
        except urllib.error.HTTPError as e:
            rows.append({"i": i, "error": f"HTTP {e.code}: {e.read()[:200].decode('replace')}"})
        print(f"\r  {i+1}/{len(samples)}", end="", file=sys.stderr, flush=True)
    print("", file=sys.stderr)
    return rows

def summarize(rows, label):
    ok = [r for r in rows if "input_tokens" in r]
    tot = sum(r["input_tokens"] for r in ok)
    print(f"{label}: turns={len(ok)} errors={len(rows)-len(ok)} "
          f"total_input_tokens={tot:,} mean={tot/max(len(ok),1):.0f}")
    return tot, ok

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:8888/v1")
    p.add_argument("--samples", default="local-ops/cot-replay-samples.json")
    p.add_argument("--out")
    p.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    a = p.parse_args()

    if a.compare:
        before = json.load(open(a.compare[0])); after = json.load(open(a.compare[1]))
        b, brows = summarize(before["rows"], "before")
        c, crows = summarize(after["rows"], "after ")
        if b:
            print(f"\nsaved {b-c:,} prompt tokens across {len(brows)} turns "
                  f"({100*(b-c)/b:.1f}%)")
        by = {r['i']: r['input_tokens'] for r in crows}
        worst = sorted(((r['input_tokens'] - by.get(r['i'], 0), r['i']) for r in brows),
                       reverse=True)[:5]
        print("biggest per-turn savings:",
              ", ".join(f"#{i}:-{d}" for d, i in worst))
        return

    samples = json.load(open(a.samples))
    rows = measure(a.base_url, samples)
    summarize(rows, "run")
    if a.out:
        json.dump({"base_url": a.base_url, "n": len(samples), "rows": rows},
                  open(a.out, "w"), indent=1)
        print(f"wrote {a.out}")

main()

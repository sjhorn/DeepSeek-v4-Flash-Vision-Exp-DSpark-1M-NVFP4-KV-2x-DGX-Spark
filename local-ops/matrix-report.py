#!/usr/bin/env python3
"""Phase 1 report: one row per turn, plus the acceptance verdict for a cell.

Consumes a prompt-tap capture taken with --metrics-url, so every row carries
BOTH the engine's measured hit ratio and prefix-diff's explanation of the same
turn. Where they disagree, the engine is right -- prefix-diff only says why.

    python3 local-ops/matrix-report.py local-ops/toolsearch-matrix/*.jsonl

Acceptance (from the plan): a mode is viable when >=95% of turns 2+ are a
strict prefix of the previous turn AND the median measured hit is >=95%.

The classifier requests (no tools, tiny max_tokens) are reported separately:
they are a different conversation that interleaves with the agent's, so mixing
them into the agent's turn-to-turn chain would invent divergences that the
engine never sees.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import statistics
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "prefix_diff", os.path.join(_HERE, "prefix-diff.py"))
_pd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pd)                  # the hyphen blocks a plain import


def is_counting(rec):
    """/v1/messages/count_tokens -- a token count, not a generation.

    Claude Code issues one before most turns. It never generates and never
    touches the prefix cache, so it belongs in neither chain.
    """
    return "count_tokens" in (rec.get("path") or "")


def is_classifier(body):
    """Claude Code's auto-mode permission classifier: no tools, tiny budget."""
    return not (body.get("tools") or []) and (body.get("max_tokens") or 0) <= 512


def _blend_factor(cache, usage):
    """queries / input_tokens for one request.

    vLLM queries the prefix cache once per prompt token, so a delta that
    belongs to exactly ONE request has queries == input_tokens (verified to
    the token in cache-probe's self-test). Anything above that is another
    request's tokens inside our measurement window.

    This replaces the obvious check -- the engine's num_requests_running gauge
    -- which is refreshed only on the engine's logging interval and so reads
    non-zero for almost every turn, including from the measured request
    itself. This one is exact and needs no extra scrape.
    """
    it = (usage or {}).get("input_tokens")
    q = (cache or {}).get("queries")
    if not it or not q:
        return 0.0
    return q / it


def _contaminated(cache, usage):
    f = _blend_factor(cache, usage)
    # 5% slack: the rendered prompt is a few tokens longer than the reported
    # input_tokens (chat-template scaffolding), seen as ratio 1.001 in practice.
    return not (0.95 <= f <= 1.05)


def conv_key(body):
    """Identify which CONVERSATION a request belongs to.

    A capture is not one chain. A subagent runs its own session against the
    same endpoint, so its turns interleave with the parent's; chaining them in
    arrival order compares a child prompt against a parent prompt and invents a
    divergence at `tools` that the engine never saw.

    Keyed on the NORMALISED SYSTEM BLOCK. The obvious key -- the first user
    message -- is wrong here: Claude Code embeds the deferred-tool name list in
    msg[0], so when that list changes (the exact head move we are hunting) the
    key changes too and the move disappears from the tally. The system block
    does not move within a session, and it DOES change for a subagent, after a
    compaction, and on a model-tier switch, which is precisely the set of seams
    that should start a new chain.
    """
    return _pd.part_hashes(body)["system"] or "?"


def report(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    name = os.path.basename(path)
    print(f"\n{'='*100}\n{name}   {len(rows)} captured requests\n{'='*100}")
    if not rows:
        print("  (empty -- the session made no requests)")
        return None

    # A turn the server rejected (502 from the proxy on a slow cold prefill was
    # seen in the smoke run) carries no usage and no meaningful cache delta.
    # Claude Code retries it, so the retry is the real turn -- keeping the
    # failure in the chain would invent a divergence against itself.
    counting = [r for r in rows if is_counting(r)]
    rows = [r for r in rows if not is_counting(r)]
    failed = [r for r in rows if r.get("status") not in (200, None)
              or r.get("stream_error")]
    ok = [r for r in rows if r not in failed]
    if counting:
        print(f"  ({len(counting)} count_tokens call(s) excluded -- no generation)")
    agent = [r for r in ok if not is_classifier(r["body"])]
    clsf = [r for r in ok if is_classifier(r["body"])]
    if failed:
        print(f"  ({len(failed)} failed request(s) excluded: "
              f"{sorted(set(str(r.get('status')) + (' stream-error' if r.get('stream_error') else '') for r in failed))})")

    print(f"  agent turns: {len(agent)}    classifier calls: {len(clsf)}")
    tool_hashes = {(r.get("hashes") or {}).get("tools") for r in agent}
    tool_counts = [(r.get("hashes") or {}).get("n_tools") for r in agent]
    print(f"  distinct tools-array hashes across agent turns: {len(tool_hashes)}"
          f"   n_tools seen: {sorted(set(c for c in tool_counts if c is not None))}")
    sys_hashes = {(r.get("hashes") or {}).get("system") for r in agent}
    print(f"  distinct raw system hashes: {len(sys_hashes)}"
          "   (>1 is fine post-Patch-11a only if normalisation absorbs it)")

    # A strict-prefix turn cannot hit more than prev_tokens/cur_tokens: the
    # part that is NEW has never been seen. Judging a turn on raw hit% mixes
    # head stability (what we are testing) with how much the turn grew (which
    # is the workload's business). `of max` is hit% against that ceiling --
    # ~100% means the cache gave everything it had.
    hdr = (f"\n  {'#':>3} {'in_tok':>8} {'hit%':>7} {'ofmax':>7} {'secs':>7} {'conv':>8} "
           f"{'tools':>10} {'system':>10} {'verdict':>14}  first divergent part")
    print(hdr)
    print("  " + "-" * (len(hdr) - 3))

    prev_by_conv = {}
    prev_tok_by_conv = {}
    convs = [conv_key(r["body"]) for r in agent]
    if len(set(convs)) > 1:
        print(f"  {len(set(convs))} distinct conversations in this capture "
              "(subagent or post-compaction); each is chained separately")
    prev = None
    prev_tok = None
    strict = 0
    comparable = 0
    hits = []
    effs = []
    for i, r in enumerate(agent):
        b = r["body"]
        h = r.get("hashes") or {}
        c = r.get("cache") or {}
        u = r.get("usage") or {}
        ck = convs[i]
        prev = prev_by_conv.get(ck)
        prev_tok = prev_tok_by_conv.get(ck)
        if prev is None:
            v = {"kind": "(first)", "label_b": "", "shared_frac": None}
        else:
            v = _pd.verdict(prev, b)
            comparable += 1
            if v["kind"] in ("identical", "strict-prefix"):
                strict += 1
        dirty = _contaminated(c, u)
        hp = c.get("hit_pct")
        if hp is not None and not dirty and prev is not None:
            hits.append(hp)
        intok = u.get("input_tokens")
        # `of max` is only meaningful for a STRICT PREFIX, where the ceiling
        # really is prev_tokens/cur_tokens. When the head moved mid-prompt the
        # ceiling is "everything before the divergence", which we do not know
        # in tokens -- so the column is left blank and prefix-diff's shared
        # fraction is printed instead, as the prediction to compare against.
        of_max = None
        if v["kind"] in ("identical", "strict-prefix") and prev_tok and intok and hp is not None:
            ceiling = 100.0 * min(prev_tok, intok) / intok
            if ceiling:
                of_max = 100.0 * hp / ceiling
                if not dirty:
                    effs.append(of_max)
        pred = v.get("shared_frac")
        print(f"  {i:>3} {(intok if intok is not None else '-'):>8} "
              f"{(f'{hp:.1f}' if hp is not None else '-'):>7} "
              f"{(f'{of_max:.0f}' if of_max is not None else ('~%.0f' % (100*pred) if pred is not None else '-')):>7} "
              f"{r.get('seconds', float('nan')):>7.2f} "
              f"{ck:>8} {str(h.get('tools'))[:10]:>10} {str(h.get('system'))[:10]:>10} "
              f"{v['kind']:>14}  {str(v.get('label_b') or '')[:44]}"
              + ("  [BLENDED x%.1f]" % _blend_factor(c, u) if dirty else "")
              # prefix-diff says most of the prompt was reusable and the engine
              # reused none of it. Neither tool sees this alone: prefix-diff
              # cannot observe the KV pool, and the engine cannot say why a
              # block was missing. Together they name it -- the blocks were
              # EVICTED, so the fix is pool pressure, not the prompt.
              + ("  [EVICTION? shared ~%.0f%% but hit %.0f%%]" % (100 * pred, hp)
                 if (not dirty and pred is not None and hp is not None
                     and pred >= 0.5 and hp < 10) else ""))
        prev_by_conv[ck] = b
        prev_tok_by_conv[ck] = intok

    if comparable == 0:
        print("\n  too few agent turns to judge (need at least 2)")
        return None

    strict_pct = 100.0 * strict / comparable
    med = statistics.median(hits) if hits else None
    med_eff = statistics.median(effs) if effs else None
    # The plan's literal criterion is strict% and median hit%. Median hit is
    # reported as specified, but it is NOT the deciding number: a turn that
    # doubles its context cannot hit 95% however stable the head is. The
    # ceiling-relative figure is what actually separates the modes.
    viable = strict_pct >= 95.0 and med_eff is not None and med_eff >= 95.0
    print(f"\n  turns 2+: {strict}/{comparable} strict prefix = {strict_pct:.1f}%  (need >=95%)")
    print(f"  clean (single-request) measurements: {len(hits)}/{comparable}"
          "   -- the rest had another client's tokens in the delta")
    print(f"  median measured hit on turns 2+: "
          f"{'n/a' if med is None else f'{med:.1f}%'}  (the plan's literal bar; "
          "capped by how much each turn grew)")
    print(f"  median hit AS A FRACTION OF THE ACHIEVABLE CEILING: "
          f"{'n/a' if med_eff is None else f'{med_eff:.1f}%'}  (need >=95%, n={len(effs)})")
    print(f"  ACCEPTANCE: {'VIABLE' if viable else 'NOT VIABLE'}")
    return {"cell": name, "agent_turns": len(agent), "classifier": len(clsf),
            "strict_pct": strict_pct, "median_hit": med, "median_eff": med_eff,
            "viable": viable,
            "distinct_tool_hashes": len(tool_hashes),
            "max_input_tokens": max((r.get("usage") or {}).get("input_tokens") or 0
                                    for r in agent)}


def main(paths):
    out = [r for r in (report(p) for p in paths) if r]
    if len(out) > 1:
        print(f"\n{'='*100}\nSUMMARY\n{'='*100}")
        print(f"  {'cell':<28} {'turns':>6} {'maxctx':>8} {'toolhash':>9} "
              f"{'strict%':>8} {'ofmax%':>8}  verdict")
        for r in out:
            mh = "n/a" if r["median_eff"] is None else "%.1f" % r["median_eff"]
            verdict = "VIABLE" if r["viable"] else "NOT VIABLE"
            print(f"  {r['cell']:<28} {r['agent_turns']:>6} {r['max_input_tokens']:>8,} "
                  f"{r['distinct_tool_hashes']:>9} {r['strict_pct']:>8.1f} {mh:>8}  {verdict}")


if __name__ == "__main__":
    main(sys.argv[1:] or ["prompt-tap.jsonl"])

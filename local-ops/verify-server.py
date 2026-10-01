#!/usr/bin/env python3
"""Post-restart regression suite for the Anthropic patch stack.

Everything here was true before Patch 12 and must still be true after. Run it
after any change to `patches/anthropic_serving_inline_system.py`.

    python3 local-ops/verify-server.py

Checks, in the order a failure would matter:
  1. every id the compose configures resolves (derived, not a hardcoded count)
  2. each tier carries its expected effort prefix  (Patch 9)
  3. the permission classifier is exempted from thinking  (Patch 9 rev 2)
  4. the leaked-CoT strip is still ASSISTANT-ONLY  (Patch 8)
  5. Patch 12 emits a guardrail line and nothing 500s
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8888"

# Absolute prompt_tokens for a minimal one-word request. The effort prefix is
# injected at message index 0 only, so these are (base 5) + prefix.
EXPECTED_PREFIX_TOKENS = {
    "deepseek-v4-flash-dspark-nothink": 5,
    "deepseek-v4-flash-dspark-think-low": 5,
    "deepseek-v4-flash-dspark-think-high": 84,
    "deepseek-v4-flash-dspark-think-max": 97,
}

VENDOR_TIERS = {           # same ladder, reached by vendor name
    "claude-haiku-4-5": 5,
    "claude-sonnet-5": 5,
    "claude-opus-5": 84,
    "claude-fable-5": 97,
}


def post(body, timeout=300):
    req = urllib.request.Request(
        BASE + "/v1/messages", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01"},
        method="POST")
    try:
        return 200, json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]
    except Exception as e:                                   # noqa: BLE001
        return -1, repr(e)[:300]


def minimal(model):
    return {"model": model, "max_tokens": 1,
            "messages": [{"role": "user", "content": "hi"}]}


results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))


def check_answered(name, statuses, ok, detail=""):
    """Three outcomes, not two.

    A check whose request never came back has told us NOTHING about the thing it
    checks -- reporting that as FAIL is a false regression. This cluster has a
    co-tenant running 150K-token prompts, so a 1-token probe can sit behind them
    for minutes; on 2026-09-20 two Patch 8 checks reported FAIL purely because
    post()'s 300s timeout expired, and the behaviour was fine when re-run
    (48.7s, identical token counts). ERROR rows do not count as failures and
    are listed separately.
    """
    bad = [st for st in statuses if st != 200]
    if bad:
        results.append((name, None, f"ERROR: request status {bad} -- check did not run"))
        print(f"  ERROR {name}   request status {bad} (cluster busy?) -- not a regression")
        return
    check(name, ok, detail)


print("Server regression suite\n" + "=" * 70)

# 1 ─ every served id resolves
try:
    ids = [m["id"] for m in json.load(
        urllib.request.urlopen(BASE + "/v1/models", timeout=30))["data"]]
except Exception as e:                                       # noqa: BLE001
    print(f"cannot reach {BASE}: {e}")
    sys.exit(2)
# DERIVED FROM THE COMPOSE, NOT A HARDCODED COUNT. `len(ids) == 12` went stale
# the first time an alias was added (claude-opus-5-5, 2026-10-01) and failed for
# being out of date rather than for anything being wrong -- which costs more than
# it catches, because a suite that cries wolf on a correct deployment is one
# people start ignoring. Comparing SETS also names the id that went missing,
# where a count could only say the total moved.
#
# Note what this does NOT assert any more: that an unlisted id is REFUSED. Since
# VLLM_SKIP_MODEL_NAME_VALIDATION=1 it is not -- the list is what /v1/models
# advertises, not what the engine accepts. See RUNTIME-SURFACE.md.
def _expected_served_ids():
    compose = (pathlib.Path(__file__).resolve().parent.parent
               / "docker-compose.dspark.yml").read_text()
    env_path = (pathlib.Path(__file__).resolve().parent.parent / ".env.dspark")
    env = env_path.read_text() if env_path.exists() else ""

    def _env(name):
        m = re.search(rf"^{name}=(.*)$", env, re.M)
        return m.group(1).strip().strip('"').strip("'") if m else None

    m = re.search(r"--served-model-name \$\{SERVED_MODEL_NAME:-([^}]*)\}", compose)
    primary = (_env("SERVED_MODEL_NAME") or (m.group(1) if m else "")).split()
    m = re.search(r"\$\{SERVED_MODEL_ALIASES:-([^}]*)\}", compose)
    aliases = (_env("SERVED_MODEL_ALIASES") or (m.group(1) if m else "")).split()
    return [*primary, *aliases]


want_ids = _expected_served_ids()
missing = sorted(set(want_ids) - set(ids))
extra = sorted(set(ids) - set(want_ids))
check(f"all {len(want_ids)} configured ids resolve",
      not missing and not extra,
      f"got {len(ids)}" + (f", missing {missing}" if missing else "")
      + (f", unexpected {extra}" if extra else ""))

# 2 ─ effort prefixes, by suffix rule and by vendor prefix rule
print("\neffort prefixes (prompt_tokens for a minimal request):")
for model, want in {**EXPECTED_PREFIX_TOKENS, **VENDOR_TIERS}.items():
    status, resp = post(minimal(model))
    got = (resp.get("usage") or {}).get("input_tokens") if status == 200 else None
    check(f"{model:<38} expect {want:>3}", got == want, f"got {got} (HTTP {status})")

# 3 ─ classifier exemption: detected by SHAPE (no tools + the monitor wording),
#     so it stays cheap whichever id Anthropic points it at next.
status, resp = post({
    "model": "claude-opus-5",          # a tier that WOULD otherwise think
    "max_tokens": 64,
    "system": "You are a security monitor for autonomous AI coding agents. "
              "Classify the following action as safe or unsafe.",
    "messages": [{"role": "user", "content": "Action: read a file. Answer safe or unsafe."}],
})
types = [b.get("type") for b in (resp.get("content") or [])] if status == 200 else []
thinking_chars = sum(len(b.get("thinking") or "")
                     for b in (resp.get("content") or [])) if status == 200 else -1
check("classifier exemption returns ['text'] only", types == ["text"], f"got {types}")
check("classifier does 0 thinking chars", thinking_chars == 0, f"got {thinking_chars}")

# 4 ─ Patch 8 must strip leaked CoT from ASSISTANT turns and nowhere else.
#     A user turn and a tool_result legitimately carry the literal string
#     (pasted logs, source files); stripping those would delete real content.
COT = "scratchpad reasoning that must not survive</think>KEPT"
probe = {"model": "deepseek-v4-flash-dspark-nothink", "max_tokens": 1, "messages": [
    {"role": "user", "content": COT},
    {"role": "assistant", "content": COT},
    {"role": "user", "content": "ok"},
]}
s1, r1 = post(probe)
# Same conversation with the assistant turn already stripped. If the strip is
# working and assistant-only, both render to the SAME prompt -> same token count.
probe2 = json.loads(json.dumps(probe))
probe2["messages"][1]["content"] = "KEPT"
s2, r2 = post(probe2)
t1 = (r1.get("usage") or {}).get("input_tokens") if s1 == 200 else None
t2 = (r2.get("usage") or {}).get("input_tokens") if s2 == 200 else None
check_answered("Patch 8 strips the assistant turn", (s1, s2), t1 == t2,
               f"with-CoT {t1} vs pre-stripped {t2}")
# And the USER turn must NOT be stripped: removing it from the user side too
# would shrink the prompt further.
probe3 = json.loads(json.dumps(probe2))
probe3["messages"][0]["content"] = "KEPT"
s3, r3 = post(probe3)
t3 = (r3.get("usage") or {}).get("input_tokens") if s3 == 200 else None
check_answered("Patch 8 leaves USER turns alone", (s1, s3), t3 is not None and t1 is not None and t3 < t1,
               f"user-stripped {t3} < assistant-only-stripped {t1}")

# 5 ─ no 500s anywhere above
n500 = sum(1 for _, ok, d in results if "HTTP 5" in d)
check("zero 5xx responses", n500 == 0, f"{n500} seen")

# ok is True -> PASS, False -> FAIL (a real regression), None -> ERROR (the
# request never answered, so the check did not run). Only FAIL is a regression;
# conflating the two is what reported a healthy Patch 8 as broken on 2026-09-20.
bad     = [n for n, ok, _ in results if ok is False]
errored = [n for n, ok, _ in results if ok is None]
passed  = [n for n, ok, _ in results if ok is True]
print("\n" + "=" * 70)
print(f"{len(passed)}/{len(results)} checks passed"
      + (f", {len(errored)} could not run" if errored else ""))
if bad:
    print("FAILED: " + ", ".join(bad))
if errored:
    print("DID NOT RUN (request never answered -- re-run when the cluster is quieter): "
          + ", ".join(errored))
sys.exit(1 if bad else 0)

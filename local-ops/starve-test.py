"""MNT-10 validation: does a long prefill still starve a decoding request?

Method. One "victim" streams a long decode with a small prompt. Once it is
established and decoding steadily, an "attacker" fires a large, UNIQUELY
STAMPED (so uncached) prompt. We compare the victim's token rate before the
attacker arrives with its rate while the attacker prefills.

Starvation shows up as the victim's during/before ratio collapsing toward 0.

Arms are flipped live via the flags file -- no restart -- which is the whole
point of gating MNT-10:
    long_prefill_token_threshold = 0     stock: one prefill takes the whole budget
    long_prefill_token_threshold = 2048  MNT-10 as deployed

Usage: starve-test.py <label>
"""
import json
import statistics
import sys
import threading
import time
import urllib.request

URL = "http://127.0.0.1:8888/v1/chat/completions"
MODEL = "deepseek-v4-flash-dspark"
LABEL = sys.argv[1] if len(sys.argv) > 1 else "run"

ATTACK_WORDS = 16000       # ~160K tokens (phrase is ~10 tokens)
VICTIM_MAX_TOKENS = 700
SETTLE_TOKENS = 25         # victim tokens to observe before firing the attacker


def post(payload, timeout=900):
    req = urllib.request.Request(
        URL, json.dumps(payload).encode(), {"Content-Type": "application/json"}
    )
    return urllib.request.urlopen(req, timeout=timeout)


victim_stamps = []          # (monotonic_time) per streamed token
attacker = {}


def run_victim():
    payload = {
        "model": MODEL,
        # Unique so the victim itself is never served from cache.
        "messages": [{"role": "user", "content":
                      f"[{LABEL}-victim-{time.time()}] Count slowly from 1 to 400, "
                      "one number per line, nothing else."}],
        "max_tokens": VICTIM_MAX_TOKENS,
        "temperature": 0,
        "stream": True,
    }
    resp = post(payload)
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data: "):
            continue
        body = line[6:]
        if body == "[DONE]":
            break
        try:
            chunk = json.loads(body)
        except ValueError:
            continue
        delta = chunk.get("choices", [{}])[0].get("delta", {})
        if delta.get("content"):
            victim_stamps.append(time.monotonic())


def run_attacker():
    # Unique stamp => genuinely uncached => a real long prefill.
    filler = f"unique-{LABEL}-{time.time()} " + ("the quick brown fox jumps over the lazy dog " * ATTACK_WORDS)
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": filler + "\nReply with just: X"}],
        "max_tokens": 1,
        "temperature": 0,
    }
    attacker["start"] = time.monotonic()
    try:
        r = post(payload)
        j = json.load(r)
        attacker["prompt_tokens"] = j["usage"]["prompt_tokens"]
        attacker["cached"] = (j["usage"].get("prompt_tokens_details") or {}).get("cached_tokens")
    except Exception as exc:                      # noqa: BLE001
        attacker["error"] = repr(exc)
    attacker["end"] = time.monotonic()


def rate(stamps):
    """Tokens/sec from a list of arrival times."""
    if len(stamps) < 2:
        return 0.0
    span = stamps[-1] - stamps[0]
    return (len(stamps) - 1) / span if span > 0 else 0.0


vt = threading.Thread(target=run_victim, daemon=True)
vt.start()

# Wait until the victim is genuinely decoding, so we measure decode vs decode.
deadline = time.monotonic() + 120
while len(victim_stamps) < SETTLE_TOKENS and time.monotonic() < deadline:
    time.sleep(0.05)

if len(victim_stamps) < SETTLE_TOKENS:
    print(json.dumps({"label": LABEL, "error": "victim never settled",
                      "tokens": len(victim_stamps)}))
    sys.exit(1)

before_cut = len(victim_stamps)
at = threading.Thread(target=run_attacker, daemon=True)
at.start()
at.join(900)
after_cut = len(victim_stamps)

before = victim_stamps[:before_cut]
during = victim_stamps[before_cut:after_cut]

r_before = rate(before)
r_during = rate(during)

# Largest gap between consecutive victim tokens while the attacker prefilled:
# this is the stall the user actually feels.
gaps = [b - a for a, b in zip(during, during[1:])] if len(during) > 1 else []

vt.join(30)

print(json.dumps({
    "label": LABEL,
    "victim_tok_s_before": round(r_before, 2),
    "victim_tok_s_during_prefill": round(r_during, 2),
    "ratio_during_over_before": round(r_during / r_before, 3) if r_before else None,
    "victim_tokens_during": len(during),
    "max_stall_s": round(max(gaps), 2) if gaps else None,
    "median_gap_s": round(statistics.median(gaps), 3) if gaps else None,
    "attacker_prompt_tokens": attacker.get("prompt_tokens"),
    "attacker_cached_tokens": attacker.get("cached"),
    "attacker_prefill_s": round(attacker["end"] - attacker["start"], 1),
    "attacker_error": attacker.get("error"),
}, indent=2))

#!/usr/bin/env python3
"""Drive KV cache into the danger zone and watch for preemption/collapse."""
import json, os, random, subprocess, sys, threading, time, urllib.request

API = "http://127.0.0.1:8888/v1/chat/completions"
MODEL = "deepseek-v4-flash-dspark"
CONTAINER = "deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1"
WORDS = [w.strip() for w in open("/usr/share/dict/words")] if os.path.exists("/usr/share/dict/words") else None
if not WORDS or len(WORDS) < 5000:
    WORDS = ["%s%d" % (c*3, i) for i, c in enumerate("abcdefghijklmnopqrstuvwxyz"*400)]

def gen_text(seed, nwords):
    r = random.Random(seed)
    return " ".join(r.choice(WORDS) for _ in range(nwords))

def post(payload, timeout=1800):
    if os.path.exists("/tmp/ABORT_TEST"):
        raise RuntimeError("aborted by oomguard")
    req = urllib.request.Request(API, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def calibrate():
    txt = gen_text(0, 2000)
    out = post({"model": MODEL, "max_tokens": 1, "temperature": 0,
                "messages": [{"role": "user", "content": txt}]}, timeout=300)
    pt = out["usage"]["prompt_tokens"]
    return pt / 2000.0

stop = False
peak = {"kv": 0.0, "running": 0, "waiting": 0}
def monitor():
    while not stop:
        if os.path.exists("/tmp/ABORT_TEST"):
            print("  monitor: ABORT flag seen, stopping", flush=True); return
        try:
            log = subprocess.run(["docker", "logs", "--tail", "25", CONTAINER],
                                 capture_output=True, text=True, timeout=20)
            for line in reversed((log.stdout + log.stderr).splitlines()):
                if "GPU KV cache usage" in line:
                    kv = float(line.split("GPU KV cache usage:")[1].split("%")[0])
                    run = int(line.split("Running:")[1].split("reqs")[0])
                    wait = int(line.split("Waiting:")[1].split("reqs")[0])
                    if kv > peak["kv"]:
                        peak.update(kv=kv, running=run, waiting=wait)
                    print("  [%s] Running:%3d Waiting:%3d  KV:%5.1f%%" % (time.strftime("%H:%M:%S"), run, wait, kv), flush=True)
                    break
        except Exception as e:
            print("  monitor: %s" % e, flush=True)
        time.sleep(4)

def wave(label, n, target_tokens, tpw, gen_tokens, seed0):
    nwords = int(target_tokens / tpw)
    print("\n### %s: %d requests x ~%dK prompt tokens (%d words each)" % (label, n, target_tokens//1000, nwords), flush=True)
    results = []
    def one(i):
        t0 = time.time()
        try:
            out = post({"model": MODEL, "max_tokens": gen_tokens, "temperature": 0.7,
                        "messages": [{"role": "user", "content":
                                      "Summarize the distinct themes in this text.\n\n" + gen_text(seed0 + i, nwords)}]})
            u = out["usage"]
            results.append((i, u["prompt_tokens"], u["completion_tokens"], time.time() - t0, None))
        except Exception as e:
            results.append((i, 0, 0, time.time() - t0, str(e)[:80]))
    ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return results

if __name__ == "__main__":
    print("### calibrating tokens/word ...", flush=True)
    tpw = calibrate()
    print("### tokens per word = %.3f" % tpw, flush=True)
    mon = threading.Thread(target=monitor, daemon=True); mon.start()
    allres = []
    # wave 1: ~50% of pool ; wave 2: push toward ~90%
    allres += wave("WAVE 1", 6, 250000, tpw, 3000, 1000)
    allres += wave("WAVE 2", 10, 250000, tpw, 3000, 2000)
    stop = True; time.sleep(1)
    print("\n### RESULTS")
    for i, pt, ct, el, err in sorted(allres):
        print("  req%-3d prompt=%-8d completion=%-6d %6.1fs %s" % (i, pt, ct, el, err or "OK"), flush=True)
    print("\n### PEAK KV: %.1f%%  (Running:%d Waiting:%d)" % (peak["kv"], peak["running"], peak["waiting"]))

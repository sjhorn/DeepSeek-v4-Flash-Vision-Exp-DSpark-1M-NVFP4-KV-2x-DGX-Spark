#!/usr/bin/env python3
"""Local capture tap: log exactly what Claude Code sends, then forward upstream.

Runs on the Mac, in front of the vllm-proxy. No server change, no restart --
Claude Code just points at it instead of the proxy:

    python3 local-ops/prompt-tap.py --port 8899          # terminal 1
    ANTHROPIC_BASE_URL=http://127.0.0.1:8899 <launcher>  # terminal 2

Every request is appended to prompt-tap.jsonl with the full body. Analyse with:

    python3 local-ops/prompt-tap.py --analyse prompt-tap.jsonl
"""
import argparse, collections, hashlib, json, os, pathlib, ssl, statistics, sys, time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROFILE = os.path.expanduser("~/.config/vllm-proxy/claude-latest-local.json")
OUT = pathlib.Path("prompt-tap.jsonl")
METRICS = None          # --metrics-url; None disables live cache measurement


def cache_counters():
    """(prefix_cache_queries, prefix_cache_hits, in_flight) or None.

    Read either side of a forwarded request, the delta is that request's own
    cache accounting -- the engine's number, not our model of the prompt.
    Measuring here rather than by replaying the capture is the whole point: a
    replay runs against a cache the original session already warmed, so every
    turn would read ~100% and the measurement would be worthless.
    """
    if not METRICS:
        return None
    try:
        txt = urllib.request.urlopen(METRICS + "/metrics", timeout=30).read().decode()
    except Exception:
        return None
    agg = {}
    for line in txt.splitlines():
        if not line or line.startswith("#"):
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        try:
            agg[name] = agg.get(name, 0.0) + float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            continue
    return (agg.get("vllm:prefix_cache_queries_total", 0.0),
            agg.get("vllm:prefix_cache_hits_total", 0.0),
            agg.get("vllm:num_requests_running", 0.0)
            + agg.get("vllm:num_requests_waiting", 0.0))


def upstream():
    p = json.loads(pathlib.Path(PROFILE).read_text())
    c = pathlib.Path(os.path.expanduser("~/.cache/vllm-proxy")) / p["name"]
    ctx = ssl.create_default_context(cafile=str(c / "ca.pem"))
    ctx.load_cert_chain(str(c / "client.crt"), str(c / "client.key"))
    return p["baseUrl"].rstrip("/"), p["apiKey"], ctx


_threading = __import__("threading")
_INFLIGHT = 0
_INFLIGHT_LOCK = _threading.Lock()
# --serialize: forward one request at a time. The engine's prefix-cache
# counters are GLOBAL, so a concurrent request lands inside another's delta and
# the hit ratio becomes a blend of two prompts. Claude Code really does run 2-3
# requests at once (measured: running=2 waiting=1 mid-session), so without this
# most turns are unmeasurable. It costs wall-clock and nothing else -- tokens
# and hit ratios are unaffected by the order requests are served in, and the
# plan treats seconds as indicative anyway.
SERIALIZE = False
_SERIAL_LOCK = _threading.Lock()


# Headers are part of the request the engine sees, and we had never recorded
# them -- a genuine blind spot: `anthropic-beta` values, `anthropic-version`
# and any cache-related header were invisible to every analysis run so far.
# Credentials are NEVER written to the capture; everything else is.
REDACT_HEADERS = {"authorization", "x-api-key", "proxy-authorization", "cookie"}


def _safe_headers(headers):
    return {k: v for k, v in headers.items()
            if k.lower() not in REDACT_HEADERS}


class Tap(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw)
        except Exception:
            body = None

        rec = None
        if body is not None:
            rec = {"ts": time.strftime("%H:%M:%S"), "path": self.path,
                   "headers": _safe_headers(self.headers), "body": body}
            sysblk = body.get("system")
            syslen = len(sysblk) if isinstance(sysblk, str) else sum(
                len(b.get("text", "")) for b in (sysblk or []) if isinstance(b, dict))
            print(f"[{rec['ts']}] {self.path} model={body.get('model')} "
                  f"max_tokens={body.get('max_tokens')} msgs={len(body.get('messages',[]))} "
                  f"tools={len(body.get('tools') or [])} system_chars={syslen} "
                  f"stream={body.get('stream')}", flush=True)

        global _INFLIGHT
        if SERIALIZE:
            _SERIAL_LOCK.acquire()
        with _INFLIGHT_LOCK:
            _INFLIGHT += 1
            concurrent = _INFLIGHT > 1
        before = cache_counters()
        t0 = time.time()

        base, key, ctx = self.server.up
        req = urllib.request.Request(base + self.path, data=raw, method="POST")
        for h in ("content-type", "anthropic-version", "anthropic-beta", "accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        req.add_header("x-api-key", key)
        try:
            r = urllib.request.urlopen(req, timeout=1800, context=ctx)
        except urllib.error.HTTPError as e:
            r = e
        self.send_response(r.status)
        for k, v in r.headers.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        seen = bytearray()
        stream_error = None
        try:
            while chunk := r.read(4096):
                if len(seen) < 1_000_000:
                    seen += chunk
                self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except Exception as e:                       # noqa: BLE001
            stream_error = repr(e)[:200]
            self.close_connection = True

        with _INFLIGHT_LOCK:
            _INFLIGHT -= 1
        after = cache_counters()
        if SERIALIZE:
            _SERIAL_LOCK.release()

        if rec is not None:
            rec["seconds"] = round(time.time() - t0, 3)
            rec["status"] = r.status
            rec["stream_error"] = stream_error
            if before and after:
                dq, dh = after[0] - before[0], after[1] - before[1]
                rec["cache"] = {
                    "queries": dq, "hits": dh,
                    "hit_pct": round(100.0 * dh / dq, 2) if dq > 0 else None,
                    # Global counters: a concurrent request lands in the same
                    # delta. Flag it rather than silently reporting a blend.
                    # Tap-side concurrency is exact. The engine's
                    # num_requests_running gauge lags its logging interval, so
                    # it is kept only as a hint, never as the flag.
                    "contended": concurrent,
                    "engine_busy": bool(before[2] or after[2]),
                }
            rec["usage"] = _usage_from_stream(bytes(seen))
            rec["hashes"] = _slice_hashes(body)
            with OUT.open("a") as f:
                f.write(json.dumps(rec) + "\n")
            c = rec.get("cache") or {}
            u = rec.get("usage") or {}
            print(f"          -> {rec['seconds']:6.2f}s  in={u.get('input_tokens')} "
                  f"out={u.get('output_tokens')} "
                  f"hit={c.get('hit_pct')}%"
                  f"{' CONTENDED' if c.get('contended') else ''}"
                  f"{' STREAM-ERROR' if stream_error else ''}",
                  flush=True)

    def do_GET(self):
        base, key, ctx = self.server.up
        req = urllib.request.Request(base + self.path)
        req.add_header("x-api-key", key)
        r = urllib.request.urlopen(req, timeout=60, context=ctx)
        data = r.read()
        self.send_response(r.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def _usage_from_stream(raw):
    """Pull the usage block out of an SSE (or plain JSON) response body."""
    try:
        return json.loads(raw)["usage"]
    except Exception:
        pass
    usage = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.startswith("data:"):
            continue
        try:
            ev = json.loads(line[5:].strip())
        except Exception:
            continue
        u = ev.get("usage") or (ev.get("message") or {}).get("usage")
        if isinstance(u, dict):
            usage.update({k: v for k, v in u.items() if v is not None})
    return usage or None


def _slice_hashes(body):
    """sha256(12) of the tools array and of the raw system text.

    The two slices that, if they change under an ongoing conversation, moved
    the prompt head. Cheap enough to take on every request.
    """
    tools = body.get("tools") or []
    th = hashlib.sha256(json.dumps(
        [{"name": t.get("name"), "schema": t.get("input_schema")} for t in tools],
        sort_keys=True).encode()).hexdigest()[:12] if tools else None
    return {"tools": th, "n_tools": len(tools),
            "tool_names": sorted(t.get("name", "?") for t in tools),
            "system": hashlib.sha256(sys_text(body).encode()).hexdigest()[:12]}


def sys_text(b):
    s = b.get("system")
    if isinstance(s, str):
        return s
    return "\n".join(x.get("text", "") for x in (s or []) if isinstance(x, dict))


def analyse(path):
    rows = [json.loads(l)["body"] for l in open(path) if l.strip()]
    print(f"captured requests: {len(rows)}\n")
    kinds = collections.Counter()
    by_sys = collections.defaultdict(list)
    for b in rows:
        st = sys_text(b)
        tools = len(b.get("tools") or [])
        kind = ("classifier?" if tools == 0 and (b.get("max_tokens") or 0) <= 512
                else "main-agent" if tools > 5 else "other")
        kinds[kind] += 1
        by_sys[(kind, st[:120])].append(b)
    print("request kinds:", dict(kinds), "\n")
    for (kind, head), items in sorted(by_sys.items(), key=lambda kv: -len(kv[1])):
        sizes = [len(json.dumps(b)) for b in items]
        mt = {b.get("max_tokens") for b in items}
        models = {b.get("model") for b in items}
        syss = {sys_text(b) for b in items}
        print(f"--- {kind}: {len(items)} requests")
        print(f"    models={models}  max_tokens={mt}")
        print(f"    distinct system prompts: {len(syss)}  "
              f"(identical => prefix-cacheable)")
        print(f"    body bytes: median={statistics.median(sizes):,.0f} "
              f"max={max(sizes):,}")
        print(f"    system starts: {head!r}\n")
    return rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--out", default="prompt-tap.jsonl")
    ap.add_argument("--analyse")
    ap.add_argument("--serialize", action="store_true",
                    help="forward one request at a time so each /metrics delta "
                         "belongs to exactly one request")
    ap.add_argument("--metrics-url", default=os.environ.get("DSPARK_BASE_URL"),
                    help="vLLM base URL for live prefix-cache measurement "
                         "(e.g. http://127.0.0.1:8888 over the SSH tunnel)")
    a = ap.parse_args()
    if a.analyse:
        analyse(a.analyse)
        sys.exit(0)
    OUT = pathlib.Path(a.out)
    METRICS = a.metrics_url.rstrip("/") if a.metrics_url else None
    SERIALIZE = a.serialize
    print("serialised forwarding:", "ON" if SERIALIZE else "off")
    print("live cache measurement:", METRICS or "OFF (pass --metrics-url)")
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Tap)
    srv.up = upstream()
    print(f"tap listening on http://127.0.0.1:{a.port} -> {srv.up[0]}")
    print(f"logging bodies to {OUT}\n")
    srv.serve_forever()

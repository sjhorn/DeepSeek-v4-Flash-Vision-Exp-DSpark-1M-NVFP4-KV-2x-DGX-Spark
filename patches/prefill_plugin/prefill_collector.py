# PATCH 14b: the engine's own per-request prefill record, published on its own
# loopback port.
#
# WHAT THIS EXISTS TO FIX. vLLM measures, per request, exactly the numbers the
# proxy spends a fitted quadratic inverting -- num_cached_tokens, queued_time,
# prefill_time, decode_time -- assembles them into a FinishedRequestStats, folds
# them into Prometheus histograms, and throws the per-request row away. The
# proxy downstream can see a prefill's wall-clock and nothing else, so it
# estimates what this process already knows.
#
# WHY IT IS A STAT LOGGER AND NOT A ROUTE. queued/prefill/decode_time never
# reach the serving layer at all: they are computed on the output-handler loop
# after the request is finished, from timestamps the scheduler kept. A FastAPI
# route has no access to them. StatLoggerBase.record() is where they surface.
#
# WHY IT IS NOT ON PORT 8888. Caddy's catch-all `handle {}` in the proxy
# forwards EVERY path to the failover pool, so any route added to this app is
# reachable by any mTLS client and by any LAN client on :443. A Caddyfile
# denylist would have to be maintained in two site blocks, on the one directive
# group that repo has already been bitten by. So this binds its own loopback
# port inside the container; sparkstats -- already tunnelled, already
# admin-only -- proxies it. Engine observability stays on the telemetry path.
#
# WHY IT IS AN ENTRY POINT AND NOT AN IMPORT. AsyncLLM is constructed in
# build_async_engine_client, which runs BEFORE init_app_state imports the
# anthropic serving module -- so monkeypatching from the already-mounted
# serving.py is too late: load_stat_logger_plugin_factories() has already run.
# The supported hook is the `vllm.stat_logger_plugins` entry-point group, which
# importlib.metadata reads off sys.path -- so a bind-mounted directory carrying
# this file and a .dist-info is enough, with no image rebuild and no wheel.
#
# IT MUST NOT BE ABLE TO HARM A REQUEST. record() runs on the output-handler
# loop, the hottest and least forgiving place in the engine. Every entry point
# here is wrapped in a bare try/except, the ring is bounded, the HTTP server
# runs on its own daemon thread, and nothing here ever touches a request.
#
# IT HOLDS NO CONTENT. FinishedRequestStats carries counts, times and an opaque
# request_id. There is no prompt anywhere in this file, by construction rather
# than by care.

from __future__ import annotations

import json
import logging
import os
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from vllm.v1.metrics.loggers import StatLoggerBase

logger = logging.getLogger(__name__)

# The ring. 4096 finished requests at ~200 bytes of Python floats and ints is a
# couple of megabytes inside a container that already holds a model -- but the
# real bound is the CURSOR below, which lets a poller take everything it has not
# seen without the ring ever needing to be large. Sized for a poller that goes
# away for an hour, not for history: history lives in the proxy's usage log.
RING = int(os.environ.get("PREFILL_RING", "4096"))
PORT = int(os.environ.get("PREFILL_COLLECTOR_PORT", "9094"))
HOST = os.environ.get("PREFILL_COLLECTOR_HOST", "127.0.0.1")

# Module-level, not per-instance. A data-parallel deployment builds one logger
# per engine and PerEngineStatLoggerAdapter fans record() out to all of them;
# they must share one ring and one listener or the cursor would mean a different
# thing on each port.
_LOCK = threading.Lock()
_ROWS: deque = deque(maxlen=RING)
_SEQ = 0
_SERVER = None

# HEALTH, BECAUSE THE FIRST VERSION COULD DIE IN COMPLETE SILENCE and did.
#
# record() is wrapped in a bare except so it can never raise into the engine's
# output-handler loop -- that part was right. What was wrong is where the
# exception went: logger.debug, on a module logger that does not reach the
# container's log at all. So a collector that raised on EVERY call looked
# exactly like a collector on an idle engine: HTTP up, answering, ring frozen.
# Measured 2026-09-20: it stopped after 34 rows and nothing anywhere said so.
#
# These counters are the fix. They cost four integers and they turn "the ring
# is not advancing" from a mystery into a number, on the same endpoint the
# consumer already polls. `last_error` is the exception's type and message
# only -- never a request field, so no prompt can reach it.
_STATS = {"calls": 0, "finished_seen": 0, "appended": 0, "skipped_no_id": 0,
          "errors": 0, "last_error": None}
_WARNED = False


def _append(row: dict) -> None:
    global _SEQ
    with _LOCK:
        _SEQ += 1
        row["seq"] = _SEQ
        _ROWS.append(row)


def _since(cursor: int, limit: int):
    """Rows strictly after `cursor`, oldest first, with the ring's extent.

    THE CURSOR IS WHY A POLL CAN NEITHER MISS NOR DUPLICATE. seq is monotonic
    and assigned under the lock, so "everything after N" is exact. `oldest` is
    returned so a caller that fell behind the ring can TELL -- if its cursor is
    below oldest-1 it has lost rows, which is a different fact from having
    caught up, and it must not be left to infer that from a short page.
    """
    with _LOCK:
        rows = [r for r in _ROWS if r["seq"] > cursor][:limit]
        oldest = _ROWS[0]["seq"] if _ROWS else 0
        return rows, oldest, _SEQ


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # noqa: D102 - silence the default stderr spam
        pass

    def do_GET(self):  # noqa: N802
        try:
            u = urlparse(self.path)
            if u.path not in ("/prefill", "/api/prefill"):
                self.send_error(404)
                return
            q = parse_qs(u.query)
            try:
                cursor = int(q.get("since", ["0"])[0])
            except (TypeError, ValueError):
                cursor = 0
            try:
                limit = max(1, min(1000, int(q.get("limit", ["200"])[0])))
            except (TypeError, ValueError):
                limit = 200
            rows, oldest, seq = _since(cursor, limit)
            body = json.dumps({
                "rows": rows,
                # next_since is the caller's next cursor. It is the last row's
                # seq and NOT `seq`: handing back the global head would skip
                # anything that arrived between the slice and the reply.
                "next_since": rows[-1]["seq"] if rows else cursor,
                "seq": seq,
                "oldest": oldest,
                "ring": RING,
                # Shipped on every read so a stalled collector is visible to
                # whoever is already looking, rather than needing a second
                # endpoint nobody thinks to call.
                "health": dict(_STATS),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception:  # noqa: BLE001
            try:
                self.send_error(500)
            except Exception:  # noqa: BLE001
                pass


def _serve_once() -> None:
    """Bind the listener, once per process. Failure costs the rows, not vLLM."""
    global _SERVER
    with _LOCK:
        if _SERVER is not None:
            return
        try:
            _SERVER = ThreadingHTTPServer((HOST, PORT), _Handler)
        except Exception:  # noqa: BLE001
            logger.warning("prefill collector could not bind %s:%s; "
                           "per-request prefill rows will not be published",
                           HOST, PORT, exc_info=True)
            _SERVER = False
            return
    t = threading.Thread(target=_SERVER.serve_forever, name="prefill-collector",
                         daemon=True)
    t.start()
    logger.info("prefill collector listening on %s:%s (ring=%d)", HOST, PORT, RING)


class PrefillCollector(StatLoggerBase):
    """Keeps the per-request prefill rows vLLM otherwise discards."""

    def __init__(self, vllm_config, engine_index: int = 0):
        self.engine_index = engine_index
        try:
            _serve_once()
        except Exception:  # noqa: BLE001
            logger.debug("prefill collector failed to start", exc_info=True)

    def record(self, scheduler_stats=None, iteration_stats=None,
               mm_cache_stats=None, engine_idx: int = 0):
        # A BARE except AROUND THE WHOLE BODY, deliberately. This runs on the
        # output-handler loop; an exception here would propagate into the loop
        # that drives every in-flight request. Losing a row is free, and losing
        # the engine is not.
        global _WARNED
        try:
            _STATS["calls"] += 1
            if iteration_stats is None:
                return
            for f in getattr(iteration_stats, "finished_requests", ()) or ():
                _STATS["finished_seen"] += 1
                rid = getattr(f, "request_id", None)
                if not rid:
                    # Without the join key the row cannot be matched to
                    # anything, and an unattributable row is noise in a ring
                    # sized for a poller. Dropped rather than stored.
                    _STATS["skipped_no_id"] += 1
                    continue
                _append({
                    "request_id": rid,
                    "engine": engine_idx,
                    "prompt_tokens": int(getattr(f, "num_prompt_tokens", 0) or 0),
                    # THE NUMBER THIS WHOLE PATH EXISTS FOR. The proxy's
                    # cacheEstimate inverts a fitted quadratic to guess it.
                    "cached_tokens": int(getattr(f, "num_cached_tokens", 0) or 0),
                    "generation_tokens": int(getattr(f, "num_generation_tokens", 0) or 0),
                    # Seconds, as the engine keeps them. Not milliseconds: the
                    # proxy's milestones are ms and converting here would make
                    # two units look like one.
                    "queued_s": float(getattr(f, "queued_time", 0.0) or 0.0),
                    # THE SPLIT THE PROXY CANNOT MAKE ON A NON-STREAM. phases()
                    # refuses there because headers and body arrive together;
                    # the engine has always known, and this is it.
                    "prefill_s": float(getattr(f, "prefill_time", 0.0) or 0.0),
                    "decode_s": float(getattr(f, "decode_time", 0.0) or 0.0),
                    "e2e_s": float(getattr(f, "e2e_latency", 0.0) or 0.0),
                    "finish_reason": str(getattr(f, "finish_reason", "") or ""),
                })
                _STATS["appended"] += 1
        except Exception as exc:  # noqa: BLE001
            # STILL NEVER RAISES into the engine loop -- but it is no longer
            # silent. The counter is the durable signal; the warning is so the
            # FIRST failure appears in the container log, once, where an
            # operator looking at logs will actually see it.
            _STATS["errors"] += 1
            _STATS["last_error"] = "%s: %s" % (type(exc).__name__, exc)
            if not _WARNED:
                _WARNED = True
                logger.warning("prefill collector record() failed; rows will be "
                               "missing from here on", exc_info=True)

    def log_engine_initialized(self):
        try:
            logger.info("prefill collector attached to engine %s", self.engine_index)
        except Exception:  # noqa: BLE001
            pass

    def log(self):
        pass

"""dspark031 -- the DSpark recipe's small runtime patches for vLLM 0.31, as a plugin.

On 0.21 these were whole-file bind-mounts of 900- and 3,300-line vLLM files
(patch7-block_pool-dedupe.py, mnt10-scheduler.py). On 0.31 each needs one
method wrapped, so they are a general plugin instead: nothing of vLLM is
copied, and an upstream change to the rest of those files cannot be shadowed.

  KV-7 (was patch7)  dedupe a recomputed (hash, group) at cache time
  MNT-10             long_prefill_token_threshold, live from the flags file

Each logs ONE line when armed, so a missing plugin is visible, and each has a
kill switch. Entry point: vllm.general_plugins -> dspark031:register (loaded
in every vLLM process; each patch is idempotent).
Detail: docs/port-0.31/README.md, docs/local/PATCH-REGISTRY.md.
"""

from __future__ import annotations

import json
import logging
import os
import time

logger = logging.getLogger("vllm.dspark031")

STATS = {"dedupe_evicted": 0, "dedupe_skipped_multi_hash": 0}


# -- KV-7: commit-time dedupe -------------------------------------------------
#
# why (measured on 0.21, ported from co-l/ds4-prefix-cache-fixes 03-dedupe.py):
# a re-computed position (hit-path drop, spec-decode boundary) caches a SECOND
# block under the same (hash, group). BlockHashToBlockMap.insert() merges the
# two, lookups return only one, and the stale copy holds an LRU slot forever.
# 0.31's NOTE #1 says it still does not de-duplicate.
#
# *** CHANGED FOR 0.31. *** A 0.31 block can carry SEVERAL hashes
# (cached_block_hashes_by_block), and _maybe_evict_cached_block() strips ALL
# of them. 0.21's patch called it on the old block, which then held exactly
# one. So this evicts the old copy only when its ONLY hash is the duplicate
# key -- the 0.21 case, where the eviction removes exactly that mapping --
# and otherwise leaves both and counts dedupe_skipped_multi_hash.
#
# kill switch: DSPARK_BLOCK_DEDUPE=0 (read per call).

def _dedupe_on() -> bool:
    return os.environ.get("DSPARK_BLOCK_DEDUPE", "1") != "0"


def install_block_dedupe() -> bool:
    try:
        from vllm.v1.core import block_pool as bp
    except Exception as exc:
        logger.warning("dspark031: KV-7 dedupe NOT installed: %s", exc)
        return False
    cls = bp.BlockPool
    orig = getattr(cls, "_insert_block_hash", None)
    if orig is None:
        logger.warning("dspark031: KV-7 dedupe NOT installed: this vLLM has no "
                       "BlockPool._insert_block_hash (not the 0.31 shape)")
        return False
    if getattr(orig, "_dspark031", False):
        return True

    def _insert_block_hash(self, block_hash_with_group_id, block, num_tokens):
        if _dedupe_on() and block.block_hash != block_hash_with_group_id:
            cache = self.cached_block_hash_to_block
            if not cache.contain(block_hash_with_group_id, block.block_id):
                old = cache.get_one_block(block_hash_with_group_id)
                if old is not None and old is not block:
                    only_this = (
                        old.block_hash == block_hash_with_group_id
                        and not self.cached_block_hashes_by_block.get(old.block_id)
                    )
                    if only_this:
                        if self._maybe_evict_cached_block(old):
                            STATS["dedupe_evicted"] += 1
                    else:
                        STATS["dedupe_skipped_multi_hash"] += 1
        return orig(self, block_hash_with_group_id, block, num_tokens)

    _insert_block_hash._dspark031 = True
    cls._insert_block_hash = _insert_block_hash
    logger.info("dspark031: KV-7 armed -- a recomputed (hash, group) evicts its "
                "stale single-hash copy at cache time (DSPARK_BLOCK_DEDUPE=0 "
                "disables)")
    return True


# -- MNT-10: long_prefill_token_threshold, live -------------------------------
#
# why (0.21, 2026-09-21): the scheduler walks self.running against ONE token
# budget, so a request mid-chunked-prefill can take all of it and starve every
# decode behind it. --long-prefill-token-threshold caps one request's share per
# step, but only at boot; the right value is unknown, and a boot per arm is the
# cost. 0.31's Scheduler.schedule() re-reads
# scheduler_config.long_prefill_token_threshold on every call, so setting that
# field before each call is exact -- no scheduler copy.
#
# Precedence: VLLM_LONG_PREFILL_TOKEN_THRESHOLD env > the flags file's
# long_prefill_token_threshold > the boot value. The file is re-read at most
# once a second; a half-written file keeps the LAST GOOD value.
#
# Changed upstream on 0.31, around this: a LONE request is never capped
# ("nobody to starve"), and --long-prefill-token-threshold-adaptive floors the
# cap at a fair share. Both act on the value set here.
#
# kill switch: none needed -- with neither the env var nor the key set, the
# boot value is used and nothing changes.

_FLAGS = os.environ.get("VLLM_KV_FLAGS_FILE", "/etc/vllm-kv-flags/flags.json")
_cache: list = [0.0, {}]
_logged: set = set()


def _flags() -> dict:
    now = time.monotonic()
    if now - _cache[0] < 1.0:
        return _cache[1]
    try:
        with open(_FLAGS) as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            data = _cache[1]
    except Exception:
        data = _cache[1]
    _cache[0], _cache[1] = now, data
    return data


def threshold(boot_value: int) -> int:
    """The per-step cap for one request; boot_value unless overridden."""
    raw = os.environ.get("VLLM_LONG_PREFILL_TOKEN_THRESHOLD")
    if raw is None or str(raw).strip() == "":
        raw = _flags().get("long_prefill_token_threshold")
    if raw is None:
        return boot_value
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return boot_value
    if value < 0:
        return boot_value
    if value != boot_value and value not in _logged:
        _logged.add(value)
        logger.info("dspark031: MNT-10 long_prefill_token_threshold -> %d (boot "
                    "value %d)", value, boot_value)
    return value


def install_live_long_prefill() -> bool:
    try:
        from vllm.v1.core.sched import scheduler as sm
    except Exception as exc:
        logger.warning("dspark031: MNT-10 NOT installed: %s", exc)
        return False
    cls = sm.Scheduler
    orig = cls.schedule
    if getattr(orig, "_dspark031", False):
        return True

    def schedule(self, *a, **kw):
        cfg = self.scheduler_config
        boot = getattr(self, "_dspark031_boot_lpt", None)
        if boot is None:
            boot = int(getattr(cfg, "long_prefill_token_threshold", 0) or 0)
            self._dspark031_boot_lpt = boot
            logger.info("dspark031: MNT-10 armed -- boot "
                        "long_prefill_token_threshold=%d; live override from "
                        "VLLM_LONG_PREFILL_TOKEN_THRESHOLD or %s (%s)", boot,
                        _FLAGS, "present" if os.path.exists(_FLAGS) else "ABSENT")
        want = threshold(boot)
        if cfg.long_prefill_token_threshold != want:
            try:
                cfg.long_prefill_token_threshold = want
            except Exception:
                object.__setattr__(cfg, "long_prefill_token_threshold", want)
        return orig(self, *a, **kw)

    schedule._dspark031 = True
    cls.schedule = schedule
    return True


def register() -> None:
    """vllm.general_plugins entry point."""
    for fn in (install_block_dedupe, install_live_long_prefill):
        try:
            fn()
        except Exception:
            logger.exception("dspark031: %s failed (continuing)", fn.__name__)

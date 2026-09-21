# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
import itertools
import json
import os
import time
from abc import ABC, abstractmethod
from collections import OrderedDict, defaultdict, deque
from collections.abc import Sequence

from vllm.logger import init_logger
from vllm.utils.math_utils import cdiv
from vllm.v1.core.block_pool import BlockPool
from vllm.v1.core.kv_cache_utils import (
    BlockHashList,
    BlockHashWithGroupId,
    KVCacheBlock,
)
from vllm.v1.kv_cache_interface import (
    ChunkedLocalAttentionSpec,
    CrossAttentionSpec,
    FullAttentionSpec,
    HiddenStateCacheSpec,
    KVCacheSpec,
    MambaSpec,
    MLAAttentionSpec,
    SinkFullAttentionSpec,
    SlidingWindowMLASpec,
    SlidingWindowSpec,
    TQFullAttentionSpec,
)
from vllm.v1.request import Request

logger = init_logger(__name__)

# MNT-6a (2026-09-06, logged as "Patch 5" before 2026-09-20): bound the prompt-block
# protection set.  NOT the detokenizer patch -- that is MNT-5.  See
# docs/local/PATCH-REGISTRY.md.
# Upstream-of-this-fork behaviour caps protected prompt blocks at
# 2 * max_model_len / block_size per KV group, which at max_model_len=1M and
# block_size=256 (8,192 blocks) exceeds the whole pool (6,911 blocks): the
# protected set then grows by ~30 blocks per request and is released only
# FIFO under allocation pressure, evicting the live conversation's prefix.
# VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION bounds the total protected share of
# the pool across all KV groups (default 0.30). Set to 0 to disable protection.
_PROTECTED_FRACTION_ENV = "VLLM_PROTECTED_PROMPT_BLOCKS_FRACTION"
# MNT-6b (2026-09-06): sliding-window / compressor groups recycle the pages they
# skip (remove_skipped_blocks) back into the SAME request instead of freeing them
# to the global LRU queue and popping fresh pages from its head. With few-token
# pages, one long prefill otherwise cycles the whole pool several times and
# evicts every other request's cached prefix (0% hit on the next turn of a long
# conversation). VLLM_SWA_RECYCLE_SKIPPED_BLOCKS=0 disables it.
_RECYCLE_ENV = "VLLM_SWA_RECYCLE_SKIPPED_BLOCKS"

# ---------------------------------------------------------------------------
# MNT-8 / MNT-9 runtime flags — readable WITHOUT a restart.
#
# Container env vars cannot be changed on a running engine, so an env-gated
# experiment costs one 250-600s cold boot per arm, with every session on the
# cluster interrupted.  These two flags are therefore read from a small JSON
# file on a bind-mounted directory instead, re-stat'ed at most once a second:
#
#   {"free_queue_prepend_uncached": 1, "pin_static_head": 0}
#
# An env var of the same name (upper-cased, VLLM_-prefixed) always WINS, so a
# boot can still pin an arm; the file only moves flags that are unset in env.
# Missing file / bad JSON / unreadable => every flag falls back to its default,
# which is OFF for both mechanisms.  A flag flip takes effect on the next
# request; it does NOT retroactively re-order blocks already freed.
# See CACHE_TEST.md.
_FLAGS_PATH = os.environ.get("VLLM_KV_FLAGS_FILE", "/etc/vllm-kv-flags/flags.json")
_FLAGS_TTL_S = 1.0
_flags_cache: dict = {}
_flags_checked_at: float = -1.0


def _flags() -> dict:
    global _flags_cache, _flags_checked_at
    now = time.monotonic()
    if now - _flags_checked_at < _FLAGS_TTL_S:
        return _flags_cache
    _flags_checked_at = now
    try:
        with open(_FLAGS_PATH) as fh:
            loaded = json.load(fh)
        _flags_cache = loaded if isinstance(loaded, dict) else {}
    except Exception:
        _flags_cache = {}
    return _flags_cache


def _flag(name: str, default):
    """`name` is the lower_snake key in the flags file; the env override is
    VLLM_<NAME>."""
    raw = os.environ.get("VLLM_" + name.upper())
    if raw is None:
        raw = _flags().get(name)
    if raw is None:
        return default
    if isinstance(default, bool):
        return str(raw).strip().lower() not in ("0", "false", "no", "")
    try:
        return type(default)(raw)
    except (TypeError, ValueError):
        return default


def _recycle_enabled() -> bool:
    """MNT-6b master switch. Was a module-level constant read from the container
    env, which cannot change on a running engine -- so A/B-ing it cost a cold
    boot per arm. Now the flags file decides, and the env var still overrides.
    """
    raw = os.environ.get(_RECYCLE_ENV)
    if raw is not None:
        return raw.strip() not in ("0", "false", "False", "")
    return bool(_flag("swa_recycle", True))


def _recycle_cached_pages() -> bool:
    """MNT-6b, finer grain -- and the arm most likely to be right.

    Recycling a page calls ``_maybe_evict_cached_block()`` on it, which destroys
    its (hash -> block) mapping.  Measured 2026-09-20 (CACHE_TEST.md 8): decode
    across several turns is what makes a conversation's prefix unreusable, and
    this eviction is the leading mechanism -- the coordinator takes the MINIMUM
    across KV groups, so losing the sliding-window checkpoints reads as 0% even
    while full attention still holds the whole head.

    With this set to 0, only pages that carry NO prefix-cache value
    (``block_hash is None``) are recycled; cached pages are freed normally and
    stay reusable in the LRU. That keeps what MNT-6b is for -- keeping one long
    prefill from churning the shared queue -- without discarding checkpoints.
    Same cached/uncached discrimination vllm#43447 makes for the free queue.

    **The default is False (MNT-6c), i.e. the fix is ON unless something turns it
    off.** It was True until 2026-09-21, with the fix carried only by
    ``/var/tmp/vllm-kv-flags/flags.json`` -- node-local state outside git, so a
    rebuilt node or a cleared ``/var/tmp`` silently restored the bug. The flag is
    now the escape hatch rather than the enabler: ``swa_recycle_cached 1``
    restores stock eviction, live, with no restart. CACHE_TEST.md 10, item 2.
    """
    return bool(_flag("swa_recycle_cached", False))


# MNT-8 (vllm#43447, ported 2026-09-20): free a request's blocks in two groups —
# uncached scratch pages to the FRONT of the free queue, cached prefix blocks to
# the back.  Stock frees both to the back, so every turn of a conversation
# buries worthless pages behind live prefix entries and the allocator evicts the
# prefixes first.  MNT-6b already covers the in-request path; this is the
# end-of-request half it does not reach.  Flag: free_queue_prepend_uncached.
_FLAG_PREPEND = "free_queue_prepend_uncached"

# MNT-9 (2026-09-20): pin the STATIC HEAD (tools + system prompt) so it survives
# for the life of the process, instead of the whole prompt prefix surviving
# transiently.  The pin primitive is MNT-6a's (_protect_prompt_blocks/touch);
# what differs is the boundary and the release policy:
#   - boundary B = first <|User|> token, minus slack, floored to the hit
#     alignment.  Verified on this build: the template renders tools, then the
#     system prompt, then the first user turn (CACHE_TEST.md 3a.1).
#   - release is LRU over WHOLE HEADS, ordered by last reuse, in a budget
#     RESERVED from MNT-6a's — sharing MNT-6a's FIFO queue would let one long
#     conversation's body evict every other agent's head, which is the failure
#     being fixed.
# Flag: pin_static_head.  Budget: head_pin_fraction (of the pool, per manager).
_FLAG_PIN_HEAD = "pin_static_head"
_HEAD_BOUNDARY_TOKEN_ID = int(os.environ.get("VLLM_HEAD_BOUNDARY_TOKEN_ID", "128803"))
_HEAD_SCAN_LIMIT = 65536  # the head is ~12.6K tokens; never scan a 1M prompt
_HEAD_SLACK_TOKENS = 64
_HEAD_MIN_TOKENS = 512  # below this there is nothing worth pinning


class SingleTypeKVCacheManager(ABC):
    _num_managers: int = 0  # MNT-6a: managers share one block pool
    """
    An abstract base class for a manager that handle the kv cache management
    logic of one specific type of attention layer.
    """

    def __init__(
        self,
        kv_cache_spec: KVCacheSpec,
        block_pool: BlockPool,
        enable_caching: bool,
        kv_cache_group_id: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
        max_admission_blocks_per_request: int | None = None,
        max_model_len: int | None = None,
    ) -> None:
        """
        Initializes the SingleTypeKVCacheManager.
        Args:
            kv_cache_spec: The kv_cache_spec for this manager.
            block_pool: The block pool.
            kv_cache_group_id: The id of the kv cache group of this manager.
            max_admission_blocks_per_request: Recycling-aware per-request
                block cap used by `get_num_blocks_to_allocate`. Only set for
                spec types that recycle blocks across chunks (SWA,
                chunked-local); `None` (the default) means no cap, which is
                correct for full-attention-style specs that hold every
                block until the request finishes.
        """
        self.block_size = kv_cache_spec.block_size
        self.dcp_world_size = dcp_world_size
        self.pcp_world_size = pcp_world_size
        if dcp_world_size * pcp_world_size > 1:
            self.block_size *= dcp_world_size * pcp_world_size
        self.kv_cache_spec = kv_cache_spec
        self.block_pool = block_pool
        self.enable_caching = enable_caching
        self._max_admission_blocks_per_request = max_admission_blocks_per_request
        self.max_model_len = max_model_len
        self.cache_alignment_tokens = self.block_size
        self.new_block_ids: list[int] = []

        # Mapping from request ID to blocks to track the blocks allocated
        # for each request, so that we can free the blocks when the request
        # is finished.
        self.req_to_blocks: defaultdict[str, list[KVCacheBlock]] = defaultdict(list)

        # {req_id: The number of cached blocks for this given request}
        # This is used to track the number of cached blocks for each request.
        # This is only used to track the RUNNING requests, we do not track the
        # data for preempted ones.
        self.num_cached_block: dict[str, int] = {}

        self.kv_cache_group_id = kv_cache_group_id
        self._null_block = block_pool.null_block
        self._protected_prompt_block_ids: set[int] = set()
        self._protected_prompt_block_queue: deque[int] = deque()
        SingleTypeKVCacheManager._num_managers += 1
        self._protected_cap_logged = False
        # MNT-6b: pages skipped by the sliding window, still owned by the
        # request (ref_cnt kept), reused for its next allocations.
        self._recycled_blocks: dict[str, list[KVCacheBlock]] = defaultdict(list)
        self._recycle_logged = False
        # MNT-9: head pins, keyed by the BlockHash of the head's first block,
        # in LRU order of last reuse.  Kept OUT of _protected_prompt_block_ids
        # so MNT-6a's FIFO trim cannot take them.
        self._head_pins: "OrderedDict[object, dict]" = OrderedDict()
        self._pinned_head_block_ids: set[int] = set()
        self._head_boundary: dict[str, int] = {}
        self._head_pin_logged = False
        self._head_pin_incomplete_logged = False

    @classmethod
    def _get_num_evictable_blocks(cls, blocks: Sequence[KVCacheBlock]):
        return sum(blk.ref_cnt == 0 and not blk.is_null for blk in blocks)

    def get_num_blocks_to_allocate(
        self,
        request_id: str,
        num_tokens: int,
        new_computed_blocks: Sequence[KVCacheBlock],
        total_computed_tokens: int,
        num_tokens_main_model: int,
        apply_admission_cap: bool = False,
    ) -> int:
        """
        Get the number of blocks needed to be allocated for the request.

        Args:
            request_id: The request ID.
            num_tokens: The total number of tokens that need a slot (including
                tokens that are already allocated).
            new_computed_blocks: The new computed blocks just hitting the
                prefix caching.
            total_computed_tokens: Include both local and external computed
                tokens.
            num_tokens_main_model: The number of tokens for the main model (aka target
                model in spec decode). w/o spec decode, it is num_tokens;
                with spec decode, it is num_tokens - num_lookahead_tokens.
            apply_admission_cap: If True, clamp by `num_required_blocks` by
                `_max_admission_blocks_per_request`for recycling-aware specs
                (SWA, chunked-local).

        Returns:
            The number of blocks to allocate.
        """

        num_required_blocks = cdiv(num_tokens, self.block_size)
        if apply_admission_cap and self._max_admission_blocks_per_request is not None:
            # Recycling-aware specs (SWA, chunked-local) cap the per-request
            # reservation here so admission matches the startup pool sizer
            # (`SlidingWindowSpec.max_admission_blocks_per_request` / its
            # chunked-local counterpart). `remove_skipped_blocks` runs from
            # `allocate_slots` before each chunk's `get_num_blocks_to_allocate`,
            # so per-request peak real-held blocks <= this cap, which keeps
            # `sum(reservations) <= pool` <=> `sum(peak_real_held) <= pool`.
            # Drift between the two would re-introduce the deadlock from
            # issue #39734 or, worse, mid-prefill OOM.
            num_required_blocks = min(
                num_required_blocks, self._max_admission_blocks_per_request
            )
        num_req_blocks = len(self.req_to_blocks.get(request_id, ()))

        if request_id in self.num_cached_block:
            # Fast-path: a running request won't have any new prefix-cache hits.
            assert len(new_computed_blocks) == 0
            # NOTE: With speculative decoding, request's blocks may be allocated
            # for draft tokens which are later rejected. In this case,
            # num_required_blocks may be smaller than num_req_blocks.
            return max(num_required_blocks - num_req_blocks, 0)

        num_skipped_tokens = self.get_num_skipped_tokens(total_computed_tokens)
        num_local_computed_blocks = len(new_computed_blocks) + num_req_blocks
        # Number of whole blocks that are skipped by the attention window.
        # If nothing is skipped, this is 0.
        num_skipped_blocks = num_skipped_tokens // self.block_size
        # We need blocks for the non-skipped suffix. If there are still
        # local-computed blocks inside the window, they contribute to the
        # required capacity; otherwise, skipped blocks dominate.
        num_new_blocks = max(
            num_required_blocks - max(num_skipped_blocks, num_local_computed_blocks),
            0,
        )

        # Among the `new_computed_blocks`, the first `num_skipped_blocks` worth
        # of blocks are skipped; `num_req_blocks` of those may already be in
        # `req_to_blocks`, so only skip the remainder from `new_computed_blocks`.
        num_skipped_new_computed_blocks = max(0, num_skipped_blocks - num_req_blocks)

        # If a computed block is an eviction candidate (in the free queue and
        # ref_cnt == 0), it will be removed from the free queue when touched by
        # the allocated request, so we must count it in the free-capacity check.
        num_evictable_blocks = self._get_num_evictable_blocks(
            new_computed_blocks[num_skipped_new_computed_blocks:]
        )
        return num_new_blocks + num_evictable_blocks

    def allocate_new_computed_blocks(
        self,
        request_id: str,
        new_computed_blocks: Sequence[KVCacheBlock],
        num_local_computed_tokens: int,
        num_external_computed_tokens: int,
    ) -> None:
        """
        Add the new computed blocks to the request. This involves three steps:
        1. Touch the computed blocks to make sure they won't be evicted.
        1.5. (Optional) For sliding window, skip blocks are padded with null blocks.
        2. Add the remaining computed blocks.
        3. (Optional) For KV connectors, allocate new blocks for external computed
            tokens (if any).

        Args:
            request_id: The request ID.
            new_computed_blocks: The new computed blocks just hitting the
                prefix cache.
            num_local_computed_tokens: The number of local computed tokens.
            num_external_computed_tokens: The number of external computed tokens.
        """

        if request_id in self.num_cached_block:
            # Fast-path: a running request won't have any new prefix-cache hits.
            # It should not have any new computed blocks.
            assert len(new_computed_blocks) == 0
            return

        # A new request.
        req_blocks = self.req_to_blocks[request_id]
        assert len(req_blocks) == 0
        num_total_computed_tokens = (
            num_local_computed_tokens + num_external_computed_tokens
        )
        num_skipped_tokens = self.get_num_skipped_tokens(num_total_computed_tokens)
        num_skipped_blocks = num_skipped_tokens // self.block_size
        if num_skipped_blocks > 0:
            # It is possible that all new computed blocks are skipped when
            # num_skipped_blocks > len(new_computed_blocks).
            new_computed_blocks = new_computed_blocks[num_skipped_blocks:]
            # Some external computed tokens may be skipped too.
            num_external_computed_tokens = min(
                num_total_computed_tokens - num_skipped_tokens,
                num_external_computed_tokens,
            )

        # Touch the computed blocks to make sure they won't be evicted.
        if self.enable_caching:
            self.block_pool.touch(new_computed_blocks)
        else:
            assert not any(new_computed_blocks), (
                "Computed blocks should be empty when prefix caching is disabled"
            )

        # Skip blocks are padded with null blocks.
        req_blocks.extend([self._null_block] * num_skipped_blocks)
        # Add the remaining computed blocks.
        req_blocks.extend(new_computed_blocks)
        # All cached hits (including skipped nulls) are already cached; mark
        # them so cache_blocks() will not try to re-cache blocks that already
        # have a block_hash set.
        self.num_cached_block[request_id] = len(req_blocks)

        if num_external_computed_tokens > 0:
            # Allocate new blocks for external computed tokens.
            allocated_blocks = self.block_pool.get_new_blocks(
                cdiv(num_total_computed_tokens, self.block_size) - len(req_blocks)
            )
            req_blocks.extend(allocated_blocks)
            if type(self.kv_cache_spec) in (FullAttentionSpec, TQFullAttentionSpec):
                self.new_block_ids.extend(b.block_id for b in allocated_blocks)

    def allocate_new_blocks(
        self, request_id: str, num_tokens: int, num_tokens_main_model: int
    ) -> list[KVCacheBlock]:
        """
        Allocate new blocks for the request to give it at least `num_tokens`
        token slots.

        Args:
            request_id: The request ID.
            num_tokens: The total number of tokens that need a slot (including
                tokens that are already allocated).
            num_tokens_main_model: The number of tokens for the main model (aka target
                model in spec decode). w/o spec decode, it is num_tokens;
                with spec decode, it is num_tokens - num_lookahead_tokens.
        Returns:
            The new allocated blocks.
        """
        req_blocks = self.req_to_blocks[request_id]
        num_required_blocks = cdiv(num_tokens, self.block_size)
        num_new_blocks = num_required_blocks - len(req_blocks)
        if num_new_blocks <= 0:
            return []
        else:
            reused: list[KVCacheBlock] = []
            recycled = self._recycled_blocks.get(request_id)
            if recycled:
                take = min(num_new_blocks, len(recycled))
                reused = recycled[-take:]
                del recycled[-take:]
                num_new_blocks -= take
            new_blocks = (
                self.block_pool.get_new_blocks(num_new_blocks)
                if num_new_blocks > 0
                else []
            )
            new_blocks = reused + new_blocks
            req_blocks.extend(new_blocks)
            if type(self.kv_cache_spec) in (FullAttentionSpec, TQFullAttentionSpec):
                self.new_block_ids.extend(b.block_id for b in new_blocks)
            return new_blocks

    def take_new_block_ids(self) -> list[int]:
        """Drain and return block IDs allocated since the last call."""
        ids = self.new_block_ids
        self.new_block_ids = []
        return ids

    def _free_split(self, blocks: Sequence[KVCacheBlock]) -> None:
        """MNT-8: free `blocks`, uncached ones to the FRONT of the free queue.

        Order within each group is preserved, so the caller's eviction priority
        still holds.  With the flag off this is exactly `free_blocks(blocks)`.
        """
        blocks = list(blocks)
        if not blocks:
            return
        if not _flag(_FLAG_PREPEND, False):
            self.block_pool.free_blocks(blocks)
            return
        cached = [b for b in blocks if b.block_hash is not None]
        uncached = [b for b in blocks if b.block_hash is None]
        if cached:
            self.block_pool.free_blocks(cached)
        if uncached:
            # No prefix-cache value: reuse these before evicting anything.
            self.block_pool.free_blocks(uncached, prepend=True)

    # ---- MNT-9: static-head pinning -------------------------------------
    def _static_head_boundary(self, request: Request) -> int:
        """B, in tokens: where the static head (tools + system) ends.

        The first <|User|> token is the end of everything a second session with
        a different body can still share.  Memoised per request — cache_blocks
        runs every scheduler step.
        """
        rid = request.request_id
        cached = self._head_boundary.get(rid)
        if cached is not None:
            return cached
        boundary = 0
        token_ids = request.prompt_token_ids
        if token_ids:
            limit = min(len(token_ids), _HEAD_SCAN_LIMIT)
            for i in range(limit):
                if token_ids[i] == _HEAD_BOUNDARY_TOKEN_ID:
                    boundary = i
                    break
        if boundary:
            boundary = max(0, boundary - _HEAD_SLACK_TOKENS)
            align = max(1, self.cache_alignment_tokens)
            boundary = boundary // align * align
            if boundary < _HEAD_MIN_TOKENS:
                boundary = 0
        self._head_boundary[rid] = boundary
        return boundary

    def _head_pin_candidates(
        self, blocks: list[KVCacheBlock], boundary_blocks: int
    ) -> list[KVCacheBlock]:
        """Which blocks of [0, B) THIS group must hold for a hit at B.

        Full attention needs the whole prefix; a sliding-window group only ever
        matches the contiguous run ending at the boundary, so pinning the rest
        would spend the budget on blocks no lookup can use.
        """
        window = getattr(self, "sliding_window", None)
        if window is None:
            return blocks[:boundary_blocks]
        need = cdiv(window - 1, self.block_size) + 1
        return blocks[max(0, boundary_blocks - need) : boundary_blocks]

    def _max_head_pin_blocks(self) -> int:
        fraction = _flag("head_pin_fraction", 0.05)
        if fraction <= 0:
            return 0
        num_managers = max(1, SingleTypeKVCacheManager._num_managers)
        return int(self.block_pool.num_gpu_blocks * fraction / num_managers)

    def _maybe_pin_static_head(self, request: Request, num_full_blocks: int) -> None:
        if not self.enable_caching or not _flag(_FLAG_PIN_HEAD, False):
            return
        boundary = self._static_head_boundary(request)
        if not boundary:
            return
        boundary_blocks = boundary // self.block_size
        if boundary_blocks <= 0 or num_full_blocks < boundary_blocks:
            return  # prefill has not crossed B yet
        blocks = self.req_to_blocks.get(request.request_id)
        if not blocks:
            return
        intended = self._head_pin_candidates(blocks, boundary_blocks)
        candidates = [
            blk for blk in intended if not blk.is_null and blk.block_hash is not None
        ]
        if not candidates:
            return
        if len(candidates) < len(intended):
            # A hit at B needs the WHOLE run in THIS group, and the coordinator
            # takes the minimum across groups -- so a partial pin cannot serve a
            # hit anywhere, it just spends budget and reports success. This is
            # exactly how the 2026-09-20 arm C produced a confident null: group 3
            # pinned 3 of the 33 blocks it needed (CACHE_TEST.md 7.3).
            if not self._head_pin_incomplete_logged:
                self._head_pin_incomplete_logged = True
                logger.warning(
                    "MNT-9: KV group %d CANNOT pin the head at B=%d tokens — only "
                    "%d of the %d blocks in the required run are cached. Not "
                    "pinning (set head_pin_partial=1 to pin anyway, but a partial "
                    "run cannot serve a hit). Request %s",
                    self.kv_cache_group_id, boundary, len(candidates),
                    len(intended), request.request_id,
                )
            if not _flag("head_pin_partial", False):
                return

        key = candidates[0].block_hash
        entry = self._head_pins.get(key)
        if entry is None:
            entry = {"ids": set(), "hits": 0, "tokens": boundary}
            self._head_pins[key] = entry
        else:
            # Re-pinning a head we already hold means a LATER request matched
            # it. That is the only reuse signal available here, and it is what
            # orders the LRU: heads nothing comes back for age out first.
            entry["hits"] += 1
            self._head_pins.move_to_end(key)

        fresh = [
            blk for blk in candidates if blk.block_id not in self._pinned_head_block_ids
        ]
        if fresh:
            self.block_pool.touch(fresh)
            for blk in fresh:
                self._pinned_head_block_ids.add(blk.block_id)
                entry["ids"].add(blk.block_id)
            if not self._head_pin_logged:
                self._head_pin_logged = True
                logger.info(
                    "MNT-9: KV group %d pinned a static head at B=%d tokens "
                    "(%d blocks, cap %d blocks, request %s)",
                    self.kv_cache_group_id, boundary, len(fresh),
                    self._max_head_pin_blocks(), request.request_id,
                )
        self._trim_head_pins()

    def _trim_head_pins(self) -> None:
        cap = self._max_head_pin_blocks()
        while self._head_pins and len(self._pinned_head_block_ids) > cap:
            _key, entry = self._head_pins.popitem(last=False)  # least recently reused
            self._release_head_pin(entry)

    def _release_head_pin(self, entry: dict) -> None:
        blocks: list[KVCacheBlock] = []
        for block_id in entry["ids"]:
            if block_id not in self._pinned_head_block_ids:
                continue
            self._pinned_head_block_ids.discard(block_id)
            block = self.block_pool.blocks[block_id]
            if block.ref_cnt > 0:
                blocks.append(block)
        entry["ids"].clear()
        if blocks:
            # Still cached and still worth something to someone: back of the
            # queue, never the front.
            self.block_pool.free_blocks(blocks)

    def _head_pin_ref(self, block: KVCacheBlock) -> int:
        """1 if this block carries an MNT-9 pin reference, else 0."""
        return 1 if block.block_id in self._pinned_head_block_ids else 0

    def _max_protected_prompt_blocks(self) -> int | None:
        legacy: int | None = None
        if self.max_model_len is not None:
            legacy = 2 * cdiv(max(1, self.max_model_len), self.block_size)
        try:
            fraction = float(os.environ.get(_PROTECTED_FRACTION_ENV, "0.30"))
        except ValueError:
            fraction = 0.30
        if fraction < 0:
            return legacy
        num_managers = max(1, SingleTypeKVCacheManager._num_managers)
        pool_cap = int(self.block_pool.num_gpu_blocks * fraction / num_managers)
        cap = pool_cap if legacy is None else min(legacy, pool_cap)
        if not self._protected_cap_logged:
            self._protected_cap_logged = True
            logger.info(
                "MNT-6a: protected prompt block cap for KV group %d = %d blocks "
                "(pool %d blocks, %d managers, fraction %.2f, legacy cap %s)",
                self.kv_cache_group_id, cap, self.block_pool.num_gpu_blocks,
                num_managers, fraction, legacy,
            )
        return cap

    def _protect_prompt_blocks(self, blocks: Sequence[KVCacheBlock]) -> None:
        if not self.enable_caching:
            return

        protected: list[KVCacheBlock] = []
        for block in blocks:
            if (
                block.is_null
                or block.block_hash is None
                or block.block_id in self._protected_prompt_block_ids
            ):
                continue
            protected.append(block)
            self._protected_prompt_block_ids.add(block.block_id)
            self._protected_prompt_block_queue.append(block.block_id)

        if not protected:
            return

        # Keep an extra reference for prompt blocks that must survive after
        # their request releases its normal runtime reference. Later request
        # reuse increments/decrements the runtime reference as usual.
        self.block_pool.touch(protected)
        self._trim_protected_prompt_blocks()

    def _trim_protected_prompt_blocks(self) -> None:
        max_blocks = self._max_protected_prompt_blocks()
        if max_blocks is None:
            return

        while len(self._protected_prompt_block_ids) > max_blocks:
            if not self._release_one_protected_prompt_block():
                return

    def _release_one_protected_prompt_block(
        self, block_ids_to_skip: set[int] | None = None
    ) -> bool:
        attempts = len(self._protected_prompt_block_queue)
        while attempts:
            block_id = self._protected_prompt_block_queue.popleft()
            attempts -= 1
            if block_id not in self._protected_prompt_block_ids:
                continue
            if block_ids_to_skip is not None and block_id in block_ids_to_skip:
                self._protected_prompt_block_queue.append(block_id)
                continue

            self._protected_prompt_block_ids.remove(block_id)
            block = self.block_pool.blocks[block_id]
            if block.ref_cnt > 0:
                self.block_pool.free_blocks([block])
            return True
        return False

    def release_protected_prompt_blocks(
        self,
        target_free_blocks: int | None = None,
        block_ids_to_skip: set[int] | None = None,
    ) -> None:
        while self._protected_prompt_block_ids:
            if (
                target_free_blocks is not None
                and self.block_pool.get_num_free_blocks() >= target_free_blocks
            ):
                return
            if not self._release_one_protected_prompt_block(block_ids_to_skip):
                return

    def cache_blocks(
        self,
        request: Request,
        num_tokens: int,
        alignment_tokens: int | None = None,
    ) -> None:
        """
        Cache the blocks for the request.

        Args:
            request: The request.
            num_tokens: The total number of tokens that need to be cached
                (including tokens that are already cached).
            alignment_tokens: The cache-hit alignment (in tokens) used by the
                coordinator's ``find_longest_cache_hit``. When greater than
                this group's ``block_size``, managers whose hit logic only
                returns a subset of blocks per alignment-aligned segment
                (SWA) skip the rest since they can never participate in a
                future cache hit.
        """
        num_cached_blocks = self.num_cached_block.get(request.request_id, 0)
        num_full_blocks = num_tokens // self.block_size

        if num_cached_blocks >= num_full_blocks:
            return

        # Fast path: when the coordinator imposes no alignment constraint
        if alignment_tokens is None or alignment_tokens <= self.block_size:
            block_mask = None
        else:
            block_mask = self._cache_block_mask(
                num_cached_blocks, num_full_blocks, alignment_tokens
            )
        self.block_pool.cache_full_blocks(
            request=request,
            blocks=self.req_to_blocks[request.request_id],
            num_cached_blocks=num_cached_blocks,
            num_full_blocks=num_full_blocks,
            block_size=self.block_size,
            kv_cache_group_id=self.kv_cache_group_id,
            block_mask=block_mask,
        )

        self.num_cached_block[request.request_id] = num_full_blocks
        self._maybe_pin_static_head(request, num_full_blocks)

    def _cache_block_mask(
        self,
        num_cached_blocks: int,
        num_full_blocks: int,
        alignment_tokens: int,
    ) -> list[bool] | None:
        """Per-block mask for ``cache_full_blocks``. ``None`` means cache
        every (non-null) block — the default for full attention.

        Subclasses with sparse hit semantics (SWA) override this to skip
        blocks that can never serve a hit at any alignment-aligned prefix
        length.
        """
        return None

    def free(self, request_id: str) -> None:
        """
        Free the blocks for the request.

        Args:
            request_id: The request ID.
        """
        # Default to [] in case a request is freed (aborted) before alloc.
        req_blocks = self.req_to_blocks.pop(request_id, [])

        # Free blocks in reverse order so that the tail blocks are
        # freed first.
        ordered_blocks = reversed(req_blocks)

        # MNT-8: scratch pages to the front of the queue, cached blocks to the
        # back.  Stock appends both, which is what buries a turn's worthless
        # pages behind the prefixes the next allocation then evicts.
        self._free_split(ordered_blocks)
        self.num_cached_block.pop(request_id, None)
        self._head_boundary.pop(request_id, None)
        leftover = self._recycled_blocks.pop(request_id, None)
        if leftover:
            # Uncached by construction — MNT-6b evicts before recycling.
            self._free_split(leftover)

    @abstractmethod
    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        """
        Get the number of common prefix blocks for all requests with allocated
        KV cache.

        Args:
            running_request_id: The request ID.

        Returns:
            The number of common prefix blocks for all requests with allocated
            KV cache.
        """

        raise NotImplementedError

    @classmethod
    @abstractmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        """
        Get the longest cache hit prefix of the blocks that is not longer than
        `max_length`. The prefix should be a common prefix hit for all the
        kv cache groups in `kv_cache_group_ids`. If no cache hit is found,
        return an empty list.
        If eagle is enabled, drop the last matched block to force recompute the
        last block to get the required hidden states for eagle drafting head.
        Need to be customized for each attention type.

        Args:
            block_hashes: The block hashes of the request.
            max_length: The maximum length of the cache hit prefix.
            kv_cache_group_ids: The ids of the kv cache groups.
            block_pool: The block pool.
            kv_cache_spec: The kv cache spec.
            use_eagle: Whether to use eagle.
            alignment_tokens: The returned cache hit length (in tokens) should
                be a multiple of this value (in tokens). By default, it should
                be set to the block_size.
            dcp_world_size: The world size of decode context parallelism.
            pcp_world_size: The world size of prefill context parallelism.

        Returns:
            A list of cached blocks with skipped blocks replaced by null block
            for each kv cache group in `kv_cache_group_ids`.
            Return a list of length `len(kv_cache_group_ids)`, where the i-th
            element is a list of cached blocks for the i-th kv cache group
            in `kv_cache_group_ids`.
            For example, sliding window manager should return a list like
            ([NULL, NULL, KVCacheBlock(7), KVCacheBlock(8)]) for block size 4
            and sliding window 8 and len(kv_cache_group_ids) = 1.
        """

        raise NotImplementedError

    def remove_skipped_blocks(
        self, request_id: str, total_computed_tokens: int
    ) -> None:
        """
        Remove and free the blocks that are no longer needed for attention computation.
        The removed blocks should be replaced by null_block.

        This function depends on `get_num_skipped_tokens`, which need to be implemented
        differently for each attention type.

        Args:
            request_id: The request ID.
            total_computed_tokens: The total number of computed tokens, including
                local computed tokens and external computed tokens.
        """
        # Remove the blocks that will be skipped during attention computation.
        num_skipped_tokens = self.get_num_skipped_tokens(total_computed_tokens)
        if num_skipped_tokens <= 0:
            # This indicates that ALL tokens are inside attention window.
            # Thus we do not need to free any blocks outside attention window.
            # A typical case is full attention that we never free any token
            # before the request is finished.
            return
        blocks = self.req_to_blocks[request_id]
        num_skipped_blocks = num_skipped_tokens // self.block_size
        # `num_skipped_tokens` may include tokens that haven't been allocated yet
        # (e.g., when the attention window moves into the external computed tokens
        # range), so we must cap to the number of blocks that currently exist for
        # this request.
        num_skipped_blocks = min(num_skipped_blocks, len(blocks))
        removed_blocks: list[KVCacheBlock] = []
        # Because the block starts from index 0, the num_skipped_block-th block
        # corresponds to index num_skipped_blocks - 1.
        for i in range(num_skipped_blocks - 1, -1, -1):
            if blocks[i] == self._null_block:
                # If the block is already a null block, the blocks before it
                # should also have been set to null blocks by the previous calls
                # to this function.
                break
            removed_blocks.append(blocks[i])
            blocks[i] = self._null_block
        if not _recycle_enabled():
            self._free_split(removed_blocks)
            return
        keep_cached = not _recycle_cached_pages()
        to_free: list[KVCacheBlock] = []
        recycled = self._recycled_blocks[request_id]
        for blk in removed_blocks:
            # Only pages held solely by this request can be reused in place;
            # shared or protected pages keep their other references.
            if blk.ref_cnt == 1 and not blk.is_null:
                if keep_cached and blk.block_hash is not None:
                    # Carries a prefix-cache entry: freeing it leaves the entry
                    # intact in the LRU, recycling it would destroy the mapping.
                    to_free.append(blk)
                    continue
                self.block_pool._maybe_evict_cached_block(blk)
                recycled.append(blk)
            else:
                to_free.append(blk)
        if to_free:
            self._free_split(to_free)
        if not self._recycle_logged and recycled:
            self._recycle_logged = True
            logger.info(
                "MNT-6b: KV group %d recycling skipped pages in-request "
                "(first request %s, %d pages)",
                self.kv_cache_group_id, request_id, len(recycled),
            )

    def get_num_skipped_tokens(self, num_computed_tokens: int) -> int:
        """
        Get the number of tokens that will be skipped for attention computation.

        Args:
            num_computed_tokens: The number of tokens that have been computed.

        Returns:
            The number of tokens that will be skipped for attention computation.
        """
        # The default behavior is to not skip any tokens.
        return 0

    def new_step_starts(self) -> None:
        # do nothing by default
        return None


class FullAttentionManager(SingleTypeKVCacheManager):
    @classmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        assert isinstance(
            kv_cache_spec, FullAttentionSpec | ChunkedLocalAttentionSpec
        ), (
            "FullAttentionManager can only be used for full attention "
            "and chunked local attention groups"
        )
        computed_blocks: tuple[list[KVCacheBlock], ...] = tuple(
            [] for _ in range(len(kv_cache_group_ids))
        )
        block_size = kv_cache_spec.block_size
        if dcp_world_size * pcp_world_size > 1:
            block_size *= dcp_world_size * pcp_world_size
        max_num_blocks = max_length // block_size
        for block_hash in itertools.islice(block_hashes, max_num_blocks):
            # block_hashes is a chain of block hashes. If a block hash is not
            # in the cached_block_hash_to_id, the following block hashes are
            # not computed yet for sure.
            if cached_block := block_pool.get_cached_block(
                block_hash, kv_cache_group_ids
            ):
                for computed, cached in zip(computed_blocks, cached_block):
                    computed.append(cached)
            else:
                break
        if use_eagle and computed_blocks[0]:
            # Need to drop the last matched block if eagle is enabled.
            for computed in computed_blocks:
                computed.pop()
        while (
            block_size != alignment_tokens  # Faster for common case.
            and len(computed_blocks[0]) * block_size % alignment_tokens != 0
        ):
            for computed in computed_blocks:
                computed.pop()
        return computed_blocks

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        blocks = self.req_to_blocks[running_request_id]
        num_common_blocks = 0
        for block in blocks:
            # MNT-9 holds its own reference on pinned head blocks; discount it
            # or every pinned block reads as "one more request than there is".
            if block.ref_cnt - self._head_pin_ref(block) == len(self.req_to_blocks):
                num_common_blocks += 1
            else:
                break
        return num_common_blocks


class MLAAttentionManager(FullAttentionManager):
    """KV cache manager for compressed / fp8 MLA cache layouts.

    Used by any MLA spec whose hit semantics need prompt-block
    protection across decode and unrelated cache churn. ``_should_
    protect_prompt_blocks`` enumerates the triggering conditions.
    """

    def _should_protect_prompt_blocks(self) -> bool:
        # Three independent triggers:
        # 1. ``model_version == "deepseek_v4"``: DSv4 explicitly opts in.
        # 2. ``cache_dtype_str == "fp8_ds_mla"``: fp8 DeepSeek-style
        #    MLA cache; protection is needed for the same hybrid-align
        #    reuse pattern.
        # 3. ``compress_ratio > 1``: any compressed MLA cache (today
        #    only DSv4 sets ``compress_ratio > 1``; V3.2 keeps it at 1).
        return (
            self.kv_cache_spec.model_version == "deepseek_v4"
            or self.kv_cache_spec.cache_dtype_str == "fp8_ds_mla"
            or self.kv_cache_spec.compress_ratio > 1
        )

    def cache_blocks(
        self,
        request: Request,
        num_tokens: int,
        alignment_tokens: int | None = None,
    ) -> None:
        super().cache_blocks(request, num_tokens, alignment_tokens=alignment_tokens)
        if not self._should_protect_prompt_blocks() or request.num_prompt_tokens <= 1:
            return

        max_cache_hit_length = request.num_prompt_tokens - 1
        aligned_cache_hit_length = (
            max_cache_hit_length
            // self.cache_alignment_tokens
            * self.cache_alignment_tokens
        )
        if aligned_cache_hit_length <= 0 or num_tokens < aligned_cache_hit_length:
            return
        num_hit_blocks = aligned_cache_hit_length // self.block_size
        if num_hit_blocks == 0:
            return

        self._protect_prompt_blocks(
            self.req_to_blocks[request.request_id][:num_hit_blocks]
        )

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        blocks = self.req_to_blocks[running_request_id]
        num_common_blocks = 0
        expected_ref_cnt = len(self.req_to_blocks)
        for block in blocks:
            ref_cnt = block.ref_cnt
            if block.block_id in self._protected_prompt_block_ids:
                ref_cnt -= 1
            ref_cnt -= self._head_pin_ref(block)  # MNT-9's own reference
            if ref_cnt == expected_ref_cnt:
                num_common_blocks += 1
            else:
                break
        return num_common_blocks


class SlidingWindowManager(SingleTypeKVCacheManager):
    def __init__(self, kv_cache_spec: SlidingWindowSpec, **kwargs) -> None:
        super().__init__(kv_cache_spec, **kwargs)
        self.sliding_window = kv_cache_spec.sliding_window

    @classmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        assert isinstance(kv_cache_spec, SlidingWindowSpec), (
            "SlidingWindowManager can only be used for sliding window groups"
        )
        assert dcp_world_size == 1, "DCP not support sliding window attn now."
        assert pcp_world_size == 1, "PCP not support sliding window attn now."

        # The number of contiguous blocks needed for prefix cache hit.
        # -1 since the input token itself is also included in the window
        sliding_window_contiguous_blocks = cdiv(
            kv_cache_spec.sliding_window - 1, kv_cache_spec.block_size
        )
        if use_eagle:
            # Need to drop the last matched block if eagle is enabled. For
            # sliding window layer, we achieve this by increasing the number of
            # contiguous blocks needed for prefix cache hit by one and dropping
            # the last matched block.
            sliding_window_contiguous_blocks += 1

        # TODO: reduce i by sliding_window_contiguous_blocks when cache miss, to
        # optimize the time complexity from O(max_num_blocks) to
        # O(max_num_blocks / sliding_window_contiguous_blocks +
        # sliding_window_contiguous_blocks),
        # which is good for low cache hit rate scenarios.
        max_num_blocks = max_length // kv_cache_spec.block_size
        computed_blocks = tuple(
            [block_pool.null_block] * max_num_blocks
            for _ in range(len(kv_cache_group_ids))
        )
        block_size = kv_cache_spec.block_size
        num_contiguous_blocks = 0
        match_found = False
        # Search from right to left and early stop when a match is found.
        for i in range(max_num_blocks - 1, -1, -1):
            if cached_block := block_pool.get_cached_block(
                block_hashes[i], kv_cache_group_ids
            ):
                # Skip prefix matching check if the block is not aligned with
                # `alignment_tokens`.
                if num_contiguous_blocks == 0 and block_size != alignment_tokens:
                    post_pop_blocks = i if use_eagle else i + 1
                    if (post_pop_blocks * block_size) % alignment_tokens != 0:
                        continue
                # Add the cached block to the computed blocks.
                for computed, cached in zip(computed_blocks, cached_block):
                    computed[i] = cached
                num_contiguous_blocks += 1
                if num_contiguous_blocks >= sliding_window_contiguous_blocks:
                    # Trim the trailing blocks.
                    # E.g., [NULL, NULL, 8, 3, NULL, 9] -> [NULL, NULL, 8, 3]
                    # when sliding_window_contiguous_blocks=2.
                    for computed in computed_blocks:
                        del computed[i + num_contiguous_blocks :]
                    match_found = True
                    break
            else:
                num_contiguous_blocks = 0
        if not match_found:
            # The first `num_contiguous_blocks` is a cache hit even if
            # `num_contiguous_blocks < sliding_window_contiguous_blocks`.
            for computed in computed_blocks:
                del computed[num_contiguous_blocks:]
            while (
                block_size != alignment_tokens  # Faster for common case.
                and len(computed_blocks[0]) * block_size % alignment_tokens != 0
            ):
                for computed in computed_blocks:
                    computed.pop()
        if use_eagle and computed_blocks[0]:
            for computed in computed_blocks:
                computed.pop()
            # Re-align after eagle pop: the pop may break the alignment
            # when block_size != alignment_tokens (hybrid models with
            # different page sizes, e.g. Gemma4).
            while (
                block_size != alignment_tokens
                and len(computed_blocks[0]) * block_size % alignment_tokens != 0
            ):
                for computed in computed_blocks:
                    computed.pop()
        return computed_blocks

    def _cache_block_mask(
        self, num_cached_blocks: int, num_full_blocks: int, alignment_tokens: int
    ) -> list[bool] | None:
        assert alignment_tokens > self.block_size
        # Eagle/MTP shifts alignment (post_pop_blocks = i, not i+1) and
        # requires one extra contiguous block.  The resulting hit pattern
        # can touch any position in the segment, so the mask must be
        # disabled — otherwise prefix-cache hit rate drops to 0 %.
        if getattr(self, "eagle_extra_cache_blocks", 0):
            return None
        per_segment = alignment_tokens // self.block_size
        tail = cdiv(self.sliding_window - 1, self.block_size)
        if tail >= per_segment:
            return None
        skip = per_segment - tail
        return [
            i % per_segment >= skip for i in range(num_cached_blocks, num_full_blocks)
        ]

    def get_num_skipped_tokens(self, num_computed_tokens: int) -> int:
        """
        Get the number of tokens that will be skipped for attention computation.

        For sliding window, this corresponds to the tokens that are prior to
        the current sliding window.

        Example:
        sliding_window=4, num_computed_tokens=7

        Tokens:   [ 0  1  2  3  4  5  6  7 ]
                  | ---- computed -----|
                                         ^ next token to be computed
                               |-----------| sliding window for next token
                  |--skipped---|

        The current window contains tokens 4~7. Tokens 0~3 will be skipped for
        attention computation since they are outside the sliding window.
        Thus, get_num_skipped_tokens(7) == 4.

        Args:
            num_computed_tokens: The number of tokens that have been computed.

        Returns:
            The number of tokens that will be skipped for attention computation.
        """
        return max(0, num_computed_tokens - self.sliding_window + 1)

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        """
        NOTE(Chen): The prefix blocks are null blocks for sliding window layers.
        So it's not correct to count ref_cnt like FullAttentionManager. Return
        0 here for correctness. Need to support cascade attention + sliding
        window in the future.
        """
        return 0


class SlidingWindowMLAManager(SlidingWindowManager):
    """KV cache manager for DeepSeek V4's sliding-window MLA cache.

    During decode, the live sliding window can move past the prompt boundary.
    The blocks around the hybrid-aligned prompt boundary are still the suffix
    needed for a future prefix-cache hit of the same prompt.
    """

    def cache_blocks(
        self,
        request: Request,
        num_tokens: int,
        alignment_tokens: int | None = None,
    ) -> None:
        super().cache_blocks(request, num_tokens, alignment_tokens=alignment_tokens)
        if not self.enable_caching or request.num_prompt_tokens <= 1:
            return

        max_cache_hit_length = request.num_prompt_tokens - 1
        aligned_cache_hit_length = (
            max_cache_hit_length
            // self.cache_alignment_tokens
            * self.cache_alignment_tokens
        )
        if aligned_cache_hit_length <= 0 or num_tokens < aligned_cache_hit_length:
            return

        aligned_num_hit_blocks = aligned_cache_hit_length // self.block_size
        last_full_prompt_block = max_cache_hit_length // self.block_size
        contiguous_blocks = cdiv(self.sliding_window - 1, self.block_size)
        first_protected_block = max(0, aligned_num_hit_blocks - contiguous_blocks)
        last_protected_block = max(aligned_num_hit_blocks, last_full_prompt_block)
        blocks = self.req_to_blocks[request.request_id]
        protected_blocks = blocks[
            first_protected_block : min(last_protected_block, len(blocks))
        ]
        self._protect_prompt_blocks(protected_blocks)


class ChunkedLocalAttentionManager(SingleTypeKVCacheManager):
    def __init__(self, kv_cache_spec: ChunkedLocalAttentionSpec, **kwargs) -> None:
        super().__init__(kv_cache_spec, **kwargs)
        self.attention_chunk_size = kv_cache_spec.attention_chunk_size

    @classmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        """
        For chunked local attention, we need to find the longest cache hit
        prefix of the blocks that is not longer than `max_length`. The prefix
        should be a common prefix hit for all the kv cache groups in
        `kv_cache_group_ids`. If no cache hit is found, return an empty list.
        note we mark as computed if the whole block is outside of the local
        window, and set the block as null. Examples:

        1. Attention chunk size of 8, block size of 4, max length of 15
        for next token at 15th (zero-indexed), 8th - 14th tokens are in
        the window(needs lookup), 0th - 7th are not in the window,
        so they are already marked as computed. We check the complete
        block3 (8th - 11th tokens), Assume block 3 is hit, we will return
        [null, null, block 3], otherwise, we return [null, null]

        2. Attention chunk size of 8, block size of 4, max length of 16
        for next token at 16th (zero-indexed), 0th - 15th tokens are not
        in the window, so they are already marked as computed.
        we return 4 blocks[null, null, null, null]

        Args:
            block_hashes: The block hashes of the request.
            max_length: The maximum length of the cache hit prefix.
            kv_cache_group_ids: The ids of the kv cache groups.
            block_pool: The block pool.
            kv_cache_spec: The kv cache spec.
            use_eagle: Whether to use eagle.
            dcp_world_size: The world size of decode context parallelism.
            pcp_world_size: The world size of prefill context parallelism.
            alignment_tokens: The returned cache hit length (in tokens) should
                be a multiple of this value (in tokens).

        Returns:
            A list of cached blocks
        """
        assert isinstance(kv_cache_spec, ChunkedLocalAttentionSpec), (
            "ChunkedLocalAttentionManager can only be used for "
            "chunked local attention groups"
        )
        assert use_eagle is False, (
            "Hybrid KV cache is not supported for " + "eagle + chunked local attention."
        )
        assert dcp_world_size == 1, "DCP not support chunked local attn now."
        assert pcp_world_size == 1, "PCP not support chunked local attn now."
        assert kv_cache_spec.block_size == alignment_tokens, (
            "KV cache groups with different block sizes are not compatible with "
            "chunked local attention now"
        )
        max_num_blocks = max_length // kv_cache_spec.block_size
        if max_length > 0:
            local_attention_start_idx = (
                max_length
                // kv_cache_spec.attention_chunk_size
                * kv_cache_spec.attention_chunk_size
            )
        else:
            local_attention_start_idx = 0
        # we marked blocks out of window as computed
        # with null blocks, and blocks inside window based on cache lookup
        # result [null] [null] ... [null] [hit block 1 (1st block contain
        # last window)] [hit block 2] ... [hit block x]
        local_attention_start_block_idx = (
            local_attention_start_idx // kv_cache_spec.block_size
        )
        computed_blocks: tuple[list[KVCacheBlock], ...] = tuple(
            [block_pool.null_block] * local_attention_start_block_idx
            for _ in range(len(kv_cache_group_ids))
        )
        for i in range(local_attention_start_block_idx, max_num_blocks):
            block_hash = block_hashes[i]
            if cached_block := block_pool.get_cached_block(
                block_hash, kv_cache_group_ids
            ):
                for computed, cached in zip(computed_blocks, cached_block):
                    computed.append(cached)
            else:
                break
        return computed_blocks

    def get_num_skipped_tokens(self, num_computed_tokens: int) -> int:
        """
        Get the number of tokens that will be skipped for attention computation.

        For chunked local attention, this corresponds to the tokens that are on
        the left side of the current chunk.

        Example 1:
        chunk size = 8, num_computed_tokens = 13
        Tokens:  [ 0 1 2 3 4 5 6 7 | 8 9 10 11 12 13 14 15 ] ...
                 | ----- computed ---------------|
                                                  ^^ next token to be computed
                                   |----------------| <-- attention window for
                                                          next token
                 |--- skipped -----|
        Output: get_num_skipped_tokens(13) == 8

        Example 2:
        chunk size = 8, num_computed_tokens = 8
        Tokens:  [ 0 1 2 3 4 5 6 7 | 8 9 10 11 12 13 14 15 ] ...
                 | --- computed ---|
                                     ^ next token to be computed
                                   |--| <-- attention window for next token
                 | --- skipped ----|
        Output: get_num_skipped_tokens(8) == 8

        Example 3:
        chunk size = 8, num_computed_tokens = 7
        Tokens:  [ 0 1 2 3 4 5 6 7 | 8 9 10 11 12 13 14 15 ] ...
                 |---computed---|
                                 ^ next token to be computed
                 |-----------------| <-- attention window for next token
                 no token should be skipped.
        Output: get_num_skipped_tokens(7) == 0

        Args:
            num_computed_tokens: The number of tokens that have been computed.

        Returns:
            The number of tokens that will be skipped for attention computation.
        """
        num_skipped_tokens = (
            num_computed_tokens // self.attention_chunk_size
        ) * self.attention_chunk_size
        return num_skipped_tokens

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        """
        cascade attention is not supported by chunked local attention.
        """
        return 0


class MambaManager(SingleTypeKVCacheManager):
    def __init__(
        self, kv_cache_spec: MambaSpec, block_pool: BlockPool, **kwargs
    ) -> None:
        super().__init__(kv_cache_spec, block_pool, **kwargs)
        self.cached_blocks_this_step: set[BlockHashWithGroupId] = set()
        self.mamba_cache_mode = kv_cache_spec.mamba_cache_mode
        self.num_speculative_blocks: int = kv_cache_spec.num_speculative_blocks
        if self.mamba_cache_mode == "align":
            # Mapping from request ID to the index of the block
            # allocated in the previous step
            self.last_state_block_idx: dict[str, int] = {}
            # The set of the requests that have been allocated blocks
            self._allocated_block_reqs: set[str] = set()

    @classmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        assert isinstance(kv_cache_spec, MambaSpec), (
            "MambaManager can only be used for mamba groups"
        )
        assert dcp_world_size == 1, "DCP not support mamba now."
        assert pcp_world_size == 1, "PCP not support mamba now."
        computed_blocks: tuple[list[KVCacheBlock], ...] = tuple(
            [] for _ in range(len(kv_cache_group_ids))
        )

        block_size = kv_cache_spec.block_size
        max_num_blocks = max_length // block_size
        # Search from right to left and early stop when a match is found.
        for i in range(max_num_blocks - 1, -1, -1):
            if cached_block := block_pool.get_cached_block(
                block_hashes[i], kv_cache_group_ids
            ):
                # When enable Mamba prefix caching, `block_size` will be aligned
                # across full attention layers and Mamba layers to ensure the
                # prefix hit length aligned at block
                if (
                    block_size != alignment_tokens  # Faster for common case.
                    and (i + 1) * block_size % alignment_tokens != 0
                ):
                    continue
                for computed, cached in zip(computed_blocks, cached_block):
                    # the hit length logic later assumes:
                    #  hit_length = len(hit_blocks_other_attn[0])
                    #               * self.other_block_size
                    # so we insert dummy blocks at the beginning:
                    computed.extend([block_pool.null_block] * i)
                    computed.append(cached)
                break  # we just need the last match - early stopping

        return computed_blocks

    def remove_skipped_blocks(self, request_id: str, num_computed_tokens: int) -> None:
        assert isinstance(self.kv_cache_spec, MambaSpec)

        # NOTE (tdoublep) with async scheduling, the num_computed_tokens can contain
        # draft tokens from the previous step that may or may not be rejected later.
        # This can make us think we are further ahead in the sequence than we actually
        # are, so let's assume that all tokens are rejected so we don't free blocks
        # that we might actually need.
        num_computed_tokens = max(0, num_computed_tokens - self.num_speculative_blocks)

        super().remove_skipped_blocks(request_id, num_computed_tokens)
        if self.mamba_cache_mode == "align":
            # `last_state_block_idx` refers to the block index allocated two steps ago.
            # The block allocated in the previous step is used to copy Mamba states
            # into the block allocated in the current step; the earlier block is
            # no longer needed and should be freed here.
            last_state_block_idx = self.last_state_block_idx.get(request_id)
            # Blocks allocated during prefill may be non-contiguous. Use
            # `last_state_block_idx` to free the appropriate block and replace it
            # with a null block.
            if (
                last_state_block_idx is not None
                and last_state_block_idx
                < cdiv(num_computed_tokens, self.block_size) - 1
            ):
                blocks = self.req_to_blocks[request_id]
                if blocks[last_state_block_idx] != self._null_block:
                    self.block_pool.free_blocks([blocks[last_state_block_idx]])
                    blocks[last_state_block_idx] = self._null_block

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        """
        cascade attention is not supported by mamba
        """
        return 0

    def get_num_blocks_to_allocate(
        self,
        request_id: str,
        num_tokens: int,
        new_computed_blocks: Sequence[KVCacheBlock],
        total_computed_tokens: int,
        num_tokens_main_model: int,
        apply_admission_cap: bool = False,
    ) -> int:
        assert isinstance(self.kv_cache_spec, MambaSpec)
        if (
            len(new_computed_blocks) > 0
            and new_computed_blocks[-1].block_hash in self.cached_blocks_this_step
        ):
            # Mamba can't rely on blocks generated by other requests in the current step
            # To put it in the next step, we return num_gpu_blocks + 1 so
            # that kv_cache_manager will think there is no enough blocks to allocate now
            # and don't schedule it in the current step.
            return self.block_pool.num_gpu_blocks + 1
        if self.mamba_cache_mode != "align":
            # Allocate extra `num_speculative_blocks` blocks for
            # speculative decoding (MTP/EAGLE) with linear attention.
            if self.num_speculative_blocks > 0:
                num_tokens += (
                    self.kv_cache_spec.block_size * self.num_speculative_blocks
                )
            return super().get_num_blocks_to_allocate(
                request_id,
                num_tokens,
                new_computed_blocks,
                total_computed_tokens,
                num_tokens_main_model,
                apply_admission_cap=apply_admission_cap,
            )
        else:
            # We don't allocate blocks for lookahead tokens in align mode, because if
            # x * block_size tokens are scheduled, num_tokens is
            # x * block_size + num_lookahead_tokens and breaks the alignment.
            # We can ignore lookahead tokens because current draft models don't have
            # mamba layers.
            num_tokens = num_tokens_main_model

            # NOTE(tdouble): this is an over-estimate of how many blocks we need because
            # num_tokens can include draft tokens that will later be rejected.
            num_required_blocks = (
                cdiv(num_tokens, self.block_size) + self.num_speculative_blocks
            )
            num_new_blocks = (
                num_required_blocks
                - len(new_computed_blocks)
                - len(self.req_to_blocks[request_id])
            )
            if num_new_blocks > 0:
                if request_id in self._allocated_block_reqs:
                    # Old request. Needs at most 1 more blocks as we can reuse the
                    # speculative blocks in previous step.
                    num_new_blocks = 1
                else:
                    # First prefill. Allocate 1 block for running state and the
                    # speculative blocks.
                    num_new_blocks = 1 + self.num_speculative_blocks

            num_evictable_computed_blocks = self._get_num_evictable_blocks(
                new_computed_blocks
            )
            return num_new_blocks + num_evictable_computed_blocks

    def allocate_new_blocks(
        self, request_id: str, num_tokens: int, num_tokens_main_model: int
    ) -> list[KVCacheBlock]:
        assert isinstance(self.kv_cache_spec, MambaSpec)
        if self.mamba_cache_mode != "align":
            # Allocate extra `num_speculative_blocks` blocks for
            # speculative decoding (MTP/EAGLE) with linear attention.
            if self.num_speculative_blocks > 0:
                num_tokens += self.block_size * self.num_speculative_blocks
            return super().allocate_new_blocks(
                request_id, num_tokens, num_tokens_main_model
            )
        else:
            # We don't allocate blocks for lookahead tokens in align mode, because if
            # x * block_size tokens are scheduled, num_tokens is
            # x * block_size + num_lookahead_tokens and breaks the alignment.
            # We can ignore lookahead tokens because current draft models don't have
            # mamba layers.
            num_tokens = num_tokens_main_model
            req_blocks: list[KVCacheBlock] = self.req_to_blocks[request_id]
            # NOTE(tdouble): this is an over-estimate of how many blocks we need because
            # num_tokens can include draft tokens that will later be rejected.
            num_required_blocks = (
                cdiv(num_tokens, self.block_size) + self.num_speculative_blocks
            )
            if num_required_blocks == len(req_blocks):
                return []
            else:
                assert num_required_blocks > len(req_blocks), (
                    "num_required_blocks "
                    f"{num_required_blocks} < len(req_blocks) {len(req_blocks)}"
                )
                prev_block_len = len(req_blocks)
                blocks_allocated = request_id in self._allocated_block_reqs
                # Record the last state block
                if blocks_allocated:
                    # We always save the running state at the last
                    # (1 + num_speculative_blocks) block
                    self.last_state_block_idx[request_id] = (
                        prev_block_len - 1 - self.num_speculative_blocks
                    )
                elif prev_block_len > 0:
                    # When a new request hits the prefix cache, the last block
                    # saves the hit state.
                    self.last_state_block_idx[request_id] = prev_block_len - 1

                num_skipped_blocks = (
                    num_required_blocks - self.num_speculative_blocks - 1
                )
                # null blocks
                if prev_block_len < num_skipped_blocks:
                    req_blocks.extend(
                        [
                            self._null_block
                            for _ in range(prev_block_len, num_skipped_blocks)
                        ]
                    )

                if blocks_allocated:
                    # reuse previous speculative blocks in this step
                    for block_idx in range(
                        prev_block_len - self.num_speculative_blocks, prev_block_len
                    ):
                        if block_idx < num_skipped_blocks:
                            req_blocks.append(req_blocks[block_idx])
                            req_blocks[block_idx] = self._null_block
                        else:
                            break
                num_new_blocks = num_required_blocks - len(req_blocks)
                if blocks_allocated:
                    assert num_new_blocks <= 1
                else:
                    assert num_new_blocks <= self.num_speculative_blocks + 1
                new_blocks = self.block_pool.get_new_blocks(num_new_blocks)
                req_blocks.extend(new_blocks)
                self._allocated_block_reqs.add(request_id)
                return req_blocks[prev_block_len:]

    def free(self, request_id: str) -> None:
        if self.mamba_cache_mode == "align":
            self._allocated_block_reqs.discard(request_id)
            self.last_state_block_idx.pop(request_id, None)
        super().free(request_id)

    def get_num_skipped_tokens(self, num_computed_tokens: int) -> int:
        """
        Get the number of tokens whose mamba state are not needed anymore. Mamba only
        need to keep the state of the last computed token, so we return
        num_computed_tokens - 1.
        """
        return num_computed_tokens - 1

    def cache_blocks(
        self,
        request: Request,
        num_tokens: int,
        alignment_tokens: int | None = None,
    ) -> None:
        num_cached_blocks_before = self.num_cached_block.get(request.request_id, 0)
        super().cache_blocks(request, num_tokens, alignment_tokens=alignment_tokens)
        num_cached_blocks_after = self.num_cached_block.get(request.request_id, 0)
        if num_cached_blocks_after > num_cached_blocks_before:
            for block in self.req_to_blocks[request.request_id][
                num_cached_blocks_before:num_cached_blocks_after
            ]:
                if block.is_null:
                    continue
                assert block.block_hash is not None
                self.cached_blocks_this_step.add(block.block_hash)

    def new_step_starts(self) -> None:
        self.cached_blocks_this_step.clear()


class CrossAttentionManager(SingleTypeKVCacheManager):
    """Manager for cross-attention KV cache in encoder-decoder models."""

    def allocate_new_computed_blocks(
        self,
        request_id: str,
        new_computed_blocks: Sequence[KVCacheBlock],
        num_local_computed_tokens: int,
        num_external_computed_tokens: int,
    ) -> None:
        # We do not cache blocks for cross-attention to be shared between
        # requests, so  `new_computed_blocks` should always be empty.
        assert len(new_computed_blocks) == 0

    def cache_blocks(
        self,
        request: Request,
        num_tokens: int,
        alignment_tokens: int | None = None,
    ) -> None:
        # We do not cache blocks for cross-attention to be shared between
        # requests, so this method is not relevant.
        raise ValueError("Should not be called as prefix caching is disabled.")

    def get_num_common_prefix_blocks(self, running_request_id: str) -> int:
        # Cross-attention blocks contain request-specific encoder states
        # and are not shared between different requests
        return 0

    @classmethod
    def find_longest_cache_hit(
        cls,
        block_hashes: BlockHashList,
        max_length: int,
        kv_cache_group_ids: list[int],
        block_pool: BlockPool,
        kv_cache_spec: KVCacheSpec,
        use_eagle: bool,
        alignment_tokens: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
    ) -> tuple[list[KVCacheBlock], ...]:
        assert isinstance(kv_cache_spec, CrossAttentionSpec), (
            "CrossAttentionManager can only be used for cross-attention groups"
        )
        # Cross-attention does not benefit from prefix caching since:
        # 1. Encoder states are unique per request (different audio/image
        #    inputs)
        # 2. Encoder states are computed once per request, not incrementally
        # 3. No reusable prefix exists between different multimodal inputs
        # Return empty blocks to indicate no cache hits
        raise NotImplementedError("CrossAttentionManager does not support caching")


class SinkFullAttentionManager(FullAttentionManager):
    def __init__(
        self,
        kv_cache_spec: SinkFullAttentionSpec,
        block_pool: BlockPool,
        enable_caching: bool,
        kv_cache_group_id: int,
        dcp_world_size: int = 1,
        pcp_world_size: int = 1,
        max_model_len: int | None = None,
    ):
        super().__init__(
            kv_cache_spec,
            block_pool,
            enable_caching,
            kv_cache_group_id,
            dcp_world_size,
            pcp_world_size,
            max_model_len=max_model_len,
        )
        sink_len = kv_cache_spec.sink_len
        assert sink_len is not None and sink_len > 0 and sink_len % self.block_size == 0
        num_sink_block = sink_len // self.block_size
        self.sink_blocks = self.block_pool.free_block_queue.popleft_n(num_sink_block)


spec_manager_map: dict[type[KVCacheSpec], type[SingleTypeKVCacheManager]] = {
    FullAttentionSpec: FullAttentionManager,
    TQFullAttentionSpec: FullAttentionManager,
    MLAAttentionSpec: MLAAttentionManager,
    HiddenStateCacheSpec: FullAttentionManager,
    SlidingWindowSpec: SlidingWindowManager,
    SlidingWindowMLASpec: SlidingWindowMLAManager,
    ChunkedLocalAttentionSpec: ChunkedLocalAttentionManager,
    MambaSpec: MambaManager,
    CrossAttentionSpec: CrossAttentionManager,
    SinkFullAttentionSpec: SinkFullAttentionManager,
}


def get_manager_for_kv_cache_spec(
    kv_cache_spec: KVCacheSpec,
    max_num_batched_tokens: int,
    max_model_len: int,
    **kwargs,
) -> SingleTypeKVCacheManager:
    manager_class = spec_manager_map[type(kv_cache_spec)]
    kwargs["max_model_len"] = max_model_len
    # SlidingWindow / ChunkedLocalAttention managers recycle blocks across
    # chunks; the runtime admission cap must match the recycling-aware bound
    # the startup pool sizer uses (single source of truth: the spec method).
    if isinstance(kv_cache_spec, (SlidingWindowSpec, ChunkedLocalAttentionSpec)):
        kwargs["max_admission_blocks_per_request"] = (
            kv_cache_spec.max_admission_blocks_per_request(
                max_num_batched_tokens=max_num_batched_tokens,
                max_model_len=max_model_len,
            )
        )
    manager = manager_class(kv_cache_spec, **kwargs)
    return manager

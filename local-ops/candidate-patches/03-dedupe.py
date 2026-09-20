#!/usr/bin/env python3
"""Commit-time same-content dedupe (# [kvfix-dedupe]).

Why: every request re-computes ~20 already-cached positions (hit-path drop /
spec-decode boundary), and each re-commit inserts a SECOND block with the
same content hash into the map. Hits always return the first copy, so the
older copies are never touched again — pure dead weight that grows with
request count (~16% of the bs-256 map at 100K / 31 requests, measured).

Fix: in block_pool.cache_full_blocks, before inserting a block's content
hash, check whether the map already holds that (hash, group) position for a
different block; if so, evict the old copy's hash mappings
(_maybe_evict_cached_block: consistent map/events/metrics/trace cleanup).
Both blocks hold byte-identical content (same hash chain), so no hit
capability is lost — the map simply keeps one block per position.

Target: vllm/v1/core/block_pool.py (the prefix-cache hash map).
Idempotent (marker: # [kvfix-dedupe]). Exit 0/1.
"""
import os
import py_compile
import sys

BASE = os.environ.get(
    "VLLM_PYTHON_DIR",
    "/opt/venv/lib/python3.12/site-packages/vllm",
)
BLOCKPOOL = f"{BASE}/v1/core/block_pool.py"

ANCHOR = (
    "            if blk.block_hash is not None:\n"
    "                # The only valid case where a \"new full block\" already has a\n"
    "                # hash is partial->full promotion of the same cache block.\n"
    "                assert (\n"
    "                    blk.block_hash_num_tokens is not None\n"
    "                    and blk.block_hash_num_tokens < num_hash_tokens\n"
    "                )\n"
    "                removed_hashes = self._remove_cached_block_hashes(blk)\n"
    "                self._emit_block_removed_events(removed_hashes)\n"
    "            self._insert_block_hash(\n"
)
REPL = (
    "            if blk.block_hash is not None:\n"
    "                # The only valid case where a \"new full block\" already has a\n"
    "                # hash is partial->full promotion of the same cache block.\n"
    "                assert (\n"
    "                    blk.block_hash_num_tokens is not None\n"
    "                    and blk.block_hash_num_tokens < num_hash_tokens\n"
    "                )\n"
    "                removed_hashes = self._remove_cached_block_hashes(blk)\n"
    "                self._emit_block_removed_events(removed_hashes)\n"
    "            # [kvfix-dedupe] Same-content duplicate guard: a re-computed\n"
    "            # position (hit-path drop / spec boundary) would otherwise\n"
    "            # insert a second block with the same (hash, group) while hits\n"
    "            # always return the first copy — the older copy then lingers\n"
    "            # forever, never touched. Both copies hold identical content\n"
    "            # (same hash chain), so drop the old mapping and keep one\n"
    "            # block per position.\n"
    "            _dup_old = self.cached_block_hash_to_block.get_one_block(\n"
    "                block_hash_with_group_id)\n"
    "            if _dup_old is not None and _dup_old is not blk:\n"
    "                self._maybe_evict_cached_block(_dup_old)\n"
    "            self._insert_block_hash(\n"
)


def main():
    src = open(BLOCKPOOL).read()
    if REPL in src:
        print("[kvfix-dedupe] already applied")
        sys.exit(0)
    if ANCHOR not in src:
        print("[kvfix-dedupe] ANCHOR MISSING in block_pool.py")
        sys.exit(1)
    src = src.replace(ANCHOR, REPL, 1)
    open(BLOCKPOOL, "w").write(src)
    py_compile.compile(BLOCKPOOL, doraise=True)
    print("[kvfix-dedupe] PATCHED + py_compile OK")
    sys.exit(0)


if __name__ == "__main__":
    main()

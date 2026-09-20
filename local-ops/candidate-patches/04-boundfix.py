#!/usr/bin/env python3
"""Sparse-retention replay-boundary tail fix (# [kvfix-boundfix]).

Two coupled defects made the sparse-retention replay tail unreachable for
some prompt geometries:

A. Anchor/geometry: the eagle hit run's rightmost block must START on an
   alignment boundary and be FULL. When the prompt ends less than one block
   past the boundary (``num_prompt % alignment < bs``), the peek block is
   partial, never committed, no valid run exists -> the sliding group returns
   0 -> the fixed-point common hit collapses. The retreat must be UNIFORM
   across sliding groups (the hit is the min over groups): slack = the
   largest sub-alignment block size, provided by the coordinator.

B. Commit-range truncation: ``cache_blocks`` only commits the CURRENT step's
   block range ``[num_cached, num_full)``, and the coordinator caps this
   manager's ``num_tokens`` at the aligned boundary + block_size (below the
   prompt end for small block sizes), so mask-kept replay-tail blocks are
   never committed. Fix: when the request's blocks first cover the full
   prompt (final prefill step, ``num_output_tokens == 0`` keeps decode out),
   run a final pass over the FULL range committing any mask-kept FULL block
   that is still uncommitted (``block_hash is None``; partial blocks and
   already-committed ones are skipped, so no partial->full promotion assert
   can fire and no partial block ever enters the map).

Targets: vllm/v1/core/single_type_kv_cache_manager.py and
vllm/v1/core/kv_cache_coordinator.py.
Idempotent. Exit 0/1.
"""
import os
import py_compile
import sys

BASE = os.environ.get(
    "VLLM_PYTHON_DIR",
    "/opt/venv/lib/python3.12/site-packages/vllm",
)
SINGLE = f"{BASE}/v1/core/single_type_kv_cache_manager.py"
COORD = f"{BASE}/v1/core/kv_cache_coordinator.py"


def _frag(*lines):
    return "".join(l + "\n" for l in lines)


# 1) cache_blocks: pass the coordinator-provided slack down to the mask.
CB_ANCHOR = _frag(
    '        block_mask = self.reachable_block_mask(',
    '            start_block=num_cached_blocks,',
    '            end_block=num_full_blocks,',
    '            alignment_tokens=self.scheduler_block_size,',
    '            kv_cache_spec=self.kv_cache_spec,',
    '            use_eagle=self.use_eagle,',
    '            retention_interval=retention_interval,',
    '            num_prompt_tokens=request.num_prompt_tokens,',
    '        )',
)
CB_REPL = _frag(
    '        block_mask = self.reachable_block_mask(',
    '            start_block=num_cached_blocks,',
    '            end_block=num_full_blocks,',
    '            alignment_tokens=self.scheduler_block_size,',
    '            kv_cache_spec=self.kv_cache_spec,',
    '            use_eagle=self.use_eagle,',
    '            retention_interval=retention_interval,',
    '            num_prompt_tokens=request.num_prompt_tokens,',
    '            eagle_slack=getattr(self, "_swa_anchor_slack", None),',
    '        )',
)

# 2) final tail-commit pass appended at the end of the base cache_blocks.
TAIL_ANCHOR = _frag(
    '        self.num_cached_block[request.request_id] = num_full_blocks',
    '',
    '    @classmethod',
    '    def reachable_block_mask(',
    '        cls,',
    '        start_block: int,',
    '        end_block: int,',
    '        alignment_tokens: int | None,',
    '        kv_cache_spec: KVCacheSpec,',
    '        use_eagle: bool,',
    '        retention_interval: int | None = None,',
    '        num_prompt_tokens: int | None = None,',
    '    ) -> list[bool] | None:',
)
TAIL_REPL = _frag(
    '        self.num_cached_block[request.request_id] = num_full_blocks',
    '',
    '        # [kvfix-boundfix] Final tail-commit pass: per-step commits only',
    '        # cover [num_cached, num_full), and the coordinator caps this',
    "        # manager's num_tokens at the aligned boundary + block_size",
    '        # (below the prompt end for small block sizes), so mask-kept',
    "        # replay-tail blocks are never committed. When the request's",
    '        # blocks first cover the full prompt (final prefill step;',
    '        # num_output_tokens == 0 keeps decode steps out), re-scan the FULL',
    '        # range and commit any mask-kept FULL block that is still',
    '        # uncommitted (block_hash is None -> no partial->full promotion',
    '        # assert; partial tail blocks never enter the map).',
    '        if (',
    '            retention_interval is not None',
    '            and request.num_output_tokens == 0',
    '        ):',
    '            _end = request.num_prompt_tokens // self.block_size',
    '            _blks = self.req_to_blocks[request.request_id]',
    '            if _end > 0 and len(_blks) >= _end:',
    '                _full_mask = self.reachable_block_mask(',
    '                    start_block=0,',
    '                    end_block=_end,',
    '                    alignment_tokens=self.scheduler_block_size,',
    '                    kv_cache_spec=self.kv_cache_spec,',
    '                    use_eagle=self.use_eagle,',
    '                    retention_interval=retention_interval,',
    '                    num_prompt_tokens=request.num_prompt_tokens,',
    '                    eagle_slack=getattr(self, "_swa_anchor_slack", None),',
    '                )',
    '                if _full_mask is not None:',
    '                    _pm = [',
    '                        bool(_full_mask[i])',
    '                        and _blks[i].block_hash is None',
    '                        and (i + 1) * self.block_size',
    '                        <= request.num_prompt_tokens',
    '                        for i in range(_end)',
    '                    ]',
    '                    if any(_pm):',
    '                        self.block_pool.cache_full_blocks(',
    '                            request=request,',
    '                            blocks=_blks,',
    '                            num_cached_blocks=0,',
    '                            num_full_blocks=_end,',
    '                            block_size=self.block_size,',
    '                            kv_cache_group_id=self.kv_cache_group_id,',
    '                            block_mask=_pm,',
    '                        )',
    '',
    '    @classmethod',
    '    def reachable_block_mask(',
    '        cls,',
    '        start_block: int,',
    '        end_block: int,',
    '        alignment_tokens: int | None,',
    '        kv_cache_spec: KVCacheSpec,',
    '        use_eagle: bool,',
    '        retention_interval: int | None = None,',
    '        num_prompt_tokens: int | None = None,',
    '        eagle_slack: int | None = None,',
    '    ) -> list[bool] | None:',
)

# 3) mask signatures gain eagle_slack (base + SWA + Mamba share the text).
SIG_TEXT = _frag(
    '    def reachable_block_mask(',
    '        cls,',
    '        start_block: int,',
    '        end_block: int,',
    '        alignment_tokens: int | None,',
    '        kv_cache_spec: KVCacheSpec,',
    '        use_eagle: bool,',
    '        retention_interval: int | None = None,',
    '        num_prompt_tokens: int | None = None,',
    '    ) -> list[bool] | None:',
)
SIG_REPL = _frag(
    '    def reachable_block_mask(',
    '        cls,',
    '        start_block: int,',
    '        end_block: int,',
    '        alignment_tokens: int | None,',
    '        kv_cache_spec: KVCacheSpec,',
    '        use_eagle: bool,',
    '        retention_interval: int | None = None,',
    '        num_prompt_tokens: int | None = None,',
    '        eagle_slack: int | None = None,',
    '    ) -> list[bool] | None:',
)

# 4) SWA mask replay-boundary formula: uniform-slack anchor.
SWA_ANCHOR = _frag(
    '        # (2) Replay-boundary tail. ``get_computed_blocks`` caps hits at',
    "        # ``num_prompt - 1`` (to recompute the last token's logits), so an exact",
    '        # prompt replay can only land on the latest *fine*-aligned boundary.',
    '        # Sparse retention would otherwise skip it, so keep its tail explicitly.',
    '        if retention_interval is not None and num_prompt_tokens is not None:',
    '            latest = (num_prompt_tokens - 1) // alignment_tokens * alignment_tokens',
    '            prompt_end_block = latest // block_size + shift',
)
SWA_REPL = _frag(
    '        # (2) Replay-boundary tail. ``get_computed_blocks`` caps hits at',
    "        # ``num_prompt - 1`` (to recompute the last token's logits), so an exact",
    '        # prompt replay can only land on the latest *fine*-aligned boundary.',
    '        # Sparse retention would otherwise skip it, so keep its tail explicitly.',
    '        if retention_interval is not None and num_prompt_tokens is not None:',
    '            # [kvfix-boundfix] Uniform-slack anchor: the eagle run\'s',
    '            # rightmost block must START on an alignment boundary and be',
    '            # FULL; when the prompt ends < one block past the boundary the',
    '            # peek is partial and no run exists. Retreat by a UNIFORM slack',
    '            # (largest sub-alignment bs, from the coordinator), applied',
    '            # UNCONDITIONALLY: the eagle group searched first reports the',
    '            # retreated boundary, and the fixed-point min caps every later',
    '            # group below it — non-eagle groups must end their runs at the',
    '            # same boundary or their tails become unreachable.',
    '            _slack = eagle_slack if eagle_slack is not None else block_size',
    '            latest = (',
    '                (num_prompt_tokens - _slack)',
    '                // alignment_tokens * alignment_tokens',
    '            )',
    '            # non-eagle groups need blocks ENDING at the boundary, the',
    '            # eagle group needs the run STARTING there: keep the',
    '            # shift-dependent form.',
    '            prompt_end_block = latest // block_size + shift',
)

# 5) Mamba mask replay boundary: uniform slack too (no eagle shift).
MAMBA_ANCHOR = _frag(
    '        # (2) Replay boundary. ``get_computed_blocks`` caps hits at',
    "        # ``num_prompt - 1``, so an exact prompt replay lands on the latest",
    '        # fine-aligned boundary. Sparse retention would otherwise skip its',
    '        # state, so keep it explicitly.',
    '        if num_prompt_tokens is not None:',
    '            latest = (num_prompt_tokens - 1) // alignment_tokens * alignment_tokens',
    '            boundary_block = latest // block_size - 1',
)
MAMBA_REPL = _frag(
    '        # (2) Replay boundary. ``get_computed_blocks`` caps hits at',
    "        # ``num_prompt - 1``, so an exact prompt replay lands on the latest",
    '        # fine-aligned boundary. Sparse retention would otherwise skip its',
    '        # state, so keep it explicitly.',
    '        # [kvfix-boundfix] Uniform-slack anchor (see the SWA mask); keep',
    '        # the state block ending at the last full aligned boundary.',
    '        if num_prompt_tokens is not None:',
    '            _slack = eagle_slack if eagle_slack is not None else block_size',
    '            latest = (',
    '                (num_prompt_tokens - _slack)',
    '                // alignment_tokens * alignment_tokens',
    '            )',
    '            boundary_block = latest // block_size - 1',
)

# 6) coordinator: set the uniform slack on every manager after creation.
COORD_ANCHOR = _frag(
    '            for i, kv_cache_group in enumerate(self.kv_cache_config.kv_cache_groups)',
    '        )',
)
COORD_REPL = _frag(
    '            for i, kv_cache_group in enumerate(self.kv_cache_config.kv_cache_groups)',
    '        )',
    '',
    '        # [kvfix-boundfix] Uniform replay-boundary slack: the largest',
    '        # sub-alignment (sliding) block size. All sliding groups must',
    '        # anchor their replay tails at the same boundary or the fixed-point',
    '        # hit (min over groups) caps the others below their tails.',
    '        _swa_slack = max(',
    '            (m.block_size for m in self.single_type_managers',
    '             if m.block_size < self.scheduler_block_size),',
    '            default=0,',
    '        )',
    '        for _m in self.single_type_managers:',
    '            _m._swa_anchor_slack = _swa_slack',
)


def _apply(src, anchor, repl, label):
    if repl in src:
        return src, True, False
    if anchor not in src:
        print(f"[kvfix-boundfix] ANCHOR MISSING: {label}")
        return src, False, False
    return src.replace(anchor, repl, 1), True, True


def main():
    src = open(SINGLE).read()
    ok = True
    changed = False
    # tail first (its anchor embeds the pre-signature classmethod header)
    src, ok1, ch1 = _apply(src, TAIL_ANCHOR, TAIL_REPL, "cache_blocks tail")
    ok &= ok1
    changed |= ch1
    src, ok1, ch1 = _apply(src, CB_ANCHOR, CB_REPL, "cache_blocks mask call")
    ok &= ok1
    changed |= ch1
    src, ok1, ch1 = _apply(src, SWA_ANCHOR, SWA_REPL, "SWA formula")
    ok &= ok1
    changed |= ch1
    src, ok1, ch1 = _apply(src, MAMBA_ANCHOR, MAMBA_REPL, "Mamba formula")
    ok &= ok1
    changed |= ch1
    # signatures last
    if SIG_TEXT in src:
        src = src.replace(SIG_TEXT, SIG_REPL)
        changed = True
    elif SIG_REPL not in src:
        print("[kvfix-boundfix] ANCHOR MISSING: mask signatures")
        ok = False
    if not ok:
        sys.exit(1)
    open(SINGLE, "w").write(src)

    coord_src = open(COORD).read()
    if "Uniform replay-boundary slack" not in coord_src:
        coord_src, ok1, ch1 = _apply(coord_src, COORD_ANCHOR, COORD_REPL,
                                     "coordinator slack")
        ok &= ok1
        changed |= ch1
        if not ok1:
            sys.exit(1)
        open(COORD, "w").write(coord_src)

    py_compile.compile(SINGLE, doraise=True)
    py_compile.compile(COORD, doraise=True)
    if changed:
        print("[kvfix-boundfix] PATCHED + py_compile OK")
    else:
        print("[kvfix-boundfix] already applied")
    sys.exit(0)


if __name__ == "__main__":
    main()

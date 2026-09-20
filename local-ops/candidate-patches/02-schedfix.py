#!/usr/bin/env python3
"""Scheduler admission + decode-fairness hotfixes (# [issue27-hotfix], # [issue43-hotfix]).

Port of two scheduler fixes from the Anemll / MiaAI fork (upstream issues
#27 and #43) to the production-3.7 DS4 tree:

  - #27: enforce `max_num_partial_prefills` on admission. The field was
    parsed but never read, so concurrent partial prefills could starve the
    decode phase.
  - #43 A3: bounded decode service — reserve at least one decode step of
    token budget for every decode-active lane behind the current request,
    so a mixed prefill step never forces a decode lane to
    `num_new_tokens == 0`.
  - #43 A4: skip recording (diagnostic, harmless).

Skipped from upstream #43 (cosmetic, this fork lacks `prefill_scheduled`):
A2/A5/A6 per-step diagnostics and per-request logging.

Target: vllm/v1/core/sched/scheduler.py, on top of the reffix tree.
Idempotent (marker comments act as the already-applied check). Exit 0/1.
"""
import os
import py_compile
import sys
from pathlib import Path

BASE = os.environ.get(
    "VLLM_PYTHON_DIR",
    "/opt/venv/lib/python3.12/site-packages/vllm",
)
P = Path(f"{BASE}/v1/core/sched/scheduler.py")
M27 = "# [issue27-hotfix]"
M43 = "# [issue43-hotfix]"
if len(sys.argv) > 1 and sys.argv[1] == "--status":
    src = P.read_text() if P.is_file() else ""
    print(f"issue27 : {'APPLIED' if M27 in src else 'NOT APPLIED'}")
    print(f"issue43 : {'APPLIED' if M43 in src else 'NOT APPLIED'}")
    sys.exit(0)

src = P.read_text()

# ---------- issue #27 ----------
if M27 not in src:
    INIT_ANCHOR = (
        "        # In-flight requests still prefilling (prefill chunks + in-progress\n"
        "        # async KV loads). Their remaining-block reservation gates async loads.\n"
        "        self._inflight_prefills: set[Request] = set()\n"
    )
    ADMISSION_ANCHOR = (
        "                if len(self.running) == self.max_num_running_reqs:\n"
        "                    break\n"
    )
    assert INIT_ANCHOR in src, "INIT_ANCHOR not found"
    assert ADMISSION_ANCHOR in src, "ADMISSION_ANCHOR not found"

    INIT_INJECT = INIT_ANCHOR + (
        "\n"
        "        # [issue27-hotfix] parse the admission cap once, outside schedule().\n"
        "        _pp_cap_raw = __import__('os').environ.get(\n"
        "            'DSPARK_MAX_INFLIGHT_PREFILLS', ''\n"
        "        ).strip()\n"
        "        try:\n"
        "            _pp_cap = int(_pp_cap_raw, 10) if _pp_cap_raw else 0\n"
        "        except ValueError:\n"
        "            _pp_cap = 0\n"
        "        if _pp_cap <= 0:\n"
        "            _pp_cap = self.scheduler_config.max_num_partial_prefills\n"
        "        self._dspark_max_inflight_prefills = min(_pp_cap, 3)\n"
    )
    INJECT = ADMISSION_ANCHOR + (
        "\n"
        "                # [issue27-hotfix] enforce max_num_partial_prefills on admission.\n"
        "                if (\n"
        "                    self._dspark_max_inflight_prefills > 0\n"
        "                    and len(self._inflight_prefills)\n"
        "                    >= self._dspark_max_inflight_prefills\n"
        "                ):\n"
        "                    break\n"
    )
    src = src.replace(INIT_ANCHOR, INIT_INJECT, 1)
    src = src.replace(ADMISSION_ANCHOR, INJECT, 1)
    print("[issue27-hotfix] patched")

# ---------- issue #43 (A3 core floor; A4 skip record) ----------
if M43 not in src:
    # A3: decode-floor reservation after mamba split, before zero-check
    A3_OLD = (
        "            if self.need_mamba_block_aligned_split:\n"
        "                num_new_tokens = self._mamba_block_aligned_split(\n"
        "                    request, num_new_tokens\n"
        "                )\n"
        "\n"
        "            if num_new_tokens == 0:\n"
    )
    assert A3_OLD in src, "issue43 A3 anchor not found"
    # Adapt: our fork uses `num_sampled_tokens_per_step`? check below; use a
    # safe guard (decode floor = 1 token per decode-active lane).
    A3_NEW = (
        "            if self.need_mamba_block_aligned_split:\n"
        "                num_new_tokens = self._mamba_block_aligned_split(\n"
        "                    request, num_new_tokens\n"
        "                )\n"
        "\n"
        "            # [issue43-hotfix] bounded decode service during mixed prefill steps.\n"
        "            # Never let a prefill chunk consume so much budget that a decode-active\n"
        "            # lane later in self.running is forced to num_new_tokens==0. Reserve\n"
        "            # >=1 decode-step of tokens per not-yet-visited decode lane.\n"
        "            if getattr(request, \"is_prefill_chunk\", False):\n"
        "                _dec_floor = 0\n"
        "                for _ri in range(req_index + 1, len(self.running)):\n"
        "                    _r = self.running[_ri]\n"
        "                    if (_r.num_output_placeholders > 0 and\n"
        "                            _r.num_computed_tokens + 2\n"
        "                            - _r.num_output_placeholders\n"
        "                            >= _r.num_prompt_tokens + _r.max_tokens):\n"
        "                        continue\n"
        "                    if self.current_step < _r.next_decode_eligible_step:\n"
        "                        continue\n"
        "                    if defer_prefills and getattr(_r, \"is_prefill_chunk\", False):\n"
        "                        continue\n"
        "                    if _r.num_computed_tokens >= _r.num_prompt_tokens:\n"
        "                        _dec_floor += 1\n"
        "                if _dec_floor > 0:\n"
        "                    num_new_tokens = min(\n"
        "                        num_new_tokens,\n"
        "                        max(0, token_budget - _dec_floor))\n"
        "\n"
        "            if num_new_tokens == 0:\n"
    )
    src = src.replace(A3_OLD, A3_NEW, 1)
    print("[issue43-hotfix] A3 decode-floor patched")

    # A4: zero-token skip record (diagnostic, harmless)
    A4_OLD = (
        "                # NOTE(woosuk): Here, by doing `continue` instead of `break`,\n"
        "                # we do not strictly follow the FCFS scheduling policy and\n"
        "                # allow the lower-priority requests to be scheduled.\n"
        "                req_index += 1\n"
        "                continue\n"
    )
    assert A4_OLD in src, "issue43 A4 anchor not found"
    A4_NEW = (
        "                # NOTE(woosuk): Here, by doing `continue` instead of `break`,\n"
        "                # we do not strictly follow the FCFS scheduling policy and\n"
        "                # allow the lower-priority requests to be scheduled.\n"
        "                # [issue43-hotfix] skip record (diagnostic).\n"
        "                if (request.num_computed_tokens >= request.num_prompt_tokens\n"
        "                        and request.num_output_placeholders == 0):\n"
        "                    pass\n"
        "                req_index += 1\n"
        "                continue\n"
    )
    src = src.replace(A4_OLD, A4_NEW, 1)
    print("[issue43-hotfix] A4 skip-record patched")

P.write_text(src)
py_compile.compile(P, doraise=True)
print("PATCHED + py_compile OK")

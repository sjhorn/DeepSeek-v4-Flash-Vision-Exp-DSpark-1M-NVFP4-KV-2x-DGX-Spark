#!/usr/bin/env bash
# check-local-patches.sh — fail-closed preflight for EVERY local bind-mounted patch.
#
# WHY.  A bind mount to the wrong path fails SILENTLY: the container starts, the
# API answers, the smoke test passes, and the patch is simply not there.  That is
# the exact failure scripts/check-patch4.sh was written for after the vision port
# dropped one mount and cost half the decode speed at unchanged output quality.
# This generalises it to all five mounted files, and — because the start script
# syncs patches/*.py to the worker but nothing verifies the result afterwards —
# it checks EVERY node you name, so head/worker drift shows up as a FAIL row.
#
# It asserts a distinctive CODE marker (never a comment) is present in the file
# the container actually imports, so a comment-only edit can never fake a pass.
#
# usage:  bash scripts/check-local-patches.sh <head-container> [worker-container...]
#         VLLM_ROOT=/path/to/site-packages/vllm overrides autodetection
#         REMOTE=user@host  runs docker against that host over ssh
# exit 0 = every row OK on every container; exit 1 = something is missing.
#
# Companion checks, run all three after a restart:
#   bash scripts/check-patch4.sh <containers>     # IMG-4, baked into the image
#   python3 local-ops/verify-server.py            # live behaviour of the API patches
#
# Registry: docs/local/PATCH-REGISTRY.md
set -uo pipefail

VLLM_ROOT_OVERRIDE="${VLLM_ROOT:-}"
REMOTE="${REMOTE:-}"

# ssh and docker both read stdin, and the row loop below feeds its list on
# stdin -- unguarded, the first container call swallows every remaining row and
# the check silently reports only one line.  Always detach stdin here.
dk() {
  if [ -n "$REMOTE" ]; then
    ssh -n "$REMOTE" docker "$@" < /dev/null
  else
    docker "$@" < /dev/null
  fi
}

# The vLLM package root is NOT the same on every image (see check-patch3.sh).
# Ask Python where vllm actually lives, then fall back to the known layouts.
resolve_root() {
  local c="$1" root=""
  if [ -n "$VLLM_ROOT_OVERRIDE" ]; then
    printf '%s\n' "$VLLM_ROOT_OVERRIDE"
    return 0
  fi
  for py in /opt/env/bin/python /usr/local/bin/python3 python3 python; do
    root=$(dk exec "$c" "$py" -c \
      'import os,vllm;print(os.path.dirname(vllm.__file__))' 2>/dev/null) || continue
    root="$(printf '%s' "$root" | tr -d '\r')"
    [ -n "$root" ] && { printf '%s\n' "$root"; return 0; }
  done
  for cand in /opt/env/lib/python3.12/site-packages/vllm \
              /usr/local/lib/python3.12/dist-packages/vllm \
              /usr/lib/python3/dist-packages/vllm; do
    if dk exec "$c" test -d "$cand" 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# id | path relative to the vllm package | distinctive CODE marker | what its absence costs
ROWS='
API-0|entrypoints/anthropic/protocol.py|max_uses|Claude Code inline system messages 422 before inference
API-8|entrypoints/anthropic/serving.py|_STRIP_LEAKED_COT|leaked CoT returns as history; measured +63.1% prompt tokens
API-9|entrypoints/anthropic/serving.py|_ALIAS_THINKING_ENABLED|every tier serves the server default; no per-tier thinking
API-9d|entrypoints/anthropic/serving.py|def client_disabled_thinking|the classifier can take a reasoning pass on every tool call
API-10|entrypoints/anthropic/serving.py|_TOOL_ARGS_STRICT|one malformed tool call 500s the turn; client retries cold
API-10b|entrypoints/anthropic/serving.py|def recover_dsml_arguments|leaked raw DSML arrives as unusable tool arguments
API-11a|entrypoints/anthropic/serving.py|_PROMPT_CACHE_STRIP_PATTERNS|the per-request token counter moves the head every turn
API-11b|entrypoints/anthropic/serving.py|def leading_system_boundary|every turn hoists its system reminder to position 0
API-12|entrypoints/anthropic/serving.py|_PREFIX_WATCH|no PREFIX_WATCH line; head moves become undetectable
API-13|entrypoints/anthropic/serving.py|_STICKY_TOOLS|a flapping client tool shrinks the tools array, moving the head
API-14|entrypoints/anthropic/serving.py|_engine_cached_tokens|the engine num_cached_tokens value never reaches the client
MNT-5|v1/engine/detokenizer.py|VLLM_SUPPRESS_STOPS_IN_REASONING|stop strings can fire inside the reasoning segment
MNT-6a|v1/core/single_type_kv_cache_manager.py|_PROTECTED_FRACTION_ENV|unbounded legacy protection caps swallow the block pool
MNT-6b|v1/core/single_type_kv_cache_manager.py|_RECYCLE_ENABLED|sliding-window pages churn the shared LRU instead of recycling
MNT-7|v1/core/block_pool.py|_dup_old|duplicate cached blocks hold LRU slots forever (3.9x retention)
'

# PLG-14b is not a patch over a vLLM file -- it is an ADDED site-packages plugin,
# found through the vllm.stat_logger_plugins entry-point group rather than by
# import, so it needs a path relative to site-packages (the vllm package's parent)
# and a check that the .dist-info is there too: without the metadata the entry
# point is never discovered and the module sits on disk doing nothing.
PLUGIN_ROWS='
PLG-14b|prefill_collector.py|PrefillCollector|per-request prefill rows are discarded; no per-turn attribution
PLG-14b|prefill_collector-0.1.dist-info/entry_points.txt|vllm.stat_logger_plugins|the module is present but never loaded -- silent no-op
'

if [ $# -eq 0 ]; then
  echo "usage: $0 <container-name> [container-name...]" >&2
  exit 2
fi

rc=0
for c in "$@"; do
  echo "== $c${REMOTE:+  (on $REMOTE)}"
  if ! dk inspect "$c" >/dev/null 2>&1; then
    echo "  ?? container not found"
    rc=1; continue
  fi
  if ! root=$(resolve_root "$c"); then
    echo "  ?? could not locate the vllm package inside the container."
    echo "     Re-run with VLLM_ROOT=/path/to/site-packages/vllm"
    rc=1; continue
  fi

  printf '%s\n' "$ROWS" | while IFS='|' read -r id rel marker cost; do
    [ -n "${id:-}" ] || continue
    f="$root/$rel"
    if ! dk exec "$c" test -f "$f" 2>/dev/null; then
      printf '  FAIL %-7s no file at %s\n' "$id" "$f"
      echo "FAILED" >> "${TMPDIR:-/tmp}/.check-local-patches.$$"
      continue
    fi
    # -F: the markers are literal text, not patterns.
    if dk exec "$c" grep -qF -- "$marker" "$f" 2>/dev/null; then
      printf '  OK   %-7s %s\n' "$id" "$rel"
    else
      printf '  FAIL %-7s MISSING from %s\n' "$id" "$f"
      printf '       marker not found: %s\n' "$marker"
      printf '       cost if absent:   %s\n' "$cost"
      printf '       the mount is probably at the wrong path — mount to the path\n'
      printf '       printed above, not to a remembered one; it fails SILENTLY.\n'
      echo "FAILED" >> "${TMPDIR:-/tmp}/.check-local-patches.$$"
    fi
  done

  # PLG-* live NEXT TO the vllm package, not inside it.
  sp="$(dirname "$root")"
  printf '%s\n' "$PLUGIN_ROWS" | while IFS='|' read -r id rel marker cost; do
    [ -n "${id:-}" ] || continue
    f="$sp/$rel"
    if dk exec "$c" grep -qF -- "$marker" "$f" 2>/dev/null; then
      printf '  OK   %-7s %s\n' "$id" "$rel"
    else
      printf '  FAIL %-7s MISSING from %s\n' "$id" "$f"
      printf '       marker not found: %s\n' "$marker"
      printf '       cost if absent:   %s\n' "$cost"
      echo "FAILED" >> "${TMPDIR:-/tmp}/.check-local-patches.$$"
    fi
  done

  if [ -s "${TMPDIR:-/tmp}/.check-local-patches.$$" ]; then
    rc=1
    rm -f "${TMPDIR:-/tmp}/.check-local-patches.$$"
  fi
done

if [ "$rc" != 0 ]; then
  echo
  echo "One or more local patches are missing.  Re-sync and restart:" >&2
  echo "  ./start-deepseek-v4-flash-dspark.sh   (scp's patches/*.py to the worker)" >&2
  echo "and read docs/local/CLUSTER.md first — a restart needs a specific ask." >&2
fi
exit $rc

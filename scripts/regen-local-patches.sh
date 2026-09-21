#!/usr/bin/env bash
# regen-local-patches.sh — regenerate patches/generated/*.patch from
# patches/pristine/ (unpatched vLLM, pulled from the runtime image) and the
# whole-file copies we actually bind-mount.
#
# WHY this exists.  The five files in patches/ are whole-file copies of vLLM
# source, because that is what a bind-mount needs.  Our real delta is tiny and
# invisible inside them: MNT-7 is 14 lines inside 534, MNT-6 is seven hunks
# inside 1,504.  The generated diffs are the REVIEW SURFACE; the whole-file
# copies stay the DEPLOY ARTEFACT.  Neither replaces the other.
#
# usage:
#   bash scripts/regen-local-patches.sh          # write patches/generated/*.patch
#   bash scripts/regen-local-patches.sh --check  # exit 1 if any diff is stale
#
# Registry: docs/local/PATCH-REGISTRY.md
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRISTINE="$ROOT/patches/pristine"
OUT="$ROOT/patches/generated"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# mounted-copy : path inside the vllm package (also the path under patches/pristine/vllm/)
MAP="
anthropic_protocol_inline_system.py:entrypoints/anthropic/protocol.py
anthropic_serving_inline_system.py:entrypoints/anthropic/serving.py
patch5-detokenizer.py:v1/engine/detokenizer.py
patch6-single_type_kv_cache_manager.py:v1/core/single_type_kv_cache_manager.py
patch7-block_pool-dedupe.py:v1/core/block_pool.py
patch8-kv_cache_utils.py:v1/core/kv_cache_utils.py
mnt10-scheduler.py:v1/core/sched/scheduler.py
"

mkdir -p "$OUT"
rc=0
stale=""

for entry in $MAP; do
  mounted="${entry%%:*}"
  target="${entry#*:}"
  src="$PRISTINE/vllm/$target"
  dst="$ROOT/patches/$mounted"
  # one .patch per target, named after the target so the file it patches is obvious
  name="$(printf '%s' "$target" | tr '/' '-')"
  patchfile="$OUT/${name%.py}.patch"

  if [ ! -f "$src" ]; then
    echo "  MISSING pristine: patches/pristine/vllm/$target" >&2
    echo "          re-capture per patches/pristine/MANIFEST.txt" >&2
    rc=1; continue
  fi
  if [ ! -f "$dst" ]; then
    echo "  MISSING mounted copy: patches/$mounted" >&2
    rc=1; continue
  fi

  # GIT diff, not diff(1). `diff -u` is NOT portable output: Apple/FreeBSD diff
  # and GNU diffutils produce different — both valid — unified diffs for the
  # SAME inputs, so a patch generated on the Mac read STALE on the head and vice
  # versa, and --check was useless on whichever machine did not generate it.
  # Measured 2026-09-20 on detokenizer.py: GNU 160 lines, BSD 159, same 4 hunks.
  # git's diff is one implementation everywhere git runs, so the output is
  # stable across both nodes and the Mac.
  #
  # --no-index compares two paths outside the index; it exits 1 when they
  # differ, which is the normal case here. The header git emits carries machine
  # paths and a blob `index` line, so it is dropped and replaced with a stable
  # a/ b/ header naming the vLLM file the patch applies to.
  new="$(printf 'a/vllm/%s\nb/vllm/%s\n' "$target" "$target" | sed '1s|^|--- |; 2s|^|+++ |'
         git --no-pager diff --no-index --no-color --no-ext-diff -- "$src" "$dst" \
           | sed -n '/^@@/,$p')"

  if [ -z "$new" ]; then
    echo "  WARNING patches/$mounted is IDENTICAL to pristine — is it still a patch?" >&2
  fi

  if [ "$CHECK" = "1" ]; then
    if [ ! -f "$patchfile" ]; then
      echo "  STALE  ${patchfile#$ROOT/} — does not exist"
      stale="$stale $mounted"; rc=1
    elif ! printf '%s\n' "$new" | diff -q - "$patchfile" >/dev/null; then
      echo "  STALE  ${patchfile#$ROOT/} — does not match patches/$mounted"
      stale="$stale $mounted"; rc=1
    else
      printf '  OK     %-48s (%s hunks)\n' "${patchfile#$ROOT/}" \
        "$(grep -c '^@@' "$patchfile")"
    fi
  else
    printf '%s\n' "$new" > "$patchfile"
    printf '  wrote  %-48s %4s hunks, %4s added, %4s removed\n' \
      "${patchfile#$ROOT/}" \
      "$(grep -c '^@@' "$patchfile")" \
      "$(grep -c '^+[^+]' "$patchfile")" \
      "$(grep -c '^-[^-]' "$patchfile")"
  fi
done

if [ "$CHECK" = "1" ] && [ -n "$stale" ]; then
  echo
  echo "Regenerate with: bash scripts/regen-local-patches.sh" >&2
fi

exit $rc

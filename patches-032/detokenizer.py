# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
#
# ===== MNT-5: keep client stop strings dormant inside the reasoning segment ==
#
# LOCAL PATCH, vLLM 0.32 line (DSpark branch vllm-0.32).  Whole-file copy of
# v1/engine/detokenizer.py, bind-mounted over it.  patches-031/detokenizer.py
# merged three-way onto v0.32.0 (2026-10-18; pristine in patches-032/pristine/).
# v0.32.0 brought #47616 (spec decode: drop tokens past a stop string; the stop
# offset now comes from per-token offsets), so the offset is computed BEFORE
# the reasoning guard here ("PATCH 5 on v0.32.0" below). Upstream's own test,
# tests/detokenizer/test_stop_string_while_stop_model_terminates.py, passes on
# this file (34/34); patches-031's copy fails it (30/34). Two layers on the
# upstream original:
#   1. upstream PR vllm-project/vllm#52486 at head 8d5f4d8bdd2c (still open,
#      2026-10-15), which applies cleanly to v0.31.0: the PROMPT-side guard
#      (prompt ends with the reasoning start token -> stops dormant until the
#      end marker, then evaluated only after it);
#   2. ours, the OUTPUT-side extension the PR does not have: when the prompt
#      does NOT end with the start token but stops and markers exist, the guard
#      is PENDING until the first visible output says whether generation opened
#      with the start marker (then the full guard) or in content (then the
#      withheld span is evaluated with normal stop semantics). Marked
#      "MNT-5 output-side" below.
# Kill switch: VLLM_SUPPRESS_STOPS_IN_REASONING=0 (process-wide, the PR's).
# The marker check-local-patches.sh greps for is that env var name.
# Detail: docs/local/PATCH-REGISTRY.md (MNT-5).
# =============================================================================
import sys
import os
from abc import ABC, abstractmethod
from bisect import bisect_left

import tokenizers.decoders
from tokenizers import Tokenizer
from transformers import TokenizersBackend

from vllm.logger import init_logger
from vllm.tokenizers import TokenizerLike
from vllm.tokenizers.detokenizer_utils import (
    convert_prompt_ids_to_tokens,
    detokenize_incrementally,
)
from vllm.utils import length_from_prompt_token_ids_or_embeds
from vllm.v1.engine import EngineCoreRequest

logger = init_logger(__name__)

# Error string from https://github.com/huggingface/tokenizers/blob/909fdde2a4ffedd9295206f705eb612be2a91b12/tokenizers/src/tokenizer/mod.rs#L1042
INVALID_PREFIX_ERR_MSG = "Invalid prefix encountered"


def uses_fast_detokenizer(tokenizer: TokenizerLike) -> bool:
    """Whether the engine detokenizes with `FastIncrementalDetokenizer`."""
    return isinstance(tokenizer, TokenizersBackend)


class IncrementalDetokenizer:
    def __init__(self):
        self.token_ids: list[int] = []

    @property
    def output_token_ids(self) -> list[int]:
        return self.token_ids

    def num_output_tokens(self) -> int:
        return len(self.token_ids)

    def update(self, new_token_ids: list[int], stop_terminated: bool) -> str | None:
        self.token_ids.extend(new_token_ids)
        return None

    def get_next_output_text(self, finished: bool, delta: bool) -> str:
        return ""

    @classmethod
    def from_new_request(
        cls,
        tokenizer: TokenizerLike | None,
        request: EngineCoreRequest,
    ) -> "IncrementalDetokenizer":
        assert request.sampling_params is not None

        if tokenizer is None:
            # No tokenizer => skipping detokenization.
            return IncrementalDetokenizer()

        if uses_fast_detokenizer(tokenizer):
            # Fast tokenizer => use tokenizers library DecodeStream.
            detokenizer: BaseIncrementalDetokenizer = FastIncrementalDetokenizer(
                tokenizer, request
            )
        else:
            # Fall back to slow python-based incremental detokenization.
            detokenizer = SlowIncrementalDetokenizer(tokenizer, request)
        _maybe_arm_reasoning_stop_guard(detokenizer, tokenizer, request)
        return detokenizer


def _reasoning_markers() -> tuple[str, str]:
    """Reasoning segment markers, preferring the deployment's reasoning
    config over the common defaults so the guard is not model-specific."""
    start, end = "<think>", "</think>"
    try:
        from vllm.config import get_current_vllm_config

        reasoning_config = getattr(
            get_current_vllm_config(), "reasoning_config", None
        )
        if reasoning_config is not None:
            start = getattr(reasoning_config, "reasoning_start_str", "") or start
            end = getattr(reasoning_config, "reasoning_end_str", "") or end
    except Exception:
        pass
    return start, end


def _maybe_arm_reasoning_stop_guard(
    detokenizer: "BaseIncrementalDetokenizer",
    tokenizer: TokenizerLike,
    request: EngineCoreRequest,
) -> None:
    """Keep client stop strings dormant while the reasoning segment is open.

    With think-in-prompt templates the prompt ends with the reasoning start
    token, so generation begins INSIDE the reasoning segment. Evaluating
    client ``stop`` strings there truncates the chain-of-thought whenever it
    restates a stop phrase (lm-evaluation-harness sends ``stop[:4]`` on every
    request): the end marker never arrives and the reasoning parser yields
    ``content: None``. Hosted deployments scope stops to content; this guard
    matches that behavior. EOS and ``max_tokens`` are unaffected, and requests
    whose prompt does not end inside reasoning are untouched.

    Opt-out (process-wide): ``VLLM_SUPPRESS_STOPS_IN_REASONING=0``.
    """
    if os.environ.get("VLLM_SUPPRESS_STOPS_IN_REASONING", "1") == "0":
        return
    if not detokenizer.stop:
        return
    prompt_token_ids = request.prompt_token_ids
    if not prompt_token_ids:
        return
    start_str, end_str = _reasoning_markers()
    try:
        think_id = tokenizer.convert_tokens_to_ids(start_str)
    except Exception:
        think_id = None
    if think_id is None or think_id < 0:
        return
    if prompt_token_ids[-1] == think_id:
        detokenizer.reasoning_stop_guard = True
        detokenizer.reasoning_end_str = end_str
    elif start_str:
        # MNT-5 output-side: some templates never put the start token in the
        # prompt and the model opens it as its first output. Which mode this
        # request is in is unknown here, so the guard is PENDING: update()
        # withholds stop evaluation until the first visible output decides.
        # Zero effect on requests without stop strings (returned above).
        detokenizer._reasoning_pending = True
        detokenizer._reasoning_start_str = start_str
        detokenizer.reasoning_end_str = end_str


class BaseIncrementalDetokenizer(IncrementalDetokenizer, ABC):
    def __init__(self, request: EngineCoreRequest):
        super().__init__()

        # Stop strings
        params = request.sampling_params
        assert params is not None
        if params.stop is None:
            self.stop = []
        elif isinstance(params.stop, str):
            self.stop = [params.stop]
        else:
            self.stop = params.stop
        self.min_tokens = params.min_tokens
        self.include_stop_str_in_output = params.include_stop_str_in_output

        # Number of chars to hold back when stop strings are to be excluded
        # from streamed output.
        if self.stop and not self.include_stop_str_in_output:
            self.stop_buffer_length = max(len(s) for s in self.stop) - 1
        else:
            self.stop_buffer_length = 0
        self._last_output_text_offset: int = 0

        # Set by _maybe_arm_reasoning_stop_guard(): while True and the
        # reasoning segment has not closed, client stop strings stay dormant.
        self.reasoning_stop_guard: bool = False
        self._reasoning_closed: bool = False
        self.reasoning_end_str: str = "</think>"
        # MNT-5 output-side: PENDING until the first visible output shows
        # whether generation opened with the reasoning start marker; then it
        # either becomes the full guard or the withheld span (from
        # _reasoning_pending_offset) is evaluated with normal stop semantics.
        self._reasoning_pending: bool = False
        self._reasoning_start_str: str = "<think>"
        self._reasoning_pending_offset: int = 0

        # Generation data
        self.output_text = ""

    def update(self, new_token_ids: list[int], stop_terminated: bool) -> str | None:
        """Update RequestState for the request_id by:
            1) Detokenize the new token ids incrementally.
            2) Evaluate stop criteria.

        Return matched stop string or None.
        """
        if not new_token_ids:
            # Skip detokenization if no new token ids.
            return None

        if stop_terminated and not self.include_stop_str_in_output:
            # If stop-terminated, exclude last token from detokenization
            # based on include_stop_str_in_output parameter.
            skipped_stop_token_id = new_token_ids[-1]
            new_token_ids = new_token_ids[:-1]
        else:
            skipped_stop_token_id = None

        # 1) Detokenize the new token ids incrementally.
        num_prev_tokens = self.num_output_tokens()
        first_new_token_index = len(self.token_ids)
        # Output text offsets at the boundaries of the new tokens.
        token_offsets = [len(self.output_text)] if self.stop else None
        for new_token_id in new_token_ids:
            self.token_ids.append(new_token_id)
            self.output_text += self.decode_next(new_token_id)
            if token_offsets is not None:
                token_offsets.append(len(self.output_text))

        if skipped_stop_token_id is not None:
            # Cleanup after skipping detokenization.
            self.token_ids.append(skipped_stop_token_id)
            if token_offsets is not None:
                token_offsets.append(len(self.output_text))

        # 2) Evaluate stop strings.
        # PATCH 5 on v0.32.0: where the stop check starts, computed HERE because
        # the reasoning guard below moves it. Upstream (v0.32.0) computes it
        # inside the stop check from per-token offsets (#47616): the first
        # token past min_tokens. Clipped to the last offset, which is 0.31's
        # value while every new token is still within min_tokens (the stop
        # check does not run then). No stop strings -> no offsets; the guard
        # only gates stops, so the end of the text is safe there.
        if token_offsets is not None:
            stop_check_offset = token_offsets[
                min(max(self.min_tokens - num_prev_tokens, 0), len(token_offsets) - 1)
            ]
        else:
            stop_check_offset = len(self.output_text)
        # Keep stops dormant while the reasoning segment is open; on closing,
        # evaluate only text FOLLOWING the end marker. With spec decoding this
        # update() may carry the reasoning tail in the same multi-token chunk
        # as the marker, and a stop inside that tail must not fire.
        # MNT-5 output-side: resolve a pending guard on the first visible
        # output. lstrip() tolerates leading template whitespace before the
        # tag; a strict prefix of the marker keeps the decision pending.
        if self._reasoning_pending and self.output_text:
            txt = self.output_text.lstrip()
            if txt:
                start = self._reasoning_start_str
                if txt.startswith(start):
                    self._reasoning_pending = False
                    self.reasoning_stop_guard = True
                elif not start.startswith(txt):
                    self._reasoning_pending = False
                    # Generation opened in content: evaluate the span
                    # withheld while pending with normal stop semantics.
                    stop_check_offset = min(
                        stop_check_offset, self._reasoning_pending_offset
                    )
        if self.reasoning_stop_guard and not self._reasoning_closed:
            marker = self.reasoning_end_str
            search_from = max(0, stop_check_offset - (len(marker) - 1))
            marker_index = self.output_text.find(marker, search_from)
            if marker_index != -1:
                self._reasoning_closed = True
                stop_check_offset = max(
                    stop_check_offset, marker_index + len(marker)
                )
        stop_string = None
        if (
            token_offsets is not None
            and self.num_output_tokens() > self.min_tokens
            and not self._reasoning_pending
            and (not self.reasoning_stop_guard or self._reasoning_closed)
        ):
            # Support min_tokens, see https://github.com/vllm-project/vllm/pull/22014
            # (stop_check_offset is set above, before the reasoning guard)
            stop = check_stop_strings(
                output_text=self.output_text,
                new_char_count=len(self.output_text) - stop_check_offset,
                stop=self.stop,
                include_in_output=self.include_stop_str_in_output,
            )
            if stop is not None:
                stop_string, truncate_to = stop
                stop_end = len(self.output_text) if truncate_to == -1 else truncate_to
                if not self.include_stop_str_in_output:
                    stop_end += len(stop_string)
                # Drop tokens generated after the one completing the stop string
                # (possible when multiple tokens are appended in one step).
                num_kept = bisect_left(token_offsets, stop_end, lo=1)
                del self.token_ids[first_new_token_index + num_kept :]
                if truncate_to != -1:
                    self.output_text = self.output_text[:truncate_to]

        return stop_string

    @abstractmethod
    def decode_next(self, next_token_id: int) -> str:
        raise NotImplementedError

    def get_next_output_text(self, finished: bool, delta: bool) -> str:
        """If delta is True, only new text since the last call to
        this method is returned"""
        # We return the full output text if the sequence is finished.
        buffer_length = 0 if finished else self.stop_buffer_length
        if not delta:
            if not buffer_length:
                return self.output_text
            return self.output_text[:-buffer_length]

        length = len(self.output_text) - buffer_length
        last_offset = self._last_output_text_offset
        if last_offset < length:
            self._last_output_text_offset = length
            return self.output_text[last_offset:length]
        return ""


class FastIncrementalDetokenizer(BaseIncrementalDetokenizer):
    def __init__(self, tokenizer: TokenizersBackend, request: EngineCoreRequest):
        super().__init__(request)

        sampling_params = request.sampling_params
        assert sampling_params is not None

        self.request_id = request.request_id
        self.skip_special_tokens = sampling_params.skip_special_tokens

        self.tokenizer: Tokenizer = tokenizer._tokenizer

        # Use native prefill to prime the decode stream with prompt tokens.
        # Look up DecodeStream on the module so backend patches (e.g. the
        # fastokens shim that replaces ``tokenizers.decoders.DecodeStream``)
        # are honored regardless of import order.
        self.stream = tokenizers.decoders.DecodeStream(
            ids=request.prompt_token_ids,
            skip_special_tokens=self.skip_special_tokens,
        )

        self.spaces_between_special_tokens = (
            sampling_params.skip_special_tokens
            or sampling_params.spaces_between_special_tokens
        )

        if not self.spaces_between_special_tokens:
            # Store dict of added token ids so that we can suppress
            # the spaces between them.
            added_token_ids = getattr(self.tokenizer, "added_token_ids", None)
            if added_token_ids is None:
                self.tokenizer.added_token_ids = added_token_ids = {
                    tid: tok.content
                    for tid, tok in self.tokenizer.get_added_tokens_decoder().items()
                }

            if added_token_ids:
                self.last_special = False
                self.added_token_ids = added_token_ids
            else:
                # No added tokens.
                self.spaces_between_special_tokens = True

    def decode_next(self, next_token_id: int) -> str:
        token = self._protected_step(next_token_id)

        if not self.spaces_between_special_tokens:
            special_token = self.added_token_ids.get(next_token_id)
            is_special = special_token is not None
            if is_special and self.last_special:
                # Return raw token string without any prefixed spaces.
                token = special_token
            self.last_special = is_special

        return token or ""

    def _protected_step(self, next_token_id: int) -> str | None:
        try:
            token = self.stream.step(self.tokenizer, next_token_id)
        except (OverflowError, TypeError):
            # Handle rare observed overflow, still to be diagnosed.
            # See https://github.com/vllm-project/vllm/issues/21951.
            logger.exception("Encountered invalid token id: %r", next_token_id)
            token = None
        except Exception as e:
            if not str(e).startswith(INVALID_PREFIX_ERR_MSG):
                raise e
            # Recover from edge case where tokenizer can produce non-monotonic,
            # invalid UTF-8 output, which breaks the internal state of
            # tokenizers' DecodeStream.
            # See https://github.com/vllm-project/vllm/issues/17448.
            logger.warning(
                "Encountered invalid prefix detokenization error"
                " for request %s, resetting decode stream.",
                self.request_id,
            )
            self.stream = tokenizers.decoders.DecodeStream(
                skip_special_tokens=self.skip_special_tokens
            )
            token = self.stream.step(self.tokenizer, next_token_id)
        return token


class SlowIncrementalDetokenizer(BaseIncrementalDetokenizer):
    def __init__(self, tokenizer: TokenizerLike, request: EngineCoreRequest):
        super().__init__(request)

        self.tokenizer = tokenizer
        params = request.sampling_params
        assert params is not None

        self.prompt_len = length_from_prompt_token_ids_or_embeds(
            request.prompt_token_ids, request.prompt_embeds
        )

        # Metadata for incremental detokenization.
        if request.prompt_token_ids is not None:
            self.tokens, self.prefix_offset, self.read_offset = (
                convert_prompt_ids_to_tokens(
                    tokenizer=tokenizer,
                    prompt_ids=request.prompt_token_ids,
                    skip_special_tokens=params.skip_special_tokens,
                )
            )
        else:
            # Prompt embedding requests cannot be detokenized, in general.
            self.tokens = [""] * self.prompt_len
            self.prefix_offset = 0
            self.read_offset = 0

        self.token_ids.extend(request.prompt_token_ids or [0] * self.prompt_len)

        self.skip_special_tokens = params.skip_special_tokens
        self.spaces_between_special_tokens = params.spaces_between_special_tokens

    @property
    def output_token_ids(self) -> list[int]:
        if self.prompt_len:
            return self.token_ids[self.prompt_len :]
        return self.token_ids

    def num_output_tokens(self) -> int:
        return len(self.token_ids) - self.prompt_len

    def decode_next(self, next_token_id: int) -> str:
        new_tokens, decoded_text, prefix_offset, read_offset = detokenize_incrementally(
            tokenizer=self.tokenizer,
            all_input_ids=self.token_ids,
            prev_tokens=self.tokens,
            prefix_offset=self.prefix_offset,
            read_offset=self.read_offset,
            skip_special_tokens=self.skip_special_tokens,
            spaces_between_special_tokens=self.spaces_between_special_tokens,
        )

        self.tokens.extend(new_tokens)
        self.prefix_offset = prefix_offset
        self.read_offset = read_offset

        return decoded_text


def check_stop_strings(
    output_text: str,
    new_char_count: int,
    stop: list[str],
    include_in_output: bool,
) -> tuple[str, int] | None:
    """Check if any stop strings are matched and truncate sequence
    output text accordingly.

    Returns tuple (stop_string, offset) if matched or else None.

    Where stop_string is the matched stop string and offset is the
    length to which output_text should be truncated, or -1 for no
    truncation.

    When several stop strings match within the newly generated text (for
    example when speculative decoding appends multiple tokens in a single
    step), the stop string that completes earliest in the text is selected,
    so the result matches appending one token at a time. Ties are broken by
    stop-list order.
    """
    if not new_char_count or not stop:
        return None

    best_stop_str: str | None = None
    best_stop_index = 0
    best_end = sys.maxsize
    for stop_str in stop:
        stop_string_len = len(stop_str)
        # Avoid searching already-searched text.
        stop_index = output_text.find(stop_str, 1 - new_char_count - stop_string_len)
        if stop_index == -1:
            continue

        # Prefer the stop string that completes earliest in the text.
        end = stop_index + stop_string_len
        if end < best_end:
            best_stop_str = stop_str
            best_stop_index = stop_index
            best_end = end

    if best_stop_str is None:
        return None

    if include_in_output:
        # Truncate to end of stop string.
        if best_end >= len(output_text):
            # No truncation required.
            return best_stop_str, -1
        return best_stop_str, best_end

    # Truncate the output text to the beginning of the stop string.
    return best_stop_str, best_stop_index

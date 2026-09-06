#!/usr/bin/env python3
"""Measure the INFORMATION CONTENT, in bits, of every example in an SFT corpus.

Cross-entropy is information. Summing ``-log2 p(token)`` over an example's
ANSWER tokens -- under exactly the mask the trainer uses -- gives the number of
bits that example costs the model. That number is the currency of a curriculum:

    bits_base     surprise under the UNTUNED base. Low => the base already knows
                  it => the example teaches nothing and only burns iterations.
    bits_tuned    surprise under a trained candidate (pass --adapter).
    learned_bits  bits_base - bits_tuned. Information the run actually acquired.
    residual_bits bits_tuned. High after training => genuinely hard OR mislabeled.
                  In a SYNTHESIZED corpus noise is the likelier cause, and that is
                  a bug in gen_training_data.py, not a hard example.

This script emits ONE of those columns per run (the model you point it at).
``select_curriculum.py`` joins a base run and a tuned run into all four.

THE DECISION COLUMN. Most of an example's bits are spent on prose that no
arbiter reads. ``evals/tmux-routing/run_evals.py:matches()`` compares
``expected["action"]`` and, when present, ``expected["session"]`` -- never
``reason``, ``question`` or ``task``. So the scorer emits a SECOND column,
``decision_bits``: the same cross-entropy summed only over the tokens that spell
the fields carrying the LABEL. ``select_curriculum.py --bits-column decision``
ranks on it.

Those fields are PER TRACK, because the four tracks do not share a schema
(``--decision-fields auto``, the default; see DECISION_FIELDS_BY_TARGET):

    routing   action, session                    847 rows
    elicit    action                             305 rows
    ledger    decision, goal_id, message_id      728 rows
    tooluse   tool, arguments                    365 rows

A FLAT ``action,session`` -- what this script used to default to -- is empty for
the whole ledger and tooluse tracks: 1093 of the 2245 rows in
datasets/mlx/train.jsonl (48.7%) carry neither key, so their ``decision_bits``
would be null and ``select_curriculum.py`` would refuse the column outright.
Measured with ``field_spans`` over that corpus, the per-track share of each
answer, by characters:

    routing   min 11.7%  median 16.0%  max 42.6%
    elicit    min  8.5%  median 10.7%  max 21.6%
    ledger    min 23.7%  median 41.1%  max 51.2%
    tooluse   min 92.5%  median 96.5%  max 97.4%   <- schema is {tool, arguments}
    ALL 2245  min  8.5%  median 36.6%  max 97.4%   (0 rows missing the column)

tooluse is ~97% because that track's answer has no prose field at all; there the
decision column is very nearly the answer column, and honestly so. By TOKENS the
share is smaller still for the tracks that do have prose, because the decisive
value is usually a single token while a ``reason`` is many.

Neither column is "the" right one -- prose bits still shape the model -- and
note that the current gate scores ONLY the routing track (51 scenarios, all
route/start/clarify/refuse), so for 1398 of 2245 rows the "decision" is the
label the corpus teaches rather than a quantity any arbiter checks today.

WHAT IT IS NOT. Bits never certify a model. `evals/tmux-routing` +
`scripts/model-factory/eval_gate.py` remain the only arbiter of promotion. Bits
choose which examples to train on; the gate says whether that worked.

Fidelity to training (see the grounding notes in README "Curriculum by
information"). The numbers are only comparable to a training loss if the
tokenization and masking match `mlx_lm`'s exactly:

  * tokenize through mlx-lm's ``TokenizerWrapper``, never the raw HF tokenizer.
    The wrapper forces ``return_dict=False`` (transformers 5.x otherwise hands
    back a ``BatchEncoding`` whose ``len()`` is 2 -- the number of dict keys) and
    injects ``enable_thinking=True`` for gemma-4, which emits ``<|think|>\\n`` in
    the first system turn. Omitting either shifts every example by ~2 tokens.
  * the offset is ``len(apply_chat_template(messages[:-1], add_generation_prompt=
    messages[-1]['role'] == 'assistant'))``, exactly as ``ChatDataset.process``
    computes it under ``--mask-prompt``.
  * the trainer's mask keeps target index ``j in [offset-1, L-1]`` of
    ``batch[:, 1:]``, i.e. predicted positions ``k in [offset, L]``. Position L
    is the trailing PAD the batch padder supplies whenever the batch is narrower
    than ``max_seq_length``, so the trainer's ``ntoks`` is ``L - offset + 1``,
    one more than the real answer. We report the honest ``answer`` count
    (``L - offset``) as the primary and the trainer's ``L - offset + 1`` as
    ``trainer_*`` so a port can be validated against a logged loss. A sequence
    that FILLS the window (``L >= max_seq_length``, truncated or exact-fit) gets
    no pad column -- ``iterate_batches`` caps the batch width at
    ``max_seq_length`` -- so there ``ntoks`` collapses to ``L' - offset``.

Guards. This refuses to touch the GPU while a fine-tune is in flight or while
free memory is below a threshold -- the same precondition as the gate sweep,
because two models in 34 GB of unified memory is how the machine gets wedged.
The guard FAILS CLOSED: if ``pgrep`` or ``vm_stat`` cannot be read, the machine
state is unknown and the run is refused unless ``--allow-unverified-machine``.

Usage:
  score_bits.py --model mlx-community/gemma-4-E4B-it-qat-4bit \\
      --data datasets/mlx/train.jsonl --out reports/bits-train-base.jsonl
  score_bits.py ... --adapter models/candidates/fin-foreman-e4b-mlx \\
      --out reports/bits-train-tuned.jsonl

  --dry-run tokenizes and reports lengths/offsets/truncation without loading the
  model. It still imports mlx_lm to reach the TokenizerWrapper, and that import
  initialises the Metal device -- so it runs the PROCESS half of the guard (no
  fine-tune may be live) while skipping the free-memory half, which it does not
  need. It is a one-minute tokenizer pass, not a GPU job; it waits its turn.

Stdlib at import time on purpose: mlx is imported lazily inside the scoring
path so the unit tests can exercise every formula without a GPU.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

LOG2_E = 1.0 / math.log(2.0)
PAD_ID = 0  # mlx_lm's iterate_batches pads with np.zeros -> token id 0 (<pad>)
BUSY_EXIT = 75  # EX_TEMPFAIL, the same code the gate sweep uses when it refuses
MIN_FREE_GB_DEFAULT = 10

# The fields evals/tmux-routing/run_evals.py:matches() actually compares.
# Everything else in a ROUTING answer is prose the arbiter never reads.
GATE_FIELDS_DEFAULT = ("action", "session")

# The DECISION fields, per track. The four tracks do not share an answer schema,
# so one flat field list cannot address them: `action,session` is empty for every
# ledger and tooluse row (1093 of 2245 = 48.7% of datasets/mlx/train.jsonl), and
# a decision column that is null for half the corpus ranks on whether it could be
# computed rather than on information. `--decision-fields auto` resolves through
# this table; an explicit comma list overrides it for every track at once.
#
# What belongs here is the field whose VALUE is the label, plus the fields that
# make that label specific (which session, which goal, which arguments) -- never
# `reason`, `question` or `task`, which are prose.
DECISION_FIELDS_BY_TARGET: dict[str, tuple[str, ...]] = {
    "routing": ("action", "session"),
    "elicit": ("action",),
    "ledger": ("decision", "goal_id", "message_id"),
    "tooluse": ("tool", "arguments"),
}
# A track we cannot classify falls back to the union, so an unrecognised schema
# degrades to "look for any of the known label keys" instead of to nothing.
DECISION_FIELDS_FALLBACK = ("action", "session", "decision", "goal_id", "message_id", "tool", "arguments")
DECISION_FIELDS_AUTO = "auto"

# The four fine-tune targets, recognised by the first line of the system prompt
# that gen_training_data.py emits for each track.
TARGET_PROMPT_MARKERS: tuple[tuple[str, str], ...] = (
    ("# Session routing", "routing"),
    ("# Goal-driving tick", "ledger"),
    ("You are Fin driving a coding agent", "tooluse"),
    ("You are Fin, foreman of a factory of coding agents", "elicit"),
)

# Fallback: infer the target from the answer schema when the prompt is unfamiliar.
ROUTING_ACTIONS = {"route", "start", "clarify", "refuse"}
ELICIT_ACTIONS = {"ask", "proceed"}


# ---------------------------------------------------------------------------
# pure helpers -- no mlx, no model, unit-testable
# ---------------------------------------------------------------------------


def bits_from_nats(nats: float) -> float:
    """Cross-entropy in nats -> information in bits."""
    return nats * LOG2_E


def content_hash(messages: Sequence[dict]) -> str:
    """Stable 64-bit content id for an example. Resume and join key."""
    blob = json.dumps(messages, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def classify(messages: Sequence[dict]) -> tuple[str, str]:
    """(target, decision_class) for one example.

    ``target`` is the fine-tune track (routing / ledger / elicit / tooluse),
    read off the system prompt the way gen_training_data.py writes it.
    ``decision_class`` is the label the example teaches, parsed out of the
    assistant JSON: ``action`` (routing, elicit), ``decision`` (ledger) or
    ``tool`` (tooluse).
    """
    system = ""
    answer = ""
    for m in messages:
        role = m.get("role")
        if role == "system" and not system:
            system = m.get("content") or ""
        if role == "assistant":
            answer = m.get("content") or ""

    target = "unknown"
    head = system.strip().splitlines()[0] if system.strip() else ""
    for marker, name in TARGET_PROMPT_MARKERS:
        if head.startswith(marker) or marker in system[:400]:
            target = name
            break

    decision = "unparsed"
    try:
        obj = json.loads(answer)
    except (ValueError, TypeError):
        obj = None
    if isinstance(obj, dict):
        for key in ("action", "decision", "tool"):
            value = obj.get(key)
            if isinstance(value, str) and value:
                decision = value
                break
        if target == "unknown":
            # Schema fallback, in the order that keeps the four tracks distinct.
            if "tool" in obj and "arguments" in obj:
                target = "tooluse"
            elif "decision" in obj:
                target = "ledger"
            elif decision in ELICIT_ACTIONS:
                target = "elicit"
            elif decision in ROUTING_ACTIONS:
                target = "routing"
    return target, decision


@dataclass
class MaskPlan:
    """Exactly which logits rows and target ids the trainer's mask selects."""

    length: int  # L, tokens before truncation
    effective_length: int  # L' = min(L, max_seq_length); what actually gets scored
    offset: int  # prompt length; first ANSWER position
    rows: list[int]  # logits row indices; row r predicts position r+1
    targets: list[int]  # target token ids, aligned with rows
    answer_tokens: int  # primary count = L' - offset
    trainer_tokens: int  # ntoks the trainer reports for this example
    truncated: bool  # answer was cut by --max-seq-length
    tokens_lost: int  # how many answer tokens the truncation ate
    usable: bool  # False => nothing to score, skip and report
    note: str = ""
    window_full: bool = False  # L >= max_seq_length: the batch has no pad column
    has_pad_step: bool = False  # a trailing PAD row was appended to `rows`


def plan_mask(
    tokens: Sequence[int],
    offset: int,
    max_seq_length: int,
    match_trainer: bool = True,
) -> MaskPlan:
    """Reproduce ``default_loss``'s mask for one example.

    The trainer does ``inputs = batch[:, :-1]; targets = batch[:, 1:]`` and keeps
    target index ``j`` when ``offset <= j+1 <= length``. Target ``j`` is
    ``batch[j+1]``, and logits row ``j`` predicts it -- so in un-shifted terms the
    scored positions are ``k in [offset, length]`` read from rows ``k-1``.

    Two counts come out of that:

    * primary (``answer_tokens``): ``k in [offset, L'-1]`` -- the real answer.
    * trainer parity (``trainer_tokens``): one more step, ``k = L'``, whose target
      is the trailing ``<pad>`` the batch padder guarantees. It exists only while
      the batch is NARROWER than ``max_seq_length``. ``iterate_batches`` sets the
      width to ``min(1 + 32*ceil(L/32), max_seq_length)``, so a sequence that
      fills the window -- truncated (``L > max_seq_length``) OR an exact fit
      (``L == max_seq_length``) -- has no pad column at all and ``ntoks``
      collapses to ``L' - offset``. Keying this off ``truncated`` alone would
      over-count the exact-fit case by one token and one pad step's nats.

    With ``match_trainer=False`` the pad step is dropped from ``rows`` AND from
    ``trainer_tokens``, so the two stay commensurable: a summary that divides
    trainer nats by trainer tokens is then a per-token mean over exactly the
    answer, not a mean biased low by a token whose nats were never summed.
    """
    length = len(tokens)
    effective_length = min(length, max_seq_length)
    truncated = length > max_seq_length
    window_full = length >= max_seq_length
    tokens_lost = length - effective_length

    if offset < 1:
        return MaskPlan(
            length=length,
            effective_length=effective_length,
            offset=offset,
            rows=[],
            targets=[],
            answer_tokens=0,
            trainer_tokens=0,
            truncated=truncated,
            tokens_lost=tokens_lost,
            usable=False,
            note="offset < 1: no prompt to condition on (position 0 is never a target)",
            window_full=window_full,
        )
    if offset >= effective_length:
        return MaskPlan(
            length=length,
            effective_length=effective_length,
            offset=offset,
            rows=[],
            targets=[],
            answer_tokens=0,
            trainer_tokens=0,
            truncated=truncated,
            tokens_lost=tokens_lost,
            usable=False,
            note=(
                "prompt fills or exceeds max_seq_length: the whole answer is "
                "truncated away, the example carries no trainable signal"
            ),
            window_full=window_full,
        )

    positions = list(range(offset, effective_length))
    rows = [k - 1 for k in positions]
    targets = [tokens[k] for k in positions]
    answer_tokens = len(positions)
    has_pad_step = match_trainer and not window_full
    trainer_tokens = answer_tokens + 1 if has_pad_step else answer_tokens

    if has_pad_step:
        rows.append(effective_length - 1)
        targets.append(PAD_ID)

    return MaskPlan(
        length=length,
        effective_length=effective_length,
        offset=offset,
        rows=rows,
        targets=targets,
        answer_tokens=answer_tokens,
        trainer_tokens=trainer_tokens,
        truncated=truncated,
        tokens_lost=tokens_lost,
        usable=True,
        note="answer truncated by max_seq_length" if truncated else "",
        window_full=window_full,
        has_pad_step=has_pad_step,
    )


def split_nats(plan: MaskPlan, nats: Sequence[float], match_trainer: bool = True) -> tuple[float, float]:
    """(answer_nats, trainer_nats) from the per-row nats ``plan`` asked for.

    ``plan.has_pad_step`` -- not ``match_trainer``, not ``truncated`` -- decides
    whether a pad step was scored, so the nats and the token count in
    ``plan.trainer_tokens`` always describe the same set of steps.
    """
    if len(nats) != len(plan.rows):
        raise ValueError(f"expected {len(plan.rows)} nats, got {len(nats)}")
    answer_nats = float(sum(nats[: plan.answer_tokens]))
    trainer_nats = float(sum(nats)) if plan.has_pad_step else answer_nats
    return answer_nats, trainer_nats


def log_softmax(row: Sequence[float]) -> list[float]:
    """Numerically stable log-softmax. Pure python; the mlx path uses
    ``nn.losses.cross_entropy`` on float32 logits, which computes the same thing.
    Kept here so the unit tests can drive the whole formula without a GPU."""
    top = max(row)
    exps = [math.exp(v - top) for v in row]
    total = math.log(sum(exps)) + top
    return [v - total for v in row]


def nats_from_logits(rows: Sequence[Sequence[float]], targets: Sequence[int]) -> list[float]:
    """-log p(target) per row, in nats. The reference implementation."""
    if len(rows) != len(targets):
        raise ValueError("rows and targets must align")
    return [-log_softmax(list(row))[t] for row, t in zip(rows, targets)]


# ---------------------------------------------------------------------------
# the DECISION mask: only the tokens the eval gate actually compares
# ---------------------------------------------------------------------------


def field_spans(answer_text: str, fields: Sequence[str]) -> list[tuple[int, int]]:
    """Character spans of ``"field": value`` members inside the ORIGINAL text.

    Spans must be in the answer's own coordinates -- re-serializing through
    ``json`` would move every offset -- so this scans the text and lets
    ``JSONDecoder.raw_decode`` find where each value ends, which is exact for
    strings with escapes, numbers, nested objects and arrays alike.

    A field that is absent contributes nothing; the caller decides whether the
    empty result is fatal. ``session`` is legitimately absent from most answers.
    """
    decoder = json.JSONDecoder()
    spans: list[tuple[int, int]] = []
    for name in fields:
        key = json.dumps(name)  # the quoted key exactly as it appears
        start = 0
        while True:
            i = answer_text.find(key, start)
            if i < 0:
                break
            start = i + len(key)
            j = start
            while j < len(answer_text) and answer_text[j] in " \t\r\n":
                j += 1
            if j >= len(answer_text) or answer_text[j] != ":":
                continue  # a string that merely looks like the key
            j += 1
            while j < len(answer_text) and answer_text[j] in " \t\r\n":
                j += 1
            try:
                _, end = decoder.raw_decode(answer_text, j)
            except ValueError:
                continue
            spans.append((i, end))
    return sorted(spans)


def token_char_bounds(
    decode: Callable[[Sequence[int]], str], tokens: Sequence[int], start: int, end: int
) -> list[tuple[int, int]] | None:
    """``[lo, hi)`` character bounds of each token in ``[start, end)``.

    Measured by cumulative decode, which is the only way that stays correct for
    a BPE/sentencepiece tokenizer where a token's text depends on its
    neighbours. Returns None if the decode is not monotone (a tokenizer whose
    prefixes are not prefixes) -- better no decision column than a wrong one.
    """
    bounds: list[tuple[int, int]] = []
    prev = 0
    for k in range(start, end):
        piece = decode(list(tokens[start : k + 1]))
        if len(piece) < prev:
            return None
        bounds.append((prev, len(piece)))
        prev = len(piece)
    return bounds


def decision_fields_for(target: str, override: Sequence[str] | None) -> tuple[str, ...]:
    """Which answer fields carry the decision for ``target``.

    ``override`` is an explicit ``--decision-fields`` list and wins for every
    track. Under ``auto`` (the default) the per-track table decides, and an
    unclassified row gets the union of every known label key rather than an
    empty list -- "I do not recognise this schema" must not read as "this answer
    has no decision", which is the difference between an unknown and a zero.
    """
    if override is not None:
        return tuple(override)
    return DECISION_FIELDS_BY_TARGET.get(target, DECISION_FIELDS_FALLBACK)


def decision_indices(
    plan: MaskPlan,
    tokens: Sequence[int],
    answer_text: str,
    fields: Sequence[str],
    decode: Callable[[Sequence[int]], str],
) -> list[int] | None:
    """Indices into ``plan.rows[:answer_tokens]`` that spell the gate fields.

    None means "could not be established" -- a truncated answer, a template
    whose decode does not round-trip, or an answer with none of the fields.
    The caller records that as ``decision_ok: false`` and leaves the column
    null rather than reporting a zero that would rank like a known-easy example.
    """
    if not plan.usable or plan.truncated:
        return None
    region = decode(list(tokens[plan.offset : plan.effective_length]))
    base = region.find(answer_text)
    if base < 0:
        return None
    spans = field_spans(answer_text, fields)
    if not spans:
        return None
    spans = [(a + base, b + base) for a, b in spans]
    bounds = token_char_bounds(decode, tokens, plan.offset, plan.effective_length)
    if bounds is None:
        return None
    # Invariant, not a branch a caller can reach: token_char_bounds returns
    # exactly ``end - start`` bounds, and ``effective_length - offset`` IS
    # ``answer_tokens`` by plan_mask's construction. Kept as an assertion so a
    # future change to either function fails loudly here instead of silently
    # mis-aligning the decision mask against the nats vector.
    assert len(bounds) == plan.answer_tokens, (
        f"token_char_bounds returned {len(bounds)} bounds for {plan.answer_tokens} answer tokens"
    )
    keep = [
        i
        for i, (lo, hi) in enumerate(bounds)
        if any(lo < span_end and hi > span_start for span_start, span_end in spans)
    ]
    return keep or None


# ---------------------------------------------------------------------------
# machine guard -- the same precondition the gate sweep enforces
# ---------------------------------------------------------------------------

# Built by concatenation so this file's own text can never satisfy its own pgrep.
_TRAINING_PATTERN = "mlx_lm lo" + "ra"
_BUSY_PATTERNS = (_TRAINING_PATTERN, "mlx_lm server", "mlx_lm fuse", "mlx_lm generate")


class MachineUnknown(Exception):
    """The machine's state could not be read. Not the same as 'it is idle'."""


def _pgrep(pattern: str) -> list[str]:
    """PIDs matching ``pattern``. Raises MachineUnknown if pgrep cannot answer.

    A guard that treats "I could not check" as "nothing is running" fails in
    exactly the direction that wedges the machine, so an unreadable process
    table propagates instead of returning [].
    """
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise MachineUnknown(f"pgrep -f {pattern!r} failed: {exc}") from exc
    if out.returncode not in (0, 1):  # 0 = matches, 1 = none; anything else is an error
        raise MachineUnknown(f"pgrep -f {pattern!r} exited {out.returncode}")
    return [line for line in out.stdout.split() if line.strip()]


def free_gb() -> float:
    """Free + inactive pages, in GiB. Same arithmetic as the gate sweep's awk.

    Raises MachineUnknown rather than returning a number that would pass: on a
    box without vm_stat the honest answer is "unknown", and the caller decides
    (--allow-unverified-machine) whether unknown is good enough.
    """
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise MachineUnknown(f"vm_stat failed: {exc}") from exc
    page = re.search(r"page size of (\d+) bytes", out)
    page_size = int(page.group(1)) if page else 16384
    total = 0
    found = False
    for label in ("Pages free", "Pages inactive"):
        m = re.search(rf"{label}:\s+(\d+)", out)
        if m:
            total += int(m.group(1))
            found = True
    if not found:
        raise MachineUnknown("vm_stat produced no page counts")
    return total * page_size / (1024**3)


def guard(
    min_free: float,
    label: str = "score_bits",
    allow_unverified: bool = False,
    check_memory: bool = True,
) -> None:
    """Refuse to compete for the GPU. Exits BUSY_EXIT; never raises past main.

    ``check_memory=False`` runs only the process half: for a caller that touches
    the Metal runtime but allocates nothing on it (``--dry-run`` imports mlx_lm
    to reach the TokenizerWrapper), "no fine-tune is live" is the precondition
    that matters and a free-memory threshold is not.
    """
    try:
        for pattern in _BUSY_PATTERNS:
            pids = _pgrep(pattern)
            if pids:
                print(
                    f"[{label}] refusing to run: '{pattern}' is live (pid {' '.join(pids)}). "
                    "Two models in 34 GB of unified memory is how the machine wedges.",
                    file=sys.stderr,
                )
                sys.exit(BUSY_EXIT)
        if not check_memory:
            print(f"[{label}] no fine-tune is live (memory not checked: nothing will be allocated)",
                  file=sys.stderr)
            return
        have = free_gb()
    except MachineUnknown as exc:
        if not allow_unverified:
            print(
                f"[{label}] refusing to run: cannot verify the machine is idle ({exc}). "
                "Pass --allow-unverified-machine only if you KNOW no fine-tune is running.",
                file=sys.stderr,
            )
            sys.exit(BUSY_EXIT)
        print(f"[{label}] machine state unverified ({exc}); proceeding on --allow-unverified-machine",
              file=sys.stderr)
        return
    if have < min_free:
        print(
            f"[{label}] refusing to run: only {have:.1f} GB free, need >= {min_free:.0f} GB.",
            file=sys.stderr,
        )
        sys.exit(BUSY_EXIT)
    print(f"[{label}] machine is clear: {have:.1f} GB free", file=sys.stderr)


# ---------------------------------------------------------------------------
# corpus IO
# ---------------------------------------------------------------------------


@dataclass
class Example:
    index: int
    messages: list[dict]
    raw: str
    hash: str
    target: str
    decision: str
    tools: Any = None  # per-line 'tools', which ChatDataset.process also passes

    @property
    def answer_text(self) -> str:
        for m in reversed(self.messages):
            if m.get("role") == "assistant":
                return m.get("content") or ""
        return ""


def read_corpus(path: Path, chat_key: str = "messages") -> list[Example]:
    out: list[Example] = []
    with path.open("r", encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if not line.strip():
                continue
            obj = json.loads(line)
            messages = obj[chat_key]
            target, decision = classify(messages)
            out.append(
                Example(
                    index=len(out),
                    messages=messages,
                    raw=line if line.endswith("\n") else line + "\n",
                    hash=content_hash(messages),
                    target=target,
                    decision=decision,
                    # ChatDataset.process passes tools=d.get("tools", None) into
                    # BOTH apply_chat_template calls. Dropping it here would
                    # tokenize a tools-carrying example differently from how the
                    # trainer tokenizes it, and its bits would silently stop
                    # matching the training loss.
                    tools=obj.get("tools"),
                )
            )
    return out


def read_scored(path: Path) -> tuple[list[dict], bool]:
    """Existing rows plus whether the file had to be repaired (torn tail)."""
    if not path.exists():
        return [], False
    rows: list[dict] = []
    torn = False
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                torn = True  # a crash mid-write; drop the partial record
    return rows, torn


# ---------------------------------------------------------------------------
# scorers
# ---------------------------------------------------------------------------


class StubScorer:
    """Deterministic fake logits, for the unit tests.

    ``logit_fn(row_index, vocab_index) -> float`` fully determines the
    distribution, so a fixture can assert an exact bits value with no GPU.
    """

    def __init__(self, vocab: int, logit_fn: Callable[[int, int], float]):
        self.vocab = vocab
        self.logit_fn = logit_fn

    def row_nats(self, tokens: Sequence[int], plan: MaskPlan) -> list[float]:
        rows = [[self.logit_fn(r, v) for v in range(self.vocab)] for r in plan.rows]
        return nats_from_logits(rows, plan.targets)

    def decode(self, ids: Sequence[int]) -> str:
        """A character-level decode: token id == code point.

        That makes the stub a real (if trivial) tokenizer, so a fixture can
        build tokens from actual answer text with ``[ord(c) for c in text]`` and
        the decision mask's span -> token mapping is exercised end to end.
        """
        return "".join(chr(i) if 0 <= i < 0x110000 else "�" for i in ids)


def chat_tokenize(tokenizer, messages: Sequence[dict], tools: Any = None) -> tuple[list[int], int]:
    """(tokens, offset) exactly as ``ChatDataset.process`` computes them under
    ``--mask-prompt``.

    ``tokenizer`` MUST be mlx-lm's ``TokenizerWrapper``: it forces
    ``return_dict=False`` and injects ``enable_thinking=True`` for a model whose
    vocab carries thinking markers. A raw HF tokenizer does neither, and both
    omissions silently change the token count.

    ``tools`` is the corpus line's own ``tools`` value, passed into BOTH calls
    exactly as ``ChatDataset.process`` does. Today's corpus has none; the tooluse
    track is the one most likely to grow one, and a hardcoded None there would
    shift every offset in that track without tripping the prefix assertion.
    """
    tokens = tokenizer.apply_chat_template(messages, tools=tools, return_dict=False)
    add_generation_prompt = messages[-1].get("role") == "assistant"
    prompt = tokenizer.apply_chat_template(
        messages[:-1],
        tools=tools,
        add_generation_prompt=add_generation_prompt,
        return_dict=False,
    )
    tokens = list(tokens)
    offset = len(prompt)
    # The mask is only meaningful if the prompt really is a prefix of the whole.
    if list(prompt) != tokens[:offset]:
        raise ValueError(
            "chat template is not prefix-stable: tokens[:offset] != prompt tokens. "
            "The prompt mask cannot be trusted for this tokenizer/template pair."
        )
    return tokens, offset


class MLXScorer:
    """The real thing. Chunked prefill, batch 1, no gradients."""

    def __init__(self, model_path: str, adapter_path: str | None, chunk: int, full_forward: bool):
        import mlx.core as mx
        import mlx.nn as nn
        from mlx_lm.utils import load

        self.mx = mx
        self.model, self.tokenizer = load(model_path, adapter_path=adapter_path)
        self.chunk = chunk
        self.full_forward = full_forward
        self._cross_entropy = nn.losses.cross_entropy

    def tokenize(self, messages: Sequence[dict], tools: Any = None) -> tuple[list[int], int]:
        return chat_tokenize(self.tokenizer, messages, tools)

    def decode(self, ids: Sequence[int]) -> str:
        return self.tokenizer.decode(list(ids))

    def _nats(self, logit_rows, targets) -> list[float]:
        mx = self.mx
        losses = self._cross_entropy(
            logit_rows.astype(mx.float32), mx.array(targets), reduction="none"
        )
        mx.eval(losses)
        return [float(v) for v in losses.tolist()]

    @staticmethod
    def expected_rows(plan: MaskPlan) -> list[int]:
        """The row indices the chunked assembly is about to stand in for.

        The chunked path rebuilds logits rows POSITIONALLY out of two forwards,
        so it never reads ``plan.rows`` and a unit test driving StubScorer
        cannot catch an off-by-one in it. Asserting the plan against the shape
        the assembly assumes turns that into a loud failure at row zero instead
        of a plausible-looking bits column.
        """
        rows = list(range(plan.offset - 1, plan.effective_length - 1))
        if plan.has_pad_step:
            rows.append(plan.effective_length - 1)
        return rows

    def row_nats(self, tokens: Sequence[int], plan: MaskPlan) -> list[float]:
        # FIRST, before touching self.mx -- so a test can drive this check on an
        # un-initialised instance and the mutation "delete the assertion" fails
        # a test instead of shipping green.
        if list(plan.rows) != self.expected_rows(plan):
            raise ValueError(
                "mask plan does not match the chunked assembly's assumption "
                f"(offset={plan.offset}, L'={plan.effective_length}, "
                f"pad_step={plan.has_pad_step}); refusing to score"
            )
        mx = self.mx
        seq = list(tokens[: plan.effective_length])

        if self.full_forward:
            # One forward over the whole sequence -- what the trainer literally
            # does. Materialises (1, L, 262144) logits; only for spot-checks.
            logits = self.model(mx.array(seq)[None, :])
            rows = mx.take(logits[0], mx.array(plan.rows), axis=0)
            mx.eval(rows)
            out = self._nats(rows, plan.targets)
            del logits, rows
            mx.clear_cache()
            return out

        from mlx_lm.models.cache import make_prompt_cache

        cache = make_prompt_cache(self.model)
        offset = plan.offset

        # 1. prefill the prompt, keeping only the final row (offset-1), which is
        #    the row that predicts the first answer token.
        last_prompt_row = None
        pos = 0
        while pos < offset:
            end = min(pos + self.chunk, offset)
            logits = self.model(mx.array(seq[pos:end])[None, :], cache=cache)
            if end == offset:
                last_prompt_row = logits[0, -1:, :]
                mx.eval(last_prompt_row)
            else:
                # generate.py:442's idiom -- eval the cache, not the logits, so
                # the 268 MB chunk of vocab logits is freed immediately.
                mx.eval([c.state for c in cache])
            del logits
            pos = end

        # 2. one forward over the answer: rows offset .. L'-1.
        answer = seq[offset : plan.effective_length]
        answer_logits = self.model(mx.array(answer)[None, :], cache=cache)
        mx.eval(answer_logits)

        # 3. rows [offset-1 .. L'-2] predict the answer; row L'-1 predicts <pad>.
        pieces = [last_prompt_row]
        if answer_logits.shape[1] > 1:
            pieces.append(answer_logits[0, :-1, :])
        if plan.has_pad_step:  # trainer-parity row
            pieces.append(answer_logits[0, -1:, :])
        stacked = mx.concatenate([p.reshape(-1, p.shape[-1]) for p in pieces], axis=0)
        mx.eval(stacked)
        out = self._nats(stacked, plan.targets)

        del answer_logits, stacked, last_prompt_row, cache
        mx.clear_cache()
        return out


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------


# The files mlx_lm's `load_adapters` actually reads out of an --adapter dir:
# the LoRA weights, and the config that decides how they are applied (rank,
# scale, which layers). Both change what the forward pass computes, so both go
# into the digest. A third file dropped in the directory does not.
ADAPTER_WEIGHTS_NAME = "adapters.safetensors"
ADAPTER_CONFIG_NAME = "adapter_config.json"
ADAPTER_DIGEST_FILES = (ADAPTER_WEIGHTS_NAME, ADAPTER_CONFIG_NAME)
_DIGEST_BLOCK = 1 << 20


def file_sha256(path: Path) -> str:
    """Streaming sha256 of one file. Constant memory, no model, no GPU."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(_DIGEST_BLOCK), b""):
            h.update(block)
    return h.hexdigest()


def adapter_content_digest(adapter_path: str | Path | None) -> str | None:
    """A fingerprint of the adapter's CONTENT, not of where it happens to sit.

    A path is not an identity. ``models/candidates/fin-foreman-e4b-mlx`` gets a
    new ``adapters.safetensors`` every 250 iterations, and the staging recipe in
    run_bits_experiment.sh deliberately copies checkpoints over one reused
    directory. So a run keyed on the path alone can be killed at row 1200,
    resumed after the file underneath changed, and append the rest of the corpus
    under different weights -- one score file, two models, one name, and
    ``learned_bits = bits_base - bits_tuned`` a difference of two incommensurable
    quantities for half the rows, with nothing downstream able to see it.

    FULL STREAMING SHA-256, not a size+mtime shortcut. Measured on this repo's
    real adapter (27,683,964 bytes): ~14 ms. That is nothing against a scoring
    run that spends minutes per stage on the GPU, and the shortcut would have
    been actively wrong here -- mtime is not content (``touch`` changes it
    without changing the weights; ``cp -p`` changes the weights without changing
    it), and consecutive LoRA checkpoints are byte-identical in size, so
    size+mtime is exactly the discriminator this hazard defeats.

    Deterministic and path-independent by construction: only file NAMES, SIZES
    and CONTENT are mixed in, in a fixed order. The same checkpoint staged at two
    different paths digests the same (correct -- it is the same measurement);
    two different checkpoints staged at one path digest differently (the whole
    point). Returns None for a base run, which has no adapter.
    """
    if adapter_path is None:
        return None
    p = Path(adapter_path)
    if p.is_dir():
        parts = []
        for name in ADAPTER_DIGEST_FILES:
            f = p / name
            if not f.is_file():
                raise SystemExit(
                    f"[score_bits] --adapter {p} has no {name}. mlx_lm loads exactly "
                    f"{list(ADAPTER_DIGEST_FILES)} out of an adapter directory; a "
                    "directory missing one of them would fail at load time anyway, and "
                    "fingerprinting it would record an adapter that was never applied."
                )
            parts.append((name, f.stat().st_size, file_sha256(f)))
    elif p.is_file():
        # REFUSED, not tolerated. It reads as unambiguous -- one named weights
        # file -- but the loader cannot take it: MLXScorer calls
        # mlx_lm.load(model, adapter_path=...), which reads adapter_config.json
        # out of a DIRECTORY. Digesting the file would fingerprint a
        # configuration that cannot run, and the fingerprint would then describe
        # something no row was ever scored under. Resolving it to its parent
        # silently is worse: the operator named a file, and the parent may hold a
        # config they never looked at. So: name the directory.
        hint = (
            f" Pass the directory instead: --adapter {p.parent}"
            if p.name in ADAPTER_DIGEST_FILES
            and all((p.parent / n).is_file() for n in ADAPTER_DIGEST_FILES)
            else " Pass the adapter DIRECTORY -- the one holding "
            f"{list(ADAPTER_DIGEST_FILES)}."
        )
        raise SystemExit(
            f"[score_bits] --adapter {p} is a file. mlx_lm's load(..., adapter_path=...) "
            f"loads {list(ADAPTER_DIGEST_FILES)} out of a DIRECTORY and would fail on "
            "this path, so fingerprinting it would record an adapter that can never be "
            "applied." + hint
        )
    else:
        raise SystemExit(f"[score_bits] --adapter {p} does not exist")
    h = hashlib.sha256()
    for name, size, digest in parts:
        h.update(f"{name}\0{size}\0{digest}\0".encode("utf-8"))
    return "sha256:" + h.hexdigest()


def run_fingerprint(
    model_label: str,
    adapter_label: str | None,
    max_seq_length: int,
    match_trainer: bool,
    full_forward: bool,
    chunk: int | None = None,
    adapter_digest: str | None = None,
) -> dict:
    """The settings a bits number is only comparable WITHIN.

    Stored on every row so a resumed run cannot silently splice rows scored
    under a different model, adapter, window or forward path into one file --
    which would make ``learned_bits = base - tuned`` a difference of two
    incommensurable quantities for half the corpus.

    ``chunk`` is part of the forward path, not a performance knob: different
    prefill boundaries mean different matmul shapes and, on a sliding-window
    architecture, different rotating-cache eviction points, so the same example
    at ``--chunk 512`` and ``--chunk 2048`` yields numerically different nats.
    It is recorded as None under ``--full-forward``, where the prompt is never
    split and the value genuinely has no effect -- so the fingerprint names the
    forward path that was actually taken rather than a flag that was ignored.

    ``adapter`` is the resolved path -- for humans, and for the base/tuned
    direction check. ``adapter_digest`` is the one that identifies the WEIGHTS
    (see ``adapter_content_digest``); the path is what the operator typed, the
    digest is what the GPU actually loaded, and only the second survives a
    checkpoint being copied over a reused directory mid-run.
    """
    return {
        "model": model_label,
        "adapter": adapter_label,
        "adapter_digest": adapter_digest,
        "max_seq_length": max_seq_length,
        "match_trainer": match_trainer,
        "full_forward": full_forward,
        "chunk": None if full_forward else chunk,
    }


# The fingerprint keys that must agree between a --base file and a --tuned file
# for `learned_bits = bits_base - bits_tuned` to be a difference of commensurable
# quantities. `adapter` and `adapter_digest` are excluded on purpose: they are
# the two things that MUST differ between the two runs. They are not unchecked,
# though -- select_curriculum.check_pair_adapters asserts they differ in the one
# direction that is valid (base has neither, tuned has both).
PAIR_FINGERPRINT_KEYS = ("model", "max_seq_length", "match_trainer", "full_forward", "chunk")
ADAPTER_FINGERPRINT_KEYS = ("adapter", "adapter_digest")


def score_example(
    example: Example,
    tokens: Sequence[int],
    offset: int,
    max_seq_length: int,
    match_trainer: bool,
    scorer: Any,
    model_label: str,
    adapter_label: str | None,
    decision_fields: Sequence[str] | None = None,
    full_forward: bool = False,
    chunk: int | None = None,
    adapter_digest: str | None = None,
) -> dict:
    """Score one example. ``decision_fields=None`` means AUTO: resolve the
    decision fields from the example's own track (DECISION_FIELDS_BY_TARGET).
    An explicit sequence overrides that for every track; an empty one disables
    the column."""
    fields = decision_fields_for(example.target, decision_fields)
    plan = plan_mask(tokens, offset, max_seq_length, match_trainer=match_trainer)
    record: dict[str, Any] = {
        "index": example.index,
        "hash": example.hash,
        "target": example.target,
        "decision_class": example.decision,
        "length": plan.length,
        "offset": plan.offset,
        "answer_tokens": plan.answer_tokens,
        "trainer_tokens": plan.trainer_tokens,
        "truncated": plan.truncated,
        "tokens_lost": plan.tokens_lost,
    }
    record.update(
        run_fingerprint(
            model_label, adapter_label, max_seq_length, match_trainer, full_forward, chunk,
            adapter_digest,
        )
    )
    record["decision_fields"] = list(fields)
    if not plan.usable:
        record.update(
            {
                "skipped": True,
                "note": plan.note,
                "nats": None,
                "bits": None,
                "bits_per_token": None,
                "trainer_nats": None,
                "trainer_bits": None,
                "decision_bits": None,
                "decision_tokens": 0,
                "decision_ok": False,
            }
        )
        return record

    nats = scorer.row_nats(tokens, plan)
    answer_nats, trainer_nats = split_nats(plan, nats, match_trainer)
    bits = bits_from_nats(answer_nats)
    record.update(
        {
            "skipped": False,
            "nats": answer_nats,
            "bits": bits,
            "bits_per_token": bits / plan.answer_tokens if plan.answer_tokens else None,
            "trainer_nats": trainer_nats,
            "trainer_bits": bits_from_nats(trainer_nats),
        }
    )

    # The decision subset of the answer. Null, never zero, when it cannot be
    # located: a zero here would rank exactly like an example the model knows.
    keep = None
    if fields and hasattr(scorer, "decode"):
        keep = decision_indices(plan, tokens, example.answer_text, fields, scorer.decode)
    if keep:
        record["decision_bits"] = bits_from_nats(float(sum(nats[i] for i in keep)))
        record["decision_tokens"] = len(keep)
        record["decision_ok"] = True
    else:
        record["decision_bits"] = None
        record["decision_tokens"] = 0
        record["decision_ok"] = False

    if plan.note:
        record["note"] = plan.note
    return record


def decision_coverage(examples: Sequence[Example], override: Sequence[str] | None) -> dict:
    """How much of a corpus the decision column CAN cover, without a GPU.

    ``field_spans`` is pure text work, so the answer is knowable in seconds --
    before two multi-hour scoring stages, not after. This exists because the
    opposite happened: a flat ``action,session`` default was empty for 48.7% of
    the corpus, ``select_curriculum.py`` correctly refused past 20% missing, and
    the refusal landed at stage 3 with the entire GPU cost already spent.

    It is an UPPER bound on what scoring will produce: tokenization can still
    fail to locate a span (a truncated answer, a decode that does not round
    trip). A corpus that fails here cannot possibly pass there.
    """
    per_target: dict[str, dict[str, int]] = {}
    missing: list[int] = []
    for e in examples:
        fields = decision_fields_for(e.target, override)
        bucket = per_target.setdefault(e.target, {"n": 0, "covered": 0})
        bucket["n"] += 1
        if fields and field_spans(e.answer_text, fields):
            bucket["covered"] += 1
        else:
            missing.append(e.index)
    n = len(examples)
    return {
        "examples": n,
        "covered": n - len(missing),
        "missing": len(missing),
        "missing_share": len(missing) / n if n else 1.0,
        "per_target": per_target,
        "missing_indices": missing[:20],
    }


def summarize(rows: Iterable[dict]) -> dict:
    rows = list(rows)
    scored = [r for r in rows if not r.get("skipped")]
    truncated = [r for r in rows if r.get("truncated")]
    skipped = [r for r in rows if r.get("skipped")]
    total_bits = sum(r["bits"] for r in scored)
    total_tokens = sum(r["answer_tokens"] for r in scored)
    trainer_tokens = sum(r["trainer_tokens"] for r in scored)
    trainer_nats = sum(r["trainer_nats"] for r in scored)
    with_decision = [r for r in scored if r.get("decision_bits") is not None]
    decision_bits = sum(r["decision_bits"] for r in with_decision)
    return {
        "examples": len(rows),
        "scored": len(scored),
        "skipped": len(skipped),
        "truncated": len(truncated),
        "total_bits": total_bits,
        "total_answer_tokens": total_tokens,
        "mean_bits_per_example": total_bits / len(scored) if scored else 0.0,
        "mean_bits_per_token": total_bits / total_tokens if total_tokens else 0.0,
        # The gate-scored slice: how much of the corpus's surprise is in the
        # fields evals/tmux-routing actually compares.
        "decision_scored": len(with_decision),
        "total_decision_bits": decision_bits,
        "decision_share_of_bits": decision_bits / total_bits if total_bits else 0.0,
        "mean_decision_tokens": (
            sum(r["decision_tokens"] for r in with_decision) / len(with_decision)
            if with_decision
            else 0.0
        ),
        # token-weighted mean nats, directly comparable to a logged VALIDATION
        # loss (trainer.py:206-213). The TRAIN loss line is an unweighted mean of
        # per-batch means, so do not compare it to this without care.
        "trainer_parity_loss_nats": trainer_nats / trainer_tokens if trainer_tokens else 0.0,
        "mean_trainer_tokens": trainer_tokens / len(scored) if scored else 0.0,
    }


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default="mlx-community/gemma-4-E4B-it-qat-4bit")
    p.add_argument("--data", required=True, help="JSONL corpus with a 'messages' key per line")
    p.add_argument(
        "--adapter",
        default=None,
        help="LoRA adapter dir; omit for bits_base. Its CONTENT is hashed "
        "(adapters.safetensors + adapter_config.json, streaming sha256, ~14 ms) and "
        "stamped on every row as adapter_digest, so a resume cannot append rows scored "
        "under a checkpoint that has since been copied over this same path.",
    )
    p.add_argument("--out", required=True, help="JSONL output, one record per example (appended)")
    p.add_argument("--max-seq-length", type=int, default=3072)
    p.add_argument("--chunk", type=int, default=512, help="prompt prefill chunk size")
    p.add_argument("--chat-key", default="messages")
    p.add_argument("--limit", type=int, default=0, help="score only the first N examples (0 = all)")
    p.add_argument("--min-free-gb", type=float, default=MIN_FREE_GB_DEFAULT)
    p.add_argument(
        "--no-match-trainer",
        action="store_true",
        help="skip the trailing <pad> step; primary answer bits are unaffected",
    )
    p.add_argument(
        "--full-forward",
        action="store_true",
        help="one un-cached forward per example (what the trainer does); slow, for parity checks",
    )
    p.add_argument("--restart", action="store_true", help="ignore and overwrite an existing --out")
    p.add_argument(
        "--decision-fields",
        default=DECISION_FIELDS_AUTO,
        help="answer fields whose tokens get their own bits column (decision_bits). "
        "'auto' (default) resolves them PER TRACK from DECISION_FIELDS_BY_TARGET -- "
        "routing action,session; elicit action; ledger decision,goal_id,message_id; "
        "tooluse tool,arguments -- which is the only setting that covers all four "
        "tracks (a flat 'action,session' is empty for 48.7% of the corpus). Pass a "
        "comma-separated list to override every track at once; empty disables the column.",
    )
    p.add_argument(
        "--allow-unverified-machine",
        action="store_true",
        help="proceed when pgrep/vm_stat cannot be read. Only if you KNOW the box is idle.",
    )
    p.add_argument(
        "--check-decision-coverage",
        type=float,
        default=None,
        metavar="MIN_SHARE",
        help="preflight, no GPU and no tokenizer: report what share of the corpus the "
        "--decision-fields setting can cover and exit 3 if it is below MIN_SHARE. Run "
        "this BEFORE the scoring stages -- the selector's own >20%%-missing refusal "
        "otherwise fires at stage 3, with every GPU hour already spent.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="tokenize and report lengths/offsets/truncation; never loads the model, "
        "never touches the GPU, and so runs even while a fine-tune holds the machine",
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    data = Path(args.data)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    match_trainer = not args.no_match_trainer

    examples = read_corpus(data, args.chat_key)
    if args.limit:
        examples = examples[: args.limit]
    print(f"[score_bits] {len(examples)} examples from {data}", file=sys.stderr)

    # None = auto (per-track); a list = an explicit override for every track.
    if args.decision_fields.strip().lower() == DECISION_FIELDS_AUTO:
        decision_fields: tuple[str, ...] | None = None
    else:
        decision_fields = tuple(f.strip() for f in args.decision_fields.split(",") if f.strip())
    adapter_label = str(Path(args.adapter).resolve()) if args.adapter else None
    # Hashed BEFORE the guard and before any weights load: it costs ~14 ms on a
    # 27.7 MB adapter, it is the thing the resume check is keyed on, and a
    # malformed --adapter dir should be refused here rather than three GPU
    # minutes later.
    digest = adapter_content_digest(args.adapter)
    want = run_fingerprint(
        args.model, adapter_label, args.max_seq_length, match_trainer, args.full_forward,
        args.chunk, digest,
    )
    if digest:
        print(f"[score_bits] adapter {adapter_label} -> {digest}", file=sys.stderr)

    if args.check_decision_coverage is not None:
        # Pure text work: no tokenizer, no weights, no guard needed. Safe to run
        # while a fine-tune holds the machine, which is the whole point.
        cov = decision_coverage(examples, decision_fields)
        print(json.dumps(cov, indent=2, sort_keys=True))
        if cov["missing_share"] > 1.0 - args.check_decision_coverage:
            print(
                f"[score_bits] decision-field coverage is "
                f"{(1 - cov['missing_share'])*100:.1f}%, below the required "
                f"{args.check_decision_coverage*100:.1f}%. Scoring would produce a "
                "decision_bits column that select_curriculum.py refuses. Fix "
                "--decision-fields (or DECISION_FIELDS_BY_TARGET) first; do NOT spend "
                "the GPU stages on it.",
                file=sys.stderr,
            )
            return 3
        print(
            f"[score_bits] decision-field coverage {(1 - cov['missing_share'])*100:.1f}% "
            "-- the decision column is viable on this corpus",
            file=sys.stderr,
        )
        return 0

    done: set[str] = set()
    if args.restart and out.exists():
        out.unlink()
    else:
        prior, torn = read_scored(out)
        # Resume is keyed on content hash, so a file appended to under different
        # flags would mix incommensurable conditions under one name. Refuse.
        for r in prior:
            got = {k: r.get(k) for k in want}
            if any(k in r for k in want) and got != want:
                differs = {k: (got[k], want[k]) for k in want if got[k] != want[k]}
                note = ""
                if "adapter_digest" in differs:
                    old, new = differs["adapter_digest"]
                    if "adapter_digest" not in r:
                        note = (
                            " Those rows were written by a scorer that recorded no adapter "
                            "digest, so which weights produced them cannot be established. "
                            "Re-score; do not extend them."
                        )
                    else:
                        note = (
                            " The ADAPTER'S CONTENT changed under the same path "
                            f"({want['adapter']}): those rows were scored under {old}, this "
                            f"run loads {new}. Appending would put two models in one file "
                            "under one name."
                        )
                print(
                    f"[score_bits] refusing to resume {out}: it holds rows scored under "
                    f"different settings {differs}.{note} Point --out at a new file, or pass "
                    "--restart to overwrite.",
                    file=sys.stderr,
                )
                return 2
        done = {r["hash"] for r in prior if "hash" in r}
        if torn:
            with out.open("w", encoding="utf-8") as fh:
                for r in prior:
                    fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
            print("[score_bits] repaired a torn tail in the output file", file=sys.stderr)
        if done:
            print(f"[score_bits] resuming: {len(done)} already scored", file=sys.stderr)

    todo = [e for e in examples if e.hash not in done]
    if not todo:
        print("[score_bits] nothing to do", file=sys.stderr)
        prior, _ = read_scored(out)
        print(json.dumps(summarize(prior), indent=2, sort_keys=True))
        return 0

    if args.dry_run:
        # A dry run loads no weights and allocates nothing on the GPU -- but
        # reaching the TokenizerWrapper means `import mlx_lm`, which pulls in
        # mlx.core and initialises the Metal device. That is the one path in
        # this file that touches the Metal runtime, so it takes the PROCESS half
        # of the guard: no fine-tune may be live. The free-memory half is
        # skipped, because nothing here will be allocated. This is a one-minute
        # tokenizer pass; it waits its turn like everything else.
        guard(args.min_free_gb, allow_unverified=args.allow_unverified_machine, check_memory=False)

        # load_tokenizer resolves a repo id through the HF cache and returns the
        # TokenizerWrapper. No weights, no Metal allocation beyond the import.
        from mlx_lm.utils import load_tokenizer

        tokenizer = load_tokenizer(args.model)
        lengths, offsets, trainer, trunc = [], [], [], 0
        for e in todo:
            tokens, offset = chat_tokenize(tokenizer, e.messages, e.tools)
            plan = plan_mask(tokens, offset, args.max_seq_length, match_trainer)
            lengths.append(plan.length)
            offsets.append(plan.offset)
            trainer.append(plan.trainer_tokens)
            trunc += 1 if plan.truncated else 0
        print(
            json.dumps(
                {
                    "dry_run": True,
                    "examples": len(todo),
                    "max_length": max(lengths),
                    "mean_length": sum(lengths) / len(lengths),
                    "mean_offset": sum(offsets) / len(offsets),
                    "mean_answer_tokens": sum(l - o for l, o in zip(lengths, offsets)) / len(lengths),
                    # compare to the run's own "Trained Tokens / iter"
                    "mean_trainer_tokens": sum(trainer) / len(trainer),
                    "truncated": trunc,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    # Everything past here loads weights. The guard is the last thing before it.
    guard(args.min_free_gb, allow_unverified=args.allow_unverified_machine)

    scorer = MLXScorer(args.model, args.adapter, args.chunk, args.full_forward)

    written = 0
    with out.open("a", encoding="utf-8") as fh:
        for e in todo:
            tokens, offset = scorer.tokenize(e.messages, e.tools)
            record = score_example(
                e,
                tokens,
                offset,
                args.max_seq_length,
                match_trainer,
                scorer,
                args.model,
                adapter_label,
                decision_fields,
                args.full_forward,
                args.chunk,
                digest,
            )
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())  # resumable across a hard kill
            written += 1
            if written % 25 == 0:
                print(f"[score_bits] {written}/{len(todo)}", file=sys.stderr, flush=True)

    rows, _ = read_scored(out)
    stats = summarize(rows)
    meta = dict(want)
    meta.update(
        {
            "data": str(data.resolve()),
            "decision_fields": (
                {"mode": DECISION_FIELDS_AUTO, "by_target": {
                    k: list(v) for k, v in DECISION_FIELDS_BY_TARGET.items()
                }, "fallback": list(DECISION_FIELDS_FALLBACK)}
                if decision_fields is None
                else {"mode": "explicit", "fields": list(decision_fields)}
            ),
            "summary": stats,
        }
    )
    Path(str(out) + ".meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    if stats["scored"] and stats["decision_scored"] < stats["scored"]:
        print(
            f"[score_bits] NOTE: {stats['scored'] - stats['decision_scored']} of "
            f"{stats['scored']} scored rows have no decision_bits (fields absent, answer "
            "truncated, or the decode did not round-trip); they rank as unknown, not zero.",
            file=sys.stderr,
        )
    if stats["truncated"]:
        print(
            f"[score_bits] WARNING: {stats['truncated']} examples had their ANSWER cut by "
            f"--max-seq-length {args.max_seq_length}; their bits are a lower bound.",
            file=sys.stderr,
        )
    print(json.dumps(stats, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

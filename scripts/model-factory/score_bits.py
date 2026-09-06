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
    is the trailing PAD the batch padder always supplies, so the trainer's
    ``ntoks`` is ``L - offset + 1``, one more than the real answer. We report the
    honest ``answer`` count (``L - offset``) as the primary and the trainer's
    ``L - offset + 1`` as ``trainer_*`` so a port can be validated against a
    logged loss.

Guards. This refuses to touch the GPU while a fine-tune is in flight or while
free memory is below a threshold -- the same precondition as gate_sweep.sh,
because two models in 34 GB of unified memory is how the machine gets wedged.

Usage:
  score_bits.py --model mlx-community/gemma-4-E4B-it-qat-4bit \\
      --data datasets/mlx/train.jsonl --out reports/bits-train-base.jsonl
  score_bits.py ... --adapter models/candidates/fin-foreman-e4b-mlx \\
      --out reports/bits-train-tuned.jsonl

  --dry-run tokenizes and reports lengths/offsets/truncation without loading the
  model (still needs the tokenizer, still cheap, still respects the guard flag).

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
BUSY_EXIT = 75  # EX_TEMPFAIL, same code gate_sweep.sh uses when it refuses
MIN_FREE_GB_DEFAULT = 10

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
      is the trailing ``<pad>`` the batch padder guarantees. Only exists when the
      example is NOT truncated -- a truncated batch is exactly ``max_seq_length``
      wide with no pad column, so ``ntoks`` collapses to ``L' - offset``.
    """
    length = len(tokens)
    effective_length = min(length, max_seq_length)
    truncated = length > max_seq_length
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
        )

    positions = list(range(offset, effective_length))
    rows = [k - 1 for k in positions]
    targets = [tokens[k] for k in positions]
    answer_tokens = len(positions)
    trainer_tokens = answer_tokens if truncated else answer_tokens + 1

    if match_trainer and not truncated:
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
    )


def split_nats(plan: MaskPlan, nats: Sequence[float], match_trainer: bool) -> tuple[float, float]:
    """(answer_nats, trainer_nats) from the per-row nats ``plan`` asked for."""
    if len(nats) != len(plan.rows):
        raise ValueError(f"expected {len(plan.rows)} nats, got {len(nats)}")
    answer_nats = float(sum(nats[: plan.answer_tokens]))
    if match_trainer and not plan.truncated:
        trainer_nats = float(sum(nats))
    else:
        trainer_nats = answer_nats
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
# machine guard -- mirrors scripts/model-factory/gate_sweep.sh step 0
# ---------------------------------------------------------------------------

# Built by concatenation so this file's own text can never satisfy its own pgrep.
_TRAINING_PATTERN = "mlx_lm lo" + "ra"
_BUSY_PATTERNS = (_TRAINING_PATTERN, "mlx_lm server", "mlx_lm fuse", "mlx_lm generate")


def _pgrep(pattern: str) -> list[str]:
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in out.stdout.split() if line.strip()]


def free_gb() -> float:
    """Free + inactive pages, in GiB. Same arithmetic as gate_sweep.sh's awk."""
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return float("inf")  # not a Mac / no vm_stat: do not block on a number we cannot read
    page = re.search(r"page size of (\d+) bytes", out)
    page_size = int(page.group(1)) if page else 16384
    total = 0
    for label in ("Pages free", "Pages inactive"):
        m = re.search(rf"{label}:\s+(\d+)", out)
        if m:
            total += int(m.group(1))
    return total * page_size / (1024**3)


def guard(min_free: float, label: str = "score_bits") -> None:
    """Refuse to compete for the GPU. Exits BUSY_EXIT; never raises past main."""
    for pattern in _BUSY_PATTERNS:
        pids = _pgrep(pattern)
        if pids:
            print(
                f"[{label}] refusing to run: '{pattern}' is live (pid {' '.join(pids)}). "
                "Two models in 34 GB of unified memory is how the machine wedges.",
                file=sys.stderr,
            )
            sys.exit(BUSY_EXIT)
    have = free_gb()
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


def chat_tokenize(tokenizer, messages: Sequence[dict]) -> tuple[list[int], int]:
    """(tokens, offset) exactly as ``ChatDataset.process`` computes them under
    ``--mask-prompt``.

    ``tokenizer`` MUST be mlx-lm's ``TokenizerWrapper``: it forces
    ``return_dict=False`` and injects ``enable_thinking=True`` for a model whose
    vocab carries thinking markers. A raw HF tokenizer does neither, and both
    omissions silently change the token count.
    """
    tokens = tokenizer.apply_chat_template(messages, tools=None, return_dict=False)
    add_generation_prompt = messages[-1].get("role") == "assistant"
    prompt = tokenizer.apply_chat_template(
        messages[:-1],
        tools=None,
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

    def tokenize(self, messages: Sequence[dict]) -> tuple[list[int], int]:
        return chat_tokenize(self.tokenizer, messages)

    def _nats(self, logit_rows, targets) -> list[float]:
        mx = self.mx
        losses = self._cross_entropy(
            logit_rows.astype(mx.float32), mx.array(targets), reduction="none"
        )
        mx.eval(losses)
        return [float(v) for v in losses.tolist()]

    def row_nats(self, tokens: Sequence[int], plan: MaskPlan) -> list[float]:
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
        if len(plan.rows) > plan.answer_tokens:  # trainer-parity row
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


def score_example(
    example: Example,
    tokens: Sequence[int],
    offset: int,
    max_seq_length: int,
    match_trainer: bool,
    scorer: Any,
    model_label: str,
    adapter_label: str | None,
) -> dict:
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
        "model": model_label,
        "adapter": adapter_label,
    }
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
    if plan.note:
        record["note"] = plan.note
    return record


def summarize(rows: Iterable[dict]) -> dict:
    rows = list(rows)
    scored = [r for r in rows if not r.get("skipped")]
    truncated = [r for r in rows if r.get("truncated")]
    skipped = [r for r in rows if r.get("skipped")]
    total_bits = sum(r["bits"] for r in scored)
    total_tokens = sum(r["answer_tokens"] for r in scored)
    trainer_tokens = sum(r["trainer_tokens"] for r in scored)
    trainer_nats = sum(r["trainer_nats"] for r in scored)
    return {
        "examples": len(rows),
        "scored": len(scored),
        "skipped": len(skipped),
        "truncated": len(truncated),
        "total_bits": total_bits,
        "total_answer_tokens": total_tokens,
        "mean_bits_per_example": total_bits / len(scored) if scored else 0.0,
        "mean_bits_per_token": total_bits / total_tokens if total_tokens else 0.0,
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
    p.add_argument("--adapter", default=None, help="LoRA adapter dir; omit for bits_base")
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
        "--dry-run",
        action="store_true",
        help="tokenize and report lengths/offsets/truncation; never loads the model",
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

    done: set[str] = set()
    if args.restart and out.exists():
        out.unlink()
    else:
        prior, torn = read_scored(out)
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

    # The guard runs before anything touches the GPU. --dry-run still checks, so
    # a dry run is an honest rehearsal of the real invocation.
    guard(args.min_free_gb)

    if args.dry_run:
        # load_tokenizer resolves a repo id through the HF cache and returns the
        # TokenizerWrapper. No weights, no Metal allocation beyond the import.
        from mlx_lm.utils import load_tokenizer

        tokenizer = load_tokenizer(args.model)
        lengths, offsets, trunc = [], [], 0
        for e in todo:
            tokens, offset = chat_tokenize(tokenizer, e.messages)
            plan = plan_mask(tokens, offset, args.max_seq_length, match_trainer)
            lengths.append(plan.length)
            offsets.append(plan.offset)
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
                    "truncated": trunc,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    scorer = MLXScorer(args.model, args.adapter, args.chunk, args.full_forward)
    adapter_label = str(Path(args.adapter).resolve()) if args.adapter else None

    written = 0
    with out.open("a", encoding="utf-8") as fh:
        for e in todo:
            tokens, offset = scorer.tokenize(e.messages)
            record = score_example(
                e,
                tokens,
                offset,
                args.max_seq_length,
                match_trainer,
                scorer,
                args.model,
                adapter_label,
            )
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())  # resumable across a hard kill
            written += 1
            if written % 25 == 0:
                print(f"[score_bits] {written}/{len(todo)}", file=sys.stderr, flush=True)

    rows, _ = read_scored(out)
    stats = summarize(rows)
    meta = {
        "model": args.model,
        "adapter": adapter_label,
        "data": str(data.resolve()),
        "max_seq_length": args.max_seq_length,
        "match_trainer": match_trainer,
        "full_forward": args.full_forward,
        "summary": stats,
    }
    Path(str(out) + ".meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
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

#!/usr/bin/env python3
"""Validate ``score_bits.py``'s forward path. Two independent checks.

1. INTERNAL parity (two score files, positional args). This is the only check on
   ``MLXScorer.row_nats``'s chunked path -- the one that rebuilds logits rows
   positionally out of a prefill and an answer forward, never consults
   ``plan.rows``, and therefore cannot be reached by any stub-driven unit test.
   ``--full-forward`` reproduces the trainer's own single un-cached forward; the
   two must agree.

   The subtlety that makes this worth a file of its own rather than a heredoc: a
   comparison over an EMPTY intersection trivially agrees. If every example in
   the sample was skipped, or the two files came from different corpora or
   different adapters, a naive ``max(..., default=0.0)`` reports a perfect match
   over zero comparisons and the pipeline goes on to call every downstream
   number validated. So this refuses when the intersection is empty or
   incomplete, and prints the count it actually compared.

     parity_check.py CHUNKED.jsonl FULLFWD.jsonl [--tolerance 0.01] [--column bits]

2. EXTERNAL anchor (--anchor META.json --log train.log). Internal parity says
   the two forward paths agree with each other; it cannot say the MASK is the
   trainer's. For that the port needs a number this repo did not produce, and
   the live run's log holds exactly one that discriminates:

       Iter 1: Val loss 2.463

   ``trainer.py`` runs ``evaluate`` BEFORE the first ``step``, so that is the
   UNTUNED base's token-weighted loss over valid.jsonl under the trainer's own
   mask -- the same quantity ``score_bits.py --data valid.jsonl`` (no --adapter)
   writes to ``summary.trainer_parity_loss_nats``.

   Why THIS anchor and not the tail of the log: the late validation losses are
   0.005-0.028 and a memorized adapter's residual on the train split is ~0.01
   either way, so comparing those two near-zero numbers passes under a correct
   port AND under a broken one -- the same vacuity the empty-intersection guard
   exists to eliminate. At 2.463 nats/token there is dynamic range: dropping or
   adding one masked token moves the mean ~3%, and a prompt-masking error (the
   failure that matters, because it would silently score the prompt as if it
   were the answer) moves it by a large multiple.

   CAVEAT, and the reason the default tolerance is loose: the log's 2.463 is
   over ``--val-batches 25`` of the 118-example split, while the meta file
   covers all 118. So this check has the power to catch a mask that is wrong in
   KIND, not a mask that is wrong by one token. It says so in its own output
   rather than implying a precision it does not have.

     parity_check.py --anchor reports/bits-valid-base.jsonl.meta.json \\
         --log models/candidates/fin-foreman-e4b-mlx/train.log [--iter 1]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Sequence

# The tolerance the chunked path must meet. One number, used everywhere: a
# comment promising 1e-3 over code enforcing 1e-2 is a 10x gap on the check that
# decides whether the bits column is trustworthy at all.
TOLERANCE = 1e-2

# Relative tolerance for the external anchor. Wide on purpose: the log's number
# is a 25-batch sample of a 118-example split, so anything tighter would be
# measuring the sampling, not the mask. See the docstring.
ANCHOR_REL_TOLERANCE = 0.15

VAL_LOSS_RE = re.compile(r"Iter (\d+): Val loss ([0-9.]+)")


def load(path: Path, column: str) -> dict[str, float]:
    out: dict[str, float] = {}
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get(column) is None:
                continue
            out[rec["hash"]] = float(rec[column])
    return out


def compare(
    chunked: dict[str, float], full: dict[str, float], tolerance: float
) -> tuple[bool, str]:
    """(ok, message). Empty or partial overlap is a FAILURE, not a pass."""
    if not full:
        return False, "the full-forward file has no scored rows to compare against"
    missing = [h for h in full if h not in chunked]
    if missing:
        return False, (
            f"{len(missing)} of {len(full)} full-forward examples are absent from the "
            "chunked file: the two files are not describing the same run, so a match "
            "would mean nothing"
        )
    worst_hash, worst = "", 0.0
    for h, v in full.items():
        delta = abs(chunked[h] - v)
        if delta >= worst:
            worst_hash, worst = h, delta
    ok = worst < tolerance
    msg = (
        f"max |chunked - full| = {worst:.6f} bits over {len(full)} examples "
        f"(worst: {worst_hash}); tolerance {tolerance:g}"
    )
    return ok, msg


def val_losses(log_text: str) -> dict[int, float]:
    """``{iteration: val loss}`` from an mlx_lm lora training log."""
    return {int(i): float(v) for i, v in VAL_LOSS_RE.findall(log_text)}


def compare_anchor(
    meta: dict, log_text: str, iteration: int, rel_tolerance: float
) -> tuple[bool, str]:
    """(ok, message). Compare a score run's token-weighted loss against a
    validation loss the TRAINER recorded, which this repo did not produce.

    Refuses rather than passes when either side is missing: an anchor check that
    silently finds no anchor is the vacuous comparison this file exists to
    prevent.
    """
    losses = val_losses(log_text)
    if not losses:
        return False, "no 'Iter N: Val loss X' lines in the log -- nothing to anchor against"
    if iteration not in losses:
        return False, (
            f"the log has no Val loss at iteration {iteration} "
            f"(it has {sorted(losses)}); --iter names the one to use"
        )
    logged = losses[iteration]

    summary = (meta or {}).get("summary") or {}
    ours = summary.get("trainer_parity_loss_nats")
    if ours is None:
        return False, "the meta file has no summary.trainer_parity_loss_nats to compare"
    if meta.get("adapter") is not None and iteration == 1:
        return False, (
            f"the meta file was scored WITH an adapter ({meta['adapter']}), but "
            "'Iter 1: Val loss' is the UNTUNED base's loss -- trainer.py evaluates "
            "before the first step. Anchor a base-model score run, or pass the "
            "--iter of a checkpoint whose adapter this is."
        )

    delta = abs(ours - logged)
    rel = delta / logged if logged else float("inf")
    ok = rel <= rel_tolerance
    msg = (
        f"trainer_parity_loss_nats={ours:.4f} vs log 'Iter {iteration}: Val loss "
        f"{logged:.4f}' -> |delta|={delta:.4f} ({rel*100:.1f}%); "
        f"tolerance {rel_tolerance*100:.0f}%. NOTE: the log's number is a "
        "--val-batches sample, so this resolves a mask that is wrong in KIND "
        "(prompt scored as answer, whole answer masked out), not one that is "
        "off by a single token."
    )
    return ok, msg


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("chunked", nargs="?")
    p.add_argument("full_forward", nargs="?")
    p.add_argument("--tolerance", type=float, default=TOLERANCE)
    p.add_argument("--column", default="bits")
    p.add_argument("--anchor", help="a score run's .meta.json (external-anchor mode)")
    p.add_argument("--log", help="the trainer's train.log (external-anchor mode)")
    p.add_argument("--iter", type=int, default=1, help="which 'Iter N: Val loss' to anchor on")
    p.add_argument("--rel-tolerance", type=float, default=ANCHOR_REL_TOLERANCE)
    args = p.parse_args(argv)

    if bool(args.anchor) != bool(args.log):
        p.error("--anchor and --log go together")

    if args.anchor:
        ok, msg = compare_anchor(
            json.loads(Path(args.anchor).read_text(encoding="utf-8")),
            Path(args.log).read_text(encoding="utf-8", errors="replace"),
            args.iter,
            args.rel_tolerance,
        )
        print(f"[parity_check/anchor] {msg}", file=sys.stderr)
        if not ok:
            print(
                "[parity_check/anchor] FAILED -- the masking port does not reproduce a "
                "loss the TRAINER itself recorded. Internal chunked-vs-full parity cannot "
                "catch this: both paths would be wrong in the same way.",
                file=sys.stderr,
            )
        return 0 if ok else 1

    if not (args.chunked and args.full_forward):
        p.error("give two score files, or --anchor META.json --log train.log")

    ok, msg = compare(
        load(Path(args.chunked), args.column),
        load(Path(args.full_forward), args.column),
        args.tolerance,
    )
    print(f"[parity_check] {msg}", file=sys.stderr)
    if not ok:
        print("[parity_check] FAILED -- the chunked path is not reproducing the "
              "trainer's forward; every bits number from it is suspect.", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

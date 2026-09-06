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

     parity_check.py CHUNKED.jsonl FULLFWD.jsonl [--tolerance REL] [--column bits]

   The tolerance is RELATIVE (with an absolute floor) and its default is
   deliberately not a gate: no GPU parity run has ever been made against this
   code, so the observed divergence is reported prominently and only a coarse
   wrong-in-KIND ceiling is enforced until an operator sets --tolerance from a
   real number. The long argument is in the constants block below.

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

# --------------------------------------------------------------------------
# The tolerance, and why it is RELATIVE and why its default is not a gate.
#
# What is being compared: an un-cached single forward, and a chunked prefill
# through a rotating KV cache, on a 4-bit-quantised model with bf16 activations.
# Those are two different sequences of floating-point operations over the same
# mathematics. score_bits.py's own comments concede the point -- different chunk
# boundaries mean different matmul shapes and different cache eviction points,
# and therefore numerically different nats. Some disagreement is EXPECTED. The
# check's job is to separate that from a chunked path that is assembling the
# wrong rows.
#
# The previous rule was TOLERANCE = 1e-2, an ABSOLUTE bound on a per-example SUM
# of bits, and it hard-gated the pipeline. The scale it was applied at, derived
# from the live training log (models/candidates/fin-foreman-e4b-mlx/train.log):
#
#     Iter 1: Val loss 2.463                      nats per unmasked token
#     Iter 3675: ... Trained Tokens 127129        => 127129/3675 = 34.6 unmasked
#                                                   tokens per optimizer step
#     2.463 x 34.6 = 85.2 nats = 123 bits per example
#
# (Those are the trainer's numbers for its own batches, not a parity run's; with
# --grad-accumulation-steps 2 a step may cover two examples, which halves the
# per-example figure. Either way the example is of order 10^2 bits.) Against
# ~123 bits, 1e-2 bits is ~8e-5 RELATIVE -- about 2.4e-6 nats per token. But a
# per-token disagreement of 1e-3 nats, unremarkable for this arithmetic, sums to
# 34.6 x 1e-3 = 0.035 nats = 0.05 bits: FIVE TIMES the old bound, and ~4e-4 in
# relative terms. So the old rule was likelier to fail on float noise than on a
# bug -- and a check that cries wolf on its first honest run gets loosened by
# whoever is holding the pipeline at 2am, which is worse than no check at all.
#
# The rule now: relative error, with an absolute floor.
#
#     error(h) = |chunked[h] - full[h]| / max(|full[h]|, ABS_FLOOR_BITS)
#
# Relative, because the quantity being compared spans orders of magnitude: a
# base-model example is ~10^2 bits and a memorized tuned example is ~10^-2, and
# one absolute bound cannot be right for both. Floored, because below ~1 bit the
# model is essentially certain and the ratio stops carrying information -- a
# 0.001-bit wobble on a 0.05-bit example is not a 2% error in any meaningful
# sense, it is the last digit of a number that is zero.
#
# AWAITING CALIBRATION. No GPU parity run has ever been made against this code
# (see the README's "never run" list), so nobody knows what these two paths
# actually agree to. Rather than invent a number and call it a bound, the default
# refuses to pretend: it enforces only UNCALIBRATED_CEILING, deliberately coarse,
# and reports the observed maximum prominently so the first real run produces the
# number that a real gate can be set from. Pass --tolerance once you have it.
#
# What would make this meaningful: one run of stage 1c/2b on the GPU, the
# reported "max relative divergence" written down, and --tolerance set a small
# multiple above it (in run_bits_experiment.sh, so the gate travels with the
# pipeline). Until then this check resolves a chunked path that is wrong in KIND
# -- off-by-one rows, the wrong cache, the prompt scored as the answer -- and
# says so in its own output rather than implying a precision it does not have.
# --------------------------------------------------------------------------

# Below this many bits an example is judged by absolute difference against the
# floor instead of by ratio. See above.
ABS_FLOOR_BITS = 1.0

# The default, uncalibrated bound: relative. Coarse ON PURPOSE. Two orders of
# magnitude above the ~4e-4 relative that a 1e-3 nats/token disagreement implies
# at this corpus's scale, and far below anything a mis-assembled row could
# produce (a wrong row is a different token's logprob, which moves an example's
# bits by tens of percent). It is an order-of-magnitude argument, not a
# measurement, and it is not a substitute for --tolerance.
UNCALIBRATED_CEILING = 5e-2

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
    chunked: dict[str, float],
    full: dict[str, float],
    tolerance: float | None = None,
    abs_floor: float = ABS_FLOOR_BITS,
) -> tuple[bool, str]:
    """(ok, message). Empty or partial overlap is a FAILURE, not a pass.

    ``tolerance`` is a RELATIVE bound, applied as
    ``|chunked - full| / max(|full|, abs_floor)``; see the block at the top of
    this file for why it is relative and why the default is not a real gate.
    ``None`` means the uncalibrated default, ``UNCALIBRATED_CEILING``.
    """
    if not full:
        return False, "the full-forward file has no scored rows to compare against"
    missing = [h for h in full if h not in chunked]
    if missing:
        return False, (
            f"{len(missing)} of {len(full)} full-forward examples are absent from the "
            "chunked file: the two files are not describing the same run, so a match "
            "would mean nothing"
        )
    bound = UNCALIBRATED_CEILING if tolerance is None else tolerance
    worst_hash, worst_rel, worst_abs, worst_scale = "", -1.0, 0.0, 0.0
    biggest_abs = 0.0
    for h, v in full.items():
        delta = abs(chunked[h] - v)
        biggest_abs = max(biggest_abs, delta)
        scale = max(abs(v), abs_floor)
        rel = delta / scale
        # Rank on the RELATIVE error, because that is what the bound is on. The
        # largest absolute gap is reported too, but it is the biggest EXAMPLE
        # about as often as it is the biggest error.
        if rel >= worst_rel:
            worst_hash, worst_rel, worst_abs, worst_scale = h, rel, delta, scale
    ok = worst_rel < bound
    msg = (
        f"max relative divergence {worst_rel:.3e} over {len(full)} examples "
        f"(worst: {worst_hash}, |chunked - full| = {worst_abs:.6f} bits against a "
        f"{worst_scale:.4f}-bit example); largest absolute gap anywhere "
        f"{biggest_abs:.6f} bits; bound {bound:g} relative"
        + (" (UNCALIBRATED default)" if tolerance is None else " (--tolerance)")
        + f", absolute floor {abs_floor:g} bits"
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
    p.add_argument(
        "--tolerance",
        type=float,
        default=None,
        help="max RELATIVE divergence |chunked-full|/max(|full|,--abs-floor) to accept. "
        f"Omitted = uncalibrated: enforce only the coarse {UNCALIBRATED_CEILING:g} ceiling, "
        "report the observed maximum, and say plainly that it is not a calibrated gate. "
        "Set this from a real run's reported number; see the block at the top of this file.",
    )
    p.add_argument(
        "--abs-floor",
        type=float,
        default=ABS_FLOOR_BITS,
        help="bits below which an example is judged against this floor instead of by "
        "ratio (a memorized tuned example is ~0.05 bits; a ratio there is meaningless)",
    )
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
        args.abs_floor,
    )
    print(f"[parity_check] {msg}", file=sys.stderr)
    if not ok:
        print("[parity_check] FAILED -- the chunked path is not reproducing the "
              "trainer's forward; every bits number from it is suspect.", file=sys.stderr)
    elif args.tolerance is None:
        # Loud on a PASS, because an uncalibrated pass is the one that gets
        # mistaken for a validated one.
        print(
            "[parity_check] NOT CALIBRATED. No GPU parity run has ever been made "
            f"against this code, so {UNCALIBRATED_CEILING:g} is an order-of-magnitude "
            "ceiling, not a measured bound: it resolves a chunked path that is wrong in "
            "KIND (rows off by one, the wrong cache, the prompt scored as the answer), "
            "not one that is off by a little. This run did NOT validate the bits column "
            "to any stated precision. Write the 'max relative divergence' above into "
            "run_bits_experiment.sh as --tolerance (a small multiple of it) to turn this "
            "into a gate that means something.",
            file=sys.stderr,
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

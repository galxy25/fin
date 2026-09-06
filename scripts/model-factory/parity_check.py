#!/usr/bin/env python3
"""Validate ``score_bits.py``'s forward path. Two independent checks.

1. INTERNAL parity (two score files, positional args). This is the only check on
   ``MLXScorer.row_nats``'s chunked path -- the one that rebuilds logits rows
   positionally out of a prefill and an answer forward, never consults
   ``plan.rows``, and therefore cannot be reached by any stub-driven unit test.
   ``--full-forward`` reproduces the trainer's own single un-cached forward; the
   two must agree.

   The subtlety that makes this worth a file of its own rather than a heredoc: a
   comparison that agrees for the wrong reason. An EMPTY intersection agrees
   perfectly over zero examples. So does a file compared against a copy of
   itself. So does a bound so wide it could not fail. Each of those "passes"
   licenses every downstream number, so each is refused by name here:

     * empty or partial overlap -> refused (this file, ``compare``);
     * the two files not scored under the same model / adapter / window, or
       scored under the SAME forward path -> refused (``check_parity_fingerprints``);
     * a bound that stops discriminating as the numbers shrink -> the tolerance
       rule is per TOKEN, and the report says how much resolving power was left
       (the block below).

     parity_check.py CHUNKED.jsonl FULLFWD.jsonl
         [--tolerance REL] [--per-token-bits B] [--column bits]

   The bound is two-sided -- relative for large examples, per-token for small --
   and its default is deliberately not a gate: no GPU parity run has ever been
   made against this code, so the observed divergence is reported prominently
   and only a coarse wrong-in-KIND ceiling is enforced until an operator sets
   both halves from a real number. The long argument is in the constants block
   below.

   Exit codes: 0 agree, 1 diverged (or the comparison was vacuous), 2 the two
   files are not a parity pair at all.

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
import math
import re
import sys
from pathlib import Path
from typing import NamedTuple, Sequence

# --------------------------------------------------------------------------
# The tolerance: what it bounds, why it is PER TOKEN, and why its default is
# not yet a gate.
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
# WHERE THE ERROR COMES FROM, AND THEREFORE WHAT TO BOUND. The compared column
# is a SUM over an example's tokens: bits(h) = sum_i bits_i. The two paths
# differ per TOKEN, and those per-token differences accumulate with the number
# of tokens summed -- not with the size of the number that comes out. The
# invariant quantity is therefore bits per token,
#
#     per_token(h) = |chunked[h] - full[h]| / n_tokens(h)
#
# under which a 0.05-bit gap on a 35-token example is exactly as suspicious as a
# 0.5-bit gap on a 350-token one. No bound on the per-example sum alone can say
# that, because the sum does not know how many tokens it is a sum over.
#
# THE SCALE, from the live training log
# (models/candidates/fin-foreman-e4b-mlx/train.log):
#
#     Iter 1: Val loss 2.463                      nats per unmasked token
#     Iter 3675: ... Trained Tokens 127129        => 127129/3675 = 34.6 unmasked
#                                                   tokens per optimizer step
#     2.463 x 34.6 = 85.2 nats = 123 bits per example, at 3.55 bits/token
#
# (Those are the trainer's numbers for its own batches, not a parity run's; with
# --grad-accumulation-steps 2 a step may cover two examples, which halves the
# per-example figure. Either way the base example is of order 10^2 bits and the
# tuned one, after this adapter memorized the train split, of order 10^-2.)
#
# THE RULE THIS REPLACES, and why it stopped discriminating. It was
#
#     error(h) = |chunked - full| / max(|full|, ABS_FLOOR_BITS=1.0)  <  5e-2
#
# and for any example at or below the 1-bit floor that collapses to a FIXED
# allowance of 5e-2 x 1.0 = 0.05 bits -- whatever the example scored, and
# whatever its length. Two consequences, pointing in opposite directions:
#
#   * VACUOUS exactly where the numbers get small, which is the tuned arm the
#     curriculum subtracts. A memorized example is ~0.05 bits, so the allowance
#     IS the whole example: the chunked path could report 0.0 bits or 0.10 bits
#     for it and pass. Further down the allowance exceeds the number entirely.
#   * SIMULTANEOUSLY TOO TIGHT at the typical length. 0.05 bits spread over this
#     corpus's 34.6 answer tokens is 1.44e-3 bits/token = 1.00e-3 nats/token --
#     precisely the per-token disagreement this file calls unremarkable for this
#     arithmetic, with NO margin. On a 350-token example the same fixed 0.05
#     bits demands 10x BETTER per-token agreement; on a 3-token example it is
#     10x looser -- wide enough to swallow a whole mis-assembled row.
#
# Length generates the disagreement, and length is the one thing a per-example
# floor cannot see.
#
# THE RULE NOW. Two-sided; each example is judged by whichever half is more
# permissive for it -- relative at the large end, per-token at the small end:
#
#     allowance(h) = max( REL x |full[h]| , PER_TOKEN_BITS x n_tokens(h) )
#     pass  iff  |chunked[h] - full[h]| < allowance(h),  for EVERY h
#
#   * The RELATIVE half carries the large end. A base example is ~123 bits, so
#     5e-2 relative is ~6 bits of room -- generous against float noise (~0.05
#     bits) and still far inside what a mis-assembled row costs, since a wrong
#     row is a different token's logprob and moves an example by tens of
#     percent.
#   * The PER-TOKEN half carries the small end, and unlike a picked floor its
#     size is an argument rather than a number: the two paths are expected to
#     disagree by ~1e-3 nats/token = 1.44e-3 bits/token, so the uncalibrated
#     allowance is 5e-3 bits/token, ~3.5x the expected noise -- at EVERY length,
#     which is the property the fixed floor lacked. For the 35-token tuned
#     example that is 0.175 bits: an honest float wobble (~0.05 bits) passes
#     with 3.5x of room, while one mis-assembled row costs about the base
#     model's own per-token surprise, ~3.5 bits, and fails by 20x. Under the old
#     fixed floor that same wobble sat exactly ON the bound -- a coin flip.
#
# WHAT THIS STILL CANNOT DO, said out loud rather than papered over. A memorized
# tuned example carries ~0.05 bits over ~35 tokens = ~1.4e-3 bits/token, which
# is the arithmetic noise floor itself. At that scale NO bound on a per-example
# bits sum can separate signal from float noise: the honest statement is that
# the check resolves a divergence wrong in KIND there and nothing finer. So the
# report counts the examples whose allowance exceeded their own bits and says
# so, per run, instead of implying a precision it does not have.
#
# AWAITING CALIBRATION. No GPU parity run has ever been made against this code
# (see the README's "never run" list), so nobody knows what these two paths
# actually agree to. Rather than invent numbers and call them bounds, both
# halves default to deliberately coarse uncalibrated values, the observed
# maxima for BOTH are reported prominently, and a pass says loudly that it is
# not a calibrated one. What would make this meaningful: one run of stage 1c/2b
# on the GPU, the reported "max relative divergence" and "max per-token
# divergence" written down, and --tolerance / --per-token-bits set a small
# multiple above them in run_bits_experiment.sh, so the gate travels with the
# pipeline.
# --------------------------------------------------------------------------

# The expected per-token disagreement between the two forward paths, in nats.
# Not measured on this code -- an order-of-magnitude figure for bf16 activations
# over a 4-bit-quantised model, and the anchor for the per-token allowance
# below. 1e-3 nats = 1.4427e-3 bits.
NOISE_NATS_PER_TOKEN = 1e-3

# The uncalibrated PER-TOKEN half of the bound, in bits per token: ~3.5x the
# noise estimate above. Coarse ON PURPOSE, and not a substitute for
# --per-token-bits set from a real run.
UNCALIBRATED_PER_TOKEN_BITS = 5e-3

# The uncalibrated RELATIVE half. Two orders of magnitude above the ~4e-4
# relative that a 1e-3 nats/token disagreement implies at this corpus's scale,
# and far below anything a mis-assembled row could produce.
UNCALIBRATED_REL_CEILING = 5e-2

# Relative tolerance for the external anchor. Wide on purpose: the log's number
# is a 25-batch sample of a 118-example split, so anything tighter would be
# measuring the sampling, not the mask. See the docstring.
ANCHOR_REL_TOLERANCE = 0.15

# Which token count a column's sum is over. The per-token half of the rule is
# only meaningful against the tokens that column actually summed: `bits` is over
# the answer, `trainer_bits` adds the trainer's trailing pad step, and
# `decision_bits` covers only the decision fields' tokens. A column that is not
# a sum over tokens (bits_per_token) has no entry, and --column will not accept
# it -- there is nothing for the rule to divide by.
COLUMN_TOKEN_FIELD = {
    "bits": "answer_tokens",
    "nats": "answer_tokens",
    "trainer_bits": "trainer_tokens",
    "trainer_nats": "trainer_tokens",
    "decision_bits": "decision_tokens",
}

# The run_fingerprint fields two files must AGREE on for a parity comparison to
# mean anything: same model, same weights, same window, same mask. Mirrors
# score_bits.PAIR_FINGERPRINT_KEYS / ADAPTER_FINGERPRINT_KEYS, but the split is
# different here, and deliberately so -- a base/tuned PAIR must differ in the
# adapter, while a parity pair must not. It is the FORWARD PATH that has to
# differ here, because that is the only thing this check is comparing.
PARITY_MUST_AGREE = ("model", "adapter", "adapter_digest", "max_seq_length", "match_trainer")
PARITY_FORWARD_KEYS = ("full_forward", "chunk")
FINGERPRINT_KEYS = PARITY_MUST_AGREE + PARITY_FORWARD_KEYS

VAL_LOSS_RE = re.compile(r"Iter (\d+): Val loss ([0-9.]+)")


class ScoreFile(NamedTuple):
    """One score file, read for one column: values, token counts, fingerprints.

    ``fingerprints`` is every DISTINCT run fingerprint seen in the file, in the
    order encountered -- more than one means the file is two runs spliced
    together, which ``check_parity_fingerprints`` refuses rather than averaging
    over.
    """

    path: Path
    values: dict[str, float]
    tokens: dict[str, int | None]
    fingerprints: list[dict]

    @property
    def fingerprint(self) -> dict:
        return self.fingerprints[0] if self.fingerprints else {}


def load(path: Path, column: str) -> ScoreFile:
    """Read one score file: the column, the token count that column sums over,
    and the run fingerprint. Rows whose column is null (the scorer skipped them)
    contribute no value but still count towards the fingerprint -- a skipped row
    was still produced by a run, and which run matters."""
    token_field = COLUMN_TOKEN_FIELD.get(column)
    values: dict[str, float] = {}
    tokens: dict[str, int | None] = {}
    fingerprints: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            fp = {k: rec[k] for k in FINGERPRINT_KEYS if k in rec}
            if fp and fp not in fingerprints:
                fingerprints.append(fp)
            if rec.get(column) is None:
                continue
            values[rec["hash"]] = float(rec[column])
            raw = rec.get(token_field) if token_field else None
            tokens[rec["hash"]] = None if raw is None else int(raw)
    return ScoreFile(path, values, tokens, fingerprints)


def check_parity_fingerprints(
    chunked: ScoreFile, full: ScoreFile, allow: bool = False
) -> tuple[bool, str]:
    """(ok, message). Are these two files a PARITY PAIR at all?

    Pairing two score files by content hash says the examples are the same. It
    says nothing about the runs, and this check compared nothing else: two files
    scored under different models, different adapters, different windows or
    different masks would be declared in parity, or -- worse -- declared out of
    parity, condemning a chunked path that was fine. The same class of bug the
    adapter_digest work fixed one file over, arriving from the other direction.

    The rule has two halves, because a parity pair is defined by what MUST agree
    and by the one thing that MUST differ:

      * ``PARITY_MUST_AGREE`` -- model, adapter, adapter_digest, max_seq_length,
        match_trainer. Different values for any of these guarantee different
        numbers for reasons that have nothing to do with the chunked path. A key
        present on one side only counts as a mismatch: that is the "one file was
        written by a different version of the scorer" case.
      * ``PARITY_FORWARD_KEYS`` -- full_forward and chunk. These are what the
        check exists to vary, so they must DIFFER. Two files describing the same
        forward path agree perfectly and prove nothing: it is the empty
        intersection again, wearing a full set of rows. (Different --chunk
        values on both sides is a legitimate pair -- different prefill
        boundaries are different arithmetic -- so the rule is "not identical",
        not "one must be --full-forward".)

    Files that record no fingerprint at all are refused, not assumed: rows
    written before the fingerprint existed carry no evidence of what produced
    them. ``allow`` (the operator's --allow-fingerprint-mismatch) downgrades
    every refusal here to a warning; it is the only way past, and it is loud.
    """
    problems: list[str] = []
    for f, which in ((chunked, "chunked"), (full, "full-forward")):
        if not f.fingerprints:
            problems.append(
                f"the {which} file {f.path} records no run fingerprint at all -- it "
                "predates score_bits.py stamping model/adapter/window/forward path on "
                "every row, so nothing establishes what produced those numbers"
            )
        elif len(f.fingerprints) > 1:
            problems.append(
                f"the {which} file {f.path} holds {len(f.fingerprints)} different run "
                f"fingerprints {f.fingerprints}: it is two runs spliced together, and a "
                "comparison against it would be a comparison against both"
            )
    if not problems:
        differs = {
            k: (chunked.fingerprint.get(k, "<absent>"), full.fingerprint.get(k, "<absent>"))
            for k in PARITY_MUST_AGREE
            if (k in chunked.fingerprint or k in full.fingerprint)
            and chunked.fingerprint.get(k) != full.fingerprint.get(k)
        }
        if differs:
            problems.append(
                f"{chunked.path} and {full.path} were scored under different settings "
                f"{differs}. Those differences change the numbers on their own, so the "
                "comparison would be measuring them and not the chunked path"
            )
        same_path = {k: chunked.fingerprint.get(k) for k in PARITY_FORWARD_KEYS} == {
            k: full.fingerprint.get(k) for k in PARITY_FORWARD_KEYS
        }
        if same_path:
            path_desc = ", ".join(
                f"{k}={chunked.fingerprint.get(k, '<absent>')!r}" for k in PARITY_FORWARD_KEYS
            )
            problems.append(
                f"{chunked.path} and {full.path} describe the SAME forward path "
                f"({path_desc}). This check compares two forward paths; given one path "
                "twice it agrees perfectly and validates nothing -- the empty comparison "
                "with a full set of rows. Score one side with --full-forward (or at a "
                "different --chunk)"
            )
    if not problems:
        return True, (
            "the two files agree on "
            + ", ".join(f"{k}={chunked.fingerprint.get(k, '<absent>')!r}" for k in PARITY_MUST_AGREE)
            + " and differ in the forward path (chunked: "
            + ", ".join(f"{k}={chunked.fingerprint.get(k, '<absent>')!r}" for k in PARITY_FORWARD_KEYS)
            + " | full: "
            + ", ".join(f"{k}={full.fingerprint.get(k, '<absent>')!r}" for k in PARITY_FORWARD_KEYS)
            + ")"
        )
    msg = " ; ".join(problems)
    if allow:
        return True, f"WARNING (--allow-fingerprint-mismatch): {msg}"
    return False, msg + ". Pass --allow-fingerprint-mismatch if you know why."


def check_token_counts(chunked: ScoreFile, full: ScoreFile, column: str) -> tuple[bool, str]:
    """(ok, message). The two files must agree on how many tokens each example's
    sum is over -- otherwise the per-token half of the bound is dividing two
    different quantities by two different denominators, and the examples are not
    even the same measurement. A disagreement here IS a masking divergence: same
    example, same window, different token count."""
    field = COLUMN_TOKEN_FIELD.get(column, "?")
    differ = [
        (h, chunked.tokens.get(h), full.tokens[h])
        for h in sorted(full.values)
        if h in chunked.values and chunked.tokens.get(h) != full.tokens[h]
    ]
    if not differ:
        return True, ""
    shown = ", ".join(f"{h}: chunked {c} vs full {f}" for h, c, f in differ[:5])
    return False, (
        f"{len(differ)} example(s) carry different {field} in the two files ({shown}"
        + (", ..." if len(differ) > 5 else "")
        + f"). The two runs masked the same example differently, so their {column} are "
        "not comparable quantities and the per-token bound has no single denominator"
    )


def compare(
    chunked: dict[str, float],
    full: dict[str, float],
    tokens: dict[str, int | None],
    tolerance: float | None = None,
    per_token_bits: float | None = None,
) -> tuple[bool, str]:
    """(ok, message). Empty or partial overlap is a FAILURE, not a pass.

    The bound is two-sided and per EXAMPLE:

        allowance(h) = max(tolerance x |full[h]|, per_token_bits x tokens[h])

    with the divergence required to be strictly inside it. ``None`` for either
    half means that half's uncalibrated default. See the block at the top of
    this file for why the small end is bounded per token rather than by a fixed
    floor, and for what the check can and cannot resolve at each scale.
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
    rel_bound = UNCALIBRATED_REL_CEILING if tolerance is None else tolerance
    tok_bound = UNCALIBRATED_PER_TOKEN_BITS if per_token_bits is None else per_token_bits
    if rel_bound < 0 or tok_bound < 0:
        return False, (
            f"a negative bound is not a bound (--tolerance {rel_bound:g}, "
            f"--per-token-bits {tok_bound:g})"
        )

    # A NaN or an inf passes every comparison written the obvious way, because
    # every comparison against NaN is False: the old rule's `-1.0` worst-so-far
    # sentinel was never displaced by one, and the check reported a divergence of
    # -1.000e+00 and exited 0. A non-finite bits value is a broken forward pass,
    # not a small one.
    nonfinite = [
        (h, chunked[h], full[h])
        for h in sorted(full)
        if not math.isfinite(full[h]) or not math.isfinite(chunked[h])
    ]
    if nonfinite:
        shown = ", ".join(f"{h}: chunked {c!r}, full {f!r}" for h, c, f in nonfinite[:5])
        return False, (
            f"{len(nonfinite)} of {len(full)} examples carry a NON-FINITE value ({shown}"
            + (", ..." if len(nonfinite) > 5 else "")
            + "). NaN/inf compares False against every bound, so this would otherwise "
            "read as a pass; a non-finite bits value means the forward pass broke, not "
            "that it agreed"
        )

    no_tokens = [h for h in sorted(full) if tokens.get(h) is None or tokens[h] <= 0]
    if no_tokens:
        return False, (
            f"{len(no_tokens)} of {len(full)} examples record no token count "
            f"({', '.join(no_tokens[:5])}"
            + (", ..." if len(no_tokens) > 5 else "")
            + "). The bound's small end is per TOKEN, so a row that does not say how "
            "many tokens its sum is over cannot be judged -- re-score with a scorer "
            "that stamps the count rather than falling back to a bound that ignores it"
        )

    worst_hash, worst_ratio, worst = "", -1.0, {}
    max_rel, max_per_token, biggest_abs = 0.0, 0.0, 0.0
    per_token_half, below_own_bits = 0, 0
    for h, v in full.items():
        delta = abs(chunked[h] - v)
        n = tokens[h] or 0
        rel_allow = rel_bound * abs(v)
        tok_allow = tok_bound * n
        allow = max(rel_allow, tok_allow)
        # allow == 0 only if the operator zeroed both halves (or zeroed the
        # per-token half against an exactly-0.0-bit example). That is a demand
        # for exactness, not a division by zero.
        ratio = (delta / allow) if allow > 0 else (0.0 if delta == 0 else math.inf)
        per_token = delta / n
        max_per_token = max(max_per_token, per_token)
        biggest_abs = max(biggest_abs, delta)
        if v:
            max_rel = max(max_rel, delta / abs(v))
        if tok_allow >= rel_allow:
            per_token_half += 1
            if tok_allow > abs(v):
                below_own_bits += 1
        if ratio >= worst_ratio:
            worst_hash, worst_ratio = h, ratio
            worst = {
                "delta": delta, "n": n, "value": v, "allow": allow,
                "per_token": per_token, "half": "per-token" if tok_allow >= rel_allow else "relative",
            }
    ok = worst_ratio < 1.0
    rel_of_worst = (
        f"{worst['delta'] / abs(worst['value']):.3e} relative"
        if worst["value"]
        else "relative n/a (that example is 0 bits)"
    )
    msg = (
        f"worst example uses {worst_ratio:.3f} of its allowance over {len(full)} examples "
        f"(worst: {worst_hash}, |chunked - full| = {worst['delta']:.6f} bits over "
        f"{worst['n']} tokens = {worst['per_token']:.3e} bits/token against a "
        f"{worst['value']:.4f}-bit example, {rel_of_worst}; allowance "
        f"{worst['allow']:.6f} bits, set by the {worst['half']} half). "
        f"max relative divergence {max_rel:.3e}; max per-token divergence "
        f"{max_per_token:.3e} bits/token; largest absolute gap {biggest_abs:.6f} bits. "
        f"Bound: {rel_bound:g} relative"
        + (" (UNCALIBRATED default)" if tolerance is None else " (--tolerance)")
        + f" OR {tok_bound:g} bits/token"
        + (" (UNCALIBRATED default)" if per_token_bits is None else " (--per-token-bits)")
        + ", whichever is larger for the example."
    )
    if per_token_half:
        msg += (
            f" {per_token_half} of {len(full)} examples were judged by the per-token half"
        )
        if below_own_bits:
            msg += (
                f", and for {below_own_bits} of those the allowance exceeds the example's "
                "own bits -- at that scale (a memorized tuned example is ~0.05 bits over "
                "~35 tokens, i.e. the noise floor itself) this check resolves a divergence "
                "that is wrong in KIND and nothing finer"
            )
        msg += "."
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
        help="the RELATIVE half of the bound: max |chunked-full|/|full| to accept. "
        f"Omitted = uncalibrated: the coarse {UNCALIBRATED_REL_CEILING:g} ceiling, "
        "reported as such. Set it from a real run's 'max relative divergence'.",
    )
    p.add_argument(
        "--per-token-bits",
        type=float,
        default=None,
        help="the PER-TOKEN half of the bound, in bits per token: an example may also "
        "diverge by this much times its token count, whichever half is larger. Omitted "
        f"= uncalibrated {UNCALIBRATED_PER_TOKEN_BITS:g} bits/token (~3.5x the "
        f"{NOISE_NATS_PER_TOKEN:g} nats/token these two float paths are expected to "
        "disagree by). Set it from a real run's 'max per-token divergence'.",
    )
    p.add_argument(
        "--allow-fingerprint-mismatch",
        action="store_true",
        help="downgrade the run-fingerprint refusal (same model/adapter/window/mask, "
        "different forward path) to a warning. Only if you know why they differ.",
    )
    p.add_argument("--column", default="bits", choices=sorted(COLUMN_TOKEN_FIELD))
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

    chunked = load(Path(args.chunked), args.column)
    full = load(Path(args.full_forward), args.column)

    fp_ok, fp_msg = check_parity_fingerprints(chunked, full, args.allow_fingerprint_mismatch)
    print(f"[parity_check/fingerprint] {fp_msg}", file=sys.stderr)
    if not fp_ok:
        print(
            "[parity_check] REFUSED -- these two files are not a parity pair. Comparing "
            "them would report agreement or divergence that says nothing about the "
            "chunked path.",
            file=sys.stderr,
        )
        return 2

    tok_ok, tok_msg = check_token_counts(chunked, full, args.column)
    if not tok_ok:
        print(f"[parity_check] REFUSED -- {tok_msg}", file=sys.stderr)
        return 2

    ok, msg = compare(
        chunked.values,
        full.values,
        full.tokens,
        args.tolerance,
        args.per_token_bits,
    )
    print(f"[parity_check] {msg}", file=sys.stderr)
    if not ok:
        print("[parity_check] FAILED -- the chunked path is not reproducing the "
              "trainer's forward; every bits number from it is suspect.", file=sys.stderr)
    elif args.tolerance is None or args.per_token_bits is None:
        # Loud on a PASS, because an uncalibrated pass is the one that gets
        # mistaken for a validated one. Named per half: setting one of them
        # leaves the other still guessing.
        still = " and ".join(
            name
            for name, unset in (
                (f"--tolerance ({UNCALIBRATED_REL_CEILING:g} relative)", args.tolerance is None),
                (
                    f"--per-token-bits ({UNCALIBRATED_PER_TOKEN_BITS:g} bits/token)",
                    args.per_token_bits is None,
                ),
            )
            if unset
        )
        print(
            f"[parity_check] NOT CALIBRATED: {still} still at the uncalibrated default. "
            "No GPU parity run has ever been made against this code, so those are "
            "order-of-magnitude ceilings, not measured bounds: they resolve a chunked "
            "path that is wrong in KIND (rows off by one, the wrong cache, the prompt "
            "scored as the answer), not one that is off by a little. This run did NOT "
            "validate the bits column to any stated precision. Write the 'max relative "
            "divergence' and 'max per-token divergence' above into "
            "run_bits_experiment.sh as --tolerance / --per-token-bits (a small multiple "
            "of each) to turn this into a gate that means something.",
            file=sys.stderr,
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

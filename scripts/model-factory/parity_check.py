#!/usr/bin/env python3
"""Compare two score files from ``score_bits.py`` example-by-example.

This is the ONLY check on ``MLXScorer.row_nats``'s chunked path -- the one that
rebuilds logits rows positionally out of a prefill and an answer forward, never
consults ``plan.rows``, and therefore cannot be reached by any stub-driven unit
test. ``--full-forward`` reproduces the trainer's own single un-cached forward;
the two must agree.

The subtlety that makes this worth a file of its own rather than a heredoc: a
comparison over an EMPTY intersection trivially agrees. If every example in the
sample was skipped, or the two files came from different corpora or different
adapters, a naive ``max(..., default=0.0)`` reports a perfect match over zero
comparisons and the pipeline goes on to call every downstream number validated.
So this refuses when the intersection is empty or incomplete, and prints the
count it actually compared.

  parity_check.py CHUNKED.jsonl FULLFWD.jsonl [--tolerance 0.01] [--column bits]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

# The tolerance the chunked path must meet. One number, used everywhere: a
# comment promising 1e-3 over code enforcing 1e-2 is a 10x gap on the check that
# decides whether the bits column is trustworthy at all.
TOLERANCE = 1e-2


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


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("chunked")
    p.add_argument("full_forward")
    p.add_argument("--tolerance", type=float, default=TOLERANCE)
    p.add_argument("--column", default="bits")
    args = p.parse_args(argv)

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

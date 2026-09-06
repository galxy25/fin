#!/usr/bin/env python3
"""Turn per-example BITS into a training curriculum: the smallest subset that
still carries the corpus's information.

Input is one or two files from ``score_bits.py``:

    --base   bits under the UNTUNED base model   (required)
    --tuned  bits under a trained candidate      (optional)

Joined on the content hash, those give the four quantities:

    bits_base     what the base did not know
    bits_tuned    what the candidate still does not know
    learned_bits  bits_base - bits_tuned   (what the run actually acquired)
    residual_bits bits_tuned               (hard, or MISLABELLED -- in a
                  synthesized corpus, noise is the likelier cause and is a bug
                  in gen_training_data.py)

Output is three things:

 1. A distribution report -- totals, per target, per decision class, percentiles,
    and a concentration measure (Gini + share of bits held by the top quartile).
    That report is the evidence for or against the standing hypothesis that the
    corpus carries far fewer than its example count's worth of bits.
 2. A REDUNDANCY estimate. Examples are clustered by surface near-duplication
    (word n-gram Jaccard, single-linkage) WITHIN each (target, decision_class)
    partition. The cluster count is the honest ceiling on distinct information;
    see LIMITS at the bottom of the report for what it cannot see.
 3. A SUBSET under a budget, chosen to cover as many high-value clusters as
    possible while holding every decision class at its original proportion --
    emitted as a byte-stable JSONL the training pipeline consumes directly, plus
    a written justification naming what was dropped and why.

Bits choose the curriculum. Bits never certify a model: `eval_gate.py` against
`evals/tmux-routing` remains the only arbiter, and the leakage rule still rules
(this script refuses a corpus under evals/, and refuses one that contains the
examples of a sibling valid.jsonl -- training on the yardstick is the same bug
wearing a different path).

WHICH BITS. ``--bits-column answer`` (default) ranks on bits over the whole
assistant turn; ``--bits-column decision`` ranks on ``decision_bits``, the bits
spent on the fields that carry the LABEL -- per track, because the four tracks
do not share a schema (routing action/session, elicit action, ledger
decision/goal_id/message_id, tooluse tool/arguments). Prose bits still shape the
model, so neither column is automatically right and the report prints both.

WHAT THE ARBITER ACTUALLY COVERS. evals/tmux-routing is 51 scenarios, all of
them routing (route/start/clarify/refuse). The ledger, elicit and tooluse tracks
-- 1398 of the 2245 training examples -- are not exercised by it. So the gate
can certify that a curriculum did not hurt ROUTING and can say nothing about the
other three quarters of what the selection cut. The report prints the count per
run under 'gate visibility'; do not read a gate win as a verdict on the corpus.

Stdlib only. Deterministic: no sampling anywhere; --seed only salts tie-breaks.

Usage:
  select_curriculum.py --base reports/bits-train-base.jsonl \\
      --tuned reports/bits-train-tuned.jsonl \\
      --corpus datasets/mlx/train.jsonl \\
      --target-fraction 0.25 --out datasets/mlx/train-bits25.jsonl \\
      --report reports/curriculum-25.txt
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

WORD_RE = re.compile(r"[a-z0-9]+")
PERCENTILES = (1, 5, 10, 25, 50, 75, 90, 95, 99)


# ---------------------------------------------------------------------------
# statistics helpers
# ---------------------------------------------------------------------------


def fmt(value: float | None, places: int = 2) -> str:
    """Format a bits figure that may legitimately be absent.

    ``score_bits`` writes ``decision_bits: null`` -- deliberately, so an
    unlocatable column ranks as unknown rather than as a known-easy zero -- and
    ``--bits-column decision`` puts that null straight into ``bits_base``.
    Every report line that formatted one with ``:.2f`` raised TypeError and
    aborted the run AFTER selection, on a traceback instead of a report.
    """
    return "n/a" if value is None else f"{value:.{places}f}"


def percentile(values: Sequence[float], pct: float) -> float:
    """Linear-interpolation percentile on a pre-sortable sequence."""
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    pos = (len(ordered) - 1) * (pct / 100.0)
    low = math.floor(pos)
    high = math.ceil(pos)
    if low == high:
        return float(ordered[int(pos)])
    return float(ordered[low] + (ordered[high] - ordered[low]) * (pos - low))


def gini(values: Sequence[float]) -> float:
    """Concentration of a non-negative quantity. 0 = every example carries the
    same bits; 1 = one example carries all of them. Negative inputs are clamped
    to 0 because Gini is undefined on them."""
    vals = sorted(max(0.0, float(v)) for v in values)
    n = len(vals)
    total = sum(vals)
    if n == 0 or total <= 0:
        return 0.0
    weighted = sum((i + 1) * v for i, v in enumerate(vals))
    return (2 * weighted) / (n * total) - (n + 1) / n


def top_share(values: Sequence[float], fraction: float) -> float:
    """Share of the total held by the top ``fraction`` of examples."""
    vals = sorted((max(0.0, float(v)) for v in values), reverse=True)
    total = sum(vals)
    if not vals or total <= 0:
        return 0.0
    k = max(1, int(round(len(vals) * fraction)))
    return sum(vals[:k]) / total


# ---------------------------------------------------------------------------
# joined records
# ---------------------------------------------------------------------------


def tie_key(row, seed: int) -> str:
    """Stable, seed-salted ordering key. The algorithm is deterministic with or
    without a seed; the seed only permutes which of two exactly-equal-value
    examples wins (and, under --rank-by random, drives the whole draw)."""
    return hashlib.sha256(f"{seed}:{row.hash}".encode()).hexdigest()


@dataclass
class Row:
    index: int
    hash: str
    target: str
    decision_class: str
    answer_tokens: int
    bits_base: float | None
    bits_tuned: float | None
    truncated: bool
    text: str = ""
    shingles: frozenset = field(default_factory=frozenset)
    # BOTH columns are carried on every row, whichever one --bits-column put
    # into bits_base/bits_tuned, so the report can show the contrast and the
    # mislabel screen can run on the column where its signal actually lives.
    answer_bits_base: float | None = None
    answer_bits_tuned: float | None = None
    decision_bits_base: float | None = None
    # Token count matching the DECISION column, so --rank-normalize can divide
    # by a denominator that belongs to its numerator. score_bits writes it; the
    # selector used to ignore it and divide decision bits by whole-answer tokens.
    decision_tokens: int = 0
    noise_suspect: bool = False  # bits so far above its class that a mislabel is likelier
    rank_cap: float | None = None  # ceiling applied to value() under --noise-policy cap
    # Which column bits_base/bits_tuned hold ("answer" or "decision"). value()
    # needs it to pick the right per-token denominator.
    bits_column: str = "answer"

    @property
    def norm_tokens(self) -> int:
        """The token count that matches whatever is in ``bits_base``."""
        return self.decision_tokens if self.bits_column == "decision" else self.answer_tokens

    @property
    def learned_bits(self) -> float | None:
        if self.bits_base is None or self.bits_tuned is None:
            return None
        return self.bits_base - self.bits_tuned

    @property
    def residual_bits(self) -> float | None:
        return self.bits_tuned

    @property
    def partition(self) -> tuple[str, str]:
        return (self.target, self.decision_class)

    def value(self, rank_by: str, normalize: bool, seed: int = 0) -> float:
        if rank_by == "random":
            # The control arm: a seeded, proportional, information-blind draw.
            # If bits-selection cannot beat this at the gate, bits bought nothing.
            return int(tie_key(self, seed)[:12], 16) / float(1 << 48)
        if rank_by == "bits_base":
            raw = self.bits_base
        elif rank_by == "learned_bits":
            raw = self.learned_bits
        elif rank_by == "residual":
            raw = self.residual_bits
        else:
            raise ValueError(f"unknown rank_by {rank_by!r}")
        if raw is None:
            return 0.0
        # Divide by the token count that BELONGS to the numerator. Under
        # --bits-column decision the numerator is decision bits, so dividing by
        # whole-answer tokens would rank two examples with identical decision
        # bits by the length of their `reason` prose -- the exact length bias
        # --rank-normalize exists to remove, reintroduced upside down.
        denom = self.norm_tokens
        v = raw / denom if (normalize and denom) else float(raw)
        if self.rank_cap is not None:
            # --noise-policy cap: a suspected mislabel keeps its place in the
            # corpus but stops out-ranking every honest example in its class.
            v = min(v, self.rank_cap)
        return v


# The fingerprint keys a --base file and a --tuned file must agree on for
# `learned_bits = bits_base - bits_tuned` to be a difference of commensurable
# quantities. Mirrors score_bits.PAIR_FINGERPRINT_KEYS; `adapter` and
# `adapter_digest` are deliberately absent, being the fields that MUST differ
# between the two runs. "Must differ" is not "unchecked": `check_pair_adapters`
# asserts they differ in the ONE direction that is valid.
PAIR_FINGERPRINT_KEYS = ("model", "max_seq_length", "match_trainer", "full_forward", "chunk")
ADAPTER_FINGERPRINT_KEYS = ("adapter", "adapter_digest")


def load_scores(
    path: Path, expect_adapter: bool | None = None
) -> tuple[dict[str, dict], set[str], dict]:
    """(scored rows by hash, hashes the scorer refused to score, run fingerprint).

    ``expect_adapter`` asserts the file is the one it is being used as: a --base
    file's rows must carry ``adapter: null`` and a --tuned file's must not.
    Swapping them makes ``learned_bits = base - tuned`` a difference of two
    quantities measured under the same model, i.e. approximately zero, and
    nothing downstream would notice.

    The FINGERPRINT is returned so the caller can compare the two files against
    each other. score_bits stamps model / max_seq_length / match_trainer /
    full_forward / chunk on every row precisely so incommensurable rows cannot be
    spliced, and enforces it WITHIN one file on resume -- but the subtraction
    happens ACROSS two files, which is the one place nothing was checking. See
    ``check_pair_fingerprints``.

    Skipped hashes are RETURNED, not silently dropped: an example the scorer
    could not score is an unknown, and an unknown that vanishes from the corpus
    is a deletion with no reason recorded.
    """
    out: dict[str, dict] = {}
    skipped: set[str] = set()
    adapters: set[str | None] = set()
    digests: set[str | None] = set()
    fingerprint: dict = {}
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if "adapter" in rec:
                adapters.add(rec["adapter"])
            if "adapter_digest" in rec:
                digests.add(rec["adapter_digest"])
            if not fingerprint:
                fingerprint = {
                    k: rec[k]
                    for k in PAIR_FINGERPRINT_KEYS + ADAPTER_FINGERPRINT_KEYS
                    if k in rec
                }
            if rec.get("skipped"):
                skipped.add(rec["hash"])
                continue
            out[rec["hash"]] = rec
    if len(adapters) > 1:
        raise SystemExit(
            f"{path} mixes rows from {len(adapters)} different adapters {sorted(map(str, adapters))}. "
            "That file is two runs spliced together; re-score with --restart."
        )
    if len(digests) > 1:
        # The case a PATH cannot see: one --adapter directory, two checkpoints.
        # `models/candidates/fin-foreman-e4b-mlx` gets a new adapters.safetensors
        # every 250 iterations and the staging recipe copies checkpoints over one
        # reused directory, so "same path" is not "same weights".
        raise SystemExit(
            f"{path} mixes rows from {len(digests)} different adapter CONTENTS "
            f"{sorted(map(str, digests))} under the path(s) {sorted(map(str, adapters))}. "
            "The weights under that path changed while the file was being written -- it "
            "holds two models under one name. Re-score with --restart."
        )
    if expect_adapter is not None and adapters:
        has_adapter = next(iter(adapters)) is not None
        if has_adapter != expect_adapter:
            want = "an --adapter run" if expect_adapter else "an UNTUNED base run"
            raise SystemExit(
                f"{path} does not look like {want} (adapter={next(iter(adapters))!r}). "
                "--base wants base scores and --tuned wants adapter scores; swapping them "
                "makes learned_bits meaningless."
            )
    return out, skipped, fingerprint


def check_pair_fingerprints(
    base_fp: dict, tuned_fp: dict, base_path: Path, tuned_path: Path, allow: bool
) -> None:
    """Refuse to subtract two bits columns measured under different conditions.

    ``learned_bits = bits_base - bits_tuned`` is only "information the run
    acquired" if both sides saw the same model, the same window and the same
    forward path. Score the base at --max-seq-length 3072 and the tuned adapter
    at 2048 and every example truncated under one but not the other contributes
    a fabricated learned_bits -- to the DEFAULT ranking key, silently.

    A key absent from BOTH files is not a mismatch (an older score file simply
    did not record it). A key present on one side only is: that is exactly the
    "one file was written by a different version of the scorer" case.
    """
    if not base_fp and not tuned_fp:
        return
    differs = {
        k: (base_fp.get(k, "<absent>"), tuned_fp.get(k, "<absent>"))
        for k in PAIR_FINGERPRINT_KEYS
        if (k in base_fp or k in tuned_fp) and base_fp.get(k) != tuned_fp.get(k)
    }
    if not differs:
        return
    msg = (
        f"{base_path} and {tuned_path} were scored under different settings {differs}. "
        "learned_bits = bits_base - bits_tuned would be a difference of two "
        "incommensurable quantities, and it is the default ranking key. Re-score one "
        "side to match, or pass --allow-fingerprint-mismatch if you know why they differ."
    )
    if not allow:
        raise SystemExit("[select_curriculum] " + msg)
    print(f"[select_curriculum] WARNING: {msg}", file=sys.stderr)


def check_pair_adapters(
    base_fp: dict, tuned_fp: dict, base_path: Path, tuned_path: Path, allow: bool
) -> None:
    """The other half of the pair rule: what must DIFFER, and in which direction.

    ``check_pair_fingerprints`` asserts the two runs agree on model, window and
    forward path. It deliberately says nothing about the adapter, because that is
    the one thing a valid pair differs in -- but "allowed to differ" quietly
    became "never looked at", and a pair that does not differ is exactly as broken
    as one that differs in the wrong field:

    * both sides UNTUNED -> ``learned_bits = base - base = 0`` for every example.
      The default ranking key becomes noise around zero and the selection is a
      coin flip nothing downstream would report.
    * both sides the SAME adapter -> the same, with an extra GPU run's worth of
      confidence behind it.
    * neither side RECORDS the fields -> written by a scorer that had no content
      digest, so nothing can be verified. Refused rather than assumed.

    So the direction is asserted, not just the difference: the --base file must
    carry no adapter and no digest, the --tuned file must carry both.

    ``adapter_digest`` is the field that makes this real. A path is not an
    identity -- two runs against one reused staging directory hold different
    weights and identical ``adapter`` strings -- so the digest is what says a
    tuned run is tuned on something, and says WHICH something in the report.
    """
    fields = ("adapter", "adapter_digest")
    recorded = any(k in base_fp for k in fields) or any(k in tuned_fp for k in fields)
    if not recorded:
        problem = (
            f"neither {base_path} nor {tuned_path} records an adapter or an "
            "adapter_digest. They predate the content fingerprint, so there is no "
            "evidence that one of them is the base run and the other the tuned one -- "
            "and if they are the same run, learned_bits is identically zero"
        )
    elif (
        base_fp.get("adapter_digest") is not None
        and base_fp.get("adapter_digest") == tuned_fp.get("adapter_digest")
    ):
        # Checked before the base-side rule so the sharpest case gets the
        # sharpest message: one checkpoint staged twice, under two paths, and
        # subtracted from itself. Nothing keyed on the PATH could see this.
        problem = (
            f"{base_path} and {tuned_path} were scored under the SAME adapter content "
            f"({base_fp['adapter_digest']}, at {base_fp.get('adapter')!r} and "
            f"{tuned_fp.get('adapter')!r}). learned_bits would be identically zero"
        )
    elif base_fp.get("adapter") is not None or base_fp.get("adapter_digest") is not None:
        problem = (
            f"{base_path} is used as --base but was scored WITH an adapter "
            f"(adapter={base_fp.get('adapter')!r}, digest={base_fp.get('adapter_digest')!r}). "
            "bits_base must be the UNTUNED model's surprise"
        )
    elif tuned_fp.get("adapter") is None and tuned_fp.get("adapter_digest") is None:
        problem = (
            f"{tuned_path} is used as --tuned but was scored with NO adapter. "
            "learned_bits = bits_base - bits_tuned would be a model minus itself: "
            "identically zero, and it is the default ranking key"
        )
    elif tuned_fp.get("adapter_digest") is None:
        problem = (
            f"{tuned_path} names an adapter ({tuned_fp.get('adapter')!r}) but records no "
            "adapter_digest, so which checkpoint produced it cannot be established. "
            "That path takes a new adapters.safetensors every 250 iterations"
        )
    else:
        return

    msg = (
        f"{problem}. The pair must differ in one direction only: --base with no adapter, "
        "--tuned with one. Re-score the side that is wrong, or pass "
        "--allow-fingerprint-mismatch if you know why they are like this."
    )
    if not allow:
        raise SystemExit("[select_curriculum] " + msg)
    print(f"[select_curriculum] WARNING: {msg}", file=sys.stderr)


def content_hash(messages: Sequence[dict]) -> str:
    blob = json.dumps(messages, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def cluster_text(messages: Sequence[dict], mode: str) -> str:
    """Text the redundancy estimator compares.

    The SYSTEM prompt is deliberately excluded: it is byte-identical across every
    example of a track, so including it would push every within-track Jaccard
    toward 1.0 and report a redundancy that is an artifact of the prompt, not of
    the data.
    """
    user = " ".join(m.get("content") or "" for m in messages if m.get("role") == "user")
    answer = " ".join(m.get("content") or "" for m in messages if m.get("role") == "assistant")
    if mode == "user":
        return user
    if mode == "answer":
        return answer
    return user + " \x00 " + answer


def shingles(text: str, n: int) -> frozenset:
    words = WORD_RE.findall(text.lower())
    if len(words) < n:
        return frozenset([" ".join(words)]) if words else frozenset()
    return frozenset(" ".join(words[i : i + n]) for i in range(len(words) - n + 1))


def jaccard(a: frozenset, b: frozenset) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if inter == 0:
        return 0.0
    return inter / (len(a) + len(b) - inter)


# ---------------------------------------------------------------------------
# clustering
# ---------------------------------------------------------------------------


class UnionFind:
    def __init__(self, n: int):
        self.parent = list(range(n))

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # Always attach the larger root to the smaller: deterministic shape.
            if ra < rb:
                self.parent[rb] = ra
            else:
                self.parent[ra] = rb


def cluster_partition(rows: Sequence[Row], threshold: float, max_exact: int) -> list[list[int]]:
    """Single-linkage clusters of near-duplicate rows, by exact pairwise Jaccard.

    O(n^2) on purpose. Partitions here are (target, decision_class) slices --
    the largest in the 2026-09-05 corpus is 230 rows, so the whole corpus costs
    ~2e5 comparisons. Exact beats approximate at this size, and an exact answer
    is what a redundancy claim needs to survive scrutiny.
    """
    n = len(rows)
    if n > max_exact:
        raise SystemExit(
            f"partition of {n} rows exceeds --max-exact {max_exact}; raise the flag "
            "(cost is quadratic) or partition the corpus further"
        )
    uf = UnionFind(n)
    for i in range(n):
        si = rows[i].shingles
        for j in range(i + 1, n):
            if jaccard(si, rows[j].shingles) >= threshold:
                uf.union(i, j)
    groups: dict[int, list[int]] = defaultdict(list)
    for i in range(n):
        groups[uf.find(i)].append(i)
    # Stable order: by the smallest member index.
    return [groups[k] for k in sorted(groups, key=lambda k: min(groups[k]))]


def redundancy_curve(
    rows: Sequence["Row"], thresholds: Sequence[float], max_exact: int
) -> list[tuple[float, int]]:
    """Cluster count at several Jaccard thresholds.

    One threshold is one arbitrary choice, and a redundancy claim that only
    holds at 0.80 is not a claim. The curve shows how fast the corpus collapses
    as the definition of "near-duplicate" loosens -- and a corpus that stays
    flat across the curve is genuinely diverse, whatever the hypothesis said.
    """
    by_partition: dict[tuple[str, str], list[Row]] = defaultdict(list)
    for r in rows:
        by_partition[r.partition].append(r)
    out = []
    for t in thresholds:
        total = 0
        for members in by_partition.values():
            total += len(cluster_partition(members, t, max_exact))
        out.append((t, total))
    return out


# ---------------------------------------------------------------------------
# selection
# ---------------------------------------------------------------------------


@dataclass
class Cluster:
    partition: tuple[str, str]
    members: list[Row]  # sorted best-first
    value: float  # cluster value = best member's value


@dataclass
class Selection:
    kept: list[Row]
    dropped: list[Row]
    clusters: dict[tuple[str, str], list[Cluster]]
    quotas: dict[tuple[str, str], int]
    reasons: dict[int, str]  # corpus index -> why it was dropped
    cuts: dict[tuple[str, str], float]  # per-partition value cut


@dataclass
class NoiseScreen:
    """What the mislabel screen actually did, per partition. Reported, so that
    "none flagged" can be read as "nothing reached cut X" rather than as an
    all-clear -- the two are indistinguishable from a bare count."""

    cuts: dict[tuple[str, str], float] = field(default_factory=dict)
    medians: dict[tuple[str, str], float] = field(default_factory=dict)
    spreads: dict[tuple[str, str], float] = field(default_factory=dict)
    bound_by: dict[tuple[str, str], str] = field(default_factory=dict)
    skipped: dict[tuple[str, str], str] = field(default_factory=dict)
    column: str = "bits_base"
    flagged: int = 0


def mad(values: Sequence[float]) -> float:
    """Median absolute deviation. Robust dispersion: a single huge outlier moves
    it almost not at all, which is what a mislabel detector needs its baseline
    to do."""
    if not values:
        return 0.0
    med = percentile(values, 50)
    return percentile([abs(v - med) for v in values], 50)


def flag_noise_suspects(
    rows: Sequence[Row],
    factor: float,
    floor: float,
    min_n: int = 8,
    z: float = 6.0,
    use_decision: bool = True,
) -> NoiseScreen:
    """Mark rows whose bits are so far above their own class that a MISLABEL is
    the likelier explanation. Returns a NoiseScreen describing every cut.

    This is the converse of the high-residual warning, and it is the one the
    SELECTOR needs: the ranking maximizes bits, and a label the generator got
    wrong is exactly what maximizes bits under the base model. Once training has
    driven bits_tuned to ~0 for everything, learned_bits ~ bits_base, so both
    ranking modes put a mislabel at the very top of its class and a 25% budget
    concentrates label noise several-fold.

    THE CUT IS SCALE-FREE, and it has to be. The previous rule was
    ``max(8.0 bits, 4.0 x the class median)``, calibrated against a unit-test
    fixture whose clean class sits at ~6.5 bits. On the real corpus the scale is
    two orders of magnitude larger -- the log's ``Iter 1: Val loss 2.463`` at
    ~34.6 trained tokens per example puts a typical whole-answer example near
    ~123 bits under the base -- so that rule cuts at ~492 bits while a wrong
    decision token adds only ~10. It could not fire, and the absolute 8.0 floor
    was inert by three orders of magnitude. The rule now is

        cut = median + z x 1.4826 x MAD          (robust; scales with the data)

    falling back to ``factor x median`` where MAD is 0 (a degenerate class in
    which every example costs the same, so any deviation at all is the signal).
    ``floor`` remains available as an absolute override and defaults to 0.0:
    an absolute bits floor is only meaningful once stage 1 has measured what a
    bit is worth in the column in force, and until then a hardcoded one silently
    binds every partition.

    WHICH COLUMN. A mislabel shows up in the DECISION bits, where a wrong label
    token is most of the signal, and drowns in whole-answer bits, where it is
    ~10 bits against a class spread of tens. So the screen prefers
    ``decision_bits_base`` when it is available for the whole partition, and
    records which column it used. Even so: this test's POWER is unknown until
    the real distribution exists. It can fire; whether it fires on the mislabels
    that are actually there is a stage-1 question, and the report says so.
    """
    by_partition: dict[tuple[str, str], list[Row]] = defaultdict(list)
    for r in rows:
        by_partition[r.partition].append(r)

    screen = NoiseScreen()
    # Prefer the decision column, but only if every scored row has one: a screen
    # run on a mix of two columns is not a screen.
    scored = [r for r in rows if r.bits_base is not None]
    use_dec = bool(
        use_decision and scored and all(r.decision_bits_base is not None for r in scored)
    )
    screen.column = "decision_bits_base" if use_dec else "bits_base"

    def val_of(r: Row) -> float | None:
        return r.decision_bits_base if use_dec else r.bits_base

    for partition, members in by_partition.items():
        vals = [v for v in (val_of(m) for m in members) if v is not None]
        if len(vals) < min_n:
            # Not enough rows to say what "normal for this class" is. Recorded,
            # never silent: an unscreened partition is where a mislabel hides.
            screen.skipped[partition] = f"only {len(vals)} scored rows (need {min_n})"
            continue
        med = percentile(vals, 50)
        spread = mad(vals)
        if spread > 0:
            robust, bound = med + z * 1.4826 * spread, f"median + {z:g}x1.4826xMAD"
        else:
            robust, bound = med * factor, f"{factor:g}x median (MAD=0)"
        cut = robust
        if floor > robust:
            cut, bound = floor, f"absolute floor {floor:g}"
        screen.cuts[partition] = cut
        screen.medians[partition] = med
        screen.spreads[partition] = spread
        screen.bound_by[partition] = bound
        for m in members:
            v = val_of(m)
            if v is not None and v >= cut:
                m.noise_suspect = True
                screen.flagged += 1
    return screen


def select(
    rows: Sequence[Row],
    fraction: float,
    rank_by: str,
    normalize: bool,
    threshold: float,
    shingle_n: int,
    min_per_class: int,
    seed: int,
    max_exact: int,
    noise_policy: str = "flag",
) -> Selection:
    by_partition: dict[tuple[str, str], list[Row]] = defaultdict(list)
    for r in rows:
        by_partition[r.partition].append(r)

    clusters: dict[tuple[str, str], list[Cluster]] = {}
    kept: list[Row] = []
    dropped: list[Row] = []
    quotas: dict[tuple[str, str], int] = {}
    reasons: dict[int, str] = {}
    cuts: dict[tuple[str, str], float] = {}

    for partition in sorted(by_partition):
        all_members = by_partition[partition]
        n = len(all_members)

        # Noise policy, applied BEFORE clustering so caps are in force for every
        # sort below. 'flag' changes nothing here and only reports.
        members = all_members
        excluded: list[Row] = []
        if noise_policy == "exclude":
            members = [m for m in all_members if not m.noise_suspect]
            excluded = [m for m in all_members if m.noise_suspect]
            if not members:  # never empty a class on suspicion alone
                members, excluded = all_members, []
        elif noise_policy == "cap":
            clean = [m for m in all_members if not m.noise_suspect]
            if clean:
                cap = max(m.value(rank_by, normalize, seed) for m in clean)
                for m in all_members:
                    if m.noise_suspect:
                        m.rank_cap = cap

        groups = cluster_partition(members, threshold, max_exact)
        built: list[Cluster] = []
        for g in groups:
            ms = sorted(
                (members[i] for i in g),
                key=lambda r: (-r.value(rank_by, normalize, seed), tie_key(r, seed)),
            )
            built.append(Cluster(partition, ms, ms[0].value(rank_by, normalize, seed)))
        # Best clusters first; ties broken by the representative's tie key.
        built.sort(key=lambda c: (-c.value, tie_key(c.members[0], seed)))
        clusters[partition] = built

        quota = int(round(fraction * n))  # the ORIGINAL n, so shares hold
        quota = max(min(min_per_class, len(members)), quota)
        quota = min(quota, len(members))
        quotas[partition] = quota

        picked: list[Row] = []
        depth = 0
        while len(picked) < quota:
            progressed = False
            for c in built:
                if depth < len(c.members):
                    picked.append(c.members[depth])
                    progressed = True
                    if len(picked) == quota:
                        break
            if not progressed:
                break
            depth += 1

        # Identity is the corpus INDEX, not the content hash: two corpus lines
        # can legitimately share a hash, and keying on the hash made the
        # unpicked twin vanish from both kept and dropped with no reason.
        picked_ids = {r.index for r in picked}
        kept.extend(picked)
        covered_clusters = {id(c) for c in built if any(m.index in picked_ids for m in c.members)}
        cut = min((r.value(rank_by, normalize, seed) for r in picked), default=0.0)
        cuts[partition] = cut

        for m in excluded:
            dropped.append(m)
            reasons[m.index] = (
                f"noise-suspect: {fmt(m.bits_base)} bits under the base is far above the "
                f"{partition[0]}/{partition[1]} median; in a synthesized corpus that is a "
                "likelier sign of a mislabel from gen_training_data.py than of a hard "
                "example (--noise-policy exclude)"
            )
        for c in built:
            for m in c.members:
                if m.index in picked_ids:
                    continue
                dropped.append(m)
                if id(c) in covered_clusters:
                    rep = c.members[0]
                    reasons[m.index] = (
                        f"redundant: >= {threshold:.2f} Jaccard with kept idx {rep.index} "
                        f"in a {len(c.members)}-example cluster; its value "
                        f"{m.value(rank_by, normalize, seed):.2f} <= the cluster rep's "
                        f"{rep.value(rank_by, normalize, seed):.2f}"
                    )
                else:
                    reasons[m.index] = (
                        f"low-information: its cluster's best value {c.value:.2f} fell below "
                        f"the {partition[0]}/{partition[1]} budget cut of {cut:.2f}"
                    )

    kept.sort(key=lambda r: r.index)
    dropped.sort(key=lambda r: r.index)
    return Selection(kept, dropped, clusters, quotas, reasons, cuts)


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------


def dist_block(title: str, values: Sequence[float]) -> list[str]:
    if not values:
        return [f"{title}: (none)"]
    lines = [
        f"{title}: n={len(values)} total={sum(values):.1f} mean={sum(values)/len(values):.2f} "
        f"min={min(values):.2f} max={max(values):.2f}"
    ]
    pcts = "  ".join(f"p{p}={percentile(values, p):.2f}" for p in PERCENTILES)
    lines.append(f"    {pcts}")
    return lines


def build_report(
    rows: list[Row],
    sel: Selection,
    args: argparse.Namespace,
    have_tuned: bool,
    curve: Sequence[tuple[float, int]] = (),
    unscored: Sequence[tuple[int, str]] = (),
    screen: NoiseScreen | None = None,
) -> str:
    out: list[str] = []
    a = out.append
    screen = screen or NoiseScreen()
    total = len(rows)
    corpus_lines = total + len(unscored)
    a("=" * 78)
    a("CURRICULUM BY INFORMATION")
    a("=" * 78)
    a(f"corpus            : {args.corpus}")
    a(f"base scores       : {args.base}")
    a(f"tuned scores      : {args.tuned if have_tuned else '(none -- base-only mode)'}")
    a(f"ranking           : {args.rank_by}{' (per-token)' if args.rank_normalize else ' (per-example)'}")
    a(f"bits column       : {args.bits_column}"
      + ("  (bits over the WHOLE assistant turn)" if args.bits_column == "answer"
         else "  (bits over the DECISION fields only)"))
    a(f"budget            : {args.target_fraction:.3f} of {total} scored examples "
      f"({corpus_lines} lines in the corpus)")
    a(f"near-dup threshold: Jaccard >= {args.jaccard} on word {args.shingle}-grams of {args.cluster_on}")
    a(f"noise policy      : {args.noise_policy} on {screen.column} "
      f"(cut = median + {args.noise_z:g}x1.4826xMAD per class; see section 5)")
    a("")
    unscored_section = "7" if have_tuned else "6"
    if unscored:
        a(f"!! {len(unscored)} corpus lines are NOT in this selection at all: the scorer")
        a(f"   could not score them, so they are neither kept nor dropped. Section "
          f"{unscored_section} names")
        a("   them. Every percentage below is over the {0} SCORED lines.".format(total))
        a("")

    # -- 1. distribution ----------------------------------------------------
    a("-" * 78)
    a("1. BITS DISTRIBUTION")
    a("-" * 78)
    col = "bits_base" if args.bits_column == "answer" else "decision_bits_base"
    base_bits = [r.bits_base for r in rows if r.bits_base is not None]
    out.extend(dist_block(f"{col} (whole corpus)", base_bits))
    per_tok = [r.bits_base / r.answer_tokens for r in rows if r.bits_base is not None and r.answer_tokens]
    out.extend(dist_block(f"{col} per answer token", per_tok))
    if have_tuned:
        out.extend(dist_block("bits_tuned (residual)", [r.bits_tuned for r in rows if r.bits_tuned is not None]))
        out.extend(dist_block("learned_bits", [r.learned_bits for r in rows if r.learned_bits is not None]))
    if args.bits_column == "decision":
        # What the ranking is NOT looking at, so the gap is on the record.
        whole = [r.answer_bits_base for r in rows if r.answer_bits_base is not None]
        out.extend(dist_block("(for contrast) whole-answer bits_base", whole))
        if whole and sum(whole):
            a(f"    the gate-scored fields hold {sum(base_bits)/sum(whole)*100:.1f}% of the "
              "corpus's whole-answer bits")
    a("")
    a(f"concentration     : Gini(bits_base) = {gini(base_bits):.3f}")
    a(f"                    top 10% of examples hold {top_share(base_bits, 0.10)*100:.1f}% of all bits")
    a(f"                    top 25% of examples hold {top_share(base_bits, 0.25)*100:.1f}% of all bits")
    a("")

    for axis, label in (("target", "per TARGET"), ("decision_class", "per DECISION CLASS")):
        a(f"  {label}")
        groups: dict[str, list[Row]] = defaultdict(list)
        for r in rows:
            groups[getattr(r, axis)].append(r)
        header = f"    {'key':<28} {'n':>5} {'bits':>10} {'mean':>8} {'b/tok':>7}"
        if have_tuned:
            header += f" {'resid':>8} {'learned':>9}"
        a(header)
        for key in sorted(groups, key=lambda k: -sum(x.bits_base or 0 for x in groups[k])):
            g = groups[key]
            bits = sum(x.bits_base or 0 for x in g)
            toks = sum(x.answer_tokens for x in g) or 1
            line = f"    {key:<28} {len(g):>5} {bits:>10.1f} {bits/len(g):>8.2f} {bits/toks:>7.3f}"
            if have_tuned:
                resid = sum(x.bits_tuned or 0 for x in g)
                learned = sum(x.learned_bits or 0 for x in g)
                line += f" {resid/len(g):>8.2f} {learned/len(g):>9.2f}"
            a(line)
        a("")

    # -- 2. redundancy ------------------------------------------------------
    a("-" * 78)
    a("2. REDUNDANCY")
    a("-" * 78)
    all_clusters = [c for cs in sel.clusters.values() for c in cs]
    n_clusters = len(all_clusters)
    sizes = sorted((len(c.members) for c in all_clusters), reverse=True)
    # DENOMINATOR: the rows that were actually clustered, not every row. Under
    # --noise-policy exclude the suspects never enter a cluster, so dividing by
    # len(rows) would count each excluded row as its own redundancy and invent
    # surface redundancy that does not exist -- while the per-partition table
    # below, which divides by the clustered count, disagreed in the same report.
    clustered = sum(sizes)
    excluded_from_clustering = total - clustered
    a(f"{clustered} clustered examples collapse to {n_clusters} distinct information "
      f"clusters ({(1 - n_clusters / clustered) * 100:.1f}% surface redundancy)"
      if clustered else "no examples were clustered")
    if excluded_from_clustering:
        a(f"  ({excluded_from_clustering} of the {total} scored rows never entered a cluster: "
          f"--noise-policy {args.noise_policy} held them out. They are NOT counted as")
        a("   redundant -- they were not compared to anything.)")
    a(f"largest cluster   : {sizes[0] if sizes else 0} examples")
    a(f"singletons        : {sum(1 for s in sizes if s == 1)}")
    if sizes:
        a(f"cluster size      : mean={sum(sizes)/len(sizes):.2f} p50={percentile(sizes, 50):.1f} "
          f"p90={percentile(sizes, 90):.1f}")
    a("")
    if clustered:
        a(f"ONE REPRESENTATIVE PER CLUSTER would need {n_clusters}/{clustered} = "
          f"{n_clusters/clustered*100:.1f}% of the clustered examples.")
        a(f"The budget in force is {args.target_fraction*100:.1f}%, so this selection is "
          f"{'ABOVE' if args.target_fraction * clustered >= n_clusters else 'BELOW'} full cluster")
        a("coverage -- below it, the ranking (not the clustering) decides what survives.")
    a("")
    if curve:
        a("redundancy vs threshold (one threshold is one arbitrary choice):")
        a(f"    {'jaccard':>8} {'clusters':>9} {'redundancy':>11}")
        for t, c in curve:
            a(f"    {t:>8.2f} {c:>9} {(1 - c / total) * 100:>10.1f}%")
        a("")
    a(f"    {'target/class':<28} {'n':>5} {'clusters':>9} {'redundancy':>11}")
    for partition in sorted(sel.clusters):
        cs = sel.clusters[partition]
        n = sum(len(c.members) for c in cs)
        a(f"    {partition[0] + '/' + partition[1]:<28} {n:>5} {len(cs):>9} "
          f"{(1 - len(cs) / n) * 100:>10.1f}%")
    unclassified = sum(1 for r in rows if r.target == "unknown" or r.decision_class == "unparsed")
    if unclassified:
        a("")
        a(f"!! {unclassified} rows are unknown/unparsed and therefore share ONE partition.")
        a("   For them the per-class quota does not hold and clustering CAN merge across")
        a("   their true labels -- both guarantees above are void for that slice. Teach")
        a("   score_bits.classify about the track before trusting this selection.")
    a("")

    # -- 3. the subset ------------------------------------------------------
    a("-" * 78)
    a("3. PROPOSED SUBSET")
    a("-" * 78)
    kept_bits = sum(r.bits_base or 0 for r in sel.kept)
    all_bits = sum(r.bits_base or 0 for r in rows) or 1.0
    a(f"kept {len(sel.kept)}/{total} scored examples ({len(sel.kept)/total*100:.1f}%) "
      f"carrying {kept_bits/all_bits*100:.1f}% of the corpus's bits_base")
    # The share of the RANKED quantity, which is the number that actually
    # evidences the hypothesis. With --tuned the criterion is learned_bits, and
    # reporting only the bits_base share describes a criterion the selector did
    # not use. Values are clamped at 0 because learned_bits can be negative and
    # a share of a signed total is not a share.
    if args.rank_by not in ("bits_base", "random"):
        ranked_kept = sum(max(0.0, r.value(args.rank_by, args.rank_normalize, args.seed))
                          for r in sel.kept)
        ranked_all = sum(max(0.0, r.value(args.rank_by, args.rank_normalize, args.seed))
                         for r in rows) or 1.0
        a(f"                  ... and {ranked_kept/ranked_all*100:.1f}% of the corpus's "
          f"{args.rank_by} -- THE CRITERION ACTUALLY USED. The bits_base share above is")
        a("                  context, not the selection's own objective.")
    a(f"accounting        : kept {len(sel.kept)} + dropped {len(sel.dropped)} = "
      f"{len(sel.kept) + len(sel.dropped)} of {total} scored "
      f"({len(unscored)} unscored, see section {unscored_section})")
    # What the arbiter can and cannot see. evals/tmux-routing scores the ROUTING
    # track only, so a cut into any other track is invisible to the gate that
    # decides whether this curriculum worked -- a measured statement, not a
    # caveat, because the fraction changes with every corpus.
    gate_blind_kept = sum(1 for r in sel.kept if r.target != "routing")
    gate_blind_drop = sum(1 for r in sel.dropped if r.target != "routing")
    if gate_blind_kept or gate_blind_drop:
        a(f"gate visibility   : evals/tmux-routing scores the ROUTING track only. "
          f"{gate_blind_kept + gate_blind_drop}/{total} rows")
        a(f"                    ({gate_blind_drop} of them dropped) are in tracks the "
          "arbiter never exercises, so damage")
        a("                    to them cannot appear in the gate score. See LIMITS.")
    covered = 0
    kept_ids = {r.index for r in sel.kept}
    for c in all_clusters:
        if any(m.index in kept_ids for m in c.members):
            covered += 1
    a(f"cluster coverage  : {covered}/{n_clusters} clusters have a representative "
      f"({covered/n_clusters*100:.1f}%)")
    a("")
    a(f"    {'target/class':<28} {'orig':>6} {'kept':>6} {'share':>7} {'orig%':>7} {'kept%':>7} {'bits%':>7}")
    orig_counts = Counter(r.partition for r in rows)
    kept_counts = Counter(r.partition for r in sel.kept)
    for partition in sorted(orig_counts):
        o, k = orig_counts[partition], kept_counts.get(partition, 0)
        ob = sum(r.bits_base or 0 for r in rows if r.partition == partition) or 1.0
        kb = sum(r.bits_base or 0 for r in sel.kept if r.partition == partition)
        a(f"    {partition[0] + '/' + partition[1]:<28} {o:>6} {k:>6} {k/o*100:>6.1f}% "
          f"{o/total*100:>6.2f}% {k/max(1,len(sel.kept))*100:>6.2f}% {kb/ob*100:>6.1f}%")
    a("")

    # -- 4. justification ---------------------------------------------------
    a("-" * 78)
    a("4. WHAT WAS DROPPED, AND WHY")
    a("-" * 78)
    kinds = Counter(sel.reasons[r.index].split(":", 1)[0] for r in sel.dropped)
    for kind, count in kinds.most_common():
        a(f"{kind:<18}: {count}")
    a("")
    dropped_bits = sum(r.bits_base or 0 for r in sel.dropped)
    a(f"dropped {len(sel.dropped)} examples holding {dropped_bits/all_bits*100:.1f}% of bits_base "
      f"(mean {dropped_bits/max(1,len(sel.dropped)):.2f} bits vs "
      f"{kept_bits/max(1,len(sel.kept)):.2f} for kept)")
    a("")
    # Sorted by the RANKED value, so the list names the drops the criterion
    # itself considered most costly. Sorting by bits_base while ranking on
    # learned_bits printed one number as the header and a different one as the
    # reason, with nothing saying which was the criterion.
    ranked_label = f"{args.rank_by}{' per token' if args.rank_normalize else ''}"
    a(f"examples (highest-{ranked_label} drops first -- these are the ones to argue about):")
    worst = sorted(
        sel.dropped, key=lambda r: -r.value(args.rank_by, args.rank_normalize, args.seed)
    )[: args.explain]
    for r in worst:
        # bits_base is None for any row whose --bits-column could not be
        # computed; formatting None with :.2f raises TypeError and would abort
        # the whole run, after selection, on a traceback instead of a report.
        a(f"  idx {r.index:>5} {r.target}/{r.decision_class} "
          f"{ranked_label}={r.value(args.rank_by, args.rank_normalize, args.seed):.2f} "
          f"bits={fmt(r.bits_base)}")
        a(f"      {sel.reasons[r.index]}")
    a("")

    # -- 5. the ranking's own failure mode ----------------------------------
    a("-" * 78)
    a("5. NOISE SUSPECTS (the ranking's own failure mode)")
    a("-" * 78)
    a("A mislabel from gen_training_data.py makes the base model maximally surprised,")
    a("so it maximizes bits_base -- and, once training has driven bits_tuned to ~0,")
    a("learned_bits too. Both ranking modes therefore put a mislabel FIRST in its")
    a("class, and a small budget concentrates label noise instead of diluting it.")
    a("This section exists so that concentration is visible rather than assumed away.")
    a("")
    a(f"screened on       : {screen.column}"
      + ("  (a mislabel's signal is concentrated in the decision fields; in "
         "whole-answer" if screen.column == "decision_bits_base" else ""))
    if screen.column == "decision_bits_base":
        a("                    bits it is ~10 bits against a class spread of tens)")
    else:
        a("                    -- no usable decision column, so the screen runs on the")
        a("                    whole answer, where its power is LOW. See LIMITS.")
    a(f"cut rule          : median + {args.noise_z:g} x 1.4826 x MAD, per (target, class)")
    a(f"partitions        : {len(screen.cuts)} screened, {len(screen.skipped)} skipped "
      f"(< --noise-min-n {args.noise_min_n} rows)")
    if screen.cuts:
        a("")
        a(f"    {'target/class':<28} {'median':>10} {'MAD':>9} {'cut':>10}  bound by")
        for partition in sorted(screen.cuts):
            a(f"    {partition[0] + '/' + partition[1]:<28} "
              f"{screen.medians[partition]:>10.3f} {screen.spreads[partition]:>9.3f} "
              f"{screen.cuts[partition]:>10.3f}  {screen.bound_by[partition]}")
    if screen.skipped:
        a("")
        a("NOT SCREENED (too few rows to say what normal is -- a mislabel here is exempt")
        a("from the test entirely, which is the failure mode this line exists to expose):")
        for partition in sorted(screen.skipped):
            a(f"    {partition[0] + '/' + partition[1]:<28} {screen.skipped[partition]}")

    suspects = [r for r in rows if r.noise_suspect]
    if not suspects:
        a("")
        a("none: no example in any SCREENED partition reached its cut above. Read that")
        a("as 'nothing exceeded these thresholds', not as 'the corpus is clean' -- the")
        a("test's power against the mislabels that are actually present is unknown until")
        a("a real bits distribution exists.")
    else:
        kept_ids_all = {r.index for r in sel.kept}
        in_kept = [r for r in suspects if r.index in kept_ids_all]
        corpus_share = len(suspects) / total
        kept_share = len(in_kept) / max(1, len(sel.kept))
        a("")
        a(f"flagged           : {len(suspects)}/{total} ({corpus_share*100:.2f}% of the corpus)")
        a(f"of those, KEPT    : {len(in_kept)}/{len(sel.kept)} ({kept_share*100:.2f}% of the subset)")
        factor = kept_share / corpus_share if corpus_share else 0.0
        a(f"concentration     : {factor:.2f}x  "
          f"({'the subset is ENRICHED in suspects' if factor > 1.25 else 'no material enrichment'})")
        a(f"policy in force   : --noise-policy {args.noise_policy}"
          + {"flag": " (reported only; nothing was excluded or capped)",
             "cap": " (their rank value was capped at their class's best clean value)",
             "exclude": " (excluded from selection; they appear in section 4)"}[args.noise_policy])
        for r in sorted(suspects, key=lambda r: -(r.bits_base or 0))[: args.explain]:
            state = "KEPT   " if r.index in kept_ids_all else "dropped"
            a(f"  {state} idx {r.index:>5} {r.target}/{r.decision_class} "
              f"bits={fmt(r.bits_base)} tokens={r.answer_tokens}")
    a("")

    if have_tuned:
        resid = [(r.bits_tuned or 0.0) for r in rows]
        pct_at = percentile(resid, args.residual_percentile)
        # A bare percentile ALWAYS names the top 1%, however small its residual.
        # After a run that memorized the corpus every residual is ~0.001 bits,
        # and printing "still surprising / likely a mislabel" over those would
        # accuse innocent examples and hide a real one. An absolute floor makes
        # the section say nothing when there is nothing to say.
        med = percentile(resid, 50)
        flag_at = max(pct_at, args.residual_floor, med * args.residual_factor)
        flagged = sorted(
            (r for r in rows if r.bits_tuned is not None and r.bits_tuned >= flag_at),
            key=lambda r: -(r.bits_tuned or 0),
        )[: args.explain]
        kept_ids_all = {r.index for r in sel.kept}
        a("-" * 78)
        a(f"6. HIGH-RESIDUAL EXAMPLES (cut = {flag_at:.3f} bits after training; "
          f"p{args.residual_percentile}={pct_at:.3f}, floor={args.residual_floor:.3f}, "
          f"{args.residual_factor:.1f}x median={med * args.residual_factor:.3f})")
        a("-" * 78)
        if not flagged:
            a(f"None. Residual bits top out at {max(resid, default=0.0):.3f} and the median is")
            a(f"{med:.3f} -- the run left nothing meaningfully unlearned, so there is no")
            a("mislabel signal to read here. (That is also what a memorized corpus looks")
            a("like: see section 5 for the noise test that does NOT depend on training.)")
        else:
            a("Still surprising after a full run. In a corpus this templated the likely")
            a("cause is a MISLABEL from gen_training_data.py, not a hard example. These")
            a("are reported, never auto-dropped -- dropping genuinely hard cases is how a")
            a("curriculum quietly deletes the thing the gate measures. The kept/dropped")
            a("column says whether the curriculum took the suspect anyway.")
            for r in flagged:
                state = "KEPT   " if r.index in kept_ids_all else "dropped"
                a(f"  {state} idx {r.index:>5} {r.target}/{r.decision_class} "
                  f"residual={fmt(r.bits_tuned, 3)} base={fmt(r.bits_base)} "
                  f"learned={(r.learned_bits or 0):.2f}")
        a("")

    if unscored:
        a("-" * 78)
        a(f"{unscored_section}. UNSCORED CORPUS LINES ({len(unscored)})")
        a("-" * 78)
        a("score_bits.py refused to score these (usually: the prompt alone fills")
        a("--max-seq-length, so the answer is entirely truncated away). They are")
        a("UNKNOWNS, not zeros: they are absent from the emitted subset, and they are")
        a("absent from every denominator above. Listing them here is the difference")
        a("between a recorded decision and a silent deletion.")
        for idx, why in list(unscored)[: args.explain]:
            a(f"  idx {idx:>5}  {why}")
        if len(unscored) > args.explain:
            a(f"  ... and {len(unscored) - args.explain} more")
        a("")

    a("-" * 78)
    a("LIMITS")
    a("-" * 78)
    a("* Bits are a property of the PAIR (example, model), not of the data alone.")
    a("  A different base -- or the same base after any training -- reorders this list.")
    a("* HIGH BITS CAN MEAN A BUG, NOT VALUE. The ranking maximizes exactly what a")
    a("  mislabel maximizes. Section 5 measures the resulting concentration; it does")
    a("  not remove it unless --noise-policy says to. A bits number cannot tell a hard")
    a("  example from a wrong one -- only reading the flagged examples can.")
    a("* THE SCREEN'S POWER IS UNMEASURED. Section 5's cut is scale-free, so unlike the")
    a("  absolute threshold it replaced it CAN fire at any bits scale. Whether it fires")
    a("  on the mislabels actually present is a different question and is unanswered:")
    a("  a wrong decision token costs perhaps ~10 bits, and in WHOLE-ANSWER bits that is")
    a("  well inside the natural spread of a class whose examples differ by the length")
    a("  of their prose. That is why the screen prefers the decision column, and why")
    a("  'none flagged' is not evidence of a clean corpus. Calibrating it needs a real")
    a("  bits distribution -- i.e. stage 1 -- and it has not been run.")
    a("* THE GATE SCORES ONE TRACK OF FOUR. evals/tmux-routing is 51 scenarios whose")
    a("  expected actions are all route/start/clarify/refuse, and run_evals.py:matches()")
    a("  compares only 'action' and, when present, 'session'. The ledger, elicit and")
    a("  tooluse tracks are NOT exercised by it at all -- see 'gate visibility' in")
    a("  section 3 for this run's count. A subset that wrecks tool-argument formatting")
    a("  scores identically on all 51 scenarios, so 'the gate is the arbiter' certifies")
    a("  the routing track and asserts nothing about the rest. Hold that in mind before")
    a("  reading a gate win as a verdict on the whole curriculum.")
    a("* THE DECISION COLUMN IS PER TRACK. --bits-column decision ranks on the fields")
    a("  that carry the label (routing action/session, elicit action, ledger decision/")
    a("  goal_id/message_id, tooluse tool/arguments). Under --bits-column answer most")
    a("  of every bits number is prose no arbiter reads. Neither is obviously right --")
    a("  prose still shapes the model -- but they rank differently and only the gate")
    a("  can say which wins, and only for routing.")
    a("* The redundancy curve is measured on --cluster-on both, which concatenates the")
    a("  ANSWER. Inside one (target, decision_class) the answer is near-constant label")
    a("  scaffold, so it inflates similarity the same way the system prompt would (the")
    a("  system prompt is excluded for exactly that reason). The curve in section 2 is")
    a("  measured on THIS corpus with the answer included; to see how much of it is")
    a("  scaffold, re-run with --cluster-on user and compare. (Measured on")
    a("  datasets/mlx/train.jsonl, 2245 rows: 0.80 gives 1735 clusters with the answer")
    a("  vs 1757 without -- robust; 0.70 gives 1283 vs 1661 and 0.50 gives 122 vs 805")
    a("  -- not robust. Those are figures for that corpus, not for whatever --corpus")
    a("  named above; read the loose end of ANY such curve as scaffold.)")
    a("* Redundancy here is SURFACE redundancy: word n-gram Jaccard cannot see two")
    a("  examples that teach the same rule in disjoint vocabulary, and it can over-")
    a("  merge two examples that differ only in the token that flips the label.")
    a("  Clustering is confined to a single (target, decision_class) partition so")
    a("  that second failure can never merge across labels -- but within a label it")
    a("  is still possible.")
    a("* Single-linkage chains: A~B and B~C put A and C in one cluster even when")
    a("  A and C are not similar. It under-counts clusters, i.e. it over-states")
    a("  redundancy. That is the conservative direction for a keep decision.")
    a("* A low-bits example is not worthless. It may be the only thing holding a")
    a("  behaviour in place; dropping the whole low-bits mass can cause forgetting")
    a("  that shows up only in the gate.")
    a("* SELECTION MUST NEVER TOUCH THE EVAL CORPORA. The leakage rule outranks")
    a("  every number in this report.")
    a("* The only proof this worked is the gate: retrain on the subset and compare")
    a("  eval-gate score at equal or fewer iterations. See run_bits_experiment.sh.")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", required=True, help="score_bits.py output under the untuned base")
    p.add_argument("--tuned", default=None, help="score_bits.py output under a trained adapter")
    p.add_argument("--corpus", required=True, help="the JSONL the scores came from")
    p.add_argument("--out", default=None, help="write the selected subset here (byte-stable JSONL)")
    p.add_argument("--report", default=None, help="write the report here as well as stdout")
    p.add_argument("--target-fraction", type=float, default=0.25)
    p.add_argument(
        "--rank-by",
        choices=("auto", "bits_base", "learned_bits", "residual", "random"),
        default="auto",
        help="auto = learned_bits when --tuned is given, else bits_base. "
        "random is the CONTROL ARM: same budget, same class proportions, "
        "information-blind -- the thing bits-selection has to beat at the gate.",
    )
    p.add_argument(
        "--rank-normalize",
        action="store_true",
        help="rank on bits PER ANSWER TOKEN, so a short high-information answer is "
        "not buried under a long one full of JSON scaffold",
    )
    p.add_argument(
        "--bits-column",
        choices=("answer", "decision"),
        default="answer",
        help="'answer' ranks on bits over the whole assistant turn; 'decision' ranks on "
        "decision_bits -- the bits spent on the per-track fields that carry the label. "
        "'decision' needs the score files to have been produced with a --decision-fields "
        "setting that covers this corpus; the selector refuses past 20% missing.",
    )
    p.add_argument("--chat-key", default="messages", help="must match score_bits.py --chat-key")
    p.add_argument("--jaccard", type=float, default=0.8)
    p.add_argument("--shingle", type=int, default=3, help="word n-gram size")
    p.add_argument("--cluster-on", choices=("user", "answer", "both"), default="both")
    p.add_argument("--min-per-class", type=int, default=1)
    p.add_argument("--max-exact", type=int, default=4000)
    p.add_argument(
        "--noise-policy",
        choices=("flag", "cap", "exclude"),
        default="flag",
        help="what to do with examples whose bits are far above their class median, which "
        "in a synthesized corpus more often means a MISLABEL than a hard example. "
        "flag = report only (default); cap = keep them but stop them out-ranking clean "
        "examples; exclude = leave them out of the curriculum, with a reason recorded.",
    )
    p.add_argument(
        "--noise-z",
        type=float,
        default=6.0,
        help="robust z: flag at median + z x 1.4826 x MAD of the class. Scale-free, so it "
        "works at whole-answer bits (~100s) and decision bits (~units) alike.",
    )
    p.add_argument(
        "--noise-factor",
        type=float,
        default=4.0,
        help="x the class median; used only where MAD is 0 (a class in which every "
        "example costs identical bits, so there is no spread to measure against)",
    )
    p.add_argument(
        "--noise-floor",
        type=float,
        default=0.0,
        help="absolute bits floor for a flag. DEFAULT 0 (off) on purpose: an absolute "
        "floor is only meaningful once a run has measured what a bit is worth in the "
        "column in force, and a hardcoded one silently binds every partition instead.",
    )
    p.add_argument(
        "--noise-min-n",
        type=int,
        default=8,
        help="a partition smaller than this is not screened at all (too few rows to say "
        "what 'normal' is). Skipped partitions are named in the report, never silent.",
    )
    p.add_argument(
        "--noise-column",
        choices=("auto", "ranked"),
        default="auto",
        help="auto = screen on decision_bits when every scored row has one (a mislabel's "
        "signal is concentrated there and drowns in whole-answer bits); ranked = screen on "
        "whatever --bits-column selected.",
    )
    p.add_argument(
        "--allow-fingerprint-mismatch",
        action="store_true",
        help="proceed when --base and --tuned were scored under different model/window/"
        "forward-path settings, or when they do not differ in the one way they must "
        "(--base untuned, --tuned with a content-fingerprinted adapter). learned_bits is "
        "then a difference of two incommensurable quantities, or of a model with itself; "
        "you are asserting you know why.",
    )
    p.add_argument("--residual-percentile", type=float, default=99.0)
    p.add_argument(
        "--residual-floor",
        type=float,
        default=1.0,
        help="absolute bits a residual must reach before it is called suspicious; without "
        "it the p99 names the top 1% even when every residual is ~0.001 bits",
    )
    p.add_argument("--residual-factor", type=float, default=10.0, help="x the median residual")
    p.add_argument(
        "--allow-valid-overlap",
        action="store_true",
        help="proceed even though --corpus contains the sibling valid.jsonl's examples",
    )
    p.add_argument("--explain", type=int, default=12, help="how many examples to name in the report")
    p.add_argument("--seed", type=int, default=17)
    p.add_argument(
        "--no-redundancy-curve",
        dest="redundancy_curve",
        action="store_false",
        help="skip the multi-threshold sweep (it re-clusters once per threshold)",
    )
    return p


def check_leakage(corpus: Path, chat_key: str, allow_valid_overlap: bool) -> None:
    """The leakage rule, enforced two ways.

    Path check: nothing under evals/ is selectable. Content check: a corpus that
    contains the examples of a sibling valid.jsonl is the train+valid file, and
    a subset of it trains on the fixed yardstick -- which is precisely what
    run_bits_experiment.sh copies valid.jsonl in unchanged to avoid.
    ``datasets/sft-train-2026-09-05.jsonl`` IS that file (2245 train + 118
    valid = 2363), and it is the one the standing directive names, so the check
    is not hypothetical.
    """
    parts = {p.lower() for p in corpus.resolve().parts}
    if "evals" in parts:
        raise SystemExit(
            f"refusing to select from {corpus}: it lives under evals/. Training on the "
            "eval corpus measures memorization, not skill (README 'Leakage rule')."
        )
    candidates = [corpus.resolve().parent / "valid.jsonl"]
    candidates += list(corpus.resolve().parent.glob("*/valid.jsonl"))
    corpus_hashes: set[str] | None = None
    for valid in candidates:
        if not valid.exists() or valid.resolve() == corpus.resolve():
            continue
        if corpus_hashes is None:
            corpus_hashes = set(corpus_line_hashes(corpus, chat_key))
        overlap = corpus_hashes & set(corpus_line_hashes(valid, chat_key))
        if not overlap:
            continue
        msg = (
            f"refusing to select from {corpus}: {len(overlap)} of its examples are also in "
            f"{valid}. A subset of it would train on the validation yardstick, and the "
            "two experiment arms would no longer share a fixed reference. Point --corpus "
            "at the train split, or pass --allow-valid-overlap if you know better."
        )
        if not allow_valid_overlap:
            raise SystemExit(msg)
        print(f"[select_curriculum] WARNING: {msg}", file=sys.stderr)


def corpus_line_hashes(path: Path, chat_key: str = "messages") -> list[str]:
    out = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            out.append(content_hash(json.loads(line)[chat_key]))
    return out


def load_rows(args: argparse.Namespace) -> tuple[list[Row], bool, list[tuple[int, str]]]:
    corpus = Path(args.corpus)
    check_leakage(corpus, args.chat_key, args.allow_valid_overlap)

    base, base_skipped, base_fp = load_scores(Path(args.base), expect_adapter=False)
    if args.tuned:
        tuned, _, tuned_fp = load_scores(Path(args.tuned), expect_adapter=True)
        check_pair_fingerprints(
            base_fp, tuned_fp, Path(args.base), Path(args.tuned),
            args.allow_fingerprint_mismatch,
        )
        # What must AGREE is checked above; what must DIFFER is checked here.
        check_pair_adapters(
            base_fp, tuned_fp, Path(args.base), Path(args.tuned),
            args.allow_fingerprint_mismatch,
        )
    else:
        tuned = {}
    have_tuned = bool(tuned)
    bits_key = "bits" if args.bits_column == "answer" else "decision_bits"

    rows: list[Row] = []
    unscored: list[tuple[int, str]] = []
    with corpus.open("r", encoding="utf-8") as fh:
        idx = 0
        for line in fh:
            if not line.strip():
                continue
            obj = json.loads(line)
            messages = obj[args.chat_key]
            h = content_hash(messages)
            b = base.get(h)
            if b is None:
                unscored.append(
                    (
                        idx,
                        "the scorer marked it skipped (prompt fills --max-seq-length)"
                        if h in base_skipped
                        else "no row for this example in the base score file",
                    )
                )
                idx += 1
                continue
            t = tuned.get(h)
            text = cluster_text(messages, args.cluster_on)
            rows.append(
                Row(
                    index=idx,
                    hash=h,
                    target=b.get("target", "unknown"),
                    decision_class=b.get("decision_class", "unparsed"),
                    answer_tokens=int(b.get("answer_tokens") or 0),
                    bits_base=b.get(bits_key),
                    bits_tuned=(t or {}).get(bits_key) if have_tuned else None,
                    truncated=bool(b.get("truncated")),
                    text=text,
                    shingles=shingles(text, args.shingle),
                    answer_bits_base=b.get("bits"),
                    answer_bits_tuned=(t or {}).get("bits") if have_tuned else None,
                    decision_bits_base=b.get("decision_bits"),
                    decision_tokens=int(b.get("decision_tokens") or 0),
                    bits_column=args.bits_column,
                )
            )
            idx += 1
    if unscored:
        print(
            f"[select_curriculum] {len(unscored)} corpus lines had no usable base score; they "
            "are reported in the report's UNSCORED section and are absent from the subset",
            file=sys.stderr,
        )
    if args.bits_column == "decision":
        blind = sum(1 for r in rows if r.bits_base is None)
        if blind:
            share = blind / len(rows) if rows else 1.0
            note = (
                f"[select_curriculum] {blind}/{len(rows)} rows have no decision_bits "
                f"({share*100:.1f}%); they would all rank as 0 and sort to the bottom"
            )
            if share > 0.2:
                raise SystemExit(
                    note + ". Refusing: at that rate --bits-column decision is not ranking "
                    "on information, it is ranking on whether the column could be computed. "
                    "Re-score with --decision-fields matching this corpus, or use "
                    "--bits-column answer."
                )
            print(note, file=sys.stderr)
    if have_tuned:
        no_tuned = sum(1 for r in rows if r.bits_tuned is None)
        if no_tuned:
            print(
                f"[select_curriculum] {no_tuned} rows had no tuned score; their learned_bits "
                "is undefined and they rank as 0",
                file=sys.stderr,
            )
    # Classification drives BOTH the per-class quota and the promise that
    # clustering never merges across labels. A track whose prompt carries none of
    # the markers lands wholesale in one ('unknown', 'unparsed') partition, and
    # then neither property holds -- so say so instead of degrading quietly.
    unknown = sum(1 for r in rows if r.target == "unknown" or r.decision_class == "unparsed")
    if unknown:
        print(
            f"[select_curriculum] WARNING: {unknown}/{len(rows)} rows classified as "
            "unknown/unparsed. They share ONE partition, so the per-class quota does not "
            "hold for them and clustering can merge across their true labels. Teach "
            "score_bits.classify about this track before trusting the selection.",
            file=sys.stderr,
        )
    truncated = sum(1 for r in rows if r.truncated)
    if truncated:
        print(
            f"[select_curriculum] WARNING: {truncated} rows were flagged truncated by "
            "score_bits.py; their bits are a LOWER BOUND and are ranked unadjusted, which "
            "systematically pushes truncated examples toward the drop side",
            file=sys.stderr,
        )
    return rows, have_tuned, unscored


def emit_subset(corpus: Path, kept: Iterable[Row], out: Path) -> int:
    """Write the ORIGINAL bytes of the selected lines, in the original order.

    Re-serializing through json would be byte-stable only by luck (key order,
    unicode escaping, separators). Copying the source line is byte-stable by
    construction, so a diff against the parent corpus is meaningful.

    INVARIANT: ``Row.index`` counts NON-BLANK corpus lines from 0, and this walk
    must count them identically -- including the ``idx += 1`` that load_rows
    performs for a line it could not score. Break either and the report
    describes one subset while the file holds another, silently. See
    ``test_emit_subset_stays_aligned_when_a_line_is_unscored``.
    """
    wanted = {r.index for r in kept}
    written = 0
    out.parent.mkdir(parents=True, exist_ok=True)
    with corpus.open("r", encoding="utf-8") as src, out.open("w", encoding="utf-8", newline="") as dst:
        idx = 0
        for line in src:
            if not line.strip():
                continue
            if idx in wanted:
                dst.write(line if line.endswith("\n") else line + "\n")
                written += 1
            idx += 1
    return written


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    rows, have_tuned, unscored = load_rows(args)
    if not rows:
        raise SystemExit("no scored rows: check that --base was produced from --corpus")

    rank_by = args.rank_by
    if rank_by == "auto":
        rank_by = "learned_bits" if have_tuned else "bits_base"
    if rank_by in ("learned_bits", "residual") and not have_tuned:
        print(
            f"[select_curriculum] --rank-by {rank_by} needs --tuned; falling back to bits_base",
            file=sys.stderr,
        )
        rank_by = "bits_base"
    if rank_by == "residual":
        print(
            "[select_curriculum] WARNING: --rank-by residual selects the HIGHEST-residual "
            "examples first -- the very ones this tool's own report calls likely mislabels "
            "from gen_training_data.py. A curriculum built this way is weighted toward "
            "suspected generator bugs. Use it to STUDY the tail, not to build a training "
            "set, unless you have read the flagged examples and they are genuinely hard.",
            file=sys.stderr,
        )
    args.rank_by = rank_by

    if args.rank_normalize:
        # A zero denominator makes value() fall back to the un-normalized bits
        # for that row alone, which silently ranks two different quantities
        # against each other. Say so rather than degrade.
        no_denom = sum(1 for r in rows if r.bits_base is not None and not r.norm_tokens)
        if no_denom:
            unit = "decision_tokens" if args.bits_column == "decision" else "answer_tokens"
            print(
                f"[select_curriculum] WARNING: --rank-normalize, but {no_denom}/{len(rows)} "
                f"rows have {unit} = 0. Those rank on RAW bits while the rest rank on bits "
                "per token -- two different quantities in one sort.",
                file=sys.stderr,
            )

    screen = flag_noise_suspects(
        rows,
        args.noise_factor,
        args.noise_floor,
        min_n=args.noise_min_n,
        z=args.noise_z,
        use_decision=(args.noise_column == "auto"),
    )

    sel = select(
        rows,
        fraction=args.target_fraction,
        rank_by=rank_by,
        normalize=args.rank_normalize,
        threshold=args.jaccard,
        shingle_n=args.shingle,
        min_per_class=args.min_per_class,
        seed=args.seed,
        max_exact=args.max_exact,
        noise_policy=args.noise_policy,
    )
    suspects_kept = sum(1 for r in sel.kept if r.noise_suspect)
    n_suspects = sum(1 for r in rows if r.noise_suspect)
    if n_suspects and sel.kept:
        conc = (suspects_kept / len(sel.kept)) / (n_suspects / len(rows))
        if conc > 1.25:
            print(
                f"[select_curriculum] WARNING: the subset is {conc:.1f}x ENRICHED in "
                f"noise suspects ({suspects_kept}/{len(sel.kept)} kept vs "
                f"{n_suspects}/{len(rows)} in the corpus). High bits is what a MISLABEL "
                "looks like as well as what a valuable example looks like; read the "
                "report's section 5, and consider --noise-policy cap.",
                file=sys.stderr,
            )

    curve = []
    if args.redundancy_curve:
        thresholds = sorted({round(t, 2) for t in (0.5, 0.6, 0.7, 0.8, 0.9, 0.95, args.jaccard)})
        curve = redundancy_curve(rows, thresholds, args.max_exact)

    report = build_report(rows, sel, args, have_tuned, curve, unscored, screen)
    sys.stdout.write(report)
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(report, encoding="utf-8")

    if args.out:
        out = Path(args.out)
        n = emit_subset(Path(args.corpus), sel.kept, out)
        meta = {
            "corpus": str(Path(args.corpus).resolve()),
            "base": str(Path(args.base).resolve()),
            "tuned": str(Path(args.tuned).resolve()) if args.tuned else None,
            "rank_by": rank_by,
            "bits_column": args.bits_column,
            "rank_normalize": args.rank_normalize,
            "target_fraction": args.target_fraction,
            "jaccard": args.jaccard,
            "shingle": args.shingle,
            "cluster_on": args.cluster_on,
            "min_per_class": args.min_per_class,
            "noise_policy": args.noise_policy,
            "noise_column": screen.column,
            "noise_partitions_screened": len(screen.cuts),
            "noise_partitions_skipped": len(screen.skipped),
            "seed": args.seed,
            "kept": n,
            "of": len(rows),
            "unscored": len(unscored),
            "corpus_lines": len(rows) + len(unscored),
            "noise_suspects": n_suspects,
            "noise_suspects_kept": suspects_kept,
            "kept_indices": [r.index for r in sel.kept],
            "kept_hashes": [r.hash for r in sel.kept],
        }
        Path(str(out) + ".meta.json").write_text(
            json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"[select_curriculum] wrote {n} examples to {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

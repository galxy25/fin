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
spent on the fields the eval gate actually compares (action/session). The gate
is the arbiter, so a curriculum built to move it has a good claim on the second
-- but prose bits still shape the model, so neither is automatically right and
the report prints both.

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
    # The whole-answer figures, kept even when --bits-column decision puts the
    # gate-scored slice into bits_base/bits_tuned, so the report can show both.
    answer_bits_base: float | None = None
    answer_bits_tuned: float | None = None
    noise_suspect: bool = False  # bits so far above its class that a mislabel is likelier
    rank_cap: float | None = None  # ceiling applied to value() under --noise-policy cap

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
        v = raw / self.answer_tokens if (normalize and self.answer_tokens) else float(raw)
        if self.rank_cap is not None:
            # --noise-policy cap: a suspected mislabel keeps its place in the
            # corpus but stops out-ranking every honest example in its class.
            v = min(v, self.rank_cap)
        return v


def load_scores(path: Path, expect_adapter: bool | None = None) -> tuple[dict[str, dict], set[str]]:
    """(scored rows by hash, hashes the scorer refused to score).

    ``expect_adapter`` asserts the file is the one it is being used as: a --base
    file's rows must carry ``adapter: null`` and a --tuned file's must not.
    Swapping them makes ``learned_bits = base - tuned`` a difference of two
    quantities measured under the same model, i.e. approximately zero, and
    nothing downstream would notice.

    Skipped hashes are RETURNED, not silently dropped: an example the scorer
    could not score is an unknown, and an unknown that vanishes from the corpus
    is a deletion with no reason recorded.
    """
    out: dict[str, dict] = {}
    skipped: set[str] = set()
    adapters: set[str | None] = set()
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if "adapter" in rec:
                adapters.add(rec["adapter"])
            if rec.get("skipped"):
                skipped.add(rec["hash"])
                continue
            out[rec["hash"]] = rec
    if len(adapters) > 1:
        raise SystemExit(
            f"{path} mixes rows from {len(adapters)} different adapters {sorted(map(str, adapters))}. "
            "That file is two runs spliced together; re-score with --restart."
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
    return out, skipped


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


def flag_noise_suspects(rows: Sequence[Row], factor: float, floor: float, min_n: int = 8) -> int:
    """Mark rows whose bits are so far above their own class that a MISLABEL is
    the likelier explanation.

    This is the converse of the high-residual warning, and it is the one the
    SELECTOR needs: the ranking maximizes bits, and a label the generator got
    wrong is exactly what maximizes bits under the base model. Once training has
    driven bits_tuned to ~0 for everything, learned_bits ~ bits_base, so both
    ranking modes put a mislabel at the very top of its class and a 25% budget
    concentrates label noise several-fold.

    The test is per-partition and relative -- ``bits >= max(floor, factor x the
    class median)`` -- because absolute bits differ hugely between an
    ``elicit/ask`` question string and a ``routing/refuse`` reason.
    """
    by_partition: dict[tuple[str, str], list[Row]] = defaultdict(list)
    for r in rows:
        by_partition[r.partition].append(r)
    flagged = 0
    for members in by_partition.values():
        vals = [r.bits_base for r in members if r.bits_base is not None]
        if len(vals) < min_n:
            continue  # too few rows to say what "normal for this class" is
        cut = max(floor, percentile(vals, 50) * factor)
        for r in members:
            if r.bits_base is not None and r.bits_base >= cut:
                r.noise_suspect = True
                flagged += 1
    return flagged


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
                f"noise-suspect: {m.bits_base:.2f} bits under the base is far above the "
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
) -> str:
    out: list[str] = []
    a = out.append
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
         else "  (bits over the gate-scored fields only)"))
    a(f"budget            : {args.target_fraction:.3f} of {total} scored examples "
      f"({corpus_lines} lines in the corpus)")
    a(f"near-dup threshold: Jaccard >= {args.jaccard} on word {args.shingle}-grams of {args.cluster_on}")
    a(f"noise policy      : {args.noise_policy} (>= max({args.noise_floor:.1f} bits, "
      f"{args.noise_factor:.1f}x the class median))")
    a("")
    if unscored:
        a(f"!! {len(unscored)} corpus lines are NOT in this selection at all: the scorer")
        a("   could not score them, so they are neither kept nor dropped. Section 6 names")
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
    a(f"{total} examples collapse to {n_clusters} distinct information clusters "
      f"({(1 - n_clusters / total) * 100:.1f}% surface redundancy)")
    a(f"largest cluster   : {sizes[0] if sizes else 0} examples")
    a(f"singletons        : {sum(1 for s in sizes if s == 1)}")
    a(f"cluster size      : mean={sum(sizes)/len(sizes):.2f} p50={percentile(sizes, 50):.1f} "
      f"p90={percentile(sizes, 90):.1f}")
    a("")
    a(f"ONE REPRESENTATIVE PER CLUSTER would need {n_clusters}/{total} = "
      f"{n_clusters/total*100:.1f}% of the corpus.")
    a(f"The budget in force is {args.target_fraction*100:.1f}%, so this selection is "
      f"{'ABOVE' if args.target_fraction * total >= n_clusters else 'BELOW'} full cluster")
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
    a(f"accounting        : kept {len(sel.kept)} + dropped {len(sel.dropped)} = "
      f"{len(sel.kept) + len(sel.dropped)} of {total} scored "
      f"({len(unscored)} unscored, see section 6)")
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
    a("examples (highest-bits drops first -- these are the ones to argue about):")
    worst = sorted(sel.dropped, key=lambda r: -(r.bits_base or 0))[: args.explain]
    for r in worst:
        a(f"  idx {r.index:>5} {r.target}/{r.decision_class} bits={r.bits_base:.2f}")
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
    suspects = [r for r in rows if r.noise_suspect]
    if not suspects:
        a("")
        a(f"none: no example reaches max({args.noise_floor:.1f} bits, "
          f"{args.noise_factor:.1f}x its class median).")
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
              f"bits={r.bits_base:.2f} tokens={r.answer_tokens}")
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
                  f"residual={r.bits_tuned:.3f} base={r.bits_base:.2f} "
                  f"learned={(r.learned_bits or 0):.2f}")
        a("")

    if unscored:
        a("-" * 78)
        a(f"{'7' if have_tuned else '6'}. UNSCORED CORPUS LINES ({len(unscored)})")
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
    a("* THE GATE READS TWO FIELDS. run_evals.py:matches() compares 'action' and, when")
    a("  present, 'session', and nothing else. Under --bits-column answer most of every")
    a("  bits number is prose the arbiter never sees; --bits-column decision ranks on")
    a("  the gate-scored tokens alone. Neither is obviously right -- prose still shapes")
    a("  the model -- but they rank differently and only the gate can say which wins.")
    a("* The redundancy curve is measured on --cluster-on both, which concatenates the")
    a("  ANSWER. Inside one (target, decision_class) the answer is near-constant label")
    a("  scaffold, so it inflates similarity the same way the system prompt would (the")
    a("  system prompt is excluded for exactly that reason). On the 2026-09-05 corpus")
    a("  the 0.80 headline is robust (1817 clusters vs 1840 user-only) but the loose")
    a("  end is not: 0.70 gives 1335 with the answer vs 1733 without, and 0.50 gives")
    a("  121 vs 834. Read the loose end of the curve as scaffold, not as shared input.")
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
        "decision_bits -- the bits spent on the fields the eval gate compares.",
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
    p.add_argument("--noise-factor", type=float, default=4.0, help="x the class median")
    p.add_argument("--noise-floor", type=float, default=8.0, help="absolute bits floor for a flag")
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

    base, base_skipped = load_scores(Path(args.base), expect_adapter=False)
    if args.tuned:
        tuned, _ = load_scores(Path(args.tuned), expect_adapter=True)
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

    flag_noise_suspects(rows, args.noise_factor, args.noise_floor)

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

    report = build_report(rows, sel, args, have_tuned, curve, unscored)
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

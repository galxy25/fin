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
    2363-example corpus carries far fewer than 2363 examples' worth of bits.
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
(this script refuses to read a corpus that lives under evals/).

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
        if normalize and self.answer_tokens:
            return raw / self.answer_tokens
        return float(raw)


def load_scores(path: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("skipped"):
                continue
            out[rec["hash"]] = rec
    return out


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
    reasons: dict[str, str]  # hash -> why it was dropped
    cuts: dict[tuple[str, str], float]  # per-partition value cut


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
) -> Selection:
    by_partition: dict[tuple[str, str], list[Row]] = defaultdict(list)
    for r in rows:
        by_partition[r.partition].append(r)

    clusters: dict[tuple[str, str], list[Cluster]] = {}
    kept: list[Row] = []
    dropped: list[Row] = []
    quotas: dict[tuple[str, str], int] = {}
    reasons: dict[str, str] = {}
    cuts: dict[tuple[str, str], float] = {}

    for partition in sorted(by_partition):
        members = by_partition[partition]
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

        n = len(members)
        quota = int(round(fraction * n))
        quota = max(min(min_per_class, n), quota)
        quota = min(quota, n)
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

        picked_hashes = {r.hash for r in picked}
        kept.extend(picked)
        covered_clusters = {id(c) for c in built if any(m.hash in picked_hashes for m in c.members)}
        cut = min((r.value(rank_by, normalize, seed) for r in picked), default=0.0)
        cuts[partition] = cut

        for c in built:
            for m in c.members:
                if m.hash in picked_hashes:
                    continue
                dropped.append(m)
                if id(c) in covered_clusters:
                    rep = c.members[0]
                    reasons[m.hash] = (
                        f"redundant: >= {threshold:.2f} Jaccard with kept idx {rep.index} "
                        f"in a {len(c.members)}-example cluster; its value "
                        f"{m.value(rank_by, normalize, seed):.2f} <= the cluster rep's "
                        f"{rep.value(rank_by, normalize, seed):.2f}"
                    )
                else:
                    reasons[m.hash] = (
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
) -> str:
    out: list[str] = []
    a = out.append
    total = len(rows)
    a("=" * 78)
    a("CURRICULUM BY INFORMATION")
    a("=" * 78)
    a(f"corpus            : {args.corpus}")
    a(f"base scores       : {args.base}")
    a(f"tuned scores      : {args.tuned if have_tuned else '(none -- base-only mode)'}")
    a(f"ranking           : {args.rank_by}{' (per-token)' if args.rank_normalize else ' (per-example)'}")
    a(f"budget            : {args.target_fraction:.3f} of {total} examples")
    a(f"near-dup threshold: Jaccard >= {args.jaccard} on word {args.shingle}-grams of {args.cluster_on}")
    a("")

    # -- 1. distribution ----------------------------------------------------
    a("-" * 78)
    a("1. BITS DISTRIBUTION")
    a("-" * 78)
    base_bits = [r.bits_base for r in rows if r.bits_base is not None]
    out.extend(dist_block("bits_base (whole corpus)", base_bits))
    per_tok = [r.bits_base / r.answer_tokens for r in rows if r.bits_base is not None and r.answer_tokens]
    out.extend(dist_block("bits_base per answer token", per_tok))
    if have_tuned:
        out.extend(dist_block("bits_tuned (residual)", [r.bits_tuned for r in rows if r.bits_tuned is not None]))
        out.extend(dist_block("learned_bits", [r.learned_bits for r in rows if r.learned_bits is not None]))
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
    a("")

    # -- 3. the subset ------------------------------------------------------
    a("-" * 78)
    a("3. PROPOSED SUBSET")
    a("-" * 78)
    kept_bits = sum(r.bits_base or 0 for r in sel.kept)
    all_bits = sum(r.bits_base or 0 for r in rows) or 1.0
    a(f"kept {len(sel.kept)}/{total} examples ({len(sel.kept)/total*100:.1f}%) "
      f"carrying {kept_bits/all_bits*100:.1f}% of the corpus's bits_base")
    covered = 0
    kept_hashes = {r.hash for r in sel.kept}
    for c in all_clusters:
        if any(m.hash in kept_hashes for m in c.members):
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
    kinds = Counter(
        "redundant" if sel.reasons[r.hash].startswith("redundant") else "low-information"
        for r in sel.dropped
    )
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
        a(f"      {sel.reasons[r.hash]}")
    a("")

    if have_tuned:
        resid = [(r.bits_tuned or 0.0) for r in rows]
        flag_at = percentile(resid, args.residual_percentile)
        flagged = sorted(
            (r for r in rows if (r.bits_tuned or 0.0) >= flag_at and r.bits_tuned is not None),
            key=lambda r: -(r.bits_tuned or 0),
        )[: args.explain]
        a("-" * 78)
        a(f"5. HIGH-RESIDUAL EXAMPLES (p{args.residual_percentile} = {flag_at:.2f} bits after training)")
        a("-" * 78)
        a("Still surprising after a full run. In a corpus this templated the likely")
        a("cause is a MISLABEL from gen_training_data.py, not a hard example. These")
        a("are reported, never auto-dropped -- dropping genuinely hard cases is how a")
        a("curriculum quietly deletes the thing the gate measures.")
        for r in flagged:
            a(f"  idx {r.index:>5} {r.target}/{r.decision_class} residual={r.bits_tuned:.2f} "
              f"base={r.bits_base:.2f} learned={(r.learned_bits or 0):.2f}")
        a("")

    a("-" * 78)
    a("LIMITS")
    a("-" * 78)
    a("* Bits are a property of the PAIR (example, model), not of the data alone.")
    a("  A different base -- or the same base after any training -- reorders this list.")
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
    p.add_argument("--jaccard", type=float, default=0.8)
    p.add_argument("--shingle", type=int, default=3, help="word n-gram size")
    p.add_argument("--cluster-on", choices=("user", "answer", "both"), default="both")
    p.add_argument("--min-per-class", type=int, default=1)
    p.add_argument("--max-exact", type=int, default=4000)
    p.add_argument("--residual-percentile", type=float, default=99.0)
    p.add_argument("--explain", type=int, default=12, help="how many examples to name in the report")
    p.add_argument("--seed", type=int, default=17)
    p.add_argument(
        "--no-redundancy-curve",
        dest="redundancy_curve",
        action="store_false",
        help="skip the multi-threshold sweep (it re-clusters once per threshold)",
    )
    return p


def load_rows(args: argparse.Namespace) -> tuple[list[Row], bool]:
    corpus = Path(args.corpus)
    parts = {p.lower() for p in corpus.resolve().parts}
    if "evals" in parts:
        raise SystemExit(
            f"refusing to select from {corpus}: it lives under evals/. Training on the "
            "eval corpus measures memorization, not skill (README 'Leakage rule')."
        )

    base = load_scores(Path(args.base))
    tuned = load_scores(Path(args.tuned)) if args.tuned else {}
    have_tuned = bool(tuned)

    rows: list[Row] = []
    missing = 0
    with corpus.open("r", encoding="utf-8") as fh:
        idx = 0
        for line in fh:
            if not line.strip():
                continue
            obj = json.loads(line)
            messages = obj["messages"]
            h = content_hash(messages)
            b = base.get(h)
            if b is None:
                missing += 1
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
                    bits_base=b.get("bits"),
                    bits_tuned=(t or {}).get("bits") if have_tuned else None,
                    truncated=bool(b.get("truncated")),
                    text=text,
                    shingles=shingles(text, args.shingle),
                )
            )
            idx += 1
    if missing:
        print(
            f"[select_curriculum] {missing} corpus lines had no base score (skipped/unscored)",
            file=sys.stderr,
        )
    if have_tuned:
        no_tuned = sum(1 for r in rows if r.bits_tuned is None)
        if no_tuned:
            print(
                f"[select_curriculum] {no_tuned} rows had no tuned score; their learned_bits "
                "is undefined and they rank as 0",
                file=sys.stderr,
            )
    truncated = sum(1 for r in rows if r.truncated)
    if truncated:
        print(
            f"[select_curriculum] WARNING: {truncated} rows were flagged truncated by "
            "score_bits.py; their bits are a lower bound",
            file=sys.stderr,
        )
    return rows, have_tuned


def emit_subset(corpus: Path, kept: Iterable[Row], out: Path) -> int:
    """Write the ORIGINAL bytes of the selected lines, in the original order.

    Re-serializing through json would be byte-stable only by luck (key order,
    unicode escaping, separators). Copying the source line is byte-stable by
    construction, so a diff against the parent corpus is meaningful.
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
    rows, have_tuned = load_rows(args)
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
    args.rank_by = rank_by

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
    )

    curve = []
    if args.redundancy_curve:
        thresholds = sorted({round(t, 2) for t in (0.5, 0.6, 0.7, 0.8, 0.9, 0.95, args.jaccard)})
        curve = redundancy_curve(rows, thresholds, args.max_exact)

    report = build_report(rows, sel, args, have_tuned, curve)
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
            "rank_normalize": args.rank_normalize,
            "target_fraction": args.target_fraction,
            "jaccard": args.jaccard,
            "shingle": args.shingle,
            "cluster_on": args.cluster_on,
            "min_per_class": args.min_per_class,
            "seed": args.seed,
            "kept": n,
            "of": len(rows),
            "kept_hashes": [r.hash for r in sel.kept],
        }
        Path(str(out) + ".meta.json").write_text(
            json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"[select_curriculum] wrote {n} examples to {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

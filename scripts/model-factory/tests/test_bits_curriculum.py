#!/usr/bin/env python3
"""Unit tests for score_bits.py and select_curriculum.py.

NO MODEL, NO GPU, NO NETWORK. Every formula the scorer depends on is exercised
against synthetic logprob fixtures through a stub scorer, and every selector
property Levi asked for is asserted directly.

  python3 scripts/model-factory/tests/test_bits_curriculum.py -v
"""

from __future__ import annotations

import io
import json
import math
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import score_bits as sb  # noqa: E402
import select_curriculum as sc  # noqa: E402


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

ROUTING_SYS = "# Session routing (prompt block for Fin's system prompt)\n\nYou manage terminal work."
LEDGER_SYS = "# Goal-driving tick (prompt block for Fin's heartbeat)\n\nYou are a copilot."
TOOLUSE_SYS = "You are Fin driving a coding agent in a live terminal, on the owner's behalf."
ELICIT_SYS = "You are Fin, foreman of a factory of coding agents, advancing a mission."


def example(system: str, user: str, answer: dict) -> list[dict]:
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
        {"role": "assistant", "content": json.dumps(answer)},
    ]


def uniform_scorer(vocab: int) -> sb.StubScorer:
    """Every token equally likely => exactly log2(vocab) bits per token."""
    return sb.StubScorer(vocab, lambda row, v: 0.0)


def peaked_scorer(vocab: int, favored: int, boost: float) -> sb.StubScorer:
    return sb.StubScorer(vocab, lambda row, v: boost if v == favored else 0.0)


# ---------------------------------------------------------------------------
# 1. the bits formula
# ---------------------------------------------------------------------------


class TestBitsFormula(unittest.TestCase):
    def test_bits_is_nats_times_log2_e(self):
        for nats in (0.0, 0.5, 1.0, math.log(2.0), 12.75, 1234.5):
            self.assertAlmostEqual(sb.bits_from_nats(nats), nats * math.log2(math.e), places=12)

    def test_one_nat_is_log2_e_bits(self):
        self.assertAlmostEqual(sb.bits_from_nats(1.0), 1.4426950408889634, places=12)

    def test_uniform_distribution_costs_log2_vocab_bits(self):
        """The sanity anchor: a uniform distribution over V symbols costs
        exactly log2(V) bits per token, whatever the target is."""
        vocab = 8
        rows = [[0.0] * vocab for _ in range(5)]
        nats = sb.nats_from_logits(rows, [0, 1, 2, 3, 7])
        for n in nats:
            self.assertAlmostEqual(sb.bits_from_nats(n), 3.0, places=12)

    def test_log_softmax_is_normalized(self):
        lp = sb.log_softmax([1.0, -2.0, 7.5, 0.25])
        self.assertAlmostEqual(sum(math.exp(v) for v in lp), 1.0, places=12)

    def test_log_softmax_is_stable_on_large_logits(self):
        lp = sb.log_softmax([1e4, 1e4 - 1.0, 1e4 - 2.0])
        self.assertAlmostEqual(sum(math.exp(v) for v in lp), 1.0, places=10)
        self.assertFalse(any(math.isnan(v) or math.isinf(v) for v in lp))

    def test_a_certain_token_costs_zero_bits(self):
        nats = sb.nats_from_logits([[100.0, 0.0, 0.0]], [0])
        self.assertAlmostEqual(sb.bits_from_nats(nats[0]), 0.0, places=6)

    def test_nats_from_logits_rejects_misaligned_targets(self):
        with self.assertRaises(ValueError):
            sb.nats_from_logits([[0.0, 0.0]], [0, 1])


# ---------------------------------------------------------------------------
# 2. the masking / index math
# ---------------------------------------------------------------------------


class TestMasking(unittest.TestCase):
    def test_mask_selects_exactly_the_answer_tokens(self):
        # Hand-built: 7 prompt tokens, then a 4-token answer.
        prompt = [2, 105, 50, 51, 106, 107, 105]
        answer = [900, 901, 902, 106]
        tokens = prompt + answer
        plan = sb.plan_mask(tokens, offset=len(prompt), max_seq_length=64, match_trainer=False)
        self.assertTrue(plan.usable)
        self.assertEqual(plan.targets, answer)
        self.assertEqual(plan.answer_tokens, 4)
        self.assertEqual(plan.answer_tokens, len(tokens) - len(prompt))
        # row r predicts position r+1, so the first row is offset-1.
        self.assertEqual(plan.rows, [6, 7, 8, 9])
        self.assertEqual(plan.rows[0], len(prompt) - 1)
        self.assertEqual(plan.rows[-1], len(tokens) - 2)
        # and no prompt token is ever a target
        for t in plan.targets:
            self.assertNotIn(t, prompt[:1])

    def test_trainer_parity_adds_exactly_one_pad_step(self):
        tokens = list(range(2, 22))  # L = 20
        plain = sb.plan_mask(tokens, 15, 64, match_trainer=False)
        parity = sb.plan_mask(tokens, 15, 64, match_trainer=True)
        self.assertEqual(plain.answer_tokens, 5)
        self.assertEqual(len(plain.rows), 5)
        self.assertEqual(len(parity.rows), 6)
        self.assertEqual(parity.targets[-1], sb.PAD_ID)
        self.assertEqual(parity.rows[-1], len(tokens) - 1)
        # ntoks the trainer reports is L - offset + 1
        self.assertEqual(parity.trainer_tokens, len(tokens) - 15 + 1)
        self.assertEqual(plain.trainer_tokens, parity.trainer_tokens)

    def test_answer_bits_ignore_the_parity_pad_step(self):
        """The primary number must not move when --match-trainer is on."""
        tokens = list(range(2, 22))  # ids 2..21, so the stub vocab must exceed 21
        vocab = 32
        scorer = uniform_scorer(vocab)
        plain = sb.plan_mask(tokens, 15, 64, match_trainer=False)
        parity = sb.plan_mask(tokens, 15, 64, match_trainer=True)
        a1, _ = sb.split_nats(plain, scorer.row_nats(tokens, plain), False)
        a2, t2 = sb.split_nats(parity, scorer.row_nats(tokens, parity), True)
        self.assertAlmostEqual(a1, a2, places=12)
        self.assertGreater(t2, a2)  # the pad step costs something under a uniform model

    def test_split_nats_rejects_a_wrong_length_vector(self):
        tokens = list(range(2, 12))
        plan = sb.plan_mask(tokens, 5, 64)
        with self.assertRaises(ValueError):
            sb.split_nats(plan, [0.1, 0.2], True)

    def test_offset_below_one_is_unusable(self):
        plan = sb.plan_mask([1, 2, 3], 0, 64)
        self.assertFalse(plan.usable)
        self.assertIn("offset", plan.note)


# ---------------------------------------------------------------------------
# 3. truncation
# ---------------------------------------------------------------------------


class TestTruncation(unittest.TestCase):
    def test_a_truncated_answer_is_flagged(self):
        tokens = list(range(2, 62))  # L = 60
        plan = sb.plan_mask(tokens, offset=40, max_seq_length=50, match_trainer=True)
        self.assertTrue(plan.truncated)
        self.assertEqual(plan.tokens_lost, 10)
        self.assertEqual(plan.effective_length, 50)
        self.assertEqual(plan.answer_tokens, 10)  # 50 - 40, not 60 - 40
        # A truncated batch is exactly max_seq_length wide, so there is no
        # trailing pad column and the trainer's ntoks collapses to L' - offset.
        self.assertEqual(plan.trainer_tokens, 10)
        self.assertEqual(len(plan.rows), 10)
        self.assertNotIn(sb.PAD_ID, plan.targets)

    def test_an_untruncated_example_is_not_flagged(self):
        tokens = list(range(2, 62))
        plan = sb.plan_mask(tokens, offset=40, max_seq_length=3072)
        self.assertFalse(plan.truncated)
        self.assertEqual(plan.tokens_lost, 0)

    def test_a_prompt_that_fills_the_window_is_unusable_not_silently_scored(self):
        tokens = list(range(2, 200))
        plan = sb.plan_mask(tokens, offset=64, max_seq_length=64)
        self.assertFalse(plan.usable)
        self.assertTrue(plan.truncated)
        self.assertEqual(plan.rows, [])
        self.assertIn("truncated away", plan.note)

    def test_score_example_marks_a_skipped_row_and_keeps_the_columns(self):
        ex = sb.Example(0, [], "", "h0", "routing", "route")
        rec = sb.score_example(ex, list(range(200)), 64, 64, True, uniform_scorer(4), "m", None)
        self.assertTrue(rec["skipped"])
        self.assertIsNone(rec["bits"])
        self.assertTrue(rec["truncated"])
        self.assertEqual(rec["target"], "routing")

    def test_summarize_counts_truncations_and_skips(self):
        rows = [
            {"skipped": False, "truncated": True, "bits": 8.0, "answer_tokens": 4,
             "trainer_tokens": 4, "trainer_nats": 1.0},
            {"skipped": False, "truncated": False, "bits": 4.0, "answer_tokens": 4,
             "trainer_tokens": 5, "trainer_nats": 1.0},
            {"skipped": True, "truncated": True},
        ]
        s = sb.summarize(rows)
        self.assertEqual(s["examples"], 3)
        self.assertEqual(s["scored"], 2)
        self.assertEqual(s["skipped"], 1)
        self.assertEqual(s["truncated"], 2)
        self.assertAlmostEqual(s["total_bits"], 12.0)
        self.assertAlmostEqual(s["mean_bits_per_token"], 1.5)


# ---------------------------------------------------------------------------
# 4. end-to-end scoring against synthetic logprob fixtures
# ---------------------------------------------------------------------------


class TestStubScoring(unittest.TestCase):
    def test_uniform_model_charges_log2_vocab_per_answer_token(self):
        tokens = [2, 10, 11, 12, 20, 21, 22, 23]
        offset = 4
        vocab = 32
        ex = sb.Example(0, [], "", "h", "routing", "route")
        rec = sb.score_example(ex, tokens, offset, 64, False, uniform_scorer(vocab), "stub", None)
        self.assertEqual(rec["answer_tokens"], 4)
        self.assertAlmostEqual(rec["bits"], 4 * math.log2(vocab), places=10)
        self.assertAlmostEqual(rec["bits_per_token"], math.log2(vocab), places=10)
        self.assertAlmostEqual(rec["nats"], rec["bits"] * math.log(2.0), places=10)

    def test_a_model_that_knows_the_answer_charges_almost_nothing(self):
        tokens = [2, 10, 11, 12, 7, 7, 7, 7]
        scorer = peaked_scorer(32, favored=7, boost=30.0)
        ex = sb.Example(0, [], "", "h", "routing", "route")
        rec = sb.score_example(ex, tokens, 4, 64, False, scorer, "stub", None)
        self.assertLess(rec["bits"], 1e-6)

    def test_learned_bits_is_base_minus_tuned(self):
        """The whole point: an untuned model pays, a tuned one does not, and the
        difference is what the run acquired."""
        tokens = [2, 10, 11, 12, 7, 7, 7, 7]
        ex = sb.Example(0, [], "", "h", "routing", "route")
        base = sb.score_example(ex, tokens, 4, 64, False, uniform_scorer(32), "stub", None)
        tuned = sb.score_example(ex, tokens, 4, 64, False, peaked_scorer(32, 7, 30.0), "stub", "a")
        learned = base["bits"] - tuned["bits"]
        self.assertAlmostEqual(learned, 4 * 5.0, places=4)  # log2(32) == 5 bits/token
        self.assertGreater(learned, 0)

    def test_scoring_is_deterministic_across_repeats(self):
        tokens = [2, 10, 11, 12, 20, 21, 22, 23]
        ex = sb.Example(3, [], "", "h", "ledger", "drive")
        scorer = peaked_scorer(64, favored=21, boost=2.5)
        first = sb.score_example(ex, tokens, 4, 64, True, scorer, "stub", None)
        second = sb.score_example(ex, tokens, 4, 64, True, scorer, "stub", None)
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))


# ---------------------------------------------------------------------------
# 5. classification / hashing / resume plumbing
# ---------------------------------------------------------------------------


class TestClassification(unittest.TestCase):
    def test_targets_come_off_the_system_prompt(self):
        cases = [
            (ROUTING_SYS, {"action": "route", "session": "s", "reason": "r"}, "routing", "route"),
            (LEDGER_SYS, {"decision": "drive", "goal_id": "g", "reason": "r"}, "ledger", "drive"),
            (TOOLUSE_SYS, {"tool": "send_input", "arguments": {}}, "tooluse", "send_input"),
            (ELICIT_SYS, {"action": "ask", "question": "q", "reason": "r"}, "elicit", "ask"),
        ]
        for system, answer, target, decision in cases:
            t, d = sb.classify(example(system, "u", answer))
            self.assertEqual((t, d), (target, decision))

    def test_schema_fallback_when_the_prompt_is_unknown(self):
        t, d = sb.classify(example("some other prompt", "u", {"tool": "notify", "arguments": {}}))
        self.assertEqual((t, d), ("tooluse", "notify"))
        t, d = sb.classify(example("some other prompt", "u", {"decision": "idle", "reason": "r"}))
        self.assertEqual((t, d), ("ledger", "idle"))
        t, d = sb.classify(example("some other prompt", "u", {"action": "refuse", "reason": "r"}))
        self.assertEqual((t, d), ("routing", "refuse"))

    def test_unparseable_answer_does_not_explode(self):
        msgs = [
            {"role": "system", "content": "mystery"},
            {"role": "user", "content": "u"},
            {"role": "assistant", "content": "not json at all"},
        ]
        self.assertEqual(sb.classify(msgs), ("unknown", "unparsed"))

    def test_content_hash_is_stable_and_discriminating(self):
        a = example(ROUTING_SYS, "route me", {"action": "route", "session": "s", "reason": "r"})
        b = example(ROUTING_SYS, "route me", {"action": "route", "session": "s", "reason": "r"})
        c = example(ROUTING_SYS, "route me too", {"action": "route", "session": "s", "reason": "r"})
        self.assertEqual(sb.content_hash(a), sb.content_hash(b))
        self.assertNotEqual(sb.content_hash(a), sb.content_hash(c))

    def test_read_scored_repairs_a_torn_tail(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "scores.jsonl"
            p.write_text('{"hash": "a", "bits": 1.0}\n{"hash": "b", "bi\n')
            rows, torn = sb.read_scored(p)
            self.assertTrue(torn)
            self.assertEqual([r["hash"] for r in rows], ["a"])

    def test_guard_pattern_never_matches_this_source_file(self):
        """The pgrep pattern is assembled at runtime so the script cannot see
        itself and refuse to run."""
        src = Path(sb.__file__).read_text()
        self.assertNotIn(sb._TRAINING_PATTERN, src)
        self.assertEqual(sb._TRAINING_PATTERN, "mlx_lm lora")


# ---------------------------------------------------------------------------
# 6. selector: clustering
# ---------------------------------------------------------------------------


class TestClustering(unittest.TestCase):
    def test_near_duplicates_land_in_one_cluster(self):
        rows = []
        for i, text in enumerate(
            [
                "please switch over to the sonata session and run the tests",
                "please switch over to the sonata session and run the test",
                "burn the ledger down and start a brand new mission from zero",
            ]
        ):
            rows.append(
                sc.Row(
                    index=i, hash=f"h{i}", target="routing", decision_class="route",
                    answer_tokens=10, bits_base=1.0, bits_tuned=None, truncated=False,
                    text=text, shingles=sc.shingles(text, 3),
                )
            )
        groups = sc.cluster_partition(rows, threshold=0.5, max_exact=100)
        sizes = sorted(len(g) for g in groups)
        self.assertEqual(sizes, [1, 2])

    def test_distinct_text_stays_in_separate_clusters(self):
        texts = [
            "route to brewlog and tail the build output",
            "close out the recipe scaling goal, it finished an hour ago",
            "ask the owner whether to ship on friday or hold for review",
        ]
        rows = [
            sc.Row(i, f"h{i}", "routing", "route", 10, 1.0, None, False, t, sc.shingles(t, 3))
            for i, t in enumerate(texts)
        ]
        groups = sc.cluster_partition(rows, threshold=0.8, max_exact=100)
        self.assertEqual(len(groups), 3)

    def test_cluster_text_excludes_the_system_prompt(self):
        msgs = example(ROUTING_SYS, "hello world", {"action": "route", "session": "s", "reason": "r"})
        text = sc.cluster_text(msgs, "both")
        self.assertNotIn("Session routing", text)
        self.assertIn("hello world", text)
        self.assertIn("route", text)

    def test_jaccard_edges(self):
        self.assertEqual(sc.jaccard(frozenset(), frozenset()), 1.0)
        self.assertEqual(sc.jaccard(frozenset("a"), frozenset()), 0.0)
        self.assertAlmostEqual(sc.jaccard(frozenset("abc"), frozenset("abd")), 0.5)

    def test_partition_over_max_exact_refuses_rather_than_guessing(self):
        rows = [
            sc.Row(i, f"h{i}", "routing", "route", 1, 1.0, None, False, "x y z", sc.shingles("x y z", 3))
            for i in range(5)
        ]
        with self.assertRaises(SystemExit):
            sc.cluster_partition(rows, threshold=0.8, max_exact=3)


# ---------------------------------------------------------------------------
# 7. selector: budget, proportions, preference, determinism
# ---------------------------------------------------------------------------


def make_rows(spec: list[tuple[str, str, str, float]]) -> list[sc.Row]:
    """spec entries: (target, decision_class, text, bits_base)."""
    rows = []
    for i, (target, cls, text, bits) in enumerate(spec):
        rows.append(
            sc.Row(
                index=i, hash=f"h{i:03d}", target=target, decision_class=cls,
                answer_tokens=10, bits_base=bits, bits_tuned=None, truncated=False,
                text=text, shingles=sc.shingles(text, 3),
            )
        )
    return rows


def synthetic_corpus() -> list[sc.Row]:
    """Two targets, four classes, 40 examples, with deliberate near-duplicates."""
    spec = []
    for cls, base_text in (("route", "route me to the {} session now"), ("refuse", "the {} box is not registered here")):
        for i in range(10):
            # examples 0-4 of each class are near-duplicates of one another
            name = "alpha" if i < 5 else f"proj{i}"
            spec.append(("routing", cls, base_text.format(name), float(i + 1)))
    for cls, base_text in (("drive", "advance the {} milestone please"), ("idle", "nothing is pending on {} right now")):
        for i in range(10):
            name = "alpha" if i < 5 else f"goal{i}"
            spec.append(("ledger", cls, base_text.format(name), float(20 - i)))
    return make_rows(spec)


class TestSelector(unittest.TestCase):
    def setUp(self):
        self.rows = synthetic_corpus()

    def test_class_proportions_are_preserved(self):
        sel = sc.select(self.rows, 0.5, "bits_base", False, 0.8, 3, 1, 17, 4000)
        for partition in {r.partition for r in self.rows}:
            orig = sum(1 for r in self.rows if r.partition == partition)
            kept = sum(1 for r in sel.kept if r.partition == partition)
            self.assertEqual(kept, round(0.5 * orig), f"{partition} drifted")
        self.assertEqual(len(sel.kept), 20)

    def test_every_class_survives_even_at_a_tiny_budget(self):
        sel = sc.select(self.rows, 0.01, "bits_base", False, 0.8, 3, 1, 17, 4000)
        kept_classes = {r.partition for r in sel.kept}
        self.assertEqual(kept_classes, {r.partition for r in self.rows})
        self.assertEqual(len(sel.kept), 4)  # min_per_class = 1, four partitions

    def test_min_per_class_floor_is_respected(self):
        sel = sc.select(self.rows, 0.01, "bits_base", False, 0.8, 3, 3, 17, 4000)
        for partition in {r.partition for r in self.rows}:
            self.assertGreaterEqual(sum(1 for r in sel.kept if r.partition == partition), 3)

    def test_it_prefers_high_bits_cluster_representatives(self):
        sel = sc.select(self.rows, 0.25, "bits_base", False, 0.8, 3, 1, 17, 4000)
        kept_hashes = {r.hash for r in sel.kept}
        for partition, clusters in sel.clusters.items():
            for cluster in clusters:
                chosen = [m for m in cluster.members if m.hash in kept_hashes]
                if not chosen:
                    continue
                best = max(m.bits_base for m in cluster.members)
                # the cluster's representative -- its highest-bits member -- is
                # always the first one taken
                self.assertAlmostEqual(max(m.bits_base for m in chosen), best)

    def test_kept_bits_beat_a_same_size_worst_case(self):
        sel = sc.select(self.rows, 0.25, "bits_base", False, 0.8, 3, 1, 17, 4000)
        kept_bits = sum(r.bits_base for r in sel.kept)
        worst = sorted(self.rows, key=lambda r: r.bits_base)[: len(sel.kept)]
        self.assertGreater(kept_bits, sum(r.bits_base for r in worst))

    def test_it_covers_clusters_before_it_doubles_up(self):
        """With a budget at least as large as the cluster count, every cluster
        must have a representative -- coverage first, depth second."""
        sel = sc.select(self.rows, 0.5, "bits_base", False, 0.8, 3, 1, 17, 4000)
        kept_hashes = {r.hash for r in sel.kept}
        for partition, clusters in sel.clusters.items():
            if sel.quotas[partition] >= len(clusters):
                for cluster in clusters:
                    self.assertTrue(
                        any(m.hash in kept_hashes for m in cluster.members),
                        f"cluster in {partition} went unrepresented",
                    )

    def test_deterministic_under_a_fixed_seed(self):
        a = sc.select(self.rows, 0.25, "bits_base", False, 0.8, 3, 1, 17, 4000)
        b = sc.select(self.rows, 0.25, "bits_base", False, 0.8, 3, 1, 17, 4000)
        self.assertEqual([r.hash for r in a.kept], [r.hash for r in b.kept])
        self.assertEqual([r.hash for r in a.dropped], [r.hash for r in b.dropped])

    def test_ties_are_broken_by_the_seed_not_by_dict_order(self):
        flat = make_rows([("routing", "route", f"unique text number {i} here", 5.0) for i in range(20)])
        a = sc.select(flat, 0.25, "bits_base", False, 0.9, 3, 1, 17, 4000)
        b = sc.select(flat, 0.25, "bits_base", False, 0.9, 3, 1, 99, 4000)
        self.assertNotEqual([r.hash for r in a.kept], [r.hash for r in b.kept])
        # ...but each seed is itself reproducible
        again = sc.select(flat, 0.25, "bits_base", False, 0.9, 3, 1, 99, 4000)
        self.assertEqual([r.hash for r in b.kept], [r.hash for r in again.kept])

    def test_random_control_arm_is_proportional_but_information_blind(self):
        """The control the experiment needs: same budget, same class shares,
        blind to bits. If bits-selection cannot beat this at the gate, bits
        bought nothing."""
        rnd = sc.select(self.rows, 0.5, "random", False, 1.01, 3, 1, 999, 4000)
        bits = sc.select(self.rows, 0.5, "bits_base", False, 1.01, 3, 1, 999, 4000)
        for partition in {r.partition for r in self.rows}:
            orig = sum(1 for r in self.rows if r.partition == partition)
            self.assertEqual(sum(1 for r in rnd.kept if r.partition == partition), round(0.5 * orig))
        self.assertNotEqual({r.hash for r in rnd.kept}, {r.hash for r in bits.kept})
        # reproducible, and a different seed draws a different sample
        again = sc.select(self.rows, 0.5, "random", False, 1.01, 3, 1, 999, 4000)
        other = sc.select(self.rows, 0.5, "random", False, 1.01, 3, 1, 1000, 4000)
        self.assertEqual([r.hash for r in rnd.kept], [r.hash for r in again.kept])
        self.assertNotEqual({r.hash for r in rnd.kept}, {r.hash for r in other.kept})

    def test_kept_and_dropped_partition_the_corpus_exactly(self):
        sel = sc.select(self.rows, 0.3, "bits_base", False, 0.8, 3, 1, 17, 4000)
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(self.rows))
        self.assertEqual(
            {r.hash for r in sel.kept} | {r.hash for r in sel.dropped},
            {r.hash for r in self.rows},
        )
        self.assertFalse({r.hash for r in sel.kept} & {r.hash for r in sel.dropped})

    def test_every_drop_carries_a_reason(self):
        sel = sc.select(self.rows, 0.3, "bits_base", False, 0.8, 3, 1, 17, 4000)
        for r in sel.dropped:
            self.assertIn(r.hash, sel.reasons)
            self.assertTrue(sel.reasons[r.hash].startswith(("redundant", "low-information")))

    def test_kept_stays_in_corpus_order(self):
        sel = sc.select(self.rows, 0.4, "bits_base", False, 0.8, 3, 1, 17, 4000)
        self.assertEqual([r.index for r in sel.kept], sorted(r.index for r in sel.kept))

    def test_full_budget_keeps_everything(self):
        sel = sc.select(self.rows, 1.0, "bits_base", False, 0.8, 3, 1, 17, 4000)
        self.assertEqual(len(sel.kept), len(self.rows))
        self.assertEqual(sel.dropped, [])

    def test_ranking_on_learned_bits_reorders_the_picks(self):
        rows = []
        for i in range(10):
            text = f"a completely distinct sentence number {i} about work"
            rows.append(
                sc.Row(i, f"h{i}", "routing", "route", 10, bits_base=float(i),
                       bits_tuned=float(i) - (10 - i) * 0.5, truncated=False,
                       text=text, shingles=sc.shingles(text, 3))
            )
        by_base = sc.select(rows, 0.3, "bits_base", False, 0.9, 3, 1, 17, 4000)
        by_learned = sc.select(rows, 0.3, "learned_bits", False, 0.9, 3, 1, 17, 4000)
        self.assertNotEqual({r.hash for r in by_base.kept}, {r.hash for r in by_learned.kept})
        # learned_bits = (10 - i) * 0.5 is largest at i = 0
        self.assertIn("h0", {r.hash for r in by_learned.kept})

    def test_rank_normalize_favors_dense_short_answers(self):
        rows = [
            sc.Row(0, "h0", "routing", "route", answer_tokens=100, bits_base=50.0,
                   bits_tuned=None, truncated=False, text="long winded first case here",
                   shingles=sc.shingles("long winded first case here", 3)),
            sc.Row(1, "h1", "routing", "route", answer_tokens=5, bits_base=20.0,
                   bits_tuned=None, truncated=False, text="terse second case there",
                   shingles=sc.shingles("terse second case there", 3)),
        ]
        plain = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000)
        dense = sc.select(rows, 0.5, "bits_base", True, 0.9, 3, 1, 17, 4000)
        self.assertEqual([r.hash for r in plain.kept], ["h0"])  # 50 bits > 20 bits
        self.assertEqual([r.hash for r in dense.kept], ["h1"])  # 4.0 b/tok > 0.5 b/tok


# ---------------------------------------------------------------------------
# 8. selector: degrading sanely, statistics, byte-stable emission
# ---------------------------------------------------------------------------


class TestStatistics(unittest.TestCase):
    def test_percentiles(self):
        vals = [float(i) for i in range(101)]
        self.assertAlmostEqual(sc.percentile(vals, 50), 50.0)
        self.assertAlmostEqual(sc.percentile(vals, 1), 1.0)
        self.assertAlmostEqual(sc.percentile(vals, 99), 99.0)
        self.assertEqual(sc.percentile([], 50), 0.0)
        self.assertEqual(sc.percentile([7.0], 90), 7.0)

    def test_gini_of_equal_values_is_zero(self):
        self.assertAlmostEqual(sc.gini([3.0] * 50), 0.0, places=9)

    def test_gini_of_a_single_holder_approaches_one(self):
        vals = [0.0] * 99 + [100.0]
        self.assertGreater(sc.gini(vals), 0.98)

    def test_top_share(self):
        vals = [10.0] + [0.0] * 9
        self.assertAlmostEqual(sc.top_share(vals, 0.10), 1.0)
        self.assertEqual(sc.top_share([], 0.25), 0.0)
        self.assertEqual(sc.top_share([0.0, 0.0], 0.5), 0.0)


class TestEndToEndCLI(unittest.TestCase):
    """The selector must run, degrade sanely with one score file, and emit a
    byte-stable subset."""

    def _write_corpus(self, d: Path) -> tuple[Path, list[str]]:
        lines = []
        for i in range(20):
            target = "routing" if i < 10 else "ledger"
            if target == "routing":
                msgs = example(ROUTING_SYS, f"send the {i} job to the alpha session",
                               {"action": "route", "session": f"s{i}", "reason": "named"})
            else:
                msgs = example(LEDGER_SYS, f"advance milestone number {i} for the crew",
                               {"decision": "drive", "goal_id": f"g{i}", "reason": "top"})
            lines.append(json.dumps({"messages": msgs}, ensure_ascii=False) + "\n")
        corpus = d / "corpus.jsonl"
        corpus.write_text("".join(lines), encoding="utf-8")
        return corpus, lines

    def _write_scores(self, d: Path, corpus: Path, name: str, scale: float) -> Path:
        p = d / name
        with p.open("w", encoding="utf-8") as fh:
            for i, line in enumerate(corpus.read_text().splitlines()):
                msgs = json.loads(line)["messages"]
                target, decision = sb.classify(msgs)
                fh.write(json.dumps({
                    "hash": sb.content_hash(msgs), "index": i, "target": target,
                    "decision_class": decision, "answer_tokens": 20,
                    "bits": (i + 1) * scale, "truncated": False, "skipped": False,
                }, sort_keys=True) + "\n")
        return p

    def test_base_only_run_degrades_sanely(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            out = d / "subset.jsonl"
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = sc.main([
                    "--base", str(base), "--corpus", str(corpus),
                    "--target-fraction", "0.5", "--out", str(out),
                    "--rank-by", "auto",
                ])
            self.assertEqual(rc, 0)
            report = buf.getvalue()
            self.assertIn("base-only mode", report)
            self.assertIn("BITS DISTRIBUTION", report)
            self.assertIn("REDUNDANCY", report)
            self.assertIn("WHAT WAS DROPPED", report)
            self.assertNotIn("HIGH-RESIDUAL", report)  # needs --tuned
            self.assertEqual(len(out.read_text().splitlines()), 10)

    def test_explicit_learned_bits_without_tuned_falls_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            buf, err = io.StringIO(), io.StringIO()
            with redirect_stdout(buf):
                stderr, sys.stderr = sys.stderr, err
                try:
                    rc = sc.main(["--base", str(base), "--corpus", str(corpus),
                                  "--rank-by", "learned_bits", "--target-fraction", "0.5"])
                finally:
                    sys.stderr = stderr
            self.assertEqual(rc, 0)
            self.assertIn("falling back to bits_base", err.getvalue())

    def test_tuned_run_reports_all_four_quantities(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 2.0)
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 0.5)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = sc.main(["--base", str(base), "--tuned", str(tuned),
                              "--corpus", str(corpus), "--target-fraction", "0.5"])
            self.assertEqual(rc, 0)
            report = buf.getvalue()
            for needle in ("bits_tuned (residual)", "learned_bits", "HIGH-RESIDUAL"):
                self.assertIn(needle, report)

    def test_subset_lines_are_byte_identical_to_the_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, lines = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            out = d / "subset.jsonl"
            with redirect_stdout(io.StringIO()):
                sc.main(["--base", str(base), "--corpus", str(corpus),
                         "--target-fraction", "0.5", "--out", str(out)])
            kept = out.read_text(encoding="utf-8").splitlines(keepends=True)
            for line in kept:
                self.assertIn(line, lines)  # byte-for-byte, not re-serialized
            # and in the original order
            positions = [lines.index(line) for line in kept]
            self.assertEqual(positions, sorted(positions))
            meta = json.loads((d / "subset.jsonl.meta.json").read_text())
            self.assertEqual(meta["kept"], len(kept))

    def test_emission_is_reproducible_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            a, b = d / "a.jsonl", d / "b.jsonl"
            for out in (a, b):
                with redirect_stdout(io.StringIO()):
                    sc.main(["--base", str(base), "--corpus", str(corpus),
                             "--target-fraction", "0.35", "--out", str(out), "--seed", "17"])
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_it_refuses_to_select_from_an_eval_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "evals" / "tmux-routing"
            d.mkdir(parents=True)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(Path(tmp), corpus, "base.jsonl", 1.0)
            with self.assertRaises(SystemExit) as ctx:
                sc.main(["--base", str(base), "--corpus", str(corpus)])
            self.assertIn("leakage", str(ctx.exception).lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)

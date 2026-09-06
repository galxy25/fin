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

import parity_check as pc  # noqa: E402
import score_bits as sb  # noqa: E402
import select_curriculum as sc  # noqa: E402

EXPERIMENT_SH = Path(__file__).resolve().parent.parent / "run_bits_experiment.sh"


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
        # the LITERAL id, not sb.PAD_ID: comparing the constant to itself would
        # pass for any value, and iterate_batches pads with np.zeros -> 0.
        self.assertEqual(parity.targets[-1], 0)
        self.assertEqual(parity.rows[-1], len(tokens) - 1)
        # ntoks the trainer reports is L - offset + 1
        self.assertEqual(parity.trainer_tokens, len(tokens) - 15 + 1)
        self.assertTrue(parity.has_pad_step)

    def test_no_match_trainer_drops_the_pad_step_from_the_COUNT_too(self):
        """Otherwise summarize() divides answer-only nats by a token count that
        includes a step whose nats were never summed, and
        trainer_parity_loss_nats -- the number the README says to compare
        against the logged validation loss -- comes out biased low."""
        tokens = list(range(2, 22))
        plain = sb.plan_mask(tokens, 15, 64, match_trainer=False)
        self.assertFalse(plain.has_pad_step)
        self.assertEqual(plain.trainer_tokens, plain.answer_tokens)
        vocab = 32
        rec = sb.score_example(
            sb.Example(0, [], "", "h", "routing", "route"),
            tokens, 15, 64, False, uniform_scorer(vocab), "stub", None,
        )
        stats = sb.summarize([rec])
        # a uniform model costs exactly ln(vocab) nats per token, pad step or not
        self.assertAlmostEqual(stats["trainer_parity_loss_nats"], math.log(vocab), places=10)

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
        self.assertTrue(plan.has_pad_step)

    def test_an_exact_fit_gets_no_pad_step_either(self):
        """L == max_seq_length loses no tokens, so it is not 'truncated' -- but
        iterate_batches caps the batch width at max_seq_length, so there is no
        pad column and the trainer's ntoks is L - offset, not L - offset + 1.
        Keying the pad step off `truncated` over-counted this boundary by one."""
        tokens = list(range(64))  # L == max_seq_length
        plan = sb.plan_mask(tokens, offset=40, max_seq_length=64, match_trainer=True)
        self.assertFalse(plan.truncated)
        self.assertTrue(plan.window_full)
        self.assertFalse(plan.has_pad_step)
        self.assertEqual(plan.answer_tokens, 24)
        self.assertEqual(plan.trainer_tokens, 24)
        self.assertEqual(len(plan.rows), 24)
        self.assertNotIn(0, plan.targets[24:])  # no pad target was appended

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
# 4b. the DECISION mask -- the tokens the eval gate actually compares
# ---------------------------------------------------------------------------


def char_tokens(text: str) -> list[int]:
    """A character-level tokenization, matching StubScorer.decode."""
    return [ord(c) for c in text]


class TestDecisionMask(unittest.TestCase):
    ANSWER = '{"action": "route", "session": "alpha", "reason": "the named session is live"}'

    def _plan_and_keep(self, answer: str, fields=("action", "session"), prompt="PROMPT>"):
        tokens = char_tokens(prompt + answer)
        plan = sb.plan_mask(tokens, len(prompt), 4096, match_trainer=True)
        stub = sb.StubScorer(256, lambda r, v: 0.0)
        return plan, tokens, sb.decision_indices(plan, tokens, answer, fields, stub.decode)

    def test_field_spans_cover_the_key_and_the_whole_value(self):
        spans = sb.field_spans(self.ANSWER, ("action", "session"))
        self.assertEqual([self.ANSWER[a:b] for a, b in spans],
                         ['"action": "route"', '"session": "alpha"'])

    def test_field_spans_handle_escapes_and_nesting(self):
        text = '{"tool": "x", "arguments": {"cmd": "echo \\"hi\\"", "n": [1, 2]}, "action": 3}'
        spans = sb.field_spans(text, ("arguments", "action"))
        self.assertEqual(text[spans[0][0]:spans[0][1]],
                         '"arguments": {"cmd": "echo \\"hi\\"", "n": [1, 2]}')
        self.assertEqual(text[spans[1][0]:spans[1][1]], '"action": 3')

    def test_a_key_that_is_only_a_lookalike_string_is_not_a_span(self):
        text = '{"reason": "the action was refused", "action": "refuse"}'
        spans = sb.field_spans(text, ("action",))
        self.assertEqual([text[a:b] for a, b in spans], ['"action": "refuse"'])

    def test_the_mask_selects_exactly_the_gate_scored_characters(self):
        plan, tokens, keep = self._plan_and_keep(self.ANSWER)
        self.assertEqual("".join(self.ANSWER[i] for i in keep),
                         '"action": "route""session": "alpha"')
        self.assertLess(len(keep), plan.answer_tokens)

    def test_decision_bits_are_a_strict_subset_of_the_answer_bits(self):
        answer = self.ANSWER
        tokens = char_tokens("PROMPT>" + answer)
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "routing", "route")
        rec = sb.score_example(ex, tokens, 7, 4096, True, uniform_scorer(256), "stub", None)
        self.assertTrue(rec["decision_ok"])
        # a uniform model over 256 symbols costs 8 bits per token, either way
        self.assertAlmostEqual(rec["decision_bits"], 8.0 * rec["decision_tokens"], places=9)
        self.assertLess(rec["decision_bits"], rec["bits"])
        self.assertGreater(rec["decision_bits"], 0.0)

    def test_an_answer_without_the_fields_reports_unknown_not_zero(self):
        """Null, never 0.0: a zero would rank exactly like an example the model
        already knows, which is the opposite of 'we could not measure it'."""
        answer = '{"decision": "drive", "reason": "top goal"}'
        tokens = char_tokens("P>" + answer)
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "ledger", "drive")
        rec = sb.score_example(ex, tokens, 2, 4096, True, uniform_scorer(256), "stub", None)
        self.assertFalse(rec["decision_ok"])
        self.assertIsNone(rec["decision_bits"])
        self.assertEqual(rec["decision_tokens"], 0)
        self.assertIsNotNone(rec["bits"])  # the primary column is unaffected

    def test_a_truncated_answer_has_no_decision_column(self):
        answer = self.ANSWER
        tokens = char_tokens("P>" + answer)
        plan, _, keep = self._plan_and_keep(answer, prompt="P>")
        self.assertIsNotNone(keep)
        short = sb.plan_mask(tokens, 2, 20, match_trainer=True)  # cuts the answer
        stub = sb.StubScorer(256, lambda r, v: 0.0)
        self.assertTrue(short.truncated)
        self.assertIsNone(sb.decision_indices(short, tokens, answer, ("action",), stub.decode))

    def test_a_non_monotone_decode_is_refused_rather_than_guessed(self):
        tokens = char_tokens("P>" + self.ANSWER)
        plan = sb.plan_mask(tokens, 2, 4096, match_trainer=True)
        self.assertIsNone(
            sb.token_char_bounds(lambda ids: "x" * (10 - len(ids)), tokens, 2, 10)
        )
        self.assertIsNone(
            sb.decision_indices(plan, tokens, self.ANSWER, ("action",),
                                lambda ids: "not the answer text at all")
        )

    def test_summarize_reports_the_gate_scored_share(self):
        answer = self.ANSWER
        tokens = char_tokens("PROMPT>" + answer)
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "routing", "route")
        rec = sb.score_example(ex, tokens, 7, 4096, True, uniform_scorer(256), "stub", None)
        s = sb.summarize([rec])
        self.assertEqual(s["decision_scored"], 1)
        self.assertAlmostEqual(s["decision_share_of_bits"], rec["decision_bits"] / rec["bits"])
        self.assertLess(s["decision_share_of_bits"], 1.0)


# ---------------------------------------------------------------------------
# 4c. the machine guard -- the mechanism the whole design leans on
# ---------------------------------------------------------------------------


class TestGuard(unittest.TestCase):
    """The guard has to REFUSE, not merely exist. Every assertion here fails if
    a refusal is removed or inverted."""

    def setUp(self):
        self._pgrep, self._free = sb._pgrep, sb.free_gb

    def tearDown(self):
        sb._pgrep, sb.free_gb = self._pgrep, self._free

    def _run(self, pgrep, free, **kw):
        sb._pgrep = pgrep
        sb.free_gb = free
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            sb.guard(10, **kw)
            return None, err.getvalue()
        except SystemExit as exc:
            return exc.code, err.getvalue()
        finally:
            sys.stderr = stderr

    def test_it_refuses_while_a_fine_tune_is_alive(self):
        code, err = self._run(lambda p: ["18405"] if p == sb._TRAINING_PATTERN else [], lambda: 30.0)
        self.assertEqual(code, sb.BUSY_EXIT)
        self.assertIn("18405", err)

    def test_it_refuses_for_every_busy_pattern_not_just_lora(self):
        for pattern in sb._BUSY_PATTERNS:
            code, _ = self._run(lambda p, want=pattern: ["999"] if p == want else [], lambda: 30.0)
            self.assertEqual(code, sb.BUSY_EXIT, f"{pattern} did not stop the run")

    def test_it_refuses_when_memory_is_short(self):
        code, err = self._run(lambda p: [], lambda: 3.5)
        self.assertEqual(code, sb.BUSY_EXIT)
        self.assertIn("3.5 GB free", err)

    def test_it_proceeds_on_an_idle_machine(self):
        code, err = self._run(lambda p: [], lambda: 25.0)
        self.assertIsNone(code)
        self.assertIn("machine is clear", err)

    def test_it_FAILS_CLOSED_when_the_machine_cannot_be_read(self):
        """A guard that reads 'I could not check' as 'nothing is running' fails
        in exactly the direction that wedges the machine."""
        def boom(_p):
            raise sb.MachineUnknown("pgrep is missing")
        code, err = self._run(boom, lambda: 25.0)
        self.assertEqual(code, sb.BUSY_EXIT)
        self.assertIn("cannot verify", err)

        def no_vm_stat():
            raise sb.MachineUnknown("vm_stat failed")
        code, _ = self._run(lambda p: [], no_vm_stat)
        self.assertEqual(code, sb.BUSY_EXIT)

    def test_allow_unverified_is_the_only_way_past_an_unreadable_machine(self):
        def boom(_p):
            raise sb.MachineUnknown("pgrep is missing")
        code, err = self._run(boom, lambda: 25.0, allow_unverified=True)
        self.assertIsNone(code)
        self.assertIn("unverified", err)


class TestChunkedAssembly(unittest.TestCase):
    """MLXScorer's chunked path rebuilds logits rows POSITIONALLY and never
    reads plan.rows, so no stub-driven test can reach it. What IS testable is
    the assumption it makes about the plan -- which row_nats now asserts."""

    def test_expected_rows_match_the_plan_with_a_pad_step(self):
        tokens = list(range(2, 22))
        plan = sb.plan_mask(tokens, 15, 64, match_trainer=True)
        self.assertEqual(sb.MLXScorer.expected_rows(plan), plan.rows)

    def test_expected_rows_match_the_plan_without_a_pad_step(self):
        tokens = list(range(2, 22))
        for plan in (
            sb.plan_mask(tokens, 15, 64, match_trainer=False),
            sb.plan_mask(tokens, 15, 18, match_trainer=True),  # truncated
            sb.plan_mask(list(range(64)), 40, 64, match_trainer=True),  # exact fit
        ):
            self.assertEqual(sb.MLXScorer.expected_rows(plan), plan.rows)

    def test_a_shifted_plan_would_be_caught(self):
        tokens = list(range(2, 22))
        plan = sb.plan_mask(tokens, 15, 64, match_trainer=True)
        plan.rows = [r + 1 for r in plan.rows]
        self.assertNotEqual(sb.MLXScorer.expected_rows(plan), plan.rows)

    def test_row_nats_refuses_a_mismatched_plan_before_it_touches_mlx(self):
        """The assertion runs first, on an instance with no model behind it, so
        deleting it fails here rather than silently shipping a gather index that
        nothing checks."""
        scorer = sb.MLXScorer.__new__(sb.MLXScorer)  # no mlx, no weights
        tokens = list(range(2, 22))
        plan = sb.plan_mask(tokens, 15, 64, match_trainer=True)
        plan.rows = [r + 1 for r in plan.rows]
        with self.assertRaises(ValueError) as ctx:
            scorer.row_nats(tokens, plan)
        self.assertIn("chunked assembly", str(ctx.exception))


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

    def test_resume_refuses_to_mix_two_different_runs_in_one_file(self):
        """Resume is keyed on the content hash. Appending adapter-scored rows to
        a file of base-scored rows -- one forgotten --out away -- would make
        learned_bits = (partly tuned) - tuned for half the corpus, silently."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus = d / "corpus.jsonl"
            msgs = example(ROUTING_SYS, "route me", {"action": "route", "session": "s"})
            corpus.write_text(json.dumps({"messages": msgs}) + "\n", encoding="utf-8")
            out = d / "scores.jsonl"
            prior = sb.run_fingerprint("m", None, 3072, True, False)
            prior.update({"hash": "deadbeef", "bits": 1.0, "skipped": False})
            out.write_text(json.dumps(prior, sort_keys=True) + "\n", encoding="utf-8")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                rc = sb.main(["--model", "m", "--data", str(corpus), "--out", str(out),
                              "--adapter", str(d)])  # a DIFFERENT condition
            finally:
                sys.stderr = stderr
            self.assertEqual(rc, 2)
            self.assertIn("different settings", err.getvalue())

    def test_resume_accepts_a_file_from_the_same_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus = d / "corpus.jsonl"
            msgs = example(ROUTING_SYS, "route me", {"action": "route", "session": "s"})
            corpus.write_text(json.dumps({"messages": msgs}) + "\n", encoding="utf-8")
            out = d / "scores.jsonl"
            row = sb.run_fingerprint("m", None, 3072, True, False)
            row.update({"hash": sb.content_hash(msgs), "bits": 1.0, "skipped": False,
                        "answer_tokens": 4, "trainer_tokens": 5, "trainer_nats": 1.0,
                        "truncated": False})
            out.write_text(json.dumps(row, sort_keys=True) + "\n", encoding="utf-8")
            buf, err = io.StringIO(), io.StringIO()
            with redirect_stdout(buf):
                stderr, sys.stderr = sys.stderr, err
                try:
                    rc = sb.main(["--model", "m", "--data", str(corpus), "--out", str(out)])
                finally:
                    sys.stderr = stderr
            self.assertEqual(rc, 0)  # nothing to do, and no model was ever loaded
            self.assertIn("nothing to do", err.getvalue())

    def test_tools_are_threaded_into_both_template_calls(self):
        """ChatDataset.process passes d.get('tools') into both apply_chat_template
        calls. A hardcoded None here would tokenize a tools-carrying example
        differently from how the trainer tokenizes it, and the prefix assertion
        cannot catch it because both of our own calls stay consistent."""
        seen = []

        class FakeTok:
            def apply_chat_template(self, messages, tools=None, add_generation_prompt=False,
                                    return_dict=False):
                seen.append(tools)
                n = 10 + (5 if tools else 0)
                return list(range(n if add_generation_prompt or len(messages) > 2 else n))

        with tempfile.TemporaryDirectory() as tmp:
            corpus = Path(tmp) / "c.jsonl"
            msgs = example(TOOLUSE_SYS, "log in", {"tool": "request_input", "arguments": {}})
            corpus.write_text(
                json.dumps({"messages": msgs, "tools": [{"name": "request_input"}]}) + "\n",
                encoding="utf-8",
            )
            examples = sb.read_corpus(corpus)
            self.assertEqual(examples[0].tools, [{"name": "request_input"}])
            sb.chat_tokenize(FakeTok(), examples[0].messages, examples[0].tools)
        self.assertEqual(seen, [[{"name": "request_input"}], [{"name": "request_input"}]])

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
            self.assertIn(r.index, sel.reasons)
            self.assertTrue(
                sel.reasons[r.index].startswith(("redundant", "low-information", "noise-suspect"))
            )

    def test_a_duplicated_example_is_still_either_kept_or_dropped(self):
        """Two corpus lines may share a content hash. Tracking picks by hash
        made the unpicked twin vanish from BOTH lists with no reason recorded,
        so the report's kept+dropped stopped reconciling with the corpus --
        and detecting a generator that emits duplicates is this tool's job."""
        rows = make_rows(
            [("routing", "route", f"a wholly distinct sentence number {i} here", float(i))
             for i in range(10)]
        )
        twin = sc.Row(
            index=10, hash=rows[0].hash, target="routing", decision_class="route",
            answer_tokens=10, bits_base=rows[0].bits_base, bits_tuned=None, truncated=False,
            text=rows[0].text, shingles=rows[0].shingles,
        )
        rows.append(twin)
        sel = sc.select(rows, 0.95, "bits_base", False, 0.9, 3, 1, 17, 4000)
        kept_ids = {r.index for r in sel.kept}
        dropped_ids = {r.index for r in sel.dropped}
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(rows))
        self.assertEqual(kept_ids | dropped_ids, {r.index for r in rows})
        self.assertFalse(kept_ids & dropped_ids)
        for r in sel.dropped:
            self.assertIn(r.index, sel.reasons)

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


class TestNoiseSuspects(unittest.TestCase):
    """The ranking maximizes exactly what a MISLABEL maximizes. These pin the
    guard that makes that visible, and the policies that blunt it."""

    def _corpus_with_one_mislabel(self):
        rows = make_rows(
            [("routing", "refuse", f"host number {i} is not registered with this factory", 6.0 + i * 0.05)
             for i in range(19)]
        )
        bad = sc.Row(
            index=19, hash="hBAD", target="routing", decision_class="refuse",
            answer_tokens=10, bits_base=48.0, bits_tuned=0.002, truncated=False,
            text="host number ninety is not registered with this factory",
            shingles=sc.shingles("host number ninety is not registered with this factory", 3),
        )
        for r in rows:
            r.bits_tuned = 0.002
        rows.append(bad)
        return rows

    def test_a_mislabel_sized_outlier_is_flagged(self):
        rows = self._corpus_with_one_mislabel()
        n = sc.flag_noise_suspects(rows, factor=4.0, floor=8.0)
        self.assertEqual(n, 1)
        self.assertEqual([r.hash for r in rows if r.noise_suspect], ["hBAD"])

    def test_bits_ranking_really_does_concentrate_the_suspect(self):
        """The failure this guard exists for: 1/20 of the corpus becomes a much
        larger share of a small curriculum, under BOTH information rankings."""
        for rank_by in ("bits_base", "learned_bits"):
            rows = self._corpus_with_one_mislabel()
            sc.flag_noise_suspects(rows, 4.0, 8.0)
            sel = sc.select(rows, 0.10, rank_by, False, 0.9, 3, 1, 17, 4000)
            kept = {r.hash for r in sel.kept}
            self.assertIn("hBAD", kept, f"{rank_by} did not rank the mislabel first")
            self.assertGreater(
                sum(1 for r in sel.kept if r.noise_suspect) / len(sel.kept),
                1 / len(rows),
            )

    def test_cap_keeps_the_suspect_but_stops_it_out_ranking_everything(self):
        rows = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows, 4.0, 8.0)
        sel = sc.select(rows, 0.10, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="cap")
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(rows))
        bad = [r for r in rows if r.hash == "hBAD"][0]
        self.assertIsNotNone(bad.rank_cap)
        # capped at the best clean value, so it can no longer beat every honest row
        self.assertAlmostEqual(bad.value("bits_base", False, 17), max(
            r.bits_base for r in rows if not r.noise_suspect))

    def test_exclude_removes_it_and_records_why(self):
        rows = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows, 4.0, 8.0)
        sel = sc.select(rows, 0.10, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="exclude")
        self.assertNotIn("hBAD", {r.hash for r in sel.kept})
        bad = [r for r in sel.dropped if r.hash == "hBAD"][0]
        self.assertIn("noise-suspect", sel.reasons[bad.index])
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(rows))

    def test_flag_is_the_default_and_changes_nothing_about_the_pick(self):
        """Reporting must not quietly become dropping."""
        rows_a = self._corpus_with_one_mislabel()
        rows_b = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows_b, 4.0, 8.0)
        a = sc.select(rows_a, 0.25, "bits_base", False, 0.9, 3, 1, 17, 4000)
        b = sc.select(rows_b, 0.25, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="flag")
        self.assertEqual([r.hash for r in a.kept], [r.hash for r in b.kept])

    def test_a_class_is_never_emptied_by_suspicion_alone(self):
        rows = make_rows([("routing", "route", f"unique sentence {i} about work", 99.0)
                          for i in range(10)])
        for r in rows:
            r.noise_suspect = True
        sel = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="exclude")
        self.assertEqual(len(sel.kept), 5)

    def test_a_uniform_class_flags_nobody(self):
        rows = make_rows([("routing", "route", f"unique sentence {i} about work", 6.0)
                          for i in range(20)])
        self.assertEqual(sc.flag_noise_suspects(rows, 4.0, 8.0), 0)


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

    def _write_corpus(self, d: Path, n: int = 20, name: str = "corpus.jsonl") -> tuple[Path, list[str]]:
        lines = []
        for i in range(n):
            target = "routing" if i < n // 2 else "ledger"
            # A non-ASCII name on some lines, and COMPACT separators throughout:
            # the real corpus is not json.dumps-round-trip-identical, so a
            # fixture that is cannot tell a byte copy from a re-serialization.
            who = "crew" if i % 3 else "équipe"
            if target == "routing":
                msgs = example(ROUTING_SYS, f"send the {i} job to the alpha session for {who}",
                               {"action": "route", "session": f"s{i}", "reason": "named"})
            else:
                msgs = example(LEDGER_SYS, f"advance milestone number {i} for the {who}",
                               {"decision": "drive", "goal_id": f"g{i}", "reason": "top"})
            lines.append(
                json.dumps({"messages": msgs}, ensure_ascii=False, separators=(",", ":")) + "\n"
            )
        corpus = d / name
        corpus.write_text("".join(lines), encoding="utf-8")
        return corpus, lines

    def _write_scores(
        self, d: Path, corpus: Path, name: str, scale: float, adapter: str | None = None
    ) -> Path:
        p = d / name
        with p.open("w", encoding="utf-8") as fh:
            i = 0
            for line in corpus.read_text().splitlines():
                if not line.strip():
                    continue
                msgs = json.loads(line)["messages"]
                target, decision = sb.classify(msgs)
                fh.write(json.dumps({
                    "hash": sb.content_hash(msgs), "index": i, "target": target,
                    "decision_class": decision, "answer_tokens": 20,
                    "bits": (i + 1) * scale, "decision_bits": (i + 1) * scale * 0.1,
                    "truncated": False, "skipped": False, "adapter": adapter,
                }, sort_keys=True) + "\n")
                i += 1
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
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 0.5, adapter="/models/cand")
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = sc.main(["--base", str(base), "--tuned", str(tuned),
                              "--corpus", str(corpus), "--target-fraction", "0.5"])
            self.assertEqual(rc, 0)
            report = buf.getvalue()
            for needle in ("bits_tuned (residual)", "learned_bits", "HIGH-RESIDUAL"):
                self.assertIn(needle, report)

    def test_base_and_tuned_files_cannot_be_swapped(self):
        """learned_bits = base - tuned is meaningless if both were scored under
        the same model, and nothing downstream would notice: the numbers just
        get small."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 2.0)
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 0.5, adapter="/models/cand")
            with self.assertRaises(SystemExit) as ctx:  # swapped
                sc.main(["--base", str(tuned), "--tuned", str(base), "--corpus", str(corpus)])
            self.assertIn("UNTUNED base run", str(ctx.exception))

    def test_it_refuses_a_corpus_that_contains_the_validation_split(self):
        """datasets/sft-train-2026-09-05.jsonl -- the file the directive names --
        is exactly train.jsonl + valid.jsonl. Selecting from it trains on the
        yardstick the two experiment arms are supposed to share."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            train, train_lines = self._write_corpus(d, n=20, name="train.jsonl")
            valid, valid_lines = self._write_corpus(d, n=4, name="valid_src.jsonl")
            # valid.jsonl holds 4 examples that also appear in the big corpus
            (d / "valid.jsonl").write_text("".join(train_lines[:4]), encoding="utf-8")
            base = self._write_scores(d, train, "base.jsonl", 1.0)
            with self.assertRaises(SystemExit) as ctx:
                sc.main(["--base", str(base), "--corpus", str(train)])
            self.assertIn("also in", str(ctx.exception))
            # ...and the override exists, loudly
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with redirect_stdout(io.StringIO()):
                    rc = sc.main(["--base", str(base), "--corpus", str(train),
                                  "--allow-valid-overlap", "--target-fraction", "0.5"])
            finally:
                sys.stderr = stderr
            self.assertEqual(rc, 0)
            self.assertIn("WARNING", err.getvalue())

    def test_rank_by_decision_ranks_on_the_gate_scored_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = sc.main(["--base", str(base), "--corpus", str(corpus),
                              "--bits-column", "decision", "--target-fraction", "0.5"])
            self.assertEqual(rc, 0)
            report = buf.getvalue()
            self.assertIn("decision_bits_base (whole corpus)", report)
            self.assertIn("gate-scored fields hold", report)

    def test_it_refuses_decision_ranking_when_the_column_is_mostly_missing(self):
        """Otherwise the ranking is on 'could this be computed', not on bits."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            rows = [json.loads(x) for x in base.read_text().splitlines()]
            for r in rows[:15]:
                r["decision_bits"] = None
            base.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
            with self.assertRaises(SystemExit) as ctx:
                sc.main(["--base", str(base), "--corpus", str(corpus),
                         "--bits-column", "decision"])
            self.assertIn("no decision_bits", str(ctx.exception))

    def test_subset_lines_are_byte_identical_to_the_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, lines = self._write_corpus(d)
            # The property is only load-bearing if the fixture would EXPOSE a
            # re-serializing implementation. Assert the fixture is hostile first.
            self.assertNotEqual(json.dumps(json.loads(lines[0])) + "\n", lines[0])
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

    def test_emit_subset_stays_aligned_when_a_line_is_unscored(self):
        """Row.index counts NON-BLANK corpus lines, and emit_subset re-walks the
        file counting the same way. A corpus with a blank line and an unscored
        line exercises both counters; drop either increment and the emitted
        subset silently stops being the subset the report describes."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, lines = self._write_corpus(d)
            body = "".join(lines[:3]) + "\n" + "".join(lines[3:])  # a blank line at 3
            corpus.write_text(body, encoding="utf-8")
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            # remove the score for the 6th non-blank line, and mark another skipped
            rows = [json.loads(x) for x in base.read_text().splitlines()]
            kept_rows = [r for r in rows if r["index"] != 5]
            kept_rows[7]["skipped"] = True
            kept_rows[7]["bits"] = None
            base.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in kept_rows))
            out, report = d / "subset.jsonl", d / "report.txt"
            buf, err = io.StringIO(), io.StringIO()
            with redirect_stdout(buf):
                stderr, sys.stderr = sys.stderr, err
                try:
                    sc.main(["--base", str(base), "--corpus", str(corpus),
                             "--target-fraction", "1.0", "--out", str(out),
                             "--report", str(report)])
                finally:
                    sys.stderr = stderr
            emitted = out.read_text(encoding="utf-8").splitlines(keepends=True)
            # every emitted line is a real corpus line, and the two unscored
            # ones are the only corpus lines missing
            for line in emitted:
                self.assertIn(line, lines)
            self.assertEqual(len(emitted), len(lines) - 2)
            self.assertNotIn(lines[5], emitted)
            # ...and their absence is RECORDED, not silent
            self.assertIn("UNSCORED CORPUS LINES (2)", report.read_text())
            self.assertIn("had no usable base score", err.getvalue())

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

    def test_the_residual_section_does_not_accuse_examples_of_being_mislabels_at_0_bits(self):
        """A bare percentile always names the top 1%, however small. After the
        run that memorized this corpus every residual is ~0.001 bits, so the
        only noise diagnostic in the pipeline would print 'still surprising,
        likely a MISLABEL' over eight innocent examples every single time."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 2.0)
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 1.0, adapter="/models/cand")
            rows = [json.loads(x) for x in tuned.read_text().splitlines()]
            for i, r in enumerate(rows):  # a memorized run: 0.0005 - 0.004 bits
                r["bits"] = 0.0005 + i * 0.0002
            tuned.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
            buf = io.StringIO()
            with redirect_stdout(buf):
                sc.main(["--base", str(base), "--tuned", str(tuned), "--corpus", str(corpus),
                         "--target-fraction", "0.5"])
            report = buf.getvalue()
            self.assertIn("HIGH-RESIDUAL", report)
            self.assertIn("None.", report)
            self.assertNotIn("likely", report.split("HIGH-RESIDUAL")[1].split("LIMITS")[0])

    def test_a_real_residual_outlier_is_still_named_and_says_if_it_was_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 2.0)
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 1.0, adapter="/models/cand")
            rows = [json.loads(x) for x in tuned.read_text().splitlines()]
            for r in rows:
                r["bits"] = 0.001
            rows[7]["bits"] = 40.0
            tuned.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
            buf = io.StringIO()
            with redirect_stdout(buf):
                sc.main(["--base", str(base), "--tuned", str(tuned), "--corpus", str(corpus),
                         "--target-fraction", "0.5"])
            section = buf.getvalue().split("HIGH-RESIDUAL")[1]
            self.assertIn("MISLABEL", section)
            self.assertIn("idx     7", section)
            self.assertTrue("KEPT" in section or "dropped" in section)

    def test_rank_by_residual_warns_that_it_ranks_on_suspected_mislabels(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 2.0)
            tuned = self._write_scores(d, corpus, "tuned.jsonl", 1.0, adapter="/models/cand")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with redirect_stdout(io.StringIO()):
                    sc.main(["--base", str(base), "--tuned", str(tuned), "--corpus", str(corpus),
                             "--rank-by", "residual", "--target-fraction", "0.5"])
            finally:
                sys.stderr = stderr
            self.assertIn("HIGHEST-residual", err.getvalue())
            self.assertIn("likely mislabels", err.getvalue())

    def test_unclassified_rows_are_reported_not_silently_pooled(self):
        """A track whose prompt carries none of the markers lands wholesale in
        one ('unknown', 'unparsed') partition -- and then the per-class quota
        and the 'clustering never merges across labels' promise both stop
        holding, invisibly."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(d, corpus, "base.jsonl", 1.0)
            rows = [json.loads(x) for x in base.read_text().splitlines()]
            for r in rows[:6]:
                r["target"], r["decision_class"] = "unknown", "unparsed"
            base.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with redirect_stdout(io.StringIO()):
                    sc.main(["--base", str(base), "--corpus", str(corpus),
                             "--target-fraction", "0.5"])
            finally:
                sys.stderr = stderr
            self.assertIn("unknown/unparsed", err.getvalue())
            self.assertIn("6/20", err.getvalue())

    def test_it_refuses_to_select_from_an_eval_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "evals" / "tmux-routing"
            d.mkdir(parents=True)
            corpus, _ = self._write_corpus(d)
            base = self._write_scores(Path(tmp), corpus, "base.jsonl", 1.0)
            with self.assertRaises(SystemExit) as ctx:
                sc.main(["--base", str(base), "--corpus", str(corpus)])
            self.assertIn("leakage", str(ctx.exception).lower())


# ---------------------------------------------------------------------------
# 9. the parity gate, and the experiment's own configuration
# ---------------------------------------------------------------------------


class TestParityCheck(unittest.TestCase):
    """The only check on the chunked KV-cache assembly. It has to be capable of
    failing -- including in the case where it compares nothing at all."""

    def test_matching_files_pass_and_report_the_count(self):
        ok, msg = pc.compare({"a": 1.0, "b": 2.0, "c": 9.0}, {"a": 1.0, "b": 2.0005}, 1e-2)
        self.assertTrue(ok)
        self.assertIn("over 2 examples", msg)

    def test_a_real_divergence_fails(self):
        ok, msg = pc.compare({"a": 1.0}, {"a": 1.5}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("0.500000", msg)

    def test_an_EMPTY_overlap_fails_instead_of_passing_vacuously(self):
        """max(..., default=0.0) over an empty generator is 0.0, which reads as
        a perfect match. Every example being skipped, or the two files coming
        from different runs, would then 'validate' the whole pipeline."""
        ok, msg = pc.compare({"aaa": 1.0}, {"zzz": 1.0}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("absent from the chunked file", msg)

    def test_no_full_forward_rows_at_all_fails(self):
        ok, msg = pc.compare({"a": 1.0}, {}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("no scored rows", msg)

    def test_a_partial_overlap_fails_rather_than_comparing_the_half_it_has(self):
        ok, _ = pc.compare({"a": 1.0}, {"a": 1.0, "b": 1.0}, 1e-2)
        self.assertFalse(ok)

    def test_the_cli_skips_null_bits_and_exits_nonzero_on_an_empty_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "chunked.jsonl").write_text(
                json.dumps({"hash": "a", "bits": None}) + "\n", encoding="utf-8")
            (d / "full.jsonl").write_text(
                json.dumps({"hash": "a", "bits": 1.0}) + "\n", encoding="utf-8")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                rc = pc.main([str(d / "chunked.jsonl"), str(d / "full.jsonl")])
            finally:
                sys.stderr = stderr
            self.assertEqual(rc, 1)
            self.assertIn("FAILED", err.getvalue())


class TestExperimentConfiguration(unittest.TestCase):
    """The experiment's honesty rests on the control arm differing from the bits
    arm in ONE thing. That is a property of the shell script, so assert it
    there: an arm that quietly regains a second difference makes any gate win
    unattributable, which is the whole reason the control exists."""

    def setUp(self):
        self.src = EXPERIMENT_SH.read_text()

    def _select_invocations(self) -> list[str]:
        out, buf, depth = [], "", 0
        for line in self.src.splitlines():
            if "select_curriculum.py" in line and not line.strip().startswith("#"):
                depth, buf = 1, line
                continue
            if depth:
                buf += " " + line.strip()
                if not line.rstrip().endswith("\\"):
                    out.append(buf)
                    depth = 0
        return out

    def test_both_arms_are_selected_and_found(self):
        self.assertEqual(len(self._select_invocations()), 2)

    def test_the_two_arms_use_the_SAME_clustering_threshold(self):
        """--jaccard 1.01 in the control only would switch deduplication off in
        one arm: measured on the real corpus that moves ~17% of the picks, so a
        bits win could have been a dedup win and the experiment could not tell
        them apart."""
        jaccards = []
        for inv in self._select_invocations():
            parts = inv.split()
            self.assertIn("--jaccard", parts, f"an arm pins no --jaccard: {inv}")
            jaccards.append(parts[parts.index("--jaccard") + 1])
        self.assertEqual(len(set(jaccards)), 1, f"the arms cluster differently: {jaccards}")

    def test_exactly_one_arm_is_the_information_blind_control(self):
        blind = [i for i in self._select_invocations() if "--rank-by random" in i]
        self.assertEqual(len(blind), 1)

    def test_the_script_does_not_hardcode_another_checkouts_path(self):
        """It writes datasets and reports; a hardcoded absolute repo path means
        running it from a worktree mutates a different checkout's trees."""
        self.assertNotIn("/Users/", self.src.split("# ----")[0])

    def test_the_shell_guard_covers_every_pattern_score_bits_covers(self):
        guard_block = self.src.split("guard() {")[1].split("}")[0]
        for pattern in sb._BUSY_PATTERNS:
            needle = pattern.replace("mlx_lm lora", 'mlx_lm lo""ra')
            self.assertIn(needle, guard_block, f"the shell guard misses {pattern}")

    def test_stage_5_names_the_full_corpus_at_reduced_iterations_baseline(self):
        """Without it, 'the subset ties 4490 iterations at 1126' is satisfiable
        by early stopping alone and the criterion reports a success that
        selection had no part in."""
        self.assertIn("D. the FULL corpus, trained for the SAME ITERS", self.src)
        self.assertIn("AND beats D", self.src)


if __name__ == "__main__":
    unittest.main(verbosity=2)

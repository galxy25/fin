#!/usr/bin/env python3
"""Unit tests for score_bits.py and select_curriculum.py.

NO MODEL, NO GPU, NO NETWORK. Every formula the scorer depends on is exercised
against synthetic logprob fixtures through a stub scorer, and every selector
property Levi asked for is asserted directly.

  python3 scripts/model-factory/tests/test_bits_curriculum.py -v
"""

from __future__ import annotations

import inspect
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


def fake_adapter(path: Path, weights: bytes = b"lora-weights-v1", rank: int = 8) -> Path:
    """An --adapter directory with the two files mlx_lm actually loads.

    Hand-built bytes, no safetensors library and no model: the digest is a
    stream hash over whatever is in the files, so a plausible-shaped directory
    is enough to exercise every path that identifies an adapter.
    """
    path.mkdir(parents=True, exist_ok=True)
    (path / sb.ADAPTER_WEIGHTS_NAME).write_bytes(weights)
    (path / sb.ADAPTER_CONFIG_NAME).write_text(
        json.dumps({"fine_tune_type": "lora", "num_layers": 16,
                    "lora_parameters": {"rank": rank, "scale": 20.0}}, sort_keys=True),
        encoding="utf-8",
    )
    return path


def parity_rows(
    values: dict,
    tokens=35,
    *,
    full_forward: bool = False,
    chunk: int | None = 512,
    model: str = "m",
    adapter: str | None = None,
    adapter_digest: str | None = None,
    max_seq_length: int = 3072,
    match_trainer: bool = True,
    column: str = "bits",
    token_field: str = "answer_tokens",
) -> list[dict]:
    """Score-file rows shaped the way ``score_bits.py`` writes them.

    parity_check.py reads three things off a row and refuses without any of
    them: the column, the TOKEN COUNT that column is a sum over (the bound's
    small end is per token), and the run fingerprint (a pair of files scored
    under different models/adapters/windows is not a parity pair). ``tokens`` is
    either one count for every row or a per-hash dict -- 35 by default, the
    corpus's 34.6 unmasked tokens per example rounded.
    """
    rows = []
    for h, v in values.items():
        row = sb.run_fingerprint(
            model, adapter, max_seq_length, match_trainer, full_forward, chunk, adapter_digest
        )
        row.update({"hash": h, column: v, "skipped": v is None})
        row[token_field] = tokens[h] if isinstance(tokens, dict) else tokens
        rows.append(row)
    return rows


def write_rows(path: Path, rows) -> Path:
    path.write_text(
        "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows), encoding="utf-8"
    )
    return path


def run_parity_cli(chunked_rows, full_rows, extra=()) -> tuple[int, str]:
    """parity_check.py's positional mode, end to end, on two real files."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        write_rows(d / "chunked.jsonl", chunked_rows)
        write_rows(d / "full.jsonl", full_rows)
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            rc = pc.main([str(d / "chunked.jsonl"), str(d / "full.jsonl"), *extra])
        finally:
            sys.stderr = stderr
        return rc, err.getvalue()


def score_file(values: dict, tokens=35, *, name: str = "scores.jsonl", **kw) -> pc.ScoreFile:
    """A loaded parity_check.ScoreFile, without going through a temp file."""
    rows = parity_rows(values, tokens, **kw)
    fps: list[dict] = []
    for r in rows:
        fp = {k: r[k] for k in pc.FINGERPRINT_KEYS if k in r}
        if fp and fp not in fps:
            fps.append(fp)
    field = kw.get("token_field", "answer_tokens")
    return pc.ScoreFile(
        Path(name), dict(values), {r["hash"]: r.get(field) for r in rows}, fps
    )


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
        answer = '{"reason": "top goal", "note": "no label key in here"}'
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
            prior = sb.run_fingerprint("m", None, 3072, True, False, 512)
            prior.update({"hash": "deadbeef", "bits": 1.0, "skipped": False})
            out.write_text(json.dumps(prior, sort_keys=True) + "\n", encoding="utf-8")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                rc = sb.main(["--model", "m", "--data", str(corpus), "--out", str(out),
                              # a DIFFERENT condition
                              "--adapter", str(fake_adapter(d / "adapter"))])
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
            row = sb.run_fingerprint("m", None, 3072, True, False, 512)
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
        screen = sc.flag_noise_suspects(rows, factor=4.0, floor=0.0)
        self.assertEqual(screen.flagged, 1)
        self.assertEqual([r.hash for r in rows if r.noise_suspect], ["hBAD"])

    def test_bits_ranking_really_does_concentrate_the_suspect(self):
        """The failure this guard exists for: 1/20 of the corpus becomes a much
        larger share of a small curriculum, under BOTH information rankings."""
        for rank_by in ("bits_base", "learned_bits"):
            rows = self._corpus_with_one_mislabel()
            sc.flag_noise_suspects(rows, 4.0, 0.0)
            sel = sc.select(rows, 0.10, rank_by, False, 0.9, 3, 1, 17, 4000)
            kept = {r.hash for r in sel.kept}
            self.assertIn("hBAD", kept, f"{rank_by} did not rank the mislabel first")
            self.assertGreater(
                sum(1 for r in sel.kept if r.noise_suspect) / len(sel.kept),
                1 / len(rows),
            )

    def test_cap_keeps_the_suspect_but_stops_it_out_ranking_everything(self):
        rows = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows, 4.0, 0.0)
        sel = sc.select(rows, 0.10, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="cap")
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(rows))
        bad = [r for r in rows if r.hash == "hBAD"][0]
        self.assertIsNotNone(bad.rank_cap)
        # capped at the best clean value, so it can no longer beat every honest row
        self.assertAlmostEqual(bad.value("bits_base", False, 17), max(
            r.bits_base for r in rows if not r.noise_suspect))

    def test_exclude_removes_it_and_records_why(self):
        rows = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows, 4.0, 0.0)
        sel = sc.select(rows, 0.10, "bits_base", False, 0.9, 3, 1, 17, 4000, noise_policy="exclude")
        self.assertNotIn("hBAD", {r.hash for r in sel.kept})
        bad = [r for r in sel.dropped if r.hash == "hBAD"][0]
        self.assertIn("noise-suspect", sel.reasons[bad.index])
        self.assertEqual(len(sel.kept) + len(sel.dropped), len(rows))

    def test_flag_is_the_default_and_changes_nothing_about_the_pick(self):
        """Reporting must not quietly become dropping."""
        rows_a = self._corpus_with_one_mislabel()
        rows_b = self._corpus_with_one_mislabel()
        sc.flag_noise_suspects(rows_b, 4.0, 0.0)
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
        self.assertEqual(sc.flag_noise_suspects(rows, 4.0, 0.0).flagged, 0)


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
                    # what score_bits stamps now: the adapter's CONTENT, not its path
                    "adapter_digest": None if adapter is None else "sha256:" + "ab" * 32,
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
        ok, msg = pc.compare(
            {"a": 1.0, "b": 2.0, "c": 9.0}, {"a": 1.0, "b": 2.0005}, {"a": 1, "b": 1}, 1e-2
        )
        self.assertTrue(ok)
        self.assertIn("over 2 examples", msg)

    def test_a_real_divergence_fails(self):
        ok, msg = pc.compare({"a": 1.0}, {"a": 1.5}, {"a": 1}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("0.500000", msg)

    def test_an_EMPTY_overlap_fails_instead_of_passing_vacuously(self):
        """max(..., default=0.0) over an empty generator is 0.0, which reads as
        a perfect match. Every example being skipped, or the two files coming
        from different runs, would then 'validate' the whole pipeline."""
        ok, msg = pc.compare({"aaa": 1.0}, {"zzz": 1.0}, {"zzz": 1}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("absent from the chunked file", msg)

    def test_no_full_forward_rows_at_all_fails(self):
        ok, msg = pc.compare({"a": 1.0}, {}, {}, 1e-2)
        self.assertFalse(ok)
        self.assertIn("no scored rows", msg)

    def test_a_partial_overlap_fails_rather_than_comparing_the_half_it_has(self):
        ok, _ = pc.compare({"a": 1.0}, {"a": 1.0, "b": 1.0}, {"a": 1, "b": 1}, 1e-2)
        self.assertFalse(ok)

    def test_the_cli_skips_null_bits_and_exits_nonzero_on_an_empty_comparison(self):
        rc, err = run_parity_cli(
            parity_rows({"a": None}),
            parity_rows({"a": 1.0}, full_forward=True),
        )
        self.assertEqual(rc, 1)
        self.assertIn("FAILED", err)

    def test_a_null_column_row_still_carries_its_run_fingerprint(self):
        """A skipped row is still evidence of WHICH run wrote the file. Dropping
        it from the fingerprint scan would let an all-skipped chunked file look
        like a file with no fingerprint at all, and be refused for the wrong
        reason -- or, waived, be compared to anything."""
        with tempfile.TemporaryDirectory() as tmp:
            f = pc.load(
                write_rows(Path(tmp) / "s.jsonl", parity_rows({"a": None})), "bits"
            )
        self.assertEqual(f.values, {})
        self.assertEqual(f.fingerprint["chunk"], 512)


class TestExperimentConfiguration(unittest.TestCase):
    """The experiment's honesty rests on the control arm differing from the bits
    arm in ONE thing. That is a property of the shell script, so assert it
    there: an arm that quietly regains a second difference makes any gate win
    unattributable, which is the whole reason the control exists."""

    def setUp(self):
        self.src = EXPERIMENT_SH.read_text()

    def _invocations(self, script: str) -> list[str]:
        out, buf, depth = [], "", 0
        for line in self.src.splitlines():
            if script in line and not line.strip().startswith("#"):
                depth, buf = 1, line.strip()
                if not line.rstrip().endswith("\\"):
                    out.append(buf)
                    depth = 0
                continue
            if depth:
                buf += " " + line.strip()
                if not line.rstrip().endswith("\\"):
                    out.append(buf)
                    depth = 0
        return out

    def _select_invocations(self) -> list[str]:
        return self._invocations("select_curriculum.py")

    def test_both_arms_are_selected_and_found(self):
        self.assertEqual(len(self._select_invocations()), 2)

    def test_every_parity_pair_in_the_script_differs_ONLY_in_the_forward_path(self):
        """parity_check now refuses a pair scored under different models,
        adapters, windows or masks (exit 2). The pipeline's own invocations have
        to satisfy the rule they enforce: the --full-forward spot-check must
        repeat the chunked run's flags exactly and change only the forward path.
        Leaving --max-seq-length off the spot-check is fine because its default
        IS the 3072 the chunked stage passes -- but that is a coincidence worth a
        test, not a thing to rediscover when a stage fails at 2am."""
        produced = {
            self._flags(inv).get("--out"): self._flags(inv)
            for inv in self._invocations("score_bits.py")
        }
        pairs = 0
        for inv in self._invocations("parity_check.py"):
            if "--anchor" in inv:
                continue
            files = [t for t in inv.split() if t.endswith('.jsonl"')]
            self.assertEqual(len(files), 2, inv)
            a, b = (produced.get(f) for f in files)
            self.assertIsNotNone(a, files[0])
            self.assertIsNotNone(b, files[1])
            for flag, default in (("--model", None), ("--adapter", None),
                                  ("--max-seq-length", "3072")):
                self.assertEqual(a.get(flag, default), b.get(flag, default),
                                 f"{flag} differs across the parity pair {files}")
            self.assertEqual(("--no-match-trainer" in a), ("--no-match-trainer" in b))
            self.assertNotEqual(("--full-forward" in a), ("--full-forward" in b),
                                f"{files} describe the same forward path")
            pairs += 1
        self.assertEqual(pairs, 2, "stage 1c and stage 2b")

    # Flags that are ALLOWED to differ between the arms, with the reason. Adding
    # to this list is how you declare a second difference on purpose; anything
    # not here that diverges fails the flag-for-flag test below.
    ALLOWED_ARM_DIFFERENCES = {
        "--rank-by",   # THE experimental variable
        "--seed",      # the control needs its own draw
        "--tuned",     # only the bits arm ranks on learned_bits
        "--out",       # different destinations, obviously
        "--report",
    }

    def _flags(self, inv: str) -> dict[str, str]:
        parts = inv.split()
        out: dict[str, str] = {}
        i = 0
        while i < len(parts):
            if parts[i].startswith("--"):
                nxt = parts[i + 1] if i + 1 < len(parts) else ""
                if nxt and not nxt.startswith("--"):
                    out[parts[i]] = nxt
                    i += 2
                    continue
                out[parts[i]] = ""
            i += 1
        return out

    def test_the_arms_differ_in_EXACTLY_the_ranking_and_nothing_else(self):
        """The general form of the property the class exists for.

        Pinning one flag at a time (this used to check only --jaccard) lets any
        OTHER flag regain a second difference with every test still green: an
        arm at --target-fraction 0.5 against an arm at 0.25 is a strictly larger
        confound than the clustering threshold, and it passed. Compare the two
        invocations flag for flag instead, and require every difference to be
        declared in ALLOWED_ARM_DIFFERENCES.
        """
        a, b = (self._flags(i) for i in self._select_invocations())
        differing = {
            k for k in set(a) | set(b) if a.get(k) != b.get(k)
        } - self.ALLOWED_ARM_DIFFERENCES
        self.assertEqual(
            differing,
            set(),
            "the arms differ in more than the ranking: "
            + ", ".join(f"{k} ({a.get(k)!r} vs {b.get(k)!r})" for k in sorted(differing))
            + ". A gate win would not be attributable to bits.",
        )

    def test_the_two_arms_use_the_SAME_clustering_threshold(self):
        """--jaccard 1.01 in the control only would switch deduplication off in
        one arm: measured on the real corpus that moves ~10% of the picks, so a
        bits win could have been a dedup win and the experiment could not tell
        them apart. (Subsumed by the flag-for-flag test above; kept because it
        names the specific bug that was actually shipped once.)"""
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
        running it from a worktree mutates a different checkout's trees.

        Over the WHOLE file: this used to read only the config header, up to the
        first '# ----' separator, which left every stage body unchecked --
        including the line that names the dataset output directory.
        """
        self.assertNotIn("/Users/", self.src)

    def test_the_preflight_stage_runs_before_any_GPU_stage(self):
        """Stage 0 is the guard against burning both scoring stages on a bits
        column that stage 3 will refuse. It is worthless if it is not in the
        default stage list, or if it runs after stage 1."""
        self.assertIn("--check-decision-coverage", self.src)
        default = [l for l in self.src.splitlines() if l.startswith("STAGES=")]
        self.assertEqual(len(default), 1, "the default stage list moved")
        self.assertIn("0", default[0], f"stage 0 is not in the default stages: {default[0]}")
        self.assertLess(
            self.src.index('" 0 "'), self.src.index('" 1 "'),
            "the preflight stage must be dispatched before the first GPU stage",
        )

    def test_the_masking_port_is_anchored_against_the_trainers_own_log(self):
        """Internal chunked-vs-full parity cannot catch a wrong MASK: both paths
        would be wrong the same way. The only discriminating number is one this
        repo did not produce -- the trainer's Iter 1 val loss."""
        anchor = [
            l for l in self.src.splitlines()
            if "--anchor" in l and not l.strip().startswith("#")
        ]
        self.assertEqual(len(anchor), 1, "the anchor check is not invoked (or is only a comment)")
        self.assertIn("train.log", self.src)
        self.assertIn("--iter 1", self.src, "the anchor must name the UNTUNED base's val loss")
        # The anchor must be taken against the BASE scores, not the tuned ones:
        # a memorized adapter's residual is ~0.01 whether the mask is right or
        # wrong, so anchoring there would pass under a broken port. Asserted on
        # the executable line rather than on prose, which a comment explaining
        # the history would otherwise trip.
        self.assertIn("bits-valid-base", anchor[0])
        self.assertNotIn("tuned", anchor[0])

    def test_stage_5_requires_more_than_one_seed_per_arm(self):
        """51 binary scenarios means one scenario is 2%; a single run per arm
        cannot distinguish a curriculum effect from seed noise."""
        self.assertIn("SEEDS", self.src)
        self.assertIn("noise floor", self.src.lower())

    def test_the_script_records_that_the_gate_covers_one_track_of_four(self):
        """A stage-5 verdict is a verdict on routing. 62.3% of what the
        curriculum cuts is invisible to the arbiter, and the script must say so
        where the criterion is stated."""
        self.assertIn("routing", self.src)
        self.assertIn("1398", self.src)

    def test_the_shell_guard_FAILS_CLOSED_like_the_python_one(self):
        """`if pgrep -f "$pat"; then refuse; fi` sends every non-zero exit down
        the same branch, so an unreadable process table (pgrep exits 2 or 3)
        read as 'nothing is running' and the stage proceeded -- while
        score_bits._pgrep raises MachineUnknown for exactly those codes. The
        comment two lines up promises the two are kept in sync; the failure
        DIRECTION has to be part of that."""
        guard_block = self.src.split("guard() {")[1].split("\n}")[0]
        self.assertIn("rc=$?", guard_block, "the guard does not inspect pgrep's exit code")
        # 0 = matched, 1 = no match, anything else = cannot verify. All three
        # must be handled distinctly; a two-way test cannot fail closed.
        self.assertRegex(guard_block, r"case\s+\"\$rc\"")
        self.assertIn("cannot verify", guard_block)

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


# ---------------------------------------------------------------------------
# 12. the per-track decision column, and the preflight that keeps its failure
#     cheap. A flat action,session was empty for 48.7% of the real corpus.
# ---------------------------------------------------------------------------


class TestPerTrackDecisionFields(unittest.TestCase):
    def test_each_track_resolves_to_the_fields_its_schema_actually_uses(self):
        self.assertEqual(sb.decision_fields_for("routing", None), ("action", "session"))
        self.assertEqual(sb.decision_fields_for("elicit", None), ("action",))
        self.assertEqual(
            sb.decision_fields_for("ledger", None), ("decision", "goal_id", "message_id")
        )
        self.assertEqual(sb.decision_fields_for("tooluse", None), ("tool", "arguments"))

    def test_an_unknown_track_gets_the_union_not_nothing(self):
        """'I do not recognise this schema' must not read as 'this answer has no
        decision' -- that is the unknown-vs-zero confusion the null column
        exists to prevent, one level up."""
        fields = sb.decision_fields_for("unknown", None)
        for key in ("action", "decision", "tool"):
            self.assertIn(key, fields)

    def test_an_explicit_list_overrides_every_track(self):
        self.assertEqual(sb.decision_fields_for("ledger", ["action"]), ("action",))

    def test_a_ledger_answer_gets_a_decision_column_under_auto(self):
        """The regression that made --bits-column decision unusable: a ledger
        answer has no 'action' and no 'session', so under the old flat default
        its decision_bits was null -- as it was for every ledger and tooluse row,
        1093 of 2245, and the selector then refused the column outright."""
        answer = '{"decision": "drive", "goal_id": "g7", "reason": "top goal"}'
        tokens = char_tokens("P>" + answer)
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "ledger", "drive")
        rec = sb.score_example(ex, tokens, 2, 4096, True, uniform_scorer(256), "stub", None)
        self.assertTrue(rec["decision_ok"])
        self.assertIsNotNone(rec["decision_bits"])
        self.assertLess(rec["decision_bits"], rec["bits"])
        # and the flat list that used to be the default still fails on it
        flat = sb.score_example(
            ex, tokens, 2, 4096, True, uniform_scorer(256), "stub", None,
            decision_fields=("action", "session"),
        )
        self.assertIsNone(flat["decision_bits"])

    def test_a_tooluse_answer_gets_a_decision_column_under_auto(self):
        answer = '{"tool": "run", "arguments": {"cmd": "ls"}}'
        tokens = char_tokens("P>" + answer)
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "tooluse", "run")
        rec = sb.score_example(ex, tokens, 2, 4096, True, uniform_scorer(256), "stub", None)
        self.assertTrue(rec["decision_ok"])

    def test_the_row_records_which_fields_were_used(self):
        answer = '{"decision": "drive", "reason": "x"}'
        ex = sb.Example(0, [{"role": "assistant", "content": answer}], "", "h", "ledger", "drive")
        rec = sb.score_example(
            ex, char_tokens("P>" + answer), 2, 4096, True, uniform_scorer(256), "stub", None
        )
        self.assertEqual(rec["decision_fields"], ["decision", "goal_id", "message_id"])


class TestDecisionCoveragePreflight(unittest.TestCase):
    """The check that makes the above failure cost seconds instead of two
    multi-hour GPU stages. Pure text work: no tokenizer, no weights."""

    def _corpus(self, d: Path) -> Path:
        lines = [
            {"messages": example(ROUTING_SYS, "go", {"action": "route", "session": "s"})},
            {"messages": example(LEDGER_SYS, "tick", {"decision": "drive", "goal_id": "g"})},
            {"messages": example(TOOLUSE_SYS, "run", {"tool": "run", "arguments": {"c": "ls"}})},
            {"messages": example(ELICIT_SYS, "ask", {"action": "ask", "question": "which?"})},
        ]
        p = d / "c.jsonl"
        p.write_text("".join(json.dumps(l) + "\n" for l in lines), encoding="utf-8")
        return p

    def test_auto_covers_every_track(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            cov = sb.decision_coverage(sb.read_corpus(self._corpus(d)), None)
            self.assertEqual(cov["missing"], 0)
            self.assertEqual(cov["missing_share"], 0.0)

    def test_the_flat_default_leaves_half_the_corpus_blind(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            cov = sb.decision_coverage(sb.read_corpus(self._corpus(d)), ("action", "session"))
            self.assertEqual(cov["missing"], 2)  # the ledger and tooluse rows
            self.assertEqual(cov["per_target"]["ledger"]["covered"], 0)
            self.assertEqual(cov["per_target"]["tooluse"]["covered"], 0)

    def test_the_cli_exits_nonzero_BEFORE_any_gpu_stage_when_coverage_is_short(self):
        """The whole point: a bad --decision-fields must be caught here, not by
        select_curriculum.py after both scoring stages have run."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus = self._corpus(d)
            buf, err = io.StringIO(), io.StringIO()
            with redirect_stdout(buf):
                stderr, sys.stderr = sys.stderr, err
                try:
                    rc = sb.main([
                        "--data", str(corpus), "--out", str(d / "o.jsonl"),
                        "--decision-fields", "action,session",
                        "--check-decision-coverage", "0.95",
                    ])
                finally:
                    sys.stderr = stderr
            self.assertEqual(rc, 3)
            self.assertIn("below the required", err.getvalue())

    def test_the_cli_passes_under_auto(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            buf, err = io.StringIO(), io.StringIO()
            with redirect_stdout(buf):
                stderr, sys.stderr = sys.stderr, err
                try:
                    rc = sb.main([
                        "--data", str(self._corpus(d)), "--out", str(d / "o.jsonl"),
                        "--check-decision-coverage", "0.95",
                    ])
                finally:
                    sys.stderr = stderr
            self.assertEqual(rc, 0)


# ---------------------------------------------------------------------------
# 13. the fingerprint, across the PAIR of files where the subtraction happens
# ---------------------------------------------------------------------------


class TestPairFingerprint(unittest.TestCase):
    BASE = {"model": "m", "max_seq_length": 3072, "match_trainer": True,
            "full_forward": False, "chunk": 512}

    def test_matching_runs_pass(self):
        sc.check_pair_fingerprints(
            dict(self.BASE), dict(self.BASE), Path("b"), Path("t"), False
        )

    def test_a_different_window_is_refused(self):
        """Score the base at 3072 and the tuned adapter at 2048 and every
        example truncated under one but not the other contributes a fabricated
        learned_bits -- to the DEFAULT ranking key, silently."""
        tuned = dict(self.BASE, max_seq_length=2048)
        with self.assertRaises(SystemExit) as cm:
            sc.check_pair_fingerprints(dict(self.BASE), tuned, Path("b"), Path("t"), False)
        self.assertIn("max_seq_length", str(cm.exception))

    def test_a_different_model_is_refused(self):
        tuned = dict(self.BASE, model="some-other-model-entirely")
        with self.assertRaises(SystemExit):
            sc.check_pair_fingerprints(dict(self.BASE), tuned, Path("b"), Path("t"), False)

    def test_a_different_forward_path_is_refused(self):
        for key, value in (("full_forward", True), ("chunk", 2048), ("match_trainer", False)):
            with self.subTest(key=key):
                with self.assertRaises(SystemExit):
                    sc.check_pair_fingerprints(
                        dict(self.BASE), dict(self.BASE, **{key: value}),
                        Path("b"), Path("t"), False,
                    )

    def test_the_ADAPTER_is_allowed_to_differ(self):
        """It is the one field that MUST differ between a base run and a tuned
        run; a check that refused it would refuse every valid pair."""
        sc.check_pair_fingerprints(
            dict(self.BASE, adapter=None), dict(self.BASE, adapter="/some/adapter"),
            Path("b"), Path("t"), False,
        )

    def test_the_escape_hatch_warns_instead_of_refusing(self):
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            sc.check_pair_fingerprints(
                dict(self.BASE), dict(self.BASE, chunk=2048), Path("b"), Path("t"), True
            )
        finally:
            sys.stderr = stderr
        self.assertIn("WARNING", err.getvalue())

    def test_two_files_that_record_no_fingerprint_at_all_are_not_a_mismatch(self):
        sc.check_pair_fingerprints({}, {}, Path("b"), Path("t"), False)

    def _pair(self, d: Path, tuned_over: dict) -> tuple[Path, Path, Path]:
        msgs = [example(ROUTING_SYS, f"route job {i} to alpha now",
                        {"action": "route", "session": f"s{i}", "reason": "named"})
                for i in range(8)]
        corpus = d / "corpus.jsonl"
        corpus.write_text(
            "".join(json.dumps({"messages": m}) + "\n" for m in msgs), encoding="utf-8"
        )
        def write(path, adapter, scale, over):
            with path.open("w", encoding="utf-8") as fh:
                for i, m in enumerate(msgs):
                    rec = dict(
                        self.BASE,
                        adapter=adapter,
                        adapter_digest=None if adapter is None else "sha256:" + "cd" * 32,
                    )
                    rec.update(over)
                    rec.update({
                        "hash": sb.content_hash(m), "index": i, "target": "routing",
                        "decision_class": "route", "answer_tokens": 20,
                        "bits": (i + 1) * scale, "decision_bits": (i + 1) * scale * 0.1,
                        "decision_tokens": 4, "truncated": False, "skipped": False,
                    })
                    fh.write(json.dumps(rec, sort_keys=True) + "\n")
        base, tuned = d / "base.jsonl", d / "tuned.jsonl"
        write(base, None, 1.0, {})
        write(tuned, "/some/adapter", 0.5, tuned_over)
        return corpus, base, tuned

    def _run(self, corpus, base, tuned, extra=()):
        buf, err = io.StringIO(), io.StringIO()
        with redirect_stdout(buf):
            stderr, sys.stderr = sys.stderr, err
            try:
                rc = sc.main(["--base", str(base), "--tuned", str(tuned),
                              "--corpus", str(corpus), *extra])
            except SystemExit as exc:
                rc = exc.code if isinstance(exc.code, int) else 1
                print(exc, file=err)
            finally:
                sys.stderr = stderr
        return rc, err.getvalue()

    def test_the_SELECTOR_refuses_a_mismatched_pair_end_to_end(self):
        """The function existed and was correct; nothing called it across the
        pair, which is the only place the subtraction happens. This drives the
        CLI, so deleting the call site fails a test."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, base, tuned = self._pair(d, {"max_seq_length": 2048})
            rc, err = self._run(corpus, base, tuned)
            self.assertNotEqual(rc, 0)
            self.assertIn("max_seq_length", err)

    def test_the_SELECTOR_accepts_a_matching_pair_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, base, tuned = self._pair(d, {})
            rc, err = self._run(corpus, base, tuned)
            self.assertEqual(rc, 0, err)

    def test_the_override_flag_lets_a_mismatched_pair_through(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus, base, tuned = self._pair(d, {"chunk": 2048})
            rc, err = self._run(corpus, base, tuned, ["--allow-fingerprint-mismatch"])
            self.assertEqual(rc, 0, err)
            self.assertIn("WARNING", err)

    def test_chunk_is_part_of_the_resume_fingerprint(self):
        """--chunk changes matmul shapes and, on a sliding-window model, cache
        eviction points, so rows scored at 512 and at 2048 are not the same
        measurement and must not land in one file."""
        self.assertIn("chunk", sb.run_fingerprint("m", None, 3072, True, False, 512))
        self.assertEqual(
            sb.run_fingerprint("m", None, 3072, True, False, 512)["chunk"], 512
        )

    def test_chunk_is_null_under_full_forward_where_it_has_no_effect(self):
        """The fingerprint names the forward path actually taken, not a flag
        that was ignored -- otherwise two identical full-forward runs would
        refuse to join over a value neither of them used."""
        self.assertIsNone(sb.run_fingerprint("m", None, 3072, True, True, 512)["chunk"])


# ---------------------------------------------------------------------------
# 14. the mislabel screen, at scales two orders of magnitude apart
# ---------------------------------------------------------------------------


class TestNoiseScreenIsScaleFree(unittest.TestCase):
    """The old rule was max(8.0 bits, 4.0 x class median). Calibrated against a
    ~6.5-bit fixture, it cut at ~492 bits on a corpus whose examples cost ~123 --
    it could not fire, and its absolute floor was inert by three orders of
    magnitude. These pin the property that broke: the cut must track the data."""

    def _class(self, centre: float, spread: float, outlier: float, n: int = 20):
        spec = [
            ("routing", "refuse", f"host number {i} is not registered with this factory",
             centre + (i % 5) * spread)
            for i in range(n)
        ]
        rows = make_rows(spec)
        rows.append(sc.Row(
            index=n, hash="hBAD", target="routing", decision_class="refuse",
            answer_tokens=10, bits_base=outlier, bits_tuned=0.0, truncated=False,
            text="host number ninety is not registered with this factory",
            shingles=sc.shingles("host number ninety is not registered here", 3),
        ))
        return rows

    def test_it_fires_at_DECISION_bits_scale(self):
        rows = self._class(centre=3.0, spread=0.2, outlier=13.0)
        screen = sc.flag_noise_suspects(rows, factor=4.0, floor=0.0)
        self.assertEqual([r.hash for r in rows if r.noise_suspect], ["hBAD"])
        self.assertEqual(screen.flagged, 1)

    def test_it_fires_at_WHOLE_ANSWER_bits_scale(self):
        """~123 bits per example is the scale the run log implies. The old
        4x-median rule cut at ~492 here and flagged nothing."""
        rows = self._class(centre=123.0, spread=3.0, outlier=400.0)
        sc.flag_noise_suspects(rows, factor=4.0, floor=0.0)
        self.assertEqual([r.hash for r in rows if r.noise_suspect], ["hBAD"])

    def test_the_old_absolute_floor_would_have_disabled_it_entirely(self):
        """A regression guard on the specific bug: an 8.0-bit absolute floor
        dominates every relative cut in a small-scale column, so nothing is ever
        flagged and section 5's 'none' is indistinguishable from an all-clear."""
        rows = self._class(centre=1.5, spread=0.1, outlier=7.5)
        self.assertEqual(sc.flag_noise_suspects(rows, 4.0, floor=8.0).flagged, 0)
        self.assertEqual(sc.flag_noise_suspects(rows, 4.0, floor=0.0).flagged, 1)

    def test_the_floor_defaults_to_off(self):
        parser = sc.build_parser()
        args = parser.parse_args(["--base", "b", "--corpus", "c"])
        self.assertEqual(args.noise_floor, 0.0)

    def test_the_screen_reports_the_cut_and_what_bound_it(self):
        rows = self._class(centre=3.0, spread=0.2, outlier=13.0)
        screen = sc.flag_noise_suspects(rows, 4.0, 0.0)
        key = ("routing", "refuse")
        self.assertIn(key, screen.cuts)
        self.assertGreater(screen.cuts[key], screen.medians[key])
        self.assertIn("MAD", screen.bound_by[key])

    def test_an_absolute_floor_that_binds_says_so(self):
        rows = self._class(centre=3.0, spread=0.2, outlier=13.0)
        screen = sc.flag_noise_suspects(rows, 4.0, floor=999.0)
        self.assertIn("floor", screen.bound_by[("routing", "refuse")])

    def test_a_partition_too_small_to_screen_is_NAMED_not_skipped_silently(self):
        """An unscreened partition is where a mislabel hides. The corpus is
        designed to grow, and a new five-example decision class would be exempt
        from the test entirely with nothing in the report saying so."""
        rows = make_rows([("ledger", "rare", f"unusual case {i} here", 5.0) for i in range(3)])
        screen = sc.flag_noise_suspects(rows, 4.0, 0.0, min_n=8)
        self.assertIn(("ledger", "rare"), screen.skipped)
        self.assertIn("3", screen.skipped[("ledger", "rare")])

    def test_a_degenerate_class_with_no_spread_falls_back_to_the_factor(self):
        rows = make_rows([("routing", "route", f"unique sentence {i} about work", 6.0)
                          for i in range(20)])
        screen = sc.flag_noise_suspects(rows, 4.0, 0.0)
        self.assertEqual(screen.flagged, 0)
        self.assertIn("MAD=0", screen.bound_by[("routing", "route")])

    def test_it_screens_the_DECISION_column_when_every_row_has_one(self):
        """A mislabel is ~10 bits against a whole-answer class spread of tens,
        and most of that spread is prose length. In the decision column it is
        most of the signal."""
        rows = make_rows([("routing", "route", f"send job {i} to alpha", 100.0 + i)
                          for i in range(12)])
        for i, r in enumerate(rows):
            r.decision_bits_base = 2.0 + (i % 3) * 0.1
        rows[5].decision_bits_base = 40.0  # a wrong label token
        screen = sc.flag_noise_suspects(rows, 4.0, 0.0)
        self.assertEqual(screen.column, "decision_bits_base")
        self.assertEqual([r.index for r in rows if r.noise_suspect], [5])

    def test_it_falls_back_to_the_ranked_column_when_the_decision_one_is_partial(self):
        rows = make_rows([("routing", "route", f"send job {i} to alpha", 10.0)
                          for i in range(12)])
        for r in rows[:6]:
            r.decision_bits_base = 1.0
        screen = sc.flag_noise_suspects(rows, 4.0, 0.0)
        self.assertEqual(screen.column, "bits_base")

    def test_noise_column_ranked_forces_the_ranked_column(self):
        rows = make_rows([("routing", "route", f"send job {i} to alpha", 10.0)
                          for i in range(12)])
        for r in rows:
            r.decision_bits_base = 1.0
        self.assertEqual(
            sc.flag_noise_suspects(rows, 4.0, 0.0, use_decision=False).column, "bits_base"
        )

    def test_exclude_keeps_the_class_quota_proportional_to_the_ORIGINAL_size(self):
        """select_curriculum.py's own comment says the quota uses the ORIGINAL n
        'so shares hold'. Nothing tested it: switching it to len(members) --
        which lets --noise-policy exclude shrink a class below its corpus share
        -- passed the whole suite."""
        rows = make_rows([("routing", "route", f"unique sentence {i} about work {i}", 5.0)
                          for i in range(20)])
        for r in rows[:4]:
            r.noise_suspect = True
        sel = sc.select(rows, 0.5, "bits_base", False, 0.99, 3, 1, 17, 4000,
                        noise_policy="exclude")
        # 0.5 * the ORIGINAL 20 = 10. On the 16 that survived exclusion it would
        # be 8, and the class would silently fall below its corpus share.
        # (Four suspects, not one: round(0.5*19) is also 10, so a single
        # exclusion cannot tell the two formulas apart.)
        self.assertEqual(sel.quotas[("routing", "route")], 10)
        self.assertEqual(len(sel.kept), 10)


# ---------------------------------------------------------------------------
# 15. report arithmetic that was wrong or crashed
# ---------------------------------------------------------------------------


class TestReportArithmetic(unittest.TestCase):
    def _args(self, **over):
        parser = sc.build_parser()
        args = parser.parse_args(["--base", "b", "--corpus", "c"])
        for k, v in over.items():
            setattr(args, k, v)
        return args

    def test_a_dropped_row_with_no_bits_column_does_not_crash_the_report(self):
        """--bits-column decision writes null, never 0.0, for a row whose fields
        could not be located. Formatting that with :.2f raised TypeError and
        killed the run AFTER selection -- a traceback instead of a report, and
        no subset written."""
        rows = make_rows([("routing", "route", f"unique sentence {i} here", float(i))
                          for i in range(10)])
        for r in rows[:2]:
            r.bits_base = None
        args = self._args(rank_by="bits_base", explain=10)
        sel = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000)
        report = sc.build_report(rows, sel, args, False)
        self.assertIn("n/a", report)

    def test_the_unscored_cross_reference_names_the_section_it_prints(self):
        """The header said 'Section 6 names them' while the section was numbered
        7 whenever --tuned was given -- i.e. in the main path."""
        rows = make_rows([("routing", "route", f"unique sentence {i} here", float(i + 1))
                          for i in range(10)])
        for r in rows:
            r.bits_tuned = 0.1
        args = self._args(rank_by="learned_bits", explain=5)
        sel = sc.select(rows, 0.5, "learned_bits", False, 0.9, 3, 1, 17, 4000)
        report = sc.build_report(rows, sel, args, True, (), [(99, "unscorable")])
        self.assertIn("Section 7 names", report)
        self.assertIn("7. UNSCORED CORPUS LINES", report)
        self.assertNotIn("Section 6 names", report)

    def test_excluded_noise_suspects_are_not_counted_as_redundant(self):
        """Under --noise-policy exclude the suspects never enter a cluster, so
        dividing the cluster count by len(rows) invents surface redundancy that
        does not exist -- and contradicts the per-partition table in the same
        report."""
        rows = make_rows([("routing", "route", f"wholly distinct sentence {i} xyz{i}", 5.0)
                          for i in range(20)])
        for r in rows[:4]:
            r.noise_suspect = True
            r.bits_base = 200.0
        args = self._args(rank_by="bits_base", noise_policy="exclude", explain=5)
        sel = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000,
                        noise_policy="exclude")
        report = sc.build_report(rows, sel, args, False)
        # every row is textually distinct: 16 clustered rows, 16 clusters, 0%
        self.assertIn("0.0% surface redundancy", report)
        self.assertIn("never entered a cluster", report)

    def test_the_report_names_the_share_of_the_RANKED_quantity(self):
        """Sections 3 and 4 quantified the selection in bits_base while the
        default ranking with --tuned is learned_bits, so the headline described
        a criterion the selector did not use."""
        rows = make_rows([("routing", "route", f"unique sentence {i} here", float(i + 1))
                          for i in range(10)])
        # bits_base ASCENDS with the index; learned_bits DESCENDS. So the two
        # orderings are exact opposites and a report that sorts by the wrong one
        # names the wrong example first.
        for i, r in enumerate(rows):
            r.bits_tuned = float(i + 1) - (10.0 - i)
        args = self._args(rank_by="learned_bits", explain=10)
        sel = sc.select(rows, 0.5, "learned_bits", False, 0.9, 3, 1, 17, 4000)
        report = sc.build_report(rows, sel, args, True)
        self.assertIn("of the corpus's learned_bits", report)
        self.assertIn("THE CRITERION ACTUALLY USED", report)
        self.assertIn("highest-learned_bits drops first", report)

        # ...and the list is actually ORDERED by that criterion, not merely
        # labelled with it. Sorting by bits_base while ranking on learned_bits
        # printed one number as the header and a different one as the reason.
        named = [int(l.split("idx")[1].split()[0])
                 for l in report.splitlines() if l.strip().startswith("idx ")]
        by_learned = sorted(sel.dropped, key=lambda r: -(r.learned_bits or 0))
        self.assertEqual(named[: len(by_learned)], [r.index for r in by_learned])
        self.assertNotEqual(
            named[: len(by_learned)],
            [r.index for r in sorted(sel.dropped, key=lambda r: -(r.bits_base or 0))],
            "the fixture must make the two orderings differ, or this proves nothing",
        )

    def test_the_report_says_how_much_of_the_cut_the_gate_cannot_see(self):
        """evals/tmux-routing scores the routing track only. A subset that
        wrecks the tooluse track gates identically, so the count belongs in the
        report as a measurement, not in a footnote as a caveat."""
        rows = make_rows(
            [("routing", "route", f"send job {i} to alpha", 5.0) for i in range(6)]
            + [("tooluse", "run", f"run command number {i} now", 5.0) for i in range(6)]
        )
        args = self._args(rank_by="bits_base", explain=5)
        sel = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000)
        report = sc.build_report(rows, sel, args, False)
        self.assertIn("gate visibility", report)
        self.assertIn("ROUTING track only", report)

    def test_the_limits_block_does_not_quote_another_corpus_as_if_it_were_this_one(self):
        """The LIMITS text hardcoded cluster counts measured on the 2363-example
        file into a report computed on the 2245-example one, contradicting
        section 2 of the same report."""
        rows = make_rows([("routing", "route", f"unique sentence {i} here", 5.0)
                          for i in range(10)])
        args = self._args(rank_by="bits_base")
        sel = sc.select(rows, 0.5, "bits_base", False, 0.9, 3, 1, 17, 4000)
        report = sc.build_report(rows, sel, args, False)
        for stale in ("1817 clusters", "1335 with the answer", "121 vs 834"):
            self.assertNotIn(stale, report)
        # the figures that remain must name the corpus they were measured on
        if "1283" in report:
            self.assertIn("datasets/mlx/train.jsonl", report)


class TestRankNormalizeUnits(unittest.TestCase):
    def test_decision_bits_are_normalized_by_DECISION_tokens(self):
        """--rank-normalize divided decision bits by whole-answer tokens, so two
        examples with identical decision bits ranked by the length of their
        reason prose -- the exact length bias the flag exists to remove, upside
        down."""
        a = sc.Row(index=0, hash="a", target="routing", decision_class="route",
                   answer_tokens=100, bits_base=10.0, bits_tuned=None, truncated=False,
                   decision_tokens=5, bits_column="decision")
        b = sc.Row(index=1, hash="b", target="routing", decision_class="route",
                   answer_tokens=20, bits_base=10.0, bits_tuned=None, truncated=False,
                   decision_tokens=5, bits_column="decision")
        # identical decision bits over identical decision tokens => identical rank
        self.assertEqual(a.value("bits_base", True), b.value("bits_base", True))
        self.assertEqual(a.value("bits_base", True), 2.0)

    def test_answer_bits_still_normalize_by_answer_tokens(self):
        r = sc.Row(index=0, hash="a", target="routing", decision_class="route",
                   answer_tokens=10, bits_base=40.0, bits_tuned=None, truncated=False,
                   decision_tokens=2, bits_column="answer")
        self.assertEqual(r.value("bits_base", True), 4.0)


# ---------------------------------------------------------------------------
# 16. the external anchor: the one check this repo did not produce the answer to
# ---------------------------------------------------------------------------


class TestTrainerAnchor(unittest.TestCase):
    LOG = (
        "Iter 1: Val loss 2.463, Val took 12.0s\n"
        "Iter 25: Train loss 1.2\n"
        "Iter 500: Val loss 0.074\n"
        "Iter 3500: Val loss 0.012\n"
    )

    def _meta(self, loss, adapter=None):
        return {"adapter": adapter, "summary": {"trainer_parity_loss_nats": loss}}

    def test_val_losses_are_read_off_the_log(self):
        self.assertEqual(pc.val_losses(self.LOG)[1], 2.463)
        self.assertEqual(pc.val_losses(self.LOG)[3500], 0.012)

    def test_a_matching_port_passes(self):
        ok, msg = pc.compare_anchor(self._meta(2.44), self.LOG, 1, 0.15)
        self.assertTrue(ok, msg)

    def test_a_prompt_masking_error_is_caught(self):
        """Scoring the prompt as if it were the answer moves the loss by a large
        multiple -- the failure that matters and the one internal parity cannot
        see, because both forward paths would be wrong the same way."""
        ok, _ = pc.compare_anchor(self._meta(0.31), self.LOG, 1, 0.15)
        self.assertFalse(ok)

    def test_anchoring_on_the_TAIL_of_the_log_is_refused_for_a_tuned_run(self):
        """The vacuous check this replaced: a memorized adapter's residual is
        ~0.01 and so is the late val loss, whether the mask is right or wrong."""
        ok, msg = pc.compare_anchor(self._meta(0.01, adapter="/a"), self.LOG, 1, 0.15)
        self.assertFalse(ok)
        self.assertIn("UNTUNED", msg)

    def test_a_log_with_no_val_losses_FAILS_rather_than_passing_vacuously(self):
        ok, msg = pc.compare_anchor(self._meta(2.463), "Iter 25: Train loss 1.2\n", 1, 0.15)
        self.assertFalse(ok)
        self.assertIn("nothing to anchor", msg)

    def test_a_missing_iteration_fails_rather_than_picking_another(self):
        ok, msg = pc.compare_anchor(self._meta(2.463), self.LOG, 999, 0.15)
        self.assertFalse(ok)
        self.assertIn("999", msg)

    def test_a_meta_file_without_the_summary_fails(self):
        ok, msg = pc.compare_anchor({"summary": {}}, self.LOG, 1, 0.15)
        self.assertFalse(ok)
        self.assertIn("no summary", msg)

    def test_the_cli_runs_in_anchor_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "m.json").write_text(json.dumps(self._meta(2.44)), encoding="utf-8")
            (d / "train.log").write_text(self.LOG, encoding="utf-8")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                rc = pc.main(["--anchor", str(d / "m.json"), "--log", str(d / "train.log")])
            finally:
                sys.stderr = stderr
            self.assertEqual(rc, 0)
            self.assertIn("2.4630", err.getvalue())


# ---------------------------------------------------------------------------
# 17. guards the review found untested by mutation
# ---------------------------------------------------------------------------


class TestPreviouslyUntestedGuards(unittest.TestCase):
    def test_a_truncated_plan_is_refused_even_when_the_answer_IS_locatable(self):
        """The old test reached its assertIsNone through a different branch --
        the truncated region simply did not contain the answer text -- so
        deleting 'or plan.truncated' from decision_indices kept every test
        green. Drive the guard directly: a plan marked truncated whose region
        DOES contain the whole answer."""
        answer = '{"action": "route"}'
        text = "P>" + answer
        tokens = char_tokens(text)
        stub = sb.StubScorer(256, lambda r, v: 0.0)
        honest = sb.plan_mask(tokens, 2, 4096, match_trainer=True)
        self.assertFalse(honest.truncated)
        self.assertIsNotNone(
            sb.decision_indices(honest, tokens, answer, ("action",), stub.decode)
        )
        # same tokens, same offset, same region -- only `truncated` differs
        lying = sb.MaskPlan(
            length=honest.length + 5, effective_length=honest.effective_length,
            offset=honest.offset, rows=list(honest.rows), targets=list(honest.targets),
            answer_tokens=honest.answer_tokens, trainer_tokens=honest.trainer_tokens,
            truncated=True, tokens_lost=5, usable=True,
        )
        self.assertIsNone(
            sb.decision_indices(lying, tokens, answer, ("action",), stub.decode),
            "a truncated answer's decision span is not established, it is guessed",
        )

    def test_a_template_whose_prompt_is_not_a_prefix_is_REFUSED(self):
        """chat_tokenize asserts tokens[:offset] == prompt tokens. The README
        advertises that refusal; nothing exercised it, and replacing the
        condition with `if False:` passed the suite."""

        class NotPrefixStable:
            def apply_chat_template(self, messages, tools=None, add_generation_prompt=False,
                                    return_dict=False):
                if len(messages) == 1:  # the prompt-only call
                    return [9, 9, 9]
                return [1, 2, 3, 4, 5]

        with self.assertRaises(ValueError) as cm:
            sb.chat_tokenize(NotPrefixStable(), [{"role": "user", "content": "u"},
                                                 {"role": "assistant", "content": "a"}])
        self.assertIn("prefix-stable", str(cm.exception))

    def test_a_prefix_stable_template_is_accepted(self):
        class PrefixStable:
            def apply_chat_template(self, messages, tools=None, add_generation_prompt=False,
                                    return_dict=False):
                return [1, 2, 3] if len(messages) == 1 else [1, 2, 3, 4, 5]

        tokens, offset = sb.chat_tokenize(
            PrefixStable(), [{"role": "user", "content": "u"},
                             {"role": "assistant", "content": "a"}]
        )
        self.assertEqual((tokens, offset), ([1, 2, 3, 4, 5], 3))

    def test_a_score_file_mixing_two_adapters_is_refused(self):
        """load_scores raises on it; no test drove that path."""
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "mixed.jsonl"
            p.write_text(
                json.dumps({"hash": "a", "bits": 1.0, "adapter": None, "skipped": False}) + "\n"
                + json.dumps({"hash": "b", "bits": 2.0, "adapter": "/x", "skipped": False}) + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit) as cm:
                sc.load_scores(p)
            self.assertIn("two runs spliced together", str(cm.exception))

    def test_dry_run_takes_the_process_half_of_the_guard(self):
        """--dry-run imports mlx_lm to reach the TokenizerWrapper, and that
        import initialises Metal. It used to skip the guard entirely -- the one
        unguarded path to the Metal runtime, under exactly the condition the
        standing rule was written for."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            corpus = d / "c.jsonl"
            corpus.write_text(json.dumps({"messages": example(
                ROUTING_SYS, "go", {"action": "route", "session": "s"})}) + "\n", encoding="utf-8")
            real = sb._pgrep
            sb._pgrep = lambda pattern: ["18405"] if "lo" + "ra" in pattern else []
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with self.assertRaises(SystemExit) as cm:
                    sb.main(["--data", str(corpus), "--out", str(d / "o.jsonl"), "--dry-run"])
            finally:
                sb._pgrep = real
                sys.stderr = stderr
            self.assertEqual(cm.exception.code, sb.BUSY_EXIT)
            self.assertIn("refusing to run", err.getvalue())

    def test_the_process_only_guard_still_ignores_free_memory(self):
        """It allocates nothing, so a memory threshold is not its precondition;
        only 'no fine-tune is live' is."""
        real_pgrep, real_free = sb._pgrep, sb.free_gb
        sb._pgrep = lambda pattern: []
        sb.free_gb = lambda: 0.5  # would fail the normal guard
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            sb.guard(10.0, check_memory=False)  # must NOT raise
        finally:
            sb._pgrep, sb.free_gb = real_pgrep, real_free
            sys.stderr = stderr
        self.assertIn("memory not checked", err.getvalue())



# ---------------------------------------------------------------------------
# 18. the adapter is identified by its CONTENT, not by its path
# ---------------------------------------------------------------------------


class TestAdapterContentDigest(unittest.TestCase):
    """A path is not an identity.

    ``models/candidates/fin-foreman-e4b-mlx/adapters.safetensors`` is rewritten
    every 250 iterations, and the staging recipe copies checkpoints over one
    reused directory on purpose. Identifying the adapter by
    ``str(Path(args.adapter).resolve())`` therefore says nothing about which
    weights produced a row.
    """

    def test_the_same_bytes_at_two_paths_digest_the_same(self):
        """Deterministic and path-independent: staging one checkpoint twice is
        the same measurement, and must join."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            a = fake_adapter(d / "stage-a", b"identical-weights")
            b = fake_adapter(d / "stage-b", b"identical-weights")
            self.assertEqual(sb.adapter_content_digest(a), sb.adapter_content_digest(b))

    def test_different_weights_digest_differently(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            a = fake_adapter(d / "a", b"checkpoint-3000")
            b = fake_adapter(d / "b", b"checkpoint-3500")
            self.assertNotEqual(sb.adapter_content_digest(a), sb.adapter_content_digest(b))

    def test_the_CONFIG_is_in_the_digest_too(self):
        """adapter_config.json decides rank, scale and which layers the LoRA is
        applied to. The same weights under a different config is a different
        forward pass, so it must be a different fingerprint."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            a = fake_adapter(d / "a", b"w", rank=8)
            b = fake_adapter(d / "b", b"w", rank=16)
            self.assertNotEqual(sb.adapter_content_digest(a), sb.adapter_content_digest(b))

    def test_a_checkpoint_copied_over_one_path_changes_the_digest(self):
        """THE hazard, in three lines: one directory, two models."""
        with tempfile.TemporaryDirectory() as tmp:
            p = fake_adapter(Path(tmp) / "adapter", b"checkpoint-3000")
            before = sb.adapter_content_digest(p)
            (p / sb.ADAPTER_WEIGHTS_NAME).write_bytes(b"checkpoint-3500")
            self.assertNotEqual(before, sb.adapter_content_digest(p))

    def test_a_base_run_has_no_digest(self):
        self.assertIsNone(sb.adapter_content_digest(None))
        self.assertIsNone(
            sb.run_fingerprint("m", None, 3072, True, False, 512)["adapter_digest"]
        )

    def test_an_adapter_directory_missing_a_loaded_file_is_refused(self):
        """Fingerprinting a directory mlx_lm could not load would record an
        adapter that was never applied. Refused before the GPU is touched."""
        for missing in (sb.ADAPTER_WEIGHTS_NAME, sb.ADAPTER_CONFIG_NAME):
            with self.subTest(missing=missing):
                with tempfile.TemporaryDirectory() as tmp:
                    p = fake_adapter(Path(tmp) / "a")
                    (p / missing).unlink()
                    with self.assertRaises(SystemExit) as cm:
                        sb.adapter_content_digest(p)
                    self.assertIn(missing, str(cm.exception))

    def test_a_nonexistent_adapter_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                sb.adapter_content_digest(Path(tmp) / "nope")

    def test_an_adapter_FILE_is_refused_because_the_loader_needs_a_DIRECTORY(self):
        """The digest used to accept a plain file as 'unambiguous -- a single
        weights file, named'. But MLXScorer loads the adapter with
        mlx_lm.load(..., adapter_path=...), which reads adapter_config.json out
        of a directory: that branch fingerprinted a configuration that could
        never run, and the fingerprint would have described something no row was
        ever scored under."""
        with tempfile.TemporaryDirectory() as tmp:
            p = fake_adapter(Path(tmp) / "adapter")
            with self.assertRaises(SystemExit) as cm:
                sb.adapter_content_digest(p / sb.ADAPTER_WEIGHTS_NAME)
            self.assertIn("is a file", str(cm.exception))
            self.assertIn("DIRECTORY", str(cm.exception))

    def test_the_refusal_names_the_directory_to_pass_instead(self):
        """The operator pointed at the weights inside a perfectly good adapter
        directory. Say which path to use rather than making them guess."""
        with tempfile.TemporaryDirectory() as tmp:
            p = fake_adapter(Path(tmp) / "adapter")
            with self.assertRaises(SystemExit) as cm:
                sb.adapter_content_digest(p / sb.ADAPTER_WEIGHTS_NAME)
            self.assertIn(f"--adapter {p}", str(cm.exception))

    def test_a_loose_file_that_is_not_in_an_adapter_dir_is_refused_too(self):
        """No directory to suggest, so it says what an adapter directory is
        instead of resolving to a parent the operator never named."""
        with tempfile.TemporaryDirectory() as tmp:
            loose = Path(tmp) / "0003000_adapters.safetensors"
            loose.write_bytes(b"checkpoint-3000")
            with self.assertRaises(SystemExit) as cm:
                sb.adapter_content_digest(loose)
            self.assertIn("adapter DIRECTORY", str(cm.exception))

    def test_the_scorer_refuses_an_adapter_file_before_it_loads_anything(self):
        """End to end: the digest runs before the machine guard and before any
        weights load, so this costs no GPU seconds -- the point of hashing
        early."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            adapter = fake_adapter(d / "adapter")
            corpus = d / "c.jsonl"
            corpus.write_text(
                json.dumps({"messages": example(
                    ROUTING_SYS, "route it", {"action": "route", "session": "s"})}) + "\n",
                encoding="utf-8")
            err = io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with self.assertRaises(SystemExit) as cm:
                    sb.main(["--model", "m", "--data", str(corpus),
                             "--out", str(d / "out.jsonl"),
                             "--adapter", str(adapter / sb.ADAPTER_WEIGHTS_NAME)])
            finally:
                sys.stderr = stderr
            self.assertIn("is a file", str(cm.exception))

    def test_the_digest_is_in_the_row_fingerprint(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = fake_adapter(Path(tmp) / "a")
            digest = sb.adapter_content_digest(p)
            fp = sb.run_fingerprint("m", str(p), 3072, True, False, 512, digest)
            self.assertEqual(fp["adapter_digest"], digest)
            self.assertTrue(digest.startswith("sha256:"))

    # -- the resume, end to end, with no model ------------------------------

    def _resumable(self, d: Path, adapter, digest):
        """A corpus and a COMPLETE score file for it, so that a resume which
        wrongly succeeds ends at 'nothing to do' -- never at a model load."""
        msgs = [example(ROUTING_SYS, f"route job {i}",
                        {"action": "route", "session": f"s{i}"})
                for i in range(3)]
        corpus = d / "corpus.jsonl"
        corpus.write_text("".join(json.dumps({"messages": m}) + "\n" for m in msgs),
                          encoding="utf-8")
        out = d / "scores.jsonl"
        with out.open("w", encoding="utf-8") as fh:
            for m in msgs:
                row = sb.run_fingerprint(
                    "m", str(Path(adapter).resolve()) if adapter else None,
                    3072, True, False, 512, digest,
                )
                row.update({"hash": sb.content_hash(m), "bits": 1.0, "skipped": False,
                            "answer_tokens": 4, "trainer_tokens": 5, "trainer_nats": 1.0,
                            "truncated": False})
                fh.write(json.dumps(row, sort_keys=True) + "\n")
        return corpus, out

    def _resume(self, corpus: Path, out: Path, adapter: Path):
        buf, err = io.StringIO(), io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            with redirect_stdout(buf):
                rc = sb.main(["--model", "m", "--data", str(corpus), "--out", str(out),
                              "--adapter", str(adapter)])
        finally:
            sys.stderr = stderr
        return rc, err.getvalue()

    def test_a_resume_after_the_weights_changed_under_one_path_is_REFUSED(self):
        """The finding, reproduced: score under checkpoint 3000, get killed, let
        checkpoint 3500 land on the same path, re-run the SAME command. Every
        recorded key still matched -- model, adapter path, window, forward path
        -- so the resume passed and appended the rest of the corpus under
        different weights. One score file, two models, one name."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            adapter = fake_adapter(d / "adapter", b"checkpoint-3000")
            corpus, out = self._resumable(d, adapter, sb.adapter_content_digest(adapter))
            # ... 250 iterations later, the trainer overwrites the same file.
            (adapter / sb.ADAPTER_WEIGHTS_NAME).write_bytes(b"checkpoint-3500")
            rc, err = self._resume(corpus, out, adapter)
            self.assertEqual(rc, 2, err)
            self.assertIn("adapter_digest", err)
            self.assertIn("ADAPTER'S CONTENT changed", err)

    def test_a_resume_against_the_same_weights_still_resumes(self):
        """The check has to be capable of passing, or it is just a stop sign."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            adapter = fake_adapter(d / "adapter", b"checkpoint-3000")
            corpus, out = self._resumable(d, adapter, sb.adapter_content_digest(adapter))
            rc, err = self._resume(corpus, out, adapter)
            self.assertEqual(rc, 0, err)
            self.assertIn("nothing to do", err)

    def test_a_tuned_file_from_a_scorer_that_recorded_no_digest_is_not_resumed(self):
        """What those rows were scored under cannot be established, so they
        cannot be extended. Re-score; do not guess."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            adapter = fake_adapter(d / "adapter")
            corpus, out = self._resumable(d, adapter, None)  # legacy rows
            rc, err = self._resume(corpus, out, adapter)
            self.assertEqual(rc, 2, err)
            self.assertIn("adapter_digest", err)

    def test_a_BASE_file_from_an_older_scorer_still_resumes(self):
        """A base run has no adapter, so 'recorded no digest' and 'has no
        digest' are the same state and old base files stay joinable. Refusing
        them would be a gratuitous re-score of the expensive half."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            msgs = example(ROUTING_SYS, "route it", {"action": "route", "session": "s"})
            corpus = d / "c.jsonl"
            corpus.write_text(json.dumps({"messages": msgs}) + "\n", encoding="utf-8")
            out = d / "s.jsonl"
            row = {"model": "m", "adapter": None, "max_seq_length": 3072,
                   "match_trainer": True, "full_forward": False, "chunk": 512,
                   "hash": sb.content_hash(msgs), "bits": 1.0, "skipped": False,
                   "answer_tokens": 4, "trainer_tokens": 5, "trainer_nats": 1.0,
                   "truncated": False}
            out.write_text(json.dumps(row, sort_keys=True) + "\n", encoding="utf-8")
            buf, err = io.StringIO(), io.StringIO()
            stderr, sys.stderr = sys.stderr, err
            try:
                with redirect_stdout(buf):
                    rc = sb.main(["--model", "m", "--data", str(corpus), "--out", str(out)])
            finally:
                sys.stderr = stderr
            self.assertEqual(rc, 0, err.getvalue())

    # -- downstream ---------------------------------------------------------

    def test_the_digest_is_deliberately_NOT_a_pair_key(self):
        """base and tuned are SUPPOSED to differ here; a must-agree rule would
        refuse every valid pair. The direction rule covers it instead."""
        for keys in (sb.PAIR_FINGERPRINT_KEYS, sc.PAIR_FINGERPRINT_KEYS):
            self.assertNotIn("adapter", keys)
            self.assertNotIn("adapter_digest", keys)

    def test_every_fingerprint_field_is_classified_agree_or_differ(self):
        """The two modules mirror one split, and a field that is in neither
        tuple is a field nothing checks across the pair -- which is how the
        adapter came to be unchecked in the first place."""
        self.assertEqual(sb.PAIR_FINGERPRINT_KEYS, sc.PAIR_FINGERPRINT_KEYS)
        self.assertEqual(sb.ADAPTER_FINGERPRINT_KEYS, sc.ADAPTER_FINGERPRINT_KEYS)
        self.assertEqual(
            set(sb.PAIR_FINGERPRINT_KEYS) | set(sb.ADAPTER_FINGERPRINT_KEYS),
            set(sb.run_fingerprint("m", None, 3072, True, False, 512)),
        )

    def test_a_file_mixing_two_adapter_CONTENTS_under_one_path_is_refused(self):
        """The mixed-adapter refusal saw one path and said nothing. This is the
        same splice the resume check now prevents, arriving from any other
        direction -- a hand-concatenated file, a restored backup."""
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "spliced.jsonl"
            p.write_text(
                json.dumps({"hash": "a", "bits": 1.0, "adapter": "/one/path",
                            "adapter_digest": "sha256:" + "11" * 32,
                            "skipped": False}) + "\n"
                + json.dumps({"hash": "b", "bits": 2.0, "adapter": "/one/path",
                              "adapter_digest": "sha256:" + "22" * 32,
                              "skipped": False}) + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit) as cm:
                sc.load_scores(p)
            self.assertIn("two models under one name", str(cm.exception))


class TestPairAdapterDirection(unittest.TestCase):
    """What must AGREE across the pair is ``check_pair_fingerprints``. What must
    DIFFER, and in which direction, is this. 'Allowed to differ' had quietly
    become 'never looked at'."""

    BASE = {"model": "m", "max_seq_length": 3072, "match_trainer": True,
            "full_forward": False, "chunk": 512, "adapter": None, "adapter_digest": None}
    TUNED = dict(BASE, adapter="/models/cand", adapter_digest="sha256:" + "ab" * 32)

    def _check(self, base, tuned, allow=False):
        sc.check_pair_adapters(base, tuned, Path("b"), Path("t"), allow)

    def test_the_valid_direction_passes(self):
        self._check(dict(self.BASE), dict(self.TUNED))

    def test_both_sides_untuned_is_refused(self):
        """learned_bits = base - base = 0 for every example, and it is the
        DEFAULT ranking key: the selection becomes a coin flip."""
        with self.assertRaises(SystemExit) as cm:
            self._check(dict(self.BASE), dict(self.BASE))
        self.assertIn("scored with NO adapter", str(cm.exception))

    def test_a_base_file_that_carries_an_adapter_is_refused(self):
        other = dict(self.TUNED, adapter="/other", adapter_digest="sha256:" + "ef" * 32)
        with self.assertRaises(SystemExit) as cm:
            self._check(dict(self.TUNED), other)
        self.assertIn("--base but was scored WITH an adapter", str(cm.exception))

    def test_the_same_CONTENT_under_two_paths_is_refused(self):
        """One checkpoint staged twice and subtracted from itself. The paths
        differ, so nothing keyed on the path could ever see it."""
        same = dict(self.TUNED, adapter="/stage-a")
        other = dict(self.TUNED, adapter="/stage-b")
        with self.assertRaises(SystemExit) as cm:
            sc.check_pair_adapters(same, other, Path("b"), Path("t"), False)
        self.assertIn("SAME adapter content", str(cm.exception))
        self.assertIn("identically zero", str(cm.exception))

    def test_a_tuned_file_with_no_digest_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            self._check(dict(self.BASE), dict(self.TUNED, adapter_digest=None))
        self.assertIn("records no adapter_digest", str(cm.exception))

    def test_a_pair_recording_neither_field_is_refused(self):
        """Both files predate the content fingerprint: there is no evidence that
        one is the base run and the other the tuned one."""
        bare = {"model": "m", "max_seq_length": 3072, "match_trainer": True,
                "full_forward": False, "chunk": 512}
        with self.assertRaises(SystemExit) as cm:
            self._check(dict(bare), dict(bare))
        self.assertIn("predate the content fingerprint", str(cm.exception))

    def test_the_escape_hatch_warns_instead_of_refusing(self):
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            self._check(dict(self.BASE), dict(self.BASE), allow=True)
        finally:
            sys.stderr = stderr
        self.assertIn("WARNING", err.getvalue())

    def test_the_SELECTOR_refuses_an_UNVERIFIABLE_tuned_file_end_to_end(self):
        """Drive the CLI, so deleting the call site fails a test. The case is
        the one only this check sees: a --tuned file that names an adapter (so
        load_scores' expect_adapter is satisfied) but records no content digest,
        which is exactly what a file scored under a path that has since taken
        four more checkpoints looks like."""
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            msgs = [example(ROUTING_SYS, f"route job {i} to alpha now",
                            {"action": "route", "session": f"s{i}", "reason": "named"})
                    for i in range(8)]
            corpus = d / "corpus.jsonl"
            corpus.write_text("".join(json.dumps({"messages": m}) + "\n" for m in msgs),
                              encoding="utf-8")

            def write(path, adapter, digest, scale):
                with path.open("w", encoding="utf-8") as fh:
                    for i, m in enumerate(msgs):
                        rec = dict(self.BASE, adapter=adapter, adapter_digest=digest)
                        rec.update({"hash": sb.content_hash(m), "index": i,
                                    "target": "routing", "decision_class": "route",
                                    "answer_tokens": 20, "bits": (i + 1) * scale,
                                    "decision_bits": (i + 1) * scale * 0.1,
                                    "decision_tokens": 4, "truncated": False,
                                    "skipped": False})
                        fh.write(json.dumps(rec, sort_keys=True) + "\n")

            base, tuned = d / "base.jsonl", d / "tuned.jsonl"
            write(base, None, None, 1.0)
            write(tuned, "/models/cand", None, 0.5)  # named, but not identified
            err = io.StringIO()
            with redirect_stdout(io.StringIO()):
                stderr, sys.stderr = sys.stderr, err
                try:
                    rc = sc.main(["--base", str(base), "--tuned", str(tuned),
                                  "--corpus", str(corpus)])
                except SystemExit as exc:
                    rc = exc.code if isinstance(exc.code, int) else 1
                    print(exc, file=err)
                finally:
                    sys.stderr = stderr
            self.assertNotEqual(rc, 0)
            self.assertIn("records no adapter_digest", err.getvalue())


# ---------------------------------------------------------------------------
# 19. the parity tolerance is relative, and honest about being uncalibrated
# ---------------------------------------------------------------------------


class TestParityToleranceIsRelative(unittest.TestCase):
    """The old rule was TOLERANCE = 1e-2 as an ABSOLUTE bound on a per-example
    SUM of bits, hard-gating the pipeline. At this corpus's scale (~123 bits per
    example: the live log's 2.463 nats/token x 34.6 unmasked tokens) that is
    ~8e-5 relative, while the two paths compared -- one un-cached forward against
    a chunked prefill through a rotating KV cache on a 4-bit-quantised model --
    disagree by more than that as a matter of arithmetic. It was far likelier to
    fail on float noise than to catch a bug."""

    CORPUS_SCALE = 123.0  # bits/example, derived from train.log; see parity_check.py
    TOKENS = 35           # 127129/3675 = 34.6 unmasked tokens per example, rounded

    def _cli(self, chunked, full, extra=(), tokens=TOKENS):
        return run_parity_cli(
            parity_rows(chunked, tokens),
            parity_rows(full, tokens, full_forward=True),
            extra,
        )

    def test_float_noise_at_corpus_scale_no_longer_fails_the_pipeline(self):
        """0.05 bits on a 123-bit example is 4e-4 relative -- what a 1e-3
        nats/token disagreement over ~35 answer tokens comes to. The old
        absolute 1e-2 bound failed it fivefold."""
        ok, msg = pc.compare(
            {"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE}, {"a": self.TOKENS}
        )
        self.assertTrue(ok, msg)
        self.assertIn("4.065e-04", msg)

    def test_the_same_absolute_gap_is_judged_differently_at_different_scales(self):
        """The definition of relative. An absolute rule cannot tell these apart,
        and one of the two answers it gives is wrong."""
        n = {"a": self.TOKENS}
        big, _ = pc.compare({"a": 123.5}, {"a": 123.0}, n)   # 0.4% -- noise
        small, _ = pc.compare({"a": 10.5}, {"a": 10.0}, n)   # 5%   -- not noise
        self.assertTrue(big)
        self.assertFalse(small)

    def test_a_divergence_that_cannot_be_float_noise_still_fails(self):
        """The bound must not have been loosened into one that passes
        everything: a mis-assembled row is a different token's logprob."""
        ok, msg = pc.compare(
            {"a": 200.0}, {"a": self.CORPUS_SCALE}, {"a": self.TOKENS}
        )
        self.assertFalse(ok, msg)
        rc, err = self._cli({"a": 200.0}, {"a": self.CORPUS_SCALE})
        self.assertEqual(rc, 1)
        self.assertIn("FAILED", err)

    def test_an_explicit_tolerance_is_enforced_strictly(self):
        """Once an operator has real numbers, they are the gate and the coarse
        ceilings are out of the way. BOTH halves have to be given: the bound is
        the larger of the two, so a tight --tolerance alone changes nothing."""
        ok, _ = pc.compare(
            {"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE}, {"a": self.TOKENS},
            1e-5, 1e-6,
        )
        self.assertFalse(ok)
        rc, err = self._cli({"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE},
                            ["--tolerance", "1e-5", "--per-token-bits", "1e-6"])
        self.assertEqual(rc, 1)
        self.assertIn("(--tolerance)", err)
        self.assertIn("(--per-token-bits)", err)

    def test_setting_only_one_half_cannot_tighten_past_the_other(self):
        """The bound is max(relative, per-token), so the looser half rules. An
        operator who calibrates one and forgets the other has NOT tightened the
        gate -- which is why the banner names the half still at its default."""
        args = ({"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE}, {"a": self.TOKENS})
        self.assertTrue(pc.compare(*args, 1e-9, None)[0])   # per-token half still 5e-3
        self.assertTrue(pc.compare(*args, None, 1e-9)[0])   # relative half still 5e-2
        self.assertFalse(pc.compare(*args, 1e-9, 1e-9)[0])
        rc, err = self._cli(*args[:2], ["--tolerance", "1e-9"])
        self.assertEqual(rc, 0)
        self.assertIn("NOT CALIBRATED", err)
        self.assertIn(f"--per-token-bits ({pc.UNCALIBRATED_PER_TOKEN_BITS:g}", err)
        self.assertNotIn(f"--tolerance ({pc.UNCALIBRATED_REL_CEILING:g}", err)

    def test_the_uncalibrated_default_says_so_loudly_ON_A_PASS(self):
        """An uncalibrated pass is the one that gets mistaken for a validated
        one, so the banner prints when the check SUCCEEDS."""
        rc, err = self._cli({"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE})
        self.assertEqual(rc, 0)
        self.assertIn("NOT CALIBRATED", err)
        self.assertIn("max relative divergence", err)
        self.assertIn("max per-token divergence", err)
        self.assertIn("--tolerance", err)

    def test_explicit_bounds_for_BOTH_halves_retire_the_uncalibrated_banner(self):
        rc, err = self._cli({"a": self.CORPUS_SCALE + 0.05}, {"a": self.CORPUS_SCALE},
                            ["--tolerance", "1e-2", "--per-token-bits", "1e-2"])
        self.assertEqual(rc, 0)
        self.assertNotIn("NOT CALIBRATED", err)

    def test_the_observed_maxima_are_reported_whatever_the_verdict(self):
        """Reporting the numbers is the point: it is how the two halves get
        calibrated at all."""
        for extra in ((), ("--tolerance", "1e-9", "--per-token-bits", "1e-12")):
            with self.subTest(extra=extra):
                _, err = self._cli({"a": 123.05, "b": 60.0}, {"a": 123.0, "b": 60.0}, extra)
                self.assertIn("max relative divergence", err)
                self.assertIn("max per-token divergence", err)
                self.assertIn("over 2 examples", err)

    def test_the_file_records_that_the_bound_is_awaiting_calibration(self):
        """No GPU parity run has ever been made against this code. The default
        must not pretend otherwise; the old absolute hard gate must not come
        back under the same name; and neither must the fixed per-example floor
        that replaced it, whose allowance ignored an example's length."""
        src = Path(pc.__file__).read_text(encoding="utf-8")
        self.assertIn("AWAITING CALIBRATION", src)
        self.assertFalse(hasattr(pc, "TOLERANCE"),
                         "the absolute, uncalibrated hard gate is back")
        self.assertFalse(hasattr(pc, "ABS_FLOOR_BITS"),
                         "the fixed per-example floor is back; the small end is per TOKEN")
        for half in ("tolerance", "per_token_bits"):
            self.assertIsNone(inspect.signature(pc.compare).parameters[half].default)


# ---------------------------------------------------------------------------
# 20. the small end of the parity bound is PER TOKEN, not a fixed floor
# ---------------------------------------------------------------------------


class TestParityBoundIsPerToken(unittest.TestCase):
    """The relative rule with a fixed 1-bit floor collapsed, for every example at
    or below 1 bit, to an allowance of 5e-2 x 1.0 = 0.05 bits -- the same number
    whatever the example scored and however many tokens it summed over. That is
    the wrong quantity twice over:

      * a memorized tuned example is ~0.05 bits, so the allowance WAS the whole
        example and the check stopped discriminating exactly where the numbers
        get small;
      * 0.05 bits over this corpus's 34.6 answer tokens is 1.44e-3 bits/token =
        1.0e-3 nats/token, the expected float disagreement itself, with no
        margin -- and on a 350-token example the same fixed 0.05 bits demands
        10x BETTER per-token agreement, while on a 3-token example it is 10x
        looser than the noise.

    The disagreement accumulates per TOKEN, so the bound's small end is per
    token.
    """

    TOKENS = 35
    TUNED_BITS = 0.05        # a memorized example, ~1.4e-3 bits/token
    NOISE_BITS_PER_TOKEN = 1e-3 / math.log(2)   # 1e-3 nats/token

    def test_the_same_per_token_error_is_judged_the_same_at_every_length(self):
        """THE property the fixed floor lacked. 0.05 bits over 35 tokens and
        0.5 bits over 350 tokens are the SAME arithmetic disagreement; the old
        rule passed the first (barely -- it sat exactly on the bound) and failed
        the second tenfold."""
        short_ok, short_msg = pc.compare({"a": 0.10}, {"a": 0.05}, {"a": 35})
        long_ok, long_msg = pc.compare({"a": 1.0}, {"a": 0.5}, {"a": 350})
        self.assertTrue(short_ok, short_msg)
        self.assertTrue(long_ok, long_msg)
        ratio = lambda m: float(m.split("worst example uses ")[1].split()[0])  # noqa: E731
        self.assertAlmostEqual(ratio(short_msg), ratio(long_msg), places=6)
        # ... and a ten-times-worse per-token error fails at BOTH lengths.
        self.assertFalse(pc.compare({"a": 0.55}, {"a": 0.05}, {"a": 35})[0])
        self.assertFalse(pc.compare({"a": 5.5}, {"a": 0.5}, {"a": 350})[0])

    def test_a_long_example_is_not_failed_for_being_long(self):
        """The old fixed 0.05-bit allowance, on a 350-token example carrying
        honest 1e-3 nats/token noise (0.505 bits), was a tenfold false alarm --
        and a check that cries wolf gets loosened by whoever is holding the
        pipeline at 2am."""
        delta = self.NOISE_BITS_PER_TOKEN * 350
        self.assertGreater(delta, 0.05, "this is the gap the old floor rejected")
        ok, msg = pc.compare({"a": 200.0 + delta}, {"a": 200.0}, {"a": 350})
        self.assertTrue(ok, msg)

    def test_a_short_example_no_longer_gets_length_blind_slack(self):
        """The other end of the same defect. On a 3-token example the fixed
        0.05-bit allowance was ~12x the expected noise there (3 x 1.44e-3 =
        0.0043 bits), so a 0.04-bit gap -- 0.013 bits/token, nine times the
        noise floor, which no arithmetic explains -- passed, purely because
        0.04 < 0.05."""
        delta = 0.04
        self.assertLess(delta, 0.05, "the old fixed floor passed exactly this")
        ok, msg = pc.compare({"a": 0.05 + delta}, {"a": 0.05}, {"a": 3})
        self.assertFalse(ok, msg)          # 0.04 > 5e-3 x 3 = 0.015
        self.assertIn("set by the per-token half", msg)

    def test_a_mis_assembled_row_at_the_TUNED_scale_still_fails(self):
        """What the check must keep resolving at the small end: one wrong row is
        a different token's logprob, ~3.55 bits at the base model's own rate,
        against a 0.175-bit allowance for a 35-token example."""
        ok, msg = pc.compare(
            {"a": self.TUNED_BITS + 3.55}, {"a": self.TUNED_BITS}, {"a": self.TOKENS}
        )
        self.assertFalse(ok, msg)
        self.assertGreater(float(msg.split("worst example uses ")[1].split()[0]), 15.0)

    def test_honest_float_noise_at_the_TUNED_scale_passes_with_margin(self):
        """The same bound, from the other side: under the old fixed floor this
        wobble sat exactly ON the bound (0.05 bits allowed, 0.0505 observed), a
        coin flip on every honest run."""
        delta = self.NOISE_BITS_PER_TOKEN * self.TOKENS
        self.assertAlmostEqual(delta, 0.0505, places=4)
        ok, msg = pc.compare(
            {"a": self.TUNED_BITS + delta}, {"a": self.TUNED_BITS}, {"a": self.TOKENS}
        )
        self.assertTrue(ok, msg)
        self.assertLess(float(msg.split("worst example uses ")[1].split()[0]), 0.35)

    def test_at_the_tuned_scale_the_report_says_what_it_can_still_resolve(self):
        """Vacuity at ~0.05 bits is physical, not a choice of constant: the
        arithmetic noise floor IS the signal there. The fix is to say so per
        run, rather than to keep quoting a ratio against a picked floor."""
        ok, msg = pc.compare(
            {"a": self.TUNED_BITS + 0.01}, {"a": self.TUNED_BITS}, {"a": self.TOKENS}
        )
        self.assertTrue(ok, msg)
        self.assertIn("judged by the per-token half", msg)
        self.assertIn("wrong in KIND", msg)

    def test_a_base_scale_example_is_judged_by_the_RELATIVE_half(self):
        """Two-sided: the per-token half must not take over the large end, where
        a proportional bound is the right one and is far tighter (6.15 bits of
        room at 123 bits, against 0.175 per-token)."""
        ok, msg = pc.compare({"a": 123.05}, {"a": 123.0}, {"a": 35})
        self.assertTrue(ok, msg)
        self.assertIn("set by the relative half", msg)
        self.assertNotIn("judged by the per-token half", msg)

    def test_the_per_token_divergence_is_reported_for_calibration(self):
        """The number an operator needs to set --per-token-bits from, in the
        units the flag takes."""
        _, msg = pc.compare({"a": 0.05 + 0.035}, {"a": 0.05}, {"a": 35})
        self.assertIn("max per-token divergence 1.000e-03 bits/token", msg)

    def test_a_row_with_no_token_count_is_refused_not_floored(self):
        """A row that does not say how many tokens its sum is over cannot be
        judged per token. Falling back to a length-blind bound is precisely the
        rule this replaces, so it refuses instead."""
        ok, msg = pc.compare({"a": 1.0}, {"a": 1.0}, {"a": None})
        self.assertFalse(ok)
        self.assertIn("record no token count", msg)
        self.assertFalse(pc.compare({"a": 1.0}, {"a": 1.0}, {"a": 0})[0])

    def test_the_column_decides_which_token_count_is_used(self):
        """`bits` sums the answer, `trainer_bits` adds the trainer's pad step,
        `decision_bits` covers only the decision fields' tokens. Dividing one
        column by another column's token count is a different number."""
        self.assertEqual(pc.COLUMN_TOKEN_FIELD["bits"], "answer_tokens")
        self.assertEqual(pc.COLUMN_TOKEN_FIELD["trainer_bits"], "trainer_tokens")
        self.assertEqual(pc.COLUMN_TOKEN_FIELD["decision_bits"], "decision_tokens")
        with tempfile.TemporaryDirectory() as tmp:
            p = write_rows(
                Path(tmp) / "s.jsonl",
                parity_rows({"a": 2.0}, 7, column="decision_bits",
                            token_field="decision_tokens"),
            )
            self.assertEqual(pc.load(p, "decision_bits").tokens, {"a": 7})

    def test_a_column_that_is_not_a_sum_over_tokens_is_rejected_by_the_parser(self):
        """bits_per_token is already per token; there is nothing for the rule to
        divide by, so --column will not take it."""
        err = io.StringIO()
        stderr, sys.stderr = sys.stderr, err
        try:
            with self.assertRaises(SystemExit):
                pc.main(["a.jsonl", "b.jsonl", "--column", "bits_per_token"])
        finally:
            sys.stderr = stderr

    def test_the_two_files_must_agree_on_the_token_count(self):
        """Same example, same window, different token count = the two runs
        masked it differently. Their sums are not comparable quantities, and the
        per-token bound has no single denominator."""
        chunked = score_file({"a": 1.0}, {"a": 34})
        full = score_file({"a": 1.0}, {"a": 35}, full_forward=True)
        ok, msg = pc.check_token_counts(chunked, full, "bits")
        self.assertFalse(ok)
        self.assertIn("answer_tokens", msg)
        rc, err = run_parity_cli(
            parity_rows({"a": 1.0}, {"a": 34}),
            parity_rows({"a": 1.0}, {"a": 35}, full_forward=True),
        )
        self.assertEqual(rc, 2)
        self.assertIn("REFUSED", err)

    def test_the_per_token_argument_is_written_down_in_the_file(self):
        """The allowance is an argument, not a number someone liked: 5e-3
        bits/token is ~3.5x the 1e-3 nats/token these two float paths are
        expected to disagree by."""
        self.assertAlmostEqual(
            pc.UNCALIBRATED_PER_TOKEN_BITS / (pc.NOISE_NATS_PER_TOKEN / math.log(2)),
            3.466, places=3,
        )
        src = Path(pc.__file__).read_text(encoding="utf-8")
        self.assertIn("nats/token", src)
        self.assertIn("WHAT THIS STILL CANNOT DO", src)


# ---------------------------------------------------------------------------
# 21. a parity pair is two runs that differ in ONE thing
# ---------------------------------------------------------------------------


class TestParityPairFingerprint(unittest.TestCase):
    """parity_check paired two score files by content hash and checked nothing
    about the runs behind them -- not the model, not the window, not the mask,
    not the adapter, not the adapter_digest the previous commit added one file
    over. So it would happily 'prove parity' between two runs that differ in
    ways that guarantee different numbers, or condemn a chunked path that was
    fine. Same class of bug as the pair check in select_curriculum.py, arriving
    from the other direction."""

    def _pair(self, **full_kw):
        return (
            score_file({"a": 1.0}, name="chunked.jsonl"),
            score_file({"a": 1.0}, name="full.jsonl", **{"full_forward": True, **full_kw}),
        )

    def test_a_valid_pair_passes_and_names_what_it_checked(self):
        ok, msg = pc.check_parity_fingerprints(*self._pair())
        self.assertTrue(ok, msg)
        self.assertIn("model='m'", msg)
        self.assertIn("full_forward=True", msg)

    def test_two_runs_under_different_models_are_refused(self):
        ok, msg = pc.check_parity_fingerprints(*self._pair(model="other-model"))
        self.assertFalse(ok)
        self.assertIn("model", msg)
        self.assertIn("different settings", msg)

    def test_two_runs_under_different_windows_or_masks_are_refused(self):
        for kw in ({"max_seq_length": 2048}, {"match_trainer": False}):
            with self.subTest(kw=kw):
                ok, msg = pc.check_parity_fingerprints(*self._pair(**kw))
                self.assertFalse(ok, msg)
                self.assertIn(next(iter(kw)), msg)

    def test_two_runs_under_different_adapters_are_refused(self):
        """One side tuned, the other not, is the difference the CURRICULUM is
        built on -- and it is exactly what must NOT differ here. A base file and
        a tuned file compared for parity would report the whole learned_bits
        column as a divergence of the chunked path."""
        ok, msg = pc.check_parity_fingerprints(
            *self._pair(adapter="/models/tuned", adapter_digest="sha256:" + "ab" * 32)
        )
        self.assertFalse(ok)
        self.assertIn("adapter", msg)

    def test_two_runs_under_different_adapter_CONTENTS_are_refused(self):
        """The case a PATH cannot see, which is why the digest exists: one
        staging directory, two checkpoints, identical `adapter` strings."""
        chunked = score_file({"a": 1.0}, adapter="/staging",
                             adapter_digest="sha256:" + "11" * 32, name="chunked.jsonl")
        full = score_file({"a": 1.0}, adapter="/staging",
                          adapter_digest="sha256:" + "22" * 32,
                          full_forward=True, name="full.jsonl")
        ok, msg = pc.check_parity_fingerprints(chunked, full)
        self.assertFalse(ok)
        self.assertIn("adapter_digest", msg)

    def test_the_SAME_forward_path_twice_is_refused_as_vacuous(self):
        """The empty comparison wearing a full set of rows: given one forward
        path twice, the check agrees perfectly and validates nothing."""
        ok, msg = pc.check_parity_fingerprints(*self._pair(full_forward=False))
        self.assertFalse(ok)
        self.assertIn("SAME forward path", msg)

    def test_two_different_CHUNK_sizes_are_a_valid_pair(self):
        """The one thing they are SUPPOSED to differ in. Different prefill
        boundaries are different matmul shapes and different cache evictions --
        a real parity comparison, even with neither side --full-forward."""
        chunked = score_file({"a": 1.0}, chunk=512, name="c512.jsonl")
        other = score_file({"a": 1.0}, chunk=2048, name="c2048.jsonl")
        ok, msg = pc.check_parity_fingerprints(chunked, other)
        self.assertTrue(ok, msg)

    def test_a_file_with_no_fingerprint_at_all_is_refused(self):
        """Rows that predate the fingerprint carry no evidence of what produced
        them. Refused, not assumed -- the same call select_curriculum makes."""
        bare = pc.ScoreFile(Path("old.jsonl"), {"a": 1.0}, {"a": 35}, [])
        ok, msg = pc.check_parity_fingerprints(bare, score_file({"a": 1.0}, full_forward=True))
        self.assertFalse(ok)
        self.assertIn("records no run fingerprint", msg)

    def test_a_file_holding_two_spliced_runs_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = write_rows(
                Path(tmp) / "spliced.jsonl",
                parity_rows({"a": 1.0}, chunk=512) + parity_rows({"b": 1.0}, chunk=2048),
            )
            spliced = pc.load(p, "bits")
        self.assertEqual(len(spliced.fingerprints), 2)
        ok, msg = pc.check_parity_fingerprints(
            spliced, score_file({"a": 1.0, "b": 1.0}, full_forward=True)
        )
        self.assertFalse(ok)
        self.assertIn("spliced together", msg)

    def test_the_refusal_can_be_waived_loudly(self):
        ok, msg = pc.check_parity_fingerprints(*self._pair(model="other"), allow=True)
        self.assertTrue(ok)
        self.assertIn("WARNING", msg)
        self.assertIn("--allow-fingerprint-mismatch", msg)

    def test_the_cli_refuses_a_mismatched_pair_with_its_own_exit_code(self):
        """Exit 2, distinct from 1: these files are not a parity pair at all, so
        neither 'agreed' nor 'diverged' is the honest answer."""
        rc, err = run_parity_cli(
            parity_rows({"a": 1.0}, max_seq_length=3072),
            parity_rows({"a": 1.0}, max_seq_length=2048, full_forward=True),
        )
        self.assertEqual(rc, 2)
        self.assertIn("not a parity pair", err)
        self.assertIn("max_seq_length", err)
        rc, err = run_parity_cli(
            parity_rows({"a": 1.0}, max_seq_length=3072),
            parity_rows({"a": 1.0}, max_seq_length=2048, full_forward=True),
            ["--allow-fingerprint-mismatch"],
        )
        self.assertEqual(rc, 0)
        self.assertIn("WARNING", err)

    def test_the_fingerprint_is_read_off_the_rows_score_bits_writes(self):
        """The two modules have to agree about what a fingerprint IS. A field
        score_bits stamps that parity_check does not classify is a field nothing
        checks across the pair -- how the adapter came to be unchecked here in
        the first place."""
        self.assertEqual(
            set(pc.PARITY_MUST_AGREE) | set(pc.PARITY_FORWARD_KEYS),
            set(sb.run_fingerprint("m", None, 3072, True, False, 512)),
        )
        self.assertEqual(
            set(pc.PARITY_MUST_AGREE),
            (set(sb.PAIR_FINGERPRINT_KEYS) | set(sb.ADAPTER_FINGERPRINT_KEYS))
            - set(pc.PARITY_FORWARD_KEYS),
            "a parity pair must agree on everything a base/tuned pair does, plus the "
            "adapter -- and differ only in the forward path",
        )


# ---------------------------------------------------------------------------
# 22. a non-finite bits value is a broken forward pass, not a small divergence
# ---------------------------------------------------------------------------


class TestParityRefusesNonFinite(unittest.TestCase):
    """Every comparison against NaN is False, so a NaN never displaced the
    worst-so-far sentinel: the check reported 'max relative divergence
    -1.000e+00' -- a divergence that cannot exist -- and exited 0."""

    def test_a_NaN_is_refused_instead_of_passing_with_a_negative_divergence(self):
        ok, msg = pc.compare({"a": float("nan")}, {"a": 1.0}, {"a": 35})
        self.assertFalse(ok)
        self.assertIn("NON-FINITE", msg)
        self.assertNotIn("-1.000e+00", msg)

    def test_a_NaN_on_either_side_is_caught(self):
        for chunked, full in (
            ({"a": float("nan")}, {"a": 1.0}),
            ({"a": 1.0}, {"a": float("nan")}),
        ):
            with self.subTest(chunked=chunked):
                self.assertFalse(pc.compare(chunked, full, {"a": 35})[0])

    def test_an_infinity_is_refused_too(self):
        ok, msg = pc.compare({"a": float("inf")}, {"a": 1.0}, {"a": 35})
        self.assertFalse(ok)
        self.assertIn("NON-FINITE", msg)

    def test_the_refusal_names_the_rows_and_counts_them(self):
        chunked = {"a": float("nan"), "b": 1.0, "c": float("inf")}
        full = {"a": 1.0, "b": 1.0, "c": 1.0}
        ok, msg = pc.compare(chunked, full, {h: 35 for h in full})
        self.assertFalse(ok)
        self.assertIn("2 of 3 examples", msg)
        self.assertIn("a:", msg)
        self.assertIn("c:", msg)

    def test_the_cli_exits_nonzero_on_a_NaN(self):
        """json.dumps writes bare NaN and json.loads reads it back, so this is
        what an actual broken scoring run leaves on disk."""
        rc, err = run_parity_cli(
            parity_rows({"a": float("nan")}),
            parity_rows({"a": 1.0}, full_forward=True),
        )
        self.assertEqual(rc, 1)
        self.assertIn("NON-FINITE", err)
        self.assertIn("FAILED", err)


# ---------------------------------------------------------------------------
# 23. a zero allowance is a demand for exactness, not a crash
# ---------------------------------------------------------------------------


class TestParityZeroAllowance(unittest.TestCase):
    """`--abs-floor 0` used to divide by max(|full|, 0) and raise an uncaught
    ZeroDivisionError the moment any full-forward example scored exactly 0.0
    bits -- which is what a memorized tuned example rounds to. The floor is gone,
    but the hazard is the same shape: zero both halves of the bound and the
    allowance is zero."""

    def test_a_zero_per_token_half_against_a_zero_bit_example_does_not_crash(self):
        ok, msg = pc.compare({"a": 0.0}, {"a": 0.0}, {"a": 35}, per_token_bits=0.0)
        self.assertTrue(ok, msg)

    def test_both_halves_zero_demands_exactness_rather_than_raising(self):
        self.assertTrue(pc.compare({"a": 5.0}, {"a": 5.0}, {"a": 35}, 0.0, 0.0)[0])
        ok, msg = pc.compare({"a": 5.0 + 1e-12}, {"a": 5.0}, {"a": 35}, 0.0, 0.0)
        self.assertFalse(ok)
        self.assertIn("inf", msg)

    def test_a_zero_bit_example_with_a_real_gap_still_fails(self):
        ok, msg = pc.compare({"a": 3.5}, {"a": 0.0}, {"a": 35}, per_token_bits=0.0)
        self.assertFalse(ok)
        self.assertIn("relative n/a", msg)

    def test_a_negative_bound_is_refused_rather_than_inverted(self):
        for tol, per_token in ((-1e-3, None), (None, -1e-3)):
            with self.subTest(tol=tol, per_token=per_token):
                ok, msg = pc.compare({"a": 1.0}, {"a": 1.0}, {"a": 35}, tol, per_token)
                self.assertFalse(ok)
                self.assertIn("negative bound", msg)

    def test_the_cli_survives_a_zero_bound_on_a_zero_bit_example(self):
        """The exact operator gesture that used to raise: bound the check at
        zero, over a corpus the adapter has memorized to 0.0 bits."""
        rc, err = run_parity_cli(
            parity_rows({"a": 0.0, "b": 0.0}),
            parity_rows({"a": 0.0, "b": 0.0}, full_forward=True),
            ["--tolerance", "0", "--per-token-bits", "0"],
        )
        self.assertEqual(rc, 0, err)
        self.assertIn("over 2 examples", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)

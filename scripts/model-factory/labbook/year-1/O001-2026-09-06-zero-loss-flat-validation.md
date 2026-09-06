---
id: O001
date: 2026-09-06
occurred: 2026-09-05 / 2026-09-06
kind: OBSERVATION
title: Train loss reaches 0.000 while validation sits flat — what that does and does not imply
status: standing
tags: [training, memorization, validation, loss]
sources:
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log:136 (first Train loss 0.000, iter 2675), :147 (iter 2925)"
  - "local-artifact: train.log val lines at :9 :31 :55 :79 :103 :127 :151 :175"
  - scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/tuner/trainer.py:284-286 (first val precedes training)
  - "shasum -a 256 datasets/mlx/valid.jsonl → 23a87bab… (118 lines); train.jsonl → 4aa180a2… (2,245 lines)"
  - d9100b6 — gate_sweep.sh header, which states the same conclusion
related: [E004, H001, H003, P004, O007]
corrects: []
superseded-by: null
---

## What was observed

By iteration **2675** of run 1 (E004), the training loss printed **0.000**.
Validation loss had already been at its floor for **1,675** iterations before
that — the floor is reached at iteration 1000 (0.013 nats) and 2675 − 1000 =
1,675.

| iter | 1 | 500 | 1000 | 1500 | 2000 | 2500 | 3000 | 3500 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| val loss (nats) | 2.463 | 0.074 | 0.013 | 0.028 | 0.005 | 0.013 | 0.009 | 0.012 |
| perplexity | 11.74 | 1.077 | 1.013 | 1.028 | 1.005 | 1.013 | 1.009 | 1.012 |

Validation dropped by a factor of ~190 in the first 1,000 iterations and then
did nothing for the next 2,500. Its range from iteration 1000 onward is
0.005-0.028 nats — 0.007 to 0.040 bits per answer token — which is noise
around "the model is not surprised at all".

Train loss reached exactly 0.000 in **2 of the 151 reports** through iteration
3775 (the snapshot E004 records); 59 of those are ≤0.010. The log was still
growing — the count is only meaningful with the offset (E004).

## What it implies

**The model fits this corpus's distribution completely.** That is a statement
about the corpus, not a criticism of the run:

1. The corpus is programmatically synthesized. All 2,363 rows come from
   `gen_training_data.py` — 65 routing templates over 16 invented domains, plus
   ledger, elicitation and tool-use families — and every label is produced by a
   deterministic function of the input (O007). There is no label noise, no
   annotator disagreement, and **H(label | input) = 0 exactly**: all 2,363
   `(system, user)` pairs are distinct.
2. With zero conditional entropy, a training loss of zero is *attainable in
   principle* and carries no information about whether decision rules were
   learned.
3. The validation split does not fix this. It is a **row-level** hold-out, not
   a template-level one: a `random.Random(17)` shuffle taking 118 of 2,363
   rows. Those 118 rows come from the same template families, the same 16
   domains and one of only 87 distinct system prompts corpus-wide. Nothing in
   validation is out of distribution.
4. Each validation pass covers 25 of the 118 rows (21%), redrawn per pass, so
   the val numbers are also a small sample of an in-distribution set.

**What it does not license is the stronger, contrastive claim** — that the model
memorized the templates *rather than* learning the decision rules. Loss cannot
separate those two (see "The load-bearing consequence" below), so an entry that
asserts one of them is stating an inference, not an observation. The validation
figures are in fact mild evidence *against* row-level memorization: 0.005-0.028
nats on 118 rows the model never trained on. "Memorized rather than learned" is
a hypothesis; it is stated as one, with the measurement that would refute it, in
**H003** — an intermediate checkpoint outscoring the final one on the hard tier
is what would support it, and a flat hard tier across checkpoints is what would
not.

## What it does not imply

- **It does not mean the run is broken.** Loss going to zero on a
  deterministic, template-generated corpus is the expected outcome, not a bug.
- **It does not mean the model will do well on the gate.** Nor badly. The loss
  curve is silent on it in both directions.
- **It does not mean training past iteration 1000 was wasted.** It might have
  been — that is exactly H002's claim — but this observation cannot decide it.
  Only gate scores at several checkpoints can (P004).
- **It does not mean "overfitting" in the usual sense.** Overfitting shows up
  as validation *rising* while training falls. Validation here does not rise;
  it flattens, because it is not measuring anything different from training.

## The load-bearing consequence

Loss cannot distinguish "learned the decision rules" from "memorized the
templates". The eval corpus's adversarial hard tier can. Therefore:

- **gate several checkpoints, not just the last one** (P004, H003);
- **treat the hard tier as the discriminator**, not the overall score;
- **stop reporting loss as evidence of anything** in this factory, except as a
  sanity check that optimization is running at all.

`gate_sweep.sh`'s header (`d9100b6`) reaches the same conclusion independently
and is the repo's own statement of it.

## Correction to the record

`d9100b6`'s header and commit message say the run "reached train loss 0.000 by
iteration ~2900". The log's first `0.000` report is iteration **2675**
(`train.log:136`, verbatim: `Iter 2675: Train loss 0.000, Learning Rate
1.000e-04, It/sec 0.064, Tokens/sec 2.206, Trained Tokens 92738, Peak mem 14.978
GB`), 225 iterations earlier, and only 2 of the 151 reports through iteration
3775 are exactly 0.000. The paraphrase overstates the frequency and understates
the timing. The argument built on it is unaffected.

## Also worth carrying forward

The iteration-1 validation runs **before any gradient step**
(`trainer.py:284-286`), so **2.463 nats = 3.553 bits per answer token is the
untuned base's surprise on this corpus**, measured for free by every run. Any
future run gets a corpus-level `bits_base` in its first log line at no cost.

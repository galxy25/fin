---
id: O004
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: A 160x training-loss excursion in epoch 2, with no per-example log to explain it
status: standing
tags: [training, loss, anomaly, run-1]
sources:
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log — contiguous reports 3400-3775, quoted verbatim below"
  - scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/tuner/trainer.py:110-142 (iterate_batches: sort by length, then permute)
  - scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/lora.py:320 (np.random.seed(args.seed))
  - "local-artifact: adapter_config.json — lr_schedule: null, learning_rate 1e-4"
  - "memory note training-bits-per-example — Levi's directive, written while watching this"
related: [E004, H001, O001]
corrects: []
superseded-by: null
---

## What was observed

After 1,500 iterations below 0.02, run 1's training loss rose by more than two
orders of magnitude and stayed elevated for at least ten consecutive reports.
Verbatim from `train.log` (loss column only; `Peak mem 14.978 GB` on every one
of these lines):

```
3400 0.014   3425 0.002   3450 0.010   3475 0.005   3500 0.006   3525 0.010
3550 0.061   3575 0.037   3600 0.050   3625 0.193   3650 0.183   3675 0.322
3700 0.078   3725 0.129   3750 0.101   3775 0.065
```

From 0.002 at iteration 3425 to **0.322** at 3675 — a **161× increase** —
sustained across six consecutive 25-iteration reports and still elevated 100
iterations later.

Context that rules out the obvious explanations:

- **Not an epoch boundary.** Epoch 2 began at iteration 2246 (4,490 iterations
  over 2,245 rows, one example per iteration — E004). The excursion starts
  ~1,280 examples into epoch 2.
- **Not a checkpoint or validation artifact.** The `0003500` save and the
  iteration-3500 validation both sit *before* the rise, and validation at 3500
  was 0.012 — its normal value.
- **Not a memory event.** Peak memory is flat at 14.978 GB throughout.
- **Not a learning-rate schedule.** `lr_schedule: null`, learning rate constant
  at 1.000e-04 on every report.

## Candidate explanations (none tested)

1. **A high-information cluster of examples.** `iterate_batches` **sorts the
   dataset by length** before cutting batches, then permutes the batch order.
   With batch size 1 the "batches" are single examples, but the sort still
   means the permutation shuffles length-ordered singletons — and a run of long
   tool-use records could land together by chance. Long records have the
   longest answers and the most tokens under gradient.
2. **Genuinely hard or mislabeled examples.** On a synthesized corpus,
   mislabeling is the likelier cause of persistent surprise than difficulty
   (H001) — and a mislabeled example is a bug in `gen_training_data.py`, not a
   hard case.
3. **Late instability at lr 1e-4 with no decay.** Adam with a constant rate
   after 2,245 optimizer steps on a near-zero-loss objective.

## The cheap test that would settle it

**The exact examples are recoverable without retraining.** Batch order is
deterministic: `iterate_batches` sorts by length and permutes with
`np.random.permutation`, called without an explicit `seed=` and therefore
drawing on the global numpy RNG, which `lora.py:320` seeds from
`--seed 17`. Replaying that permutation reproduces the exact sequence of
examples behind iterations 3525-3775 — 250 named rows, no GPU, a few seconds
of CPU.

Once named, the question splits cleanly: are they long, are they one template
family, or are they mislabeled? That is the cheapest available test of H001 and
it needs nothing but the corpus and the seed.

## What this does not show

- **Cause is UNSOURCED.** This run produces no per-example loss, only
  25-iteration means, so nothing in the log distinguishes "one catastrophic
  example every 25" from "all 25 moderately surprising". *Settled by:* a
  per-example loss log, which would require a trainer patch, or by the replay
  above plus a scoring pass (`score_bits.py`, H001).
- **It does not show the excursion harmed the model.** Loss is not the
  arbiter (O001). Whether checkpoints `0003500` and `0003750` differ in gate
  score is exactly what P004's sweep will report, and this excursion makes that
  comparison more interesting, not less.

## Provenance note

This excursion is what prompted Levi's bits-per-example directive on
2026-09-06 (H001). The memory note written at the time describes it as "a
train-loss spike from 0.002 to 0.183 in one 25-iteration window". Both
endpoints are real log values — 0.002 at iteration 3425, 0.183 at 3650 — but
they are **nine reports apart, not one**, and the rise is gradual across
3525-3675. The log is authoritative; the note compresses it. Recorded here as a
correction to that note.

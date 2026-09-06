---
id: O004
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: A late-epoch-2 training-loss excursion, with no per-example log to explain it
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

After a quiet stretch, run 1's training loss rose by more than an order of
magnitude and stayed elevated for at least ten consecutive reports. Verbatim
from `train.log` (loss column only; `Peak mem 14.978 GB` on every one of these
lines):

```
3400 0.014   3425 0.002   3450 0.010   3475 0.005   3500 0.006   3525 0.010
3550 0.061   3575 0.037   3600 0.050   3625 0.193   3650 0.183   3675 0.322
3700 0.078   3725 0.129   3750 0.101   3775 0.065
```

### How long the quiet stretch actually was

The unbroken run of reports below 0.02 immediately before the rise is
**iterations 3025-3525 — 21 reports, about 500 iterations**, not 1,500. Between
iterations 2000 and 3525 nine reports sit at or above 0.02: 2100 (0.029), 2150
(0.021), 2175 (0.025), 2225 (0.044), 2400 (0.022), 2500 (0.049), 2550 (0.025),
2975 (0.021), 3000 (0.028). Two of those — 2500 and 3000 — are printed in
E004's own sampled trajectory table, so the earlier "1,500 iterations below
0.02" contradicted a table in the same commit. A per-500-iteration *mean* stays
under 0.02 from 2001 onward, which is the reading that makes the looser claim
almost true; the per-report series does not.

### The size of the excursion, with its denominator stated

From 0.002 at iteration 3425 to **0.322** at 3675 is a **161× increase**,
sustained across six consecutive 25-iteration reports and still elevated 100
iterations later. That ratio is anchored on the single lowest report in the
whole run, a 25-iteration mean printed to three decimals — so the denominator
carries ±25% before anything else is considered, and a headline built on it is
the same compression this entry criticises the memory note for.

The denominator-independent statements are the ones to carry forward:

| measure | value |
| --- | --- |
| peak report | 0.322 (iteration 3675) |
| run median (151 reports through 3775) | 0.017 |
| peak ÷ median | **19×** |
| lowest report in the run | 0.002 (iteration 3425) |
| peak ÷ lowest | 161× |
| reports ≥ 0.03 in 3550-3775 | **10 of 10** |

19× against the run's own median is the honest headline, and it is still a
plain anomaly.

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

**The exact examples are recoverable without retraining, but the replay is not
one line.** Batch order is deterministic: `iterate_batches` sorts by length and
permutes with `np.random.permutation`, called without an explicit `seed=`
(`trainer.py:275-280`) and therefore drawing on the **global** numpy RNG, which
`lora.py:320` seeds from `--seed 17` at the top of `run()`.

The trap: `evaluate()` calls the same `iterate_batches`, also without `seed=`
(`trainer.py:195-200`), so **every validation pass consumes a permutation draw
from that same global RNG**. Eight validations have run by iteration 3500 (log
lines 9, 31, 55, 79, 103, 127, 151, 175), five of them before the training
generator's second permutation at iteration 2246. Iterations 3525-3775 lie in
that second pass, so seeding `np.random.seed(17)` and drawing only the training
permutations reproduces a *different* example order for exactly the window this
entry cares about. The replay must interleave the validation draws in the order
the trainer makes them.

With that done it is still cheap: 250 named rows, no GPU, a few seconds of
CPU.

Once named, the question splits cleanly: are they long, are they one template
family, or are they mislabeled? That is the cheapest available test of H001 and
it needs nothing but the corpus and the seed.

## What this does not show

- **Cause is UNSOURCED.** This run produces no per-example loss, only
  25-iteration means, so nothing in the log distinguishes "one catastrophic
  example every 25" from "all 25 moderately surprising". That is also why no
  ratio quoted here should be read to more than one significant figure. *Settled by:* a
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

And a correction to this entry's own first draft, which committed the same
class of error twice: it opened with "after 1,500 iterations below 0.02" (the
real stretch is ~500) and headlined a 161× ratio off the run's single lowest
report while criticising the note for compressing those same two endpoints. The
mistake is instructive and is worth keeping legible: a ratio is a claim about
its denominator, and picking the extreme one is how a real anomaly gets
oversold.

**This entry was rewritten in place, and an earlier version of this paragraph
denied it.** That sentence read *"The entry is kept rather than rewritten around
the mistake"*, which `git diff a02cec3 cdb895a --
scripts/model-factory/labbook/year-1/O004-2026-09-06-late-run-loss-excursion.md`
refutes on its face: the title changed from *"A 160x training-loss excursion in
epoch 2…"* to the present one, the opening sentence was rewritten from *"After
1,500 iterations below 0.02, run 1's training loss rose by more than two orders
of magnitude"* to *"After a quiet stretch … more than an order of magnitude"*,
and `INDEX.md`'s row was edited to match. The wrong number was **deleted**, not
struck through; it survives here only as the corrector's paraphrase two
paragraphs up — which is exactly the loss the README's rule
(*"The wrong number staying visible is what makes the correction readable"*)
exists to prevent. The rewrite happened during the book's first-day authoring
pass, when the whole book was still a draft; the general case is recorded in
O008, which also says when the append-only rule starts binding. Claiming the
rule had been followed when it had not is the part that was not defensible, and
it is corrected here rather than removed.

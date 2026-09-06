---
id: H003
date: 2026-09-06
occurred: 2026-09-06
kind: HYPOTHESIS
title: The best checkpoint is not the last one
status: untested
tags: [checkpoints, gate, memorization, promotion]
sources:
  - d9100b6 — gate_sweep.sh:6-10, which states this claim in the repo
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/ — 15 checkpoints at 250-iteration granularity, 27,683,964 B each"
  - "local-artifact: train.log — val loss flat 0.005-0.028 from iteration 1000; first Train loss 0.000 at iteration 2675"
  - evals/tmux-routing/scenarios.json — 25 hard scenarios (parsed today)
related: [O001, P004, E004, H002]
corrects: []
superseded-by: null
---

## The claim

**An intermediate checkpoint of run 1 scores higher on the gate's adversarial
hard tier than the final one, because later checkpoints trade generalization
for template memorization.**

Stated in the repo first, in `gate_sweep.sh:6-10` (`d9100b6`):

> *"the 2026-09-06 run reached train loss 0.000 by iteration ~2900 on
> programmatically synthesized data, so later checkpoints memorize templates
> while the eval corpus's adversarial 'hard' tier is what actually
> discriminates. Loss cannot tell those apart; the gate can."*

## Why it is plausible

- Validation stopped improving at iteration 1000 of 4,490 and training loss hit
  0.000 at 2675 (O001). Everything after that is optimization pressure on a
  distribution the model already fits exactly.
- The corpus has zero conditional entropy (H001), so continued training cannot
  be averaging out label noise — there is none. It can only be sharpening the
  model's commitment to template surface forms.
- The hard tier is, by construction, everything the templates are not:
  paraphrase with zero vocabulary overlap, voice-transcription damage,
  multi-clause misdirection, ordinary words that collide with session names
  (E005 lists the families). A model more strongly committed to template
  surface forms should do worse on exactly those.

## The prediction, in falsifiable form

Let `hard(i)` be the hard-tier score of the checkpoint at iteration `i`.

**H003 predicts `argmax_i hard(i) < 4490`** — and more specifically that
`hard(i)` peaks somewhere in 1000-2500 and declines after, while the *core*
tier stays flat or improves monotonically (core scenarios are close to the
training distribution; hard ones are not).

**Refuted if** the final checkpoint takes the maximum hard score, or if hard
score is flat within noise across all sampled checkpoints.

**Note on statistical power:** the hard tier is 25 scenarios, so one scenario
is 4 percentage points and a difference of 1-2 scenarios is not evidence of
anything. Only a difference of ≥3 hard scenarios between the best and the
final checkpoint should count as support. Nothing here has a variance
estimate (E001's scores are single runs), so treat small differences as noise.

## The experiment

P004's sweep, exactly as written: score checkpoints `1000 2250 3500 final`,
one at a time, against a **re-recorded** champion (O002), fusing and deleting
each in turn. 15 checkpoints exist at 250-iteration granularity if a finer
sweep is warranted after the first pass.

Report the table as core and hard separately. The overall number will hide the
effect if it exists, because core is expected to be flat and would dilute it.

Adding `0003500` and `0003750` explicitly is worth the extra two runs: they
bracket the O004 loss excursion, so the sweep answers a second question for
free — whether the excursion left a mark on behaviour or only on the loss
curve.

## What follows if it holds

The factory's default changes: **promote from a swept checkpoint, never from
the last one**, and record the swept iteration in the model manifest (which
does not yet exist — O005). It would also make `--iters` a much less important
hyperparameter than it looks, and strengthen H002's case that most of run 1's
18 hours bought nothing.

## What follows if it is refuted

Also useful: it would mean 2 epochs on this corpus does not degrade
generalization, and the sweep can be dropped to a cheap two-point check
(midpoint and final) instead of a full pass. Either way the first sweep is
worth its cost.

## What this hypothesis does not address

- **Whether any checkpoint promotes at all.** H003 is about the *shape* of the
  curve, not its level. Every checkpoint could fail core 26/26 and H003 could
  still be true.
- **The serving confound.** All sweep rows are scored through `mlx_lm.server`
  while the champion is scored through LM Studio (P004). That biases every row
  equally, so the *ranking* H003 predicts survives it — but the absolute
  numbers do not transfer to a promotion decision without the re-score on the
  real serving surface.

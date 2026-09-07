---
id: H003
date: 2026-09-06
occurred: 2026-09-06
kind: HYPOTHESIS
title: The best checkpoint is not the last one
status: untested
tags: [checkpoints, gate, memorization, promotion]
sources:
  - d9100b6 — gate_sweep.sh:7-10, which states this claim in the repo (line 6 is a bare `#`)
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/ — 15 checkpoints at 250-iteration granularity, 27,683,964 B each"
  - "local-artifact: train.log — val loss flat 0.005-0.028 from iteration 1000; first Train loss 0.000 at iteration 2675"
  - evals/tmux-routing/scenarios.json — 25 hard scenarios (parsed today)
  - "git merge-base --is-ancestor d9100b6 59b0515 → non-zero, and git cat-file -e 59b0515:scripts/model-factory/gate_sweep.sh → fails; d9100b6 is likewise not an ancestor of 704ab09 or 077d970"
  - "merged from docs/labbook/entries/H002-2026-09-06-best-checkpoint-is-not-last.md (the parallel book, 4705b67) — see the merge note below"
related: [O001, O004, P004, E004, H001, H002]
corrects: []
superseded-by: E009
---

**Merged from two drafts.** Both lab books opened on 2026-09-06 wrote this
hypothesis: `scripts/model-factory/labbook/year-1/H003-2026-09-06-best-checkpoint-not-last.md`
(this entry) and `docs/labbook/entries/H002-2026-09-06-best-checkpoint-is-not-last.md`.
The consolidation (O009) kept this one — it carries the enumeration of what
continued training might be doing, the statistical-power threshold and the
serving confound — and folded the other's overall-score predictions, its
saturation reading of a flat result, its verification that `gate_sweep.sh` is
not on a runnable branch, and its follow-up sweep into the sections below. The
two drafts agreed on the claim and on the ≥3-scenario threshold; neither
contradicted the other on any number.

## The claim

**An intermediate checkpoint of run 1 scores higher on the gate's adversarial
hard tier than the final one, because later checkpoints trade generalization
for template memorization.**

Stated in the repo first, in `gate_sweep.sh:7-10` (`d9100b6`; that script is
on the `imac-site` line of history and is not an ancestor of `704ab09` or
`59b0515` — P004:21-24):

> *"the 2026-09-06 run reached train loss 0.000 by iteration ~2900 on
> programmatically synthesized data, so later checkpoints memorize templates
> while the eval corpus's adversarial 'hard' tier is what actually
> discriminates. Loss cannot tell those apart; the gate can."*

## Why it is plausible

- Validation stopped improving at iteration 1000 of 4,490 and training loss hit
  0.000 at 2675 (O001). Everything after that is optimization pressure on a
  distribution the model already fits exactly.
- The corpus has zero conditional entropy (H001), so continued training cannot
  be averaging out label noise — there is none. **What it is doing instead is
  not established.** An earlier version of this bullet concluded "it can only be
  sharpening the model's commitment to template surface forms", which claims an
  enumeration this entry never made. Ruling out denoising leaves at least four
  live candidates, and nothing here separates them:

  | candidate | why it is not ruled out |
  | --- | --- |
  | sharpening commitment to template surface forms | the mechanism this hypothesis assumes; it predicts the hard-tier decline below |
  | almost nothing measurable | 59 of the 162 reports in `train.log` are ≤0.010 and two are exactly 0.000; near-zero gradients move near-zero weight |
  | drift in the 6.9M LoRA parameters uncorrelated with surface form | no per-parameter or per-example logging exists for this run (O005) |
  | changes in calibration or format confidence rather than in the decision | the gate scores exact-match decisions and would not see this at all |

  Sharpening is the mechanism this hypothesis *rests on*, so it is stated as an
  assumption, not deduced. If the prediction below holds, that is evidence for
  it; if hard score is flat, the second row is the likeliest explanation and
  this hypothesis is not merely unsupported but pointing at the wrong quantity.
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

### The overall-score form of the same prediction

The merged draft stated it on the 51-scenario total rather than per tier, and
both forms are worth having because they fail differently:

1. **Overall score is non-monotonic in iteration**, peaking at or before 2,250.
2. The spread between the best and the final checkpoint is **≥3 scenarios of
   51** — large enough that checkpoint selection matters more than any
   hyperparameter in this run.
3. The variation is concentrated in the **hard** tier; **core** moves by at most
   one scenario across all four checkpoints.

The per-tier form above is the sharper test, because core is expected to be flat
and dilutes the effect in any overall number. The overall form is the one a
sweep prints without extra work, so it is the one that will be looked at first;
if it is flat while the hard column is not, believe the hard column.

**What a flat result would mean, stated before the fact.** If overall is flat
across all four checkpoints — spread ≤1 — the hypothesis is wrong, and the
useful conclusion is not "checkpoint choice does not matter" but *this corpus
saturates the adapter before iteration 1,000*: the run should have been a tenth
as long, and the next one should be. That is H002's claim arriving by a
different road, which is why a refutation here is nearly as valuable as a
confirmation.

## The experiment

P004's sweep, exactly as written: score checkpoints `1000 2250 3500 final`,
one at a time, against a **re-recorded** champion (O002), fusing and deleting
each in turn. 15 checkpoints exist at 250-iteration granularity if a finer
sweep is warranted after the first pass.

```sh
# on a checkout of imac-site — see below; after the fine-tune ends,
# with LM Studio serving the champion on :1234
scripts/model-factory/gate_sweep.sh 1000 2250 3500 final
```

**The script cannot be run from this branch, and that is two problems, not
one.** `git merge-base --is-ancestor d9100b6 59b0515` exits non-zero and
`git cat-file -e 59b0515:scripts/model-factory/gate_sweep.sh` fails — so every
`gate_sweep.sh` line number in this entry and in P004 is against the 115-line
blob `9a8b9fcc…` at `d9100b6`, and the command above needs a checkout that has
it. (`077d970` does have a `scripts/model-factory/gate_sweep.sh`, but it is a
different 140-line script, blob `c0c2f72e…` from `919cfcb`; these line numbers
do not address it — see O002.) Separately, `models/gate-sweep/` does not exist on disk: **the sweep
has never been run.** Landing the script somewhere it can run from is a
precondition of testing this hypothesis at all.

**The follow-up worth planning now.** The default sweep skips the 250-750 and
2,500-3,250 checkpoints. If the peak lands at 1,000, the interesting second pass
is 250/500/750 — because the earliest checkpoint that clears the gate is also
the cheapest model to retrain, and finding where the curve turns is worth more
than knowing that it does.

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

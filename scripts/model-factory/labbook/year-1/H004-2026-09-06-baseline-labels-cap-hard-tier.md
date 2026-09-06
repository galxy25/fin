---
id: H004
date: 2026-09-06
occurred: 2026-09-06
kind: HYPOTHESIS
title: Distilling the deterministic baseline will pull the hard tier down toward it
status: untested
tags: [distillation, labels, hard-tier, gate]
sources:
  - "O007: 1,659 of 2,363 labels are router_baseline / policy_baseline output (gen_training_data.py:276-285, :540-552)"
  - "E005 (measured today): router_baseline 29/51, core 26/26, hard 3/25"
  - evals/tmux-routing/RESULTS.md:27 — google/gemma-4-e4b, round-3 prompt, 49/51, core 25/26, hard 24/25
  - "local-artifact: train.log — 2 epochs over those labels, loss to 0.000"
related: [O007, E005, E001, P004, H003]
corrects: []
superseded-by: null
---

## The claim

**Fine-tuning on baseline-generated labels will move the candidate's hard-tier
score away from the base model's 24/25 and toward the baseline's 3/25 — and the
size of that move is the most informative number the first gate sweep will
produce.**

## The setup, stated once

| policy | overall | core | hard | role |
| --- | --- | --- | --- | --- |
| `router_baseline.py` | 29/51 | 26/26 | **3/25** | the **labeler** of 890 routing training examples (O007) |
| `google/gemma-4-e4b`, round-3 prompt | 49/51 | 25/26 | **24/25** | the **base being tuned**, and the champion |

The candidate is the second model, trained for two epochs to a loss of zero on
the first model's answers, and then scored on a corpus where the two differ by
21 hard scenarios.

The training system prompt is the round-3 prompt — the one that makes the base
score 24/25 on hard. So the corpus pairs *the strong policy's framing* with
*the weak policy's answers*, on inputs drawn from a vocabulary disjoint from
the eval's (P002).

## Three outcomes, and what each would mean

**B is the refutation.** If the hard tier holds within noise of the base's
24/25, the claim that distilling a 3/25 labeler pulls the candidate toward it is
false and should be marked `refuted`. Noise here is not small: the hard tier is
25 scenarios, one scenario is 4 points, and every score in this book is a single
un-repeated run, so **a drop of ≤2 hard scenarios counts as B, not as A** — the
same threshold H003 sets for itself.

| outcome | hard tier | reading |
| --- | --- | --- |
| **A — distillation dominates** | falls ≥3 scenarios below 24/25 | the fine-tune taught the model to be the baseline. The corpus is the problem, not the recipe. |
| **B — format-only transfer** *(the refutation)* | holds within 2 scenarios of 24/25 | the base's own reasoning survives; the fine-tune moved output format and easy-case reliability without displacing judgment. The corpus is harmless but weak, and **this hypothesis is wrong**. |
| **C — improvement** | above 24/25 | something is teaching judgment the labels do not contain. **Look for a confound first**: the stale champion (O002), a prompt change between training and scoring (O003), or a serving difference (P004). |

The interesting result is not which of A/B/C happens, it is *how far*. That
number tells the factory how much a corpus's label quality actually propagates
into behaviour, which is the single most useful calibration it can get before
building corpus 2.

## Why the answer is not obvious

Arguments for A: 4,490 iterations — **2,245 optimizer steps at an effective
batch of 2**, since `--grad-accumulation-steps 2` gates the update rather than
the iteration (E004 reads this off the installed trainer; an earlier draft of
this entry said "4,490 gradient steps") — loss to zero, 890 examples of one
routing policy, and a LoRA at rank 8 over 16 layers touching 6.9M parameters.
Two full passes over every row is enough capacity to shift routing behaviour.

Arguments for B: only **1.81% of the corpus's message characters** are unmasked
— the labels, 272,847 of 15,070,991 — and the system prompt (89.6%) is masked
and identical to the one under which the base already performs at 24/25. (As
fractions of the file's 16,142,664 bytes those are 1.69% and 83.7%; the byte
denominator also counts JSON syntax, so the character figures are the ones that
describe what the model sees.) The examples the baseline gets right
are the *easy* ones, and every training input is vocabulary-disjoint from the
eval scenarios, so the model may never be pushed to contradict its own
judgment on a hard-tier-shaped input. A LoRA of 0.093% of parameters may be
learning "emit this JSON shape" more than "decide this way".

## The experiment

It is already scheduled and needs no new work: **P004's sweep closes this**,
provided the results are read per tier. Requirements:

1. Re-record the champion under the current prompt first (O002) — otherwise
   outcome C is unfalsifiable, since the stale 36/51 bar has hard 15/25 and any
   candidate above it looks like an improvement.
2. Report **core and hard separately** for every checkpoint. The overall number
   averages the two effects this hypothesis is about and will hide them.
3. Report the untuned base under identical conditions as a row in the same
   table — same server, same prompt, same day. Without it, the comparison is to
   a number from 2026-09-05.

## The design change that follows if A holds

Stop labeling with the deterministic baselines. The alternatives, from O007:
model labels with human review; real telemetry through `raw/trajectories/`
(the ingest path is deployed and unused); and above all **examples where a
human overruled the policy**, which is the only category that adds information
the generator does not already contain (H001).

## What this hypothesis does not claim

- It says nothing about the ledger half of the corpus, because nothing scores
  it (O006). The same argument applies there with `policy_baseline` at 3/14 on
  hard, and there will be no measurement of it.
- It does not predict a core-tier regression. The baseline is 26/26 on core;
  training on its answers should if anything *help* there, and might even fix
  c01 — the base's one core miss (E001) — since the baseline gets c01 right.
  A candidate at core 26/26 with a collapsed hard tier would be the sharpest
  possible confirmation of A, and would also **pass the gate's core condition**
  while being a worse router.

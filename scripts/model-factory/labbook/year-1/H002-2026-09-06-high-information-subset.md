---
id: H002
date: 2026-09-06
occurred: 2026-09-06
kind: HYPOTHESIS
title: A small high-information subset reaches the same gate score in materially fewer iterations
status: untested
tags: [curriculum, bits, cost, training]
sources:
  - "H001's corpus measurements: xz -9e = 196 bits/example; generator source = 172 bits/example; H(Y) = 8.585 bits/example"
  - "local-artifact: train.log — val loss 0.013 nats at iteration 1000, never meaningfully lower through 3500"
  - "local-artifact: checkpoint mtimes — 60.4 min per 250 iterations, mean over 14 intervals"
  - "memory note training-bits-per-example — 'Standing goal: fewest iterations for equal gate score'"
related: [H001, H003, O001, E004, P004]
corrects: []
superseded-by: null
---

## The claim

**A subset of the corpus selected by information content reaches the same
`eval_gate.py` score as the full corpus, in materially fewer iterations.**

"Materially" is stated up front so the hypothesis can fail: **≥40% fewer
iterations for a gate score within 1 scenario of the full-corpus run's.**

Levi's standing goal behind it: *"fewest iterations for equal gate score"* —
report each factory run as gate-score-per-iteration, so a curriculum change is
judged on cost as well as quality.

## Why it is plausible here

Three separate lines of evidence, all already measured:

1. **The corpus's information is bounded by its generator.** `xz -9e` puts the
   whole 16 MB corpus at ~58 KB, and `gen_training_data.py`'s own source is
   50,743 bytes — two estimators agreeing within 14% (H001). More rows from
   the same generator add approximately zero bits.
2. **Validation stopped improving at iteration 1000 of 4,490.** 0.013 nats at
   1000, and nothing meaningfully lower through 3500 (O001). Whatever the run
   was going to learn from this distribution, it had learned by then.
3. **Zero conditional entropy.** With H(label | input) = 0 there is nothing to
   average over; repetition of an already-learned pattern is pure cost.

## What it would buy, in this run's units

At the measured pace of **60.4 minutes per 250 iterations** (mean over 14
checkpoint intervals):

| iterations | wall clock | fraction of run 1 |
| --- | --- | --- |
| 4,490 (run 1, 2 epochs) | ≈18.2 h | 100% |
| 2,245 (1 epoch) | ≈9.0 h | 50% |
| 1,000 | ≈4.0 h | 22% |

If the hypothesis holds at 1,000 iterations, an experiment cycle drops from a
day to an afternoon — which changes what the factory can do far more than any
single score does. That is the real payoff, and it is the reason to test this
before chasing points.

## The experiment, with its control

Three runs, identical in every respect but the training set, gated identically:

| arm | training set | iterations |
| --- | --- | --- |
| **A — full (already have it)** | all 2,245 rows | 4,490 (run 1, E004) |
| **B — selected** | the top-`k` rows by `learned_bits` (H001), k ≈ 500-800 | 2 epochs over `k` |
| **C — the control: random** | `k` rows chosen uniformly at random, **same k, same seed discipline** | same iteration count as B |

**C is the entire experiment.** Without it, B beating a truncated A shows only
that fewer iterations were enough — not that *selection* did anything. The
hypothesis is confirmed only if **B > C on the gate**, at equal k and equal
iterations. If B ≈ C, the honest finding is "this corpus needs fewer
iterations", which is worth knowing and is not a curriculum result.

A fourth arm worth running if the first three are cheap: **D — anti-selected**,
the *bottom* k by `learned_bits`. If D also matches A, the corpus carries even
less information than H001 estimates.

Everything else held fixed: base model, LoRA rank/scale/layers, learning rate,
seed 17, sequence length, the memory contract (P003), and the gate's champion
record (which must be re-recorded first — O002).

Report the result as **gate score per iteration**, not gate score.

## What would refute it

- B within 1 scenario of C at the same k → selection adds nothing; only the
  iteration count mattered.
- B materially below A → the discarded rows were carrying something the bits
  measure did not see.
- B's core tier below 26/26 while A's is at 26/26 → selection dropped a
  gate-critical behaviour. This is the failure mode to watch: the core tier has
  narrow classes (`refuse` has 4 scenarios) and a bits-ranked subset could
  starve one.

## Constraints on running it

- **Serialized GPU work.** Each arm is a training run plus a gate sweep and
  nothing else may touch the GPU (P003). Three arms at even 1,000 iterations
  is most of a day.
- **Scoring is itself GPU work.** `score_bits.py` must run after run 1 finishes
  and before any new training starts.
- **The stale champion must be fixed first** (O002), or every arm is scored
  against a number that flatters all of them equally — which preserves the
  *ranking* but makes the reported scores meaningless.

## The ceiling this cannot break

Selection over this corpus cannot raise the hard tier above what the corpus's
labels contain, and those labels come from a policy scoring 3/25 on hard
(O007). H002 is about **cost**, not capability. If a curriculum experiment
reports a higher gate score, look for a confound before believing it.

# H002 — The best checkpoint is not the final one

- **Kind:** HYPOTHESIS
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## The claim

Among the checkpoints of `fin-foreman-e4b-mlx`, the one that scores highest
on `evals/tmux-routing` is an **early** one — around iteration 1,000–2,250 —
not `adapters.safetensors` (the final weights). Selecting the last checkpoint
because it is last would ship a worse model than the run produced.

## Why

Three independent reasons, each with an artifact.

1. **Loss stopped informing the choice at iteration 1,000.** Validation loss
   was 0.013 at iteration 1,000 and has oscillated in [0.005, 0.028] for the
   2,500 iterations since ([O002](O002-2026-09-06-validation-split-in-distribution.md),
   from `train.log`). There is no signal left in it to prefer iteration 3,500
   over iteration 1,000 — and since the validation split is in-distribution,
   there never was a signal about generalization in it at all.

2. **Continued training on a memorizable corpus is continued memorization.**
   The corpus has zero conditional entropy and ~180 bits/example of
   description length against 6.9M trainable parameters
   ([E004](E004-2026-09-06-bits-per-example.md)). Past the point where the
   templates are fit, further iterations sharpen template-matching, which is
   the behavior the adversarial tier is specifically built to punish.

3. **The tail of the run is unstable.** Training loss rose from a ~0.008 floor
   to 0.193 / 0.183 / 0.322 at iterations 3,625–3,675
   ([O002](O002-2026-09-06-validation-split-in-distribution.md)). Whatever the
   cause, the final weights are being written out of a disturbed region of the
   curve rather than a settled one.

This is already the operating assumption of `gate_sweep.sh` (its header,
lines 7-10: "the LAST checkpoint is not automatically the best one … Loss
cannot tell those apart; the gate can"). This entry states it as a
falsifiable prediction with a shape, so the sweep either confirms it or does
not.

## Prediction, stated so it can be wrong

Scoring checkpoints 1,000 / 2,250 / 3,500 / final:

1. **Overall score is non-monotonic in iteration**, peaking at or before
   2,250.
2. The spread between best and final checkpoint is **≥ 3 scenarios** out of
   51 — large enough that checkpoint selection matters more than any
   hyperparameter in this run.
3. The variation is concentrated in the **hard** tier; **core** moves by at
   most one scenario across all four checkpoints.

If overall turns out flat across all four checkpoints (spread ≤ 1), the
hypothesis is wrong, and the useful conclusion is that this corpus saturates
the adapter before iteration 1,000 — which would mean the run should have
been a tenth as long, and the next one should be.

## The test

```sh
# after the fine-tune ends, LM Studio serving the champion on :1234
scripts/model-factory/gate_sweep.sh 1000 2250 3500 final
```

It stages, fuses, serves and scores each checkpoint one at a time, deleting
each ~5 GB fused model afterwards, and writes `models/gate-sweep/results.tsv`.
That directory does not exist yet — **the sweep has never been run**.

Note the sweep skips iteration 250–750 and 2,500–3,250 checkpoints by
default. If prediction 1 holds with a peak at 1,000, the interesting
follow-up is a second sweep at 250/500/750 to find where the curve actually
turns — the earliest checkpoint that clears the gate is also the cheapest
model to retrain.

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

2. **Continued training on a memorizable corpus has nothing left to average
   out.** The corpus has zero conditional entropy and 196-290 bits/example of
   description length — 196 by `xz -9e`, 290 by the six-file generating program
   — against 6.9M trainable parameters
   ([E004](E004-2026-09-06-bits-per-example.md)). (An earlier draft of this
   line said "~180 bits/example", a figure E004 withdrew; see E004's section 3.)
   Zero label noise means further iterations cannot be denoising the labels,
   because there is no label noise to denoise. What they *are* doing is not
   established here: sharpening template-matching is the mechanism this entry
   assumes, and it is an assumption, not a measurement — the sweep below is
   what would test it.

3. **The tail of the run is unstable.** Training loss rose from a ~0.008 floor
   to 0.193 / 0.183 / 0.322 at iterations 3,625–3,675
   ([O002](O002-2026-09-06-validation-split-in-distribution.md)). Whatever the
   cause, the final weights are being written out of a disturbed region of the
   curve rather than a settled one.

This is already the operating assumption of `gate_sweep.sh` (its header,
lines 7-10 at `d9100b6`: "the LAST checkpoint is not automatically the best
one … Loss cannot tell those apart; the gate can"). **That script is not on
this branch.** `git branch --contains d9100b6` returns `imac-site` only, and
`git cat-file -e labbook:scripts/model-factory/gate_sweep.sh` fails with "does
not exist in 'labbook'" — so every `gate_sweep.sh` line number in this entry is
against `d9100b6` on `imac-site`, and the command below cannot be run from a
`labbook` or `main` checkout. This entry states the claim as a falsifiable
prediction with a shape, so the sweep — once the script is on a branch where
it can run — either confirms it or does not.

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
# on a checkout of imac-site (see above — the script is not on main or labbook),
# after the fine-tune ends, LM Studio serving the champion on :1234
scripts/model-factory/gate_sweep.sh 1000 2250 3500 final
```

It stages, fuses, serves and scores each checkpoint one at a time, deleting
each ~5 GB fused model afterwards, and writes `models/gate-sweep/results.tsv`.
Two things are missing, not one: the script is absent from this branch, and
`models/gate-sweep/` does not exist on disk — **the sweep has never been
run**.

Note the sweep skips iteration 250–750 and 2,500–3,250 checkpoints by
default. If prediction 1 holds with a peak at 1,000, the interesting
follow-up is a second sweep at 250/500/750 to find where the curve actually
turns — the earliest checkpoint that clears the gate is also the cheapest
model to retrain.

# O002 — The validation split is in-distribution; the loss curve measures memorization

- **Kind:** OBSERVATION
- **Date:** 2026-09-06
- **Corrections:** corrects a figure in `d9100b6`'s commit message (below)
- **Superseded-by:** —

## What was noticed

`datasets/mlx/valid.jsonl` is 118 rows drawn by a seeded shuffle from the same
2,363-row corpus ([E003](E003-2026-09-06-mlx-split-recovery.md)). It is held
out at the *row* level and not at the *template* level: every validation row
comes from the same 65 routing templates, 16 domains, 44 elicit/tool-use
templates and 16 flavors as the training rows, and shares one of only **87
distinct system prompts** across the whole corpus.

So validation loss here answers "did the model memorize these particular
2,245 rows, or the templates behind them?" — and both answers score the same.
It cannot answer "did the model learn the decision rules?"

## The curve

From `models/candidates/fin-foreman-e4b-mlx/train.log` (run started
2026-09-05 20:15:29, pid 18405, still running at the time of writing —
last report `Iter 3700` of 4490):

| iteration | val loss |
| ---: | ---: |
| 1 | 2.463 |
| 500 | 0.074 |
| 1,000 | **0.013** |
| 1,500 | 0.028 |
| 2,000 | 0.005 |
| 2,500 | 0.013 |
| 3,000 | 0.009 |
| 3,500 | 0.012 |

Validation loss reached 0.013 at iteration 1,000 and has oscillated in
[0.005, 0.028] for the 2,500 iterations since — it is noise around a floor,
not a trend. Training loss, by 25-iteration report, mean per window:

| window | mean | min | max |
| --- | ---: | ---: | ---: |
| 1–500 | 0.2381 | 0.041 | 0.970 |
| 501–1,000 | 0.0467 | 0.020 | 0.124 |
| 1,001–1,500 | 0.0169 | 0.004 | 0.035 |
| 1,501–2,000 | 0.0114 | 0.002 | 0.034 |
| 2,001–2,500 | 0.0160 | 0.002 | 0.049 |
| 2,501–3,000 | 0.0074 | 0.000 | 0.028 |
| 3,001–3,500 | 0.0080 | 0.002 | 0.016 |
| 3,501–3,700 | **0.1168** | 0.010 | 0.322 |

Both curves are consistent with [E004](E004-2026-09-06-bits-per-example.md):
a corpus with zero conditional entropy has an attainable loss of zero, and 6.9M
LoRA parameters over ~50 KB of generator description length is a wide margin.

## Two things worth flagging

**A late-run rise.** The last eight reports break the pattern: iteration 3,550
= 0.061, then 3,625 = 0.193, 3,650 = 0.183, 3,675 = 0.322, 3,700 = 0.078 —
after 1,500 iterations spent below 0.02. The run is at 82% of 4,490 iterations
and epoch 2 of 2 (E004 establishes one example per iteration, so the second
epoch began at iteration 2,246; the rise is not an epoch boundary). Cause
**UNSOURCED**. Candidates: a run of long tool-use examples, a data-order
effect from `mlx_lm`'s per-epoch shuffle, or genuine late instability at lr
1e-4 with no schedule (`"lr_schedule": null`, `adapter_config.json`). The
artifact that would settle it: per-example loss logging, which this run does
not produce. It is a live reason to gate intermediate checkpoints rather than
the final one — [H002](H002-2026-09-06-best-checkpoint-is-not-last.md).

**A correction.** Commit `d9100b6` ("Model factory: gate several checkpoints,
not just the last one") states the run "reached train loss 0.000 by iteration
~2900". The log says otherwise: the first report of exactly `0.000` is at
**iteration 2,675**, and only **2 of 148** reports are exactly 0.000. The
substance of that commit's argument is unaffected — 59 of 148 reports are
≤0.010, 42 of them after iteration 2,000 — but "reached 0.000" reads as
"converged to zero" and the log does not support that. Verify with:

```sh
L=models/candidates/fin-foreman-e4b-mlx/train.log
grep -o "Iter [0-9]*: Train loss [0-9.]*" "$L" | grep "0\.000"
```

---
id: E004
date: 2026-09-06
occurred: 2026-09-05 20:15:29 — in flight
kind: EXPERIMENT
title: Run 1 — fin-foreman-e4b-mlx, a 2-epoch LoRA on gemma-4 E4B (CLOSED by E009)
status: closed
tags: [training, mlx, lora, run-1]
sources:
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/launch-train.sh (the exact argv)"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log:1 — '=== TRAIN START 2026-09-05 20:15:29 pid 18405 base=mlx-community/gemma-4-E4B-it-qat-4bit ==='"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/adapter_config.json (written by mlx-lm at launch)"
  - "scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/tuner/trainer.py:110-142, :195-200, :247-262, :273-282 (the training loop — `for it, batch in zip(` at 273, the closing `):` at 282), :284-286"
  - "shasum -a 256 datasets/mlx/train.jsonl → 4aa180a204d61e2f87f0ddcbfab70fb50067452d071751294079701c03c00adb (2,245 lines)"
  - 8aa690c — the corpus commit (2026-09-05 19:26)
related: [E003, O001, O004, P004, H003]
corrects: []
superseded-by: E009
---

## Closed 2026-09-06 by E009

**Appended 2026-09-06, after the run finished and was gated.** This is the one
edit the README's append-only rule permits to a published entry beyond the
`superseded-by:` back-pointer: *"a status change is itself an append ... except
on an `open` EXPERIMENT, whose closure is the one case where the original entry
is the right place for the result."* Two front-matter fields changed with it —
`status: open` → `closed`, and the title's `(OPEN)` marker → `(CLOSED by E009)`.
Nothing below this block was altered; the section that follows still reads
"Status: OPEN" because that is what it said while the run was going, and E004 is
the record of the run rather than of the result.

The run ended **2026-09-06 14:28:36** — 18 h 13 m 07 s, 14.607 s/iteration,
against the 14:25:17-14:25:58 this entry projected from checkpoint mtimes. Final
validation loss **0.003** at iteration 4490 (`train.log:223`, a 225-line file).

**The gate sweep it named as its closing event ran 14:38-14:48 and promoted
nothing:** 43, 44, 42, 45 of 51 for checkpoints 1000, 2250, 3500 and 4490
against a champion re-recorded at 49/51. The result, the method, the verdict and
what none of it shows are in **E009**.

---

## Status: OPEN

The run is still going as this is written (iteration 3775 of 4490 at 11:29
PDT, 2026-09-06). **This entry is closed by the first gate sweep (P004)**, which
scores several checkpoints and produces the only number that matters — a gate
score. Until then the trajectory below is a record of the run, not a result.

## Question

Does a LoRA fine-tune of the served Gemma family on 2,245 synthesized
foreman-decision examples beat the untuned base on `evals/tmux-routing`?

## Method

Launched detached at **2026-09-05 20:15:29 PDT**, pid 18405, via
`models/candidates/fin-foreman-e4b-mlx/launch-train.sh`:

```sh
exec caffeinate -i scripts/model-factory/.venv/bin/python -m mlx_lm lora \
  --model mlx-community/gemma-4-E4B-it-qat-4bit \
  --train --data datasets/mlx \
  --fine-tune-type lora --num-layers 16 \
  --batch-size 1 --grad-accumulation-steps 2 --grad-checkpoint --mask-prompt \
  --max-seq-length 3072 \
  --iters 4490 --learning-rate 1e-4 --seed 17 \
  --steps-per-report 25 --steps-per-eval 500 --val-batches 25 --save-every 250 \
  --adapter-path "$OUT" >> "$OUT/train.log" 2>&1
```

| parameter | value | source |
| --- | --- | --- |
| base | `mlx-community/gemma-4-E4B-it-qat-4bit`, snapshot `0f35c6f6…`, 6.4 GB | E002 |
| toolchain | python 3.11, **mlx-lm 0.31.3**, **mlx 0.32.2** in `scripts/model-factory/.venv` | dist-info dirs |
| LoRA | rank 8, scale 20.0, dropout 0.0, `num_layers` 16, optimizer adam, `lr_schedule: null` | `adapter_config.json` |
| trainable | **0.093% — 6.914M / 7,463.013M** | `train.log:6` |
| corpus | `datasets/mlx/train.jsonl` 2,245 lines / `valid.jsonl` 118 lines | measured; hashes in front matter |
| memory contract | grad-checkpoint, batch 1, accum 2, seq 3072 | P003 |

### What the flags actually mean (read from the installed trainer, not assumed)

- **1 iteration = 1 batch = 1 example.** `trainer.py:273-282` zips
  `range(1, args.iters+1)` with `iterate_batches(..., batch_size=1)`. So
  **4490 iterations over 2,245 rows is exactly 2.00 epochs**, and epoch 2
  begins at iteration 2246.
- **`--grad-accumulation-steps 2` does not change the iteration count.** It
  gates `optimizer.update` behind `do_update = it % grad_accum_steps == 0` and
  divides the summed gradient by 2 (`trainer.py:247-262`). The run therefore
  performs **2,245 optimizer steps at an effective batch of 2** — not 4,490
  steps, and not 4 epochs.
- **Batch order is deterministic, but replaying it is not one line.**
  `iterate_batches` sorts the dataset by length, cuts fixed batches, then
  permutes per pass with `np.random.permutation`. It is called without `seed=`,
  so it draws on the **global** numpy RNG, which `lora.py:320` seeds from
  `--seed 17`. The run is therefore reproducible — but *only if the replay
  consumes the same draws in the same order*. `evaluate()` calls the same
  `iterate_batches` with no `seed=` (`trainer.py:195-200`), so **every
  validation pass consumes a permutation draw from that same global RNG**. Eight
  validations have run by iteration 3500, five of them before the training
  generator's second pass begins at iteration 2246. A replay that seeds
  `np.random.seed(17)` and draws only the training permutations produces a
  *different* example order for anything in epoch 2 — which is exactly the
  window O004 wants. The correct replay interleaves the validation draws.
- **`Trained Tokens` counts unmasked answer tokens only.** 129,814 tokens over
  3,750 iterations = **34.6 answer tokens per example**, consistent with the
  measured assistant labels (median 117 characters) and inconsistent with two
  examples per iteration.

## Trajectory so far

Training loss, sampled every 10th report from `train.log`:

| iter | 25 | 250 | 500 | 750 | 1000 | 1250 | 1500 | 1750 | 2000 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| train loss | 0.970 | 0.131 | 0.056 | 0.053 | 0.024 | 0.019 | 0.017 | 0.005 | 0.004 |

| iter | 2250 | 2500 | 2750 | 3000 | 3250 | 3500 | 3750 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| train loss | 0.012 | 0.049 | 0.004 | 0.028 | 0.007 | 0.006 | 0.101 |

Across the **151** reports at that snapshot — one every 25 iterations, 25
through 3775 — min **0.000**, max 0.970, median **0.017**; exactly **two**
reports at 0.000 (iterations 2675 and 2925); **59** reports ≤0.010, the first at
iteration 1050.

The count is part of the number. `train.log` was still being written: at
`wc -l` = 194 it held 156 reports through iteration 3900 and the median is still
0.017, while at 148 reports (iteration 3700) it is 0.016. Any figure quoted off
this file carries the offset it was read at, here and in E003 and O001.

Validation — every `Val loss` line in the log, with the nats→bits conversion
(bits = nats × 1.4427):

| iter | val loss (nats) | bits/answer-token | perplexity | val took | log line |
| --- | --- | --- | --- | --- | --- |
| 1 | **2.463** | 3.553 | 11.74 | 192.899 s | 9 |
| 500 | 0.074 | 0.107 | 1.077 | 190.002 s | 31 |
| 1000 | 0.013 | 0.019 | 1.013 | 168.721 s | 55 |
| 1500 | 0.028 | 0.040 | 1.028 | 162.412 s | 79 |
| 2000 | 0.005 | 0.007 | 1.005 | 179.361 s | 103 |
| 2500 | 0.013 | 0.019 | 1.013 | 166.148 s | 127 |
| 3000 | 0.009 | 0.013 | 1.009 | 163.695 s | 151 |
| 3500 | 0.012 | 0.017 | 1.012 | 149.742 s | 175 |

Two properties of that first row make it usable as a baseline, both read from
the installed trainer: **the first validation runs before any gradient step**
(`trainer.py:284-286`, "the first validation loss is always measured before any
training"), and each pass covers **25 of the 118 valid rows (21%)**, redrawn
from the permuted batch order. So **2.463 nats = 3.553 bits per answer token is
the untuned base's surprise on a 25-row draw from the 118-row validation
split**, measured for free.

State the denominator every time this number is used, because it is small: one
validation pass is ~25 rows and ~870 answer tokens, not the corpus and not even
the whole split, and each pass is a *different* draw (`trainer.py:195-200` calls
`iterate_batches` with no `seed=`). H001 uses this figure as its `bits_base`
starting point; that is a legitimate use, but "corpus-level" is the wrong word
for it and an earlier version of this paragraph used it. There is no variance
estimate — one pass, one draw, never repeated — so the right reading is "the
base model's surprise is a few bits per answer token", not "3.553".

### Cost and pace

| quantity | value |
| --- | --- |
| checkpoints on disk | 15 (`0000250`…`0003750`) + rolling `adapters.safetensors`, **27,683,964 B each** |
| adapter dtype | 27,683,964 B ÷ 6.914M params ≈ **4.00 bytes/param → fp32** |
| mean wall clock per 250 iterations | 60.4 min over the 15 spans through `0003750` (spread 55.4-68.5); 60.7 over the 16 spans through `0004000` |
| It/sec across reports | min 0.055, max 0.118, mean ≈0.072 (≈13.9 s/iter of step time) |
| average including validation and saves | **14.49 s/iter** at the time of writing (54,351 s from train start 20:15:29 to `0003750` at 11:21:20, ÷ 3,750); 14.57 s/iter recomputed at `0004000` (58,289 s ÷ 4,000). An earlier version of this row said ≈14.6, which did not reproduce from the artifacts cited beside it. |
| validation cost so far | 1,372.98 s = 22.9 min over 8 passes |
| peak memory | 14.978 GB, flat since iteration 375 (E003) |
| **projected finish** | see the note below — **≈14:20 PDT** from the mtimes available when this was written, **≈14:25** after the next checkpoint landed |

**On the projected finish, and how a DERIVED number goes wrong.** The first
version of this row read *"≈14:25-14:31 PDT (DERIVED from checkpoint mtimes;
total ≈18.2 h)"*. That did not reproduce from the mtimes it cited. With the 15
checkpoints then on disk (`0000250` at 2026-09-05 21:16:46 … `0003750` at
2026-09-06 11:21:20) and train start 20:15:29:

| basis | mean min / 250 iters | 4,490 iters | finish |
| --- | ---: | ---: | ---: |
| 14 checkpoint-to-checkpoint intervals (844.6 min) | 60.33 | 18.06 h | 14:18:56 |
| 15 spans, counting train start → `0000250` | 60.39 | 18.08 h | 14:20:05 |
| the 5 most recent spans | 59.58 | — | 14:17:42 |

Every route gave ≈14:18-14:20 and ≈18.1 h. 18.2 h implies 60.8 min per 250
iterations, which was above every mean on record — the figure was rounded up by
hand and then labelled DERIVED, which is the specific dishonesty rule 2 exists
to prevent. A label that says DERIVED is a promise that the arithmetic runs.

The run has since written `0004000` at 12:26:58, a 65.6-minute span, and the
same arithmetic over 16 checkpoints now gives 60.68-60.72 min per 250, **18.16
h**, finish **14:25:17-14:25:58**. So the original guess landed close — by a
late slowdown it could not have known about, not by derivation. Both states are
recorded here because the difference between them is the point.

## What happens when it finishes

1. Do **not** promote on the stored champion (O002).
2. Run the checkpoint sweep (P004) — this closes the entry.
3. Restore `google/gemma-4-12b-qat` in LM Studio for the cloud brain,
   whatever the verdict (`fuse-and-gate.md` step 5).

## What this run cannot show

- **Whether the model learned routing judgment.** The corpus is synthesized
  from template families and the validation split shares them, so the loss
  curve shows only that the model **fits the corpus's distribution**; it cannot
  say which mechanism produced that fit. An earlier version of this bullet said
  the curve "measures memorization, not generalization (O001)" — O001 says the
  opposite in terms, and refuses exactly that contrastive claim: loss cannot
  separate "memorized these rows" from "learned the templates" from "learned
  the decision rules", because all three score identically on an
  in-distribution split, and O001 records the 0.005-0.028 nats on 118 unseen
  rows as mild evidence *against* row-level memorization. The hard tier of the
  gate is the only discriminator available; the loss curve is silent.
- **What the ceiling is.** The routing labels are deterministic-baseline output
  (O007), and the baseline scores 3/25 on the hard tier. H004 states the
  prediction that follows.
- **Whether the last checkpoint is the best one.** H003.
- **Whether the run is even scored under the prompt it was trained on.** The
  system message of all 890 routing examples embeds `router.md` as of
  2026-09-05 19:46. That file was edited on 2026-09-06 at 09:52 (`7a591f4`, on
  `imac-site`), mid-run. O003 covers it.

## Open

- **UNSOURCED: no command records how `datasets/mlx/` was produced.** The
  behaviour is fully recovered — a `random.Random(17)` shuffle of the 2,363-row
  corpus taking the first 118 as validation reproduces both files
  byte-for-byte, line order included — but nothing in the repo runs it.
  *Settled by:* a committed `split_dataset.py` taking corpus path, fraction and
  seed.
- The projected finish time is arithmetic on checkpoint mtimes, not a
  scheduler's estimate.

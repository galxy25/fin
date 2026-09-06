---
id: E003
date: 2026-09-06
occurred: 2026-09-05
kind: EXPERIMENT
title: Fitting a LoRA run under a 24 GB Metal ceiling — batch 2 OOMs, grad-checkpoint + batch 1 holds at 14.978 GB
status: closed
tags: [memory, mlx, training, machine-safety]
sources:
  - "device probe 2026-09-05 19:50:52 PDT: max_recommended_working_set_size = 24 (GB)"
  - "memory note machine-safety-serialized-builds — 'A 4B 4-bit LoRA at batch 2 × seq 3072 without gradient checkpointing peaked at 28 GB and OOM'd'"
  - "memory note foreman-finetune-state — 'Smoke #1 (batch 2, no grad-checkpoint): Metal OOM at 28 GB peak'"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log — 'Peak mem 14.978 GB' on 134 consecutive reports from iter 375"
  - scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/tuner/trainer.py:341 — peak_mem = mx.get_peak_memory()/1e9
related: [P003, E002, E004]
corrects: []
superseded-by: null
---

## Question

What training configuration fits a 4-bit Gemma LoRA at sequence length 3072
inside the 24 GB Metal working set of a 32 GB M4 iMac?

## Method

Two smoke trains on `mlx-community/gemma-3-4b-it-4bit` (the base later dropped,
E002), on 2026-09-05 evening, differing in three flags.

| | smoke #1 | smoke #2 |
| --- | --- | --- |
| `--batch-size` | 2 | 1 |
| `--grad-accumulation-steps` | — | 2 |
| `--grad-checkpoint` | off | on |
| `--mask-prompt` | — | on |
| `--max-seq-length` | 3072 | 3072 |

Sequence length was fixed at 3072 for a measured reason recorded in
`machine-safety-serialized-builds`: **3072 keeps 100% of examples, 2048 would
truncate 38%** (real-tokenizer lengths: median 1669, p95 2798, max 2810).
Truncating a third of the corpus to save memory would have silently changed
what was being trained.

## Result

| config | peak memory | outcome | source quality |
| --- | --- | --- | --- |
| batch 2, no grad-checkpoint, ~4B | **28 GB** | **Metal out-of-memory, crashed** | **UNSOURCED — recollection** |
| batch 1 + accum 2 + grad-checkpoint, ~4B | "just under 10 GB" | ran | **UNSOURCED — recollection** |
| batch 1 + accum 2 + grad-checkpoint, **7.46B** (the live run) | **14.978 GB** | running 15 h, no crash | **logged, 134 reports** |

Against a 24 GB recommended working set: 28 GB is 4 GB past the ceiling;
14.978 GB is **62% of it**, for a model **1.87× larger** (7.463B vs ~4B) than
the one that failed.

The live run's peak memory takes exactly three values across the whole run and
has not moved since iteration 375:

| iterations | Peak mem | reports |
| --- | --- | --- |
| 25-100 | 14.847 GB | 4 |
| 125-350 | 14.950 GB | 10 |
| 375- | **14.978 GB** | 134 |

`peak_mem` is `mx.get_peak_memory()/1e9` (`trainer.py:341`), i.e. the
allocator's high-water mark in decimal GB, not a resident-set measurement.

## Interpretation

Three flags do three different things and only one of them is the memory fix:

- **`--grad-checkpoint`** is the fix. It trades recomputation for stored
  activations, and activations at seq 3072 are what blew the ceiling.
- **`--batch-size 1`** halves the activation footprint again.
- **`--grad-accumulation-steps 2`** buys back the *optimization* behaviour that
  batch 1 lost — it sums two examples' gradients before an update — at no
  memory cost. It does not change the iteration count (see E004).

The combination is now a standing rule (P003), and it is what let a 7.46B base
train where a 4B base had failed.

## What this does not show

- **The 28 GB and "just under 10 GB" figures are UNSOURCED recollections.**
  The smoke logs lived in a worktree under `/tmp/fin-wt-train`, which the
  19:35:56 reboot wiped. A grep for `metal::malloc`, `Attempting to allocate`,
  `bad_alloc`, `libc++abi` and `out of memory` across all three session
  transcripts returns zero hits: the raw stderr never reached a transcript.
  The numbers are internally consistent (28 > 24) but their precision cannot
  be checked. *Settled by:* re-running the batch-2 config — which nobody
  should do while the GPU is busy — or a
  `~/Library/Logs/DiagnosticReports/` crash report from 2026-09-05, not yet
  checked.
- **The verbatim MLX OOM error text and the exact allocation that failed are
  lost.**
- **Whether smoke #1 ran before or after the 19:35:56 reboot is ambiguous.**
  The gemma-3 download is stamped 19:28 (pre-crash), but the contemporaneous
  status message says smoke #1 "reproduced the crash shape", implying a
  post-reboot rerun. Both readings fit the surviving artifacts.
- **Smoke #1's `--iters` and dataset path were never recorded.**
- **No intermediate configuration was tried.** Nobody measured batch 2 *with*
  grad-checkpoint, or batch 1 without it. The winning config is a bundle, and
  the contribution of each flag is inferred from how MLX works, not measured
  here.

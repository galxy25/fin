---
id: E003
date: 2026-09-06
occurred: 2026-09-05
kind: EXPERIMENT
title: Fitting a LoRA run under a 24 GB Metal ceiling — batch 2 OOMs, grad-checkpoint + batch 1 holds at 14.978 GB
status: closed
tags: [memory, mlx, training, machine-safety]
sources:
  - "memory note machine-safety-serialized-builds.md:15 — 'Metal's max recommended working set is only 24 GB of the 32'"
  - "reproducing command for the ceiling: python3 -c 'import mlx.core as mx; print(mx.metal.device_info())' — NOT run while a fine-tune holds the GPU (P003)"
  - "memory note machine-safety-serialized-builds — 'A 4B 4-bit LoRA at batch 2 × seq 3072 without gradient checkpointing peaked at 28 GB and OOM'd'"
  - "memory note foreman-finetune-state — 'Smoke #1 (batch 2, no grad-checkpoint): Metal OOM at 28 GB peak'"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log — 'Peak mem 14.978 GB' on 137 consecutive reports, iterations 375-3775, read at wc -l = 194 while the run was still writing"
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

Sequence length was fixed at 3072 for a measured reason, recorded across two
memory notes. The rule is in `machine-safety-serialized-builds.md:24-25`,
where the sentence wraps — line 24 is *"- Train with `--grad-checkpoint
--batch-size 1 --grad-accumulation-steps 2` (seq 3072 keeps"* and line 25 is
*"100% of examples; 2048 would truncate 38%)."* (An earlier version anchored
the whole parenthetical to `:25`, which holds only its second half.) The
real-tokenizer
lengths behind it are in a different note, `foreman-finetune-state.md:22` —
*"Token lengths (real tokenizer): median 1669, p95 2798, max 2810 →
`--max-seq-length 3072`"*. Truncating a third of the corpus to save memory
would have silently changed what was being trained.

## Result

| config | peak memory | outcome | source quality |
| --- | --- | --- | --- |
| batch 2, no grad-checkpoint, ~4B | **28 GB** | **Metal out-of-memory, crashed** | **UNSOURCED — recollection** |
| batch 1 + accum 2 + grad-checkpoint, ~4B | "just under 10 GB" | ran | **UNSOURCED — recollection** |
| batch 1 + accum 2 + grad-checkpoint, **7.46B** (the live run) | **14.978 GB** | running 15 h, no crash | **logged, 137 reports** |

Against a 24 GB recommended working set: 28 GB is 4 GB past the ceiling;
14.978 GB is **62% of it**, for a model **1.87× larger** (7.463B vs ~4B) than
the one that failed.

### Where the 24 GB comes from, and what class of artifact that is

The 24 GB is not a probe this entry ran. It is the figure recorded in
`machine-safety-serialized-builds.md:15` — *"Metal's max recommended working set
is only 24 GB of the 32"* — and the command that re-derives it is
`mx.metal.device_info()["max_recommended_working_set_size"]`, which is
GPU-adjacent and so was not run while E004 holds the device. Every memory
conclusion in this entry and in P003 turns on that one number, so it is worth
being explicit about which class of artifact it comes from.

**And that class is the weakest one in the book.** "Memory note" means a file
under `~/.claude/projects/-Users-deepspacenine-forges-levi-fin/memory/` — the
Claude Code project memory directory, cited throughout this book by bare
filename. It is worth stating exactly what that citation is worth:

- **Not in any git repository.** `git -C
  ~/.claude/projects/-Users-deepspacenine-forges-levi-fin/memory rev-parse`
  returns *"fatal: not a git repository"*, and `git log -- '*machine-safety*'`
  in this repo returns nothing.
- **Rewritten in place, with no history.** A number can change between a
  citation being written and being read, and nothing records that it did.
- **Outside the repo entirely**, so a reader holding only a clone can resolve
  none of these citations.

Six entries plus the README lean on these notes (E002, E003, H001, H002, O004,
P003, and README.md's own provenance section, which cites
`labbook-and-publishing` as the authority for where this directory lives). They
are a real artifact class and they are not in the README's durability table.
Treat them as **`local-artifact`, quoted verbatim** — the same treatment
gitignored `datasets/` and `models/` files get, and for the same reason: the
quote may outlive the file. Every memory-note citation in this entry quotes its
line verbatim for exactly that reason. Ten notes exist in that directory today;
the ones this book cites are `machine-safety-serialized-builds`,
`foreman-finetune-state`, `training-bits-per-example`,
`scaling-and-curriculum-hypotheses` and `labbook-and-publishing`.

The live run's peak memory takes exactly three values across the whole run and
has not moved since iteration 375:

| iterations | Peak mem | reports |
| --- | --- | --- |
| 25-100 | 14.847 GB | 4 |
| 125-350 | 14.950 GB | 10 |
| 375-3775 | **14.978 GB** | 137 |

Counted at the same snapshot E004 records — iteration **3775**, 151 reports,
`wc -l train.log` = 194 lines of a file still being appended to. 4 + 10 + 137 =
151, which is the check that the three rows partition the log. A later reader
will find a larger third row and should not read that as a discrepancy: at 156
reports (iteration 3900) it is 142. **A statistic read off a live log means
nothing without the offset it was read at**, which is why that offset is now
written beside every figure in this entry.

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

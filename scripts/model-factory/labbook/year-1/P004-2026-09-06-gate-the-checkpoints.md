---
id: P004
date: 2026-09-06
occurred: 2026-09-06
kind: PROCESS
title: Gate several checkpoints, not just the last one
status: proposed
tags: [gate, checkpoints, promotion, memorization]
sources:
  - d9100b6 — "Model factory: gate several checkpoints, not just the last one" (2026-09-06 08:05); NOT an ancestor of main (verified with git merge-base --is-ancestor)
  - scripts/model-factory/gate_sweep.sh:1-22 (rationale and order of operations)
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/ — 15 checkpoints, 27,683,964 B each"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/fuse-and-gate.md"
related: [P001, H003, O001, O002]
corrects: []
superseded-by: null
---

## Status: proposed, never yet run

`scripts/model-factory/gate_sweep.sh` exists (`d9100b6`, 2026-09-06 08:05) but
lives on the `imac-site` branch and is **not on main** — verified:
`git merge-base --is-ancestor d9100b6 main` exits non-zero. Its working
directory `models/gate-sweep/` does not exist, so it has never been executed.
This entry records the protocol as designed. Its first run closes E004 and
tests H003.

## Why not just gate the final adapter

Because loss cannot tell the two candidate stories apart. The script's own
header says it (`gate_sweep.sh:7-10`):

> *"the 2026-09-06 run reached train loss 0.000 by iteration ~2900 on
> programmatically synthesized data, so later checkpoints memorize templates
> while the eval corpus's adversarial 'hard' tier is what actually
> discriminates. Loss cannot tell those apart; the gate can."*

(That paraphrase overstates by ~225 iterations — the log's first `0.000` is
iteration **2675**, not ~2900. See O001. The argument is unaffected.)

The run saves an adapter every 250 iterations, so there are 15 candidates on
disk, not one, all 27,683,964 bytes each. Nothing about the training objective
makes the last one best.

## Protocol

Run only when the GPU is free (P003).

0. **Refuse to compete for memory.** Abort if a fine-tune is running
   (`pgrep -f "mlx_lm lora"`) or LM Studio holds the GPU.
1. **Re-record the champion first.** Score the untuned `google/gemma-4-e4b`
   through the *current* `evals/tmux-routing/prompts/router.md` and use that
   number as the bar. The stored 36/51 was measured with the round-0 prompt
   (O002); scoring a candidate against it would flatter the candidate by up to
   **12** points of the base model's own prompt engineering. (12, not 13,
   because `eval_gate.py:75-80` uses a strict `>`: against a stored 36/51 the
   worst candidate that still promotes scores 37, and 49 − 37 = 12. 13 is the
   separate and also-true number — the gap between the stored record and what
   the base actually scores today. O002:72-77 derives both; an earlier version
   of this step attached the record gap to the candidate.) The script's closing
   line is the guard: `champion: … || echo 'NOT RE-RECORDED — do not promote
   on the stale 36/51'`.
2. **Per checkpoint, one at a time:** stage → `mlx_lm.fuse` → serve with
   `mlx_lm.server` → `run_evals.py` → record the row → **delete the fused
   model**. Each fused model is ~4-6 GB; twelve of them would fill the disk.
3. **Print a table and name the winner.** Default checkpoints: `1000 2250 3500
   final`.
4. **Promotion still requires `eval_gate.py`** against the re-recorded
   champion (P001). The sweep ranks; it does not promote.
5. **Re-score the winner on the real serving surface** — LM Studio — before it
   goes live.

The post-training runbook that surrounds this is
`models/candidates/fin-foreman-e4b-mlx/fuse-and-gate.md`: fuse → stage under
`~/.lmstudio/models/fin/` → re-record champion → gate → restore
`google/gemma-4-12b-qat` for the cloud brain regardless of verdict → fix the
docs that still say gemma-3.

## The confound this protocol carries

Step 1 scores the champion through **LM Studio** serving `google/gemma-4-e4b`;
step 2 scores candidates through **`mlx_lm.server`** serving a fused
`mlx-community/gemma-4-E4B-it-qat-4bit`. Different quantization, different
server, same nominal model family. The script acknowledges it and defers to
step 5. Until step 5 runs, any promotion decision includes an unmeasured
serving delta.

A cleaner design would re-record the champion on the same server the
candidates use, and treat the LM Studio number as a separate row. That has not
been done and is not scheduled.

## What this does not do

- It scores `tmux-routing` only. `goals-ledger` has no model-backed runner at
  all (O006).
- It writes to `models/gate-sweep/results.tsv`, not to
  `evals-champions.json` — so a sweep leaves the recorded champion untouched,
  and a third copy of "the champion" now exists (repo JSON, S3
  `models/champion.json`, the sweep's scratch file) with no reconciliation
  code.
- It records no prompt hash with its rows, so a results.tsv from two different
  `router.md` versions would look identical (O005).

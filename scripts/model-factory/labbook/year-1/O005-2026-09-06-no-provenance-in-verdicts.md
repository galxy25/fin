---
id: O005
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Nothing in the factory records provenance — no prompt hash, no corpus commit, no dataset manifest
status: standing
tags: [provenance, gate, data, reproducibility]
sources:
  - "grep -n 'prompt|commit|sha' scripts/model-factory/eval_gate.py → no matches"
  - scripts/model-factory/eval_gate.py:113-140 (the verdict fields)
  - main:scripts/model-factory/README.md:173-175 (the manifest that is specified but never written) — see the line-anchor note at the end of this entry
  - "ls datasets/ — no manifest.json anywhere; git grep 'datasets/mlx' → no tracked hit (exit 1)"
  - scripts/model-factory/train/qlora_config.yaml:7 — base_model: google/gemma-3-4b-it
related: [O002, O003, E002, E004, P001]
corrects: []
superseded-by: null
---

## What was observed

Every measurement this factory makes is unattributable after the fact, because
nothing records what it was measured against.

### The gate verdict has no provenance fields

`grep -n "prompt\|commit\|sha" scripts/model-factory/eval_gate.py` returns
nothing. The verdict JSON records `eval`, `model`, `baseUrl`, `ranAt`,
`scores`, `champion`, `coreGate`, `beatsChampion`, `promoted`, `reason`,
`runExitCode` and `runOutput` — a good record of *what happened*, and no record
of *what it happened to*:

| missing field | why it matters |
| --- | --- |
| hash of `prompts/router.md` | the prompt is read at scoring time and has five known revisions (E001) and three live texts (O003) |
| corpus git commit | scenarios have been re-tiered once already (`2234284`) |
| candidate adapter / checkpoint id | fifteen checkpoints exist for run 1 |
| server + quantization | champion and candidate are scored on different servers (P004) |

Consequence: two verdicts with identical scores can mean completely different
things, and there is no way to tell them apart later. This is what makes O002
possible — a stale champion is exactly a score whose provenance was not
recorded.

The README's *model manifest* schema does specify a `corpusCommit` field.
Nothing emits it.

### There is no dataset manifest either

`README.md:173-175` (on `main`) specifies one: *"Every build writes
`datasets/<dataset-id>/manifest.json`: source list, example counts per track,
per-split sha256, corpus git commit, build date."* That README is the **only**
place the manifest is promised. An earlier draft of this entry also cited
`build_dataset.py:32-38` as a docstring promising it; that is wrong — `grep -in
manifest scripts/model-factory/build_dataset.py` returns **zero** matches, and
lines 29-33 there are the LEAKAGE WARNING while 35-39 are the Usage block and
the default output path. The citation is withdrawn rather than re-targeted,
because there is nothing in that file to re-target it to.

Neither `gen_training_data.py` nor whatever produced `datasets/mlx/` writes one.
No `manifest.json` exists anywhere under `datasets/`.

Consequence, concretely: establishing that the corpus now training was built
from main's `router.md` and not `imac-site`'s took a full regeneration at two
commits and a byte-diff (O003). A manifest carrying the corpus sha256 next to
the sha of `prompts/router.md` would have made that a one-line check instead
of archaeology.

### And no record of how `datasets/mlx/` was made

**No *tracked* file references it.** `git grep 'datasets/mlx'` exits 1 with no
output. The word "tracked" is load-bearing and an earlier draft of this entry
omitted it: a plain `grep -rn` over the working tree returns two hits, both
inside gitignored `models/` —
`models/candidates/fin-foreman-e4b-mlx/launch-train.sh:13` (`--train --data
datasets/mlx \`, reproduced in full in E004) and
`models/candidates/fin-foreman-e4b-mlx/adapter_config.json:6` (`"data":
"datasets/mlx"`). Those are the *run's* record of the path, written by mlx-lm,
not a script that builds it.

The conclusion is unchanged and is the one that matters: the split's *behaviour*
is fully recovered — a `random.Random(17)` shuffle of the 2,363-row corpus,
first 118 rows to validation, reproduces both files byte-for-byte including line
order — but **no committed script performs it**. It is a command someone ran
once.

### Committed docs contradict the running system

| file | says | reality |
| --- | --- | --- |
| `train/qlora_config.yaml:7` | `base_model: google/gemma-3-4b-it` | run 1 uses `mlx-community/gemma-4-E4B-it-qat-4bit` (E002) |
| `train/qlora_config.yaml` | `output_dir: models/candidates/fin-foreman-4b` | never created |
| `README.md:40` | "[ ] Synthetic expansion … unblocks the first real fine-tune" | done, `8aa690c` |
| `README.md:42` | "[ ] First fine-tune run (**human go required**)" | **running since 2026-09-05 20:15:29** |
| `README.md:44` | "[ ] goals-ledger eval joins the gate (that branch has not merged)" | the design merged `2026-09-05 12:45` (`e025413`); the *gate wiring* did not (O006) |
| `README.md:29-33` | leakage caveat on the seed build | superseded by `8aa690c` (P002) |

A checklist showing "first fine-tune, human go required" unchecked while one
runs will eventually be trusted at the wrong moment.

## Smallest fix with the highest leverage

Write the dataset manifest and add three fields to the gate verdict
(`promptSha`, `corpusCommit`, `adapterPath`). Both are small changes that turn
future assertions into checks instead of archaeology. Neither has been done.

## What this does not show

- **It does not show any recorded number is wrong.** Every score in
  `RESULTS.md` reconstructs correctly from commit ordering (E001). The problem
  is that reconstruction was necessary at all.
- **It does not show the run is illegitimate.** `README.md:231-238` explicitly
  exempts local mlx runs from the GPU-spend approval rule; run 1 needed no
  purchase approval. The stale checkbox is a documentation failure, not a
  process violation.

## Line-anchor note for every `scripts/model-factory/README.md:N` citation

**Every `scripts/model-factory/README.md:N` line number in this book is against
`main` at `704ab09`.** The lab-book commit itself inserts a 22-line "## Lab
book" section at line 22 of that file, so on branch `labbook` every anchor below
line 22 shifts by **+22**: `## Status` 22→44, the three checkboxes 40/42/44→
62/64/66, the manifest spec 173-175→195-197, `**Leakage rule:**` 167→189,
`### Hard rule` 231→253, `## Eval gate` 240→262. A reader following
`README.md:44` on this branch lands on `## Status`, not on the goals-ledger
checkbox quoted above. The same shift applies to the citations in P001 and P002.
This is a small, live example of exactly what the entry is about: a line number
is a provenance claim, and it is only true of a stated revision.

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
  - scripts/model-factory/eval_gate.py:114-144 (the verdict dict; 113 is blank)
  - main:scripts/model-factory/README.md:173-175 (the manifest that is specified but never written) — see the line-anchor note at the end of this entry
  - "ls datasets/ — no manifest.json anywhere; git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook' → exit 1, no output, at main and at 0fe0883 on labbook (the exclusion is mandatory — see the section below)"
  - scripts/model-factory/train/qlora_config.yaml:7 — base_model: google/gemma-3-4b-it
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/fuse-and-gate.md step 6 — the docs fix list"
  - "merged from docs/labbook/entries/O005-2026-09-06-factory-docs-drift.md (the parallel book, 4705b67) — see the merge note below"
related: [O002, O003, O006, E002, E004, E006, E008, P001, P005]
corrects: []
superseded-by: null
---

**Merged from two drafts.** Both books numbered an entry `O005` on 2026-09-06:
this one, `scripts/model-factory/labbook/year-1/O005-2026-09-06-no-provenance-in-verdicts.md`,
and `docs/labbook/entries/O005-2026-09-06-factory-docs-drift.md`. Same id,
different framing of an overlapping fact — this entry treats the drifted
checklist as one symptom of the factory recording no provenance at all; the
other treated the checklist as the subject. The consolidation (O009) kept this
one as the wider frame and folded the other's two extra drift rows and its
argument for why a docs bug belongs in a lab book into "Committed docs
contradict the running system" below. The four README rows the two drafts share
were identical in both.

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

`main:README.md:173-175` (branch `labbook`: 204-206) specifies one: *"Every build writes
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

**No file that is part of the factory references it.** The exact command
matters, and three successive drafts of this sentence got it wrong in three
different ways — the third being the one that produced this book's
self-referential-count rule.

| command | exit | output |
| --- | ---: | --- |
| `git grep -n 'datasets/mlx' main` | 1 | none |
| `git grep -n 'datasets/mlx' 0fe0883` (bare, on `labbook`) | **0** | **30 hits** — every one of them inside a lab book, including the row above it |
| **`git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook'`** | **1** | **none** — at `main` and at `0fe0883` |
| `grep -rn 'datasets/mlx'` over the working tree | 0 | 2 hits under gitignored `models/`, plus the lab-book hits |

The third form is the durable one, because it asks the question actually meant:
*does anything in the factory reference this path?*

**How the other three failed, in order.** The first draft said "`grep -rn`
returns nothing", ignoring the working tree's gitignored artifacts. The
correction said "`git grep 'datasets/mlx'` exits 1 with no output" — true at
`main`, false on the branch this entry lives on. The third draft caught that and
wrote the bare-`labbook` row as **24 hits**, "every one of them inside
`docs/labbook/` or `scripts/model-factory/labbook/` — including this sentence".
That was true for about an hour. At `0fe0883` the same command returns **30**,
and it went up because the book kept being written; it will move again at the
next commit, in the direction of whoever edits the book last.

**So the number was never evidence about the factory. It was a measurement of
this book, taken by this book, cited as if it were about something else.** That
is the failure the README's conventions now name in one line: *a count of the
book by itself is not evidence.* Updating 24 to 30 would fix the arithmetic and
leave the defect exactly where it was. The fix is the pathspec — and the entry
already knew the `--` exclusion form, since it is the third row of its own
table.

Note also that the exclusion is now **one** pathspec, not two: `docs/labbook/`
no longer exists (O009 consolidated it into this book), so excluding it would be
excluding nothing. That is itself a small demonstration of the rule — a command
written against the shape of the repository on one afternoon stops meaning what
it meant when the repository changes.

The two working-tree hits are both inside gitignored `models/` —
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
| `main:README.md:40` | "[ ] Synthetic expansion … unblocks the first real fine-tune" | done, `8aa690c` |
| `main:README.md:42` | "[ ] First fine-tune run (**human go required**)" | **running since 2026-09-05 20:15:29** |
| `main:README.md:44` | "[ ] goals-ledger eval joins the gate (that branch has not merged)" | the design merged `2026-09-05 12:45` (`e025413`); the *gate wiring* did not (O006) |
| `main:README.md:29-33` | leakage caveat on the seed build | superseded by `8aa690c` (P002) |

Two more rows, folded in from the merged draft:

| file | says | reality |
| --- | --- | --- |
| `train/README-local.md` | names gemma-3 as the base | run 1 uses `mlx-community/gemma-4-E4B-it-qat-4bit` (`launch-train.sh:12`, E002). Already on the fix list — `fuse-and-gate.md` step 6 — and unfixed |
| `main:README.md` "Eval gate" section | describes the gate as the routing corpus alone | **accurate**, and that is the point: `evals/goals-ledger` is merged but `eval_gate.py` never mentions it, so the *behaviour* is honest while the *checklist* is not (O006) |

**Why a docs bug belongs in a lab book at all**, which the merged draft argued
and this entry had only implied: the Status block is load-bearing for the "human
go required" rule. A reader checking whether a fine-tune has been authorized
reads an unchecked box next to those words while a fine-tune is running. The run
itself is legitimate — the standing rule exempts local mlx runs, see "What this
does not show" below — but a checklist that contradicts the machine's process
table is a checklist that will eventually be trusted at the wrong moment. The
lab book records it because the lab book is where the factory's claims get
checked against the factory.

## Smallest fix with the highest leverage

Write the dataset manifest and add three fields to the gate verdict
(`promptSha`, `corpusCommit`, `adapterPath`). Both are small changes that turn
future assertions into checks instead of archaeology. Neither has been done.

## What this does not show

- **It does not show any recorded number is wrong.** Every score in
  `RESULTS.md` reconstructs correctly from commit ordering (E001). The problem
  is that reconstruction was necessary at all.
- **It does not show the run is illegitimate.** `main:README.md:231-238`
  (branch `labbook`: 262-269) explicitly
  exempts local mlx runs from the GPU-spend approval rule; run 1 needed no
  purchase approval. The stale checkbox is a documentation failure, not a
  process violation.

## Line-anchor note for every `scripts/model-factory/README.md:N` citation

**Every `scripts/model-factory/README.md:N` line number in this book is against
`main` at `704ab09` unless it says otherwise.** The lab-book work inserts a
`## Lab book` section at line 22 of that file, so on branch `labbook` every
anchor below line 22 shifts down. The table below is measured on `labbook` at
the commit that contains this note; the reproducer beside it is the part that
does not rot.

| text | `main` @ `704ab09` | branch `labbook` | reproducer on `labbook` |
| --- | ---: | ---: | --- |
| `## Lab book` (the inserted section, lines 22-52) | — | 22-52 | `grep -n '^## Lab book' scripts/model-factory/README.md` |
| `## Status` | 22 | **53** | `grep -n '^## Status'` |
| the three open checkboxes quoted above | 40 / 42 / 44 | **71 / 73 / 75** | `grep -n '^- \[ \]'` — returns five open boxes (71, 73, 74, 75, 76); the three quoted here are the 1st, 2nd and 4th |
| leakage caveat on the seed build (a `- [x]` block) | 29-33 | **60-64** | `grep -n 'Leakage caveat'` — lands at 62, mid-block |
| `**Leakage rule:**` | 167 | **198** | `grep -n '^\*\*Leakage rule:\*\*'` |
| the dataset-manifest spec | 173-175 | **204-206** | `grep -n 'manifest.json.: source list'` |
| `### Hard rule` (the GPU-spend rule, 231-238 / 262-269) | 231 | **262** | `grep -n '^### Hard rule'` |
| `## Eval gate` (the section, 240-262 / 271-293) | 240 | **271** | `grep -n '^## Eval gate'` |

The shift is **+31**, not the +22 an earlier version of this note claimed. The
file gained 367 − 336 = 31 lines, which `git diff --numstat main labbook --
scripts/model-factory/README.md` reports as `31 0`. The wrong figure arose the
obvious way and is worth stating plainly: the note was written while counting
the section it was itself part of, `a02cec3` added 22 lines, `cdb895a` added 9
more to the same section, and the note was not recomputed. Every anchor the
first version derived was therefore 9 lines short, and P001 and P002 — which
defer to this note — carried the same 9-line error until it was corrected with
this table. The worst of them was silent rather than obvious: the old note sent
a reader looking for `## Eval gate` to line 262, which on this branch is exactly
`### Hard rule`, so they would have read a real section and never noticed.

**How to keep this true.** Do not hand-propagate a shift; re-run the grep. Any
commit that edits `scripts/model-factory/README.md` invalidates the middle
column of this table, and the only defence that survives is the right-hand one.
The entry's own subject, demonstrated on itself three times now — twice in this
table's line numbers and once in the grep count above: **a line number, a hit
count and a command's exit code are all provenance claims, and each is only true
of a stated revision — including when the revision is the one you are writing.**
When the thing being counted is the book itself, the number is not evidence at
all until it is both pinned to a revision and scoped away from the book's own
paths.

**Anchors that defer to this note:** P001 (`## Eval gate`), P002 (`**Leakage
rule:**`), O006 (the goals-ledger checkbox), and — added by the consolidation —
O003 and P005 (the dataset-manifest spec, 173-175 / 204-206). Each states both
columns inline so none of them depends on a reader finding this table.

**Checked after the consolidation (O009).** That pass rewrote
`scripts/model-factory/README.md`'s "Lab book" section, replacing an
eight-line block with an eight-line block, so the file is still 367 lines on
this branch against 336 on `main` and **every anchor in the table above still
resolves exactly**. It was luck that the replacement was the same length; the
right-hand column is what was actually re-run to confirm it. Two anchors
*inside this book* did move in that pass — `O002:72-77` and `O001:60-61`, both
because the entries they point into received merged content — and P004 and H001
were corrected to the new numbers with a grep beside each. Same lesson, one
directory closer to home.

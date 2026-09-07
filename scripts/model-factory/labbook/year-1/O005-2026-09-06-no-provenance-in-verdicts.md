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
  - 704ab09:scripts/model-factory/README.md:173-175 (the manifest that is specified but never written) — pinned to the sha, not to the name `main`, which has since moved to 587fb9a; see the line-anchor note at the end of this entry
  - "ls datasets/ — no manifest.json anywhere; git grep -n 'datasets/mlx' 704ab09 → exit 1, no output. The exclusion form is revision-dependent and there is no `<rev>` that works for all of them: at 0fe0883 BOTH ':(exclude)docs/labbook' and ':(exclude)scripts/model-factory/labbook' are needed to exit 1, at 5305044 one suffices, and at 587fb9a neither helps. The full matrix, run at every revision it names, is the table below"
  - scripts/model-factory/train/qlora_config.yaml:7 — base_model: google/gemma-3-4b-it
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/fuse-and-gate.md step 6 — the docs fix list"
  - "merged from docs/labbook/entries/O005-2026-09-06-factory-docs-drift.md (the parallel book, 4705b67) — see the merge note below"
related: [O002, O003, O006, O010, E002, E004, E006, E008, P001, P005]
corrects: []
superseded-by: [O010, O013]
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

`704ab09:scripts/model-factory/README.md:173-175` (the same text is at 204-206
of the 367-line copy at `59b0515`) specifies one: *"Every build writes
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
from `704ab09`'s `router.md` and not `cd64914`'s took a full regeneration at two
commits and a byte-diff (O003). A manifest carrying the corpus sha256 next to
the sha of `prompts/router.md` would have made that a one-line check instead
of archaeology.

### And no record of how `datasets/mlx/` was made

**No file that is part of the factory references it.** The exact command
matters, and **four** successive drafts of this sentence got it wrong in four
different ways. The third produced this book's self-referential-count rule; the
fourth was written *by the fix for the third* and produced O010's.

There is no single command that answers this question at every revision, so the
table is a matrix rather than a list. **Every cell below was run**, on
2026-09-06 after the consolidation, at the revision that labels its row:

| revision | bare `git grep -n 'datasets/mlx' <rev>` | `-- ':(exclude)scripts/model-factory/labbook'` | `-- ':(exclude)docs/labbook' ':(exclude)scripts/model-factory/labbook'` |
| --- | --- | --- | --- |
| `704ab09` — what `main` pointed at while this entry was written | **1**, none | **1**, none | **1**, none |
| `4705b67` — the other book opens | 0, 9 hits | 0, 9 hits | **1**, none |
| `a02cec3` — this book opens | 0, 22 hits | 0, 9 hits | **1**, none |
| `cdb895a` — the first audit | 0, **24** hits | 0, 9 hits | **1**, none |
| `0fe0883` — round 2 | 0, **30** hits | 0, **11** hits | **1**, none |
| `5305044` — the consolidation, `docs/labbook/` deleted | 0, 32 hits | **1**, none | **1**, none |
| `587fb9a` — `main` today | 0, **1** hit | 0, **1** hit | 0, **1** hit |

Two columns to read across. **The one-exclusion form only became sufficient at
`5305044`**, because that is the commit that deleted `docs/labbook/`; before it,
the 9-to-11 hits it leaves behind are all in the other book. And the whole
question changed under the name `main`: at `704ab09` nothing outside the factory
mentioned the path, while at `587fb9a` the sibling publishing pipeline does —
`content/claims-ledger.md:416` quotes `launch-train.sh`'s `mlx_lm lora --data
datasets/mlx` as evidence for a different claim. That single hit is a prose
citation in a ledger, not a script that builds the directory, so the *finding*
is the same blob at `704ab09` and `077d970` (`git rev-parse <rev>:content/claims-ledger.md`
run at both); but the sentence "exits 1 with no output at `main`" is now simply false, and no
edit to this book made it false.

`grep -rn 'datasets/mlx'` over the working tree returns, in addition, 2 hits
under gitignored `models/`.

**How the four drafts failed, in order.** The first said "`grep -rn` returns
nothing", ignoring the working tree's gitignored artifacts. The second said
"`git grep 'datasets/mlx'` exits 1 with no output" — true at `704ab09`, false on
the branch this entry lives on, and false at `587fb9a` (and still false at
`077d970`). The third caught that
and wrote the bare-`labbook` row as **24 hits**, "every one of them inside
`docs/labbook/` or `scripts/model-factory/labbook/` — including this sentence".
That was true at `cdb895a` and for about half an hour after it: at `0fe0883` the
same command returns **30**, at `5305044` it returns **32**, and it moves in the
direction of whoever edits the book last.

**So the number was never evidence about the factory. It was a measurement of
this book, taken by this book, cited as if it were about something else.** That
is the failure the README's conventions name in one line: *a count of the book
by itself is not evidence.* Updating 24 to 30 would fix the arithmetic and leave
the defect exactly where it was. The fix is the pathspec.

**And the fourth draft is the one worth the most.** The consolidation, fixing
the third, replaced the row with a single `<rev>`-parameterised command and
asserted it exits 1 "at `main` and at `0fe0883`". Nobody ran it at `0fe0883`. It
exits **0** there with 11 hits, because the second book still existed at that
revision and the pathspec excludes only the first — and the pre-consolidation
draft of E008 had said so explicitly, in a sentence the consolidation deleted:
*"Both qualifiers are load-bearing."* The new rule ("exclude this directory")
was applied to a passage written before this directory was the only one, and the
qualifier that made the old command correct went with the old wording. That is
O010, and it is why the exclusion form above is a column of a matrix and not a
sentence.

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
| `704ab09:scripts/model-factory/README.md:40` | "[ ] Synthetic expansion … unblocks the first real fine-tune" | done, `8aa690c` |
| `704ab09:scripts/model-factory/README.md:42` | "[ ] First fine-tune run (**human go required**)" | **running since 2026-09-05 20:15:29** |
| `704ab09:scripts/model-factory/README.md:44` | "[ ] goals-ledger eval joins the gate (that branch has not merged)" | the design merged `2026-09-05 12:45` (`e025413`); the *gate wiring* did not (O006) |
| `704ab09:scripts/model-factory/README.md:29-33` | leakage caveat on the seed build | superseded by `8aa690c` (P002) |

Two more rows, folded in from the merged draft:

| file | says | reality |
| --- | --- | --- |
| `train/README-local.md` | names gemma-3 as the base | run 1 uses `mlx-community/gemma-4-E4B-it-qat-4bit` (`launch-train.sh:12`, E002). Already on the fix list — `fuse-and-gate.md` step 6 — and unfixed |
| `704ab09:scripts/model-factory/README.md` "Eval gate" section | describes the gate as the routing corpus alone | **accurate**, and that is the point: `evals/goals-ledger` is merged but `eval_gate.py` never mentions it, so the *behaviour* is honest while the *checklist* is not (O006) |

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
- **It does not show the run is illegitimate.**
`704ab09:scripts/model-factory/README.md:231-238`
  (branch `labbook`: 262-269) explicitly
  exempts local mlx runs from the GPU-spend approval rule; run 1 needed no
  purchase approval. The stale checkbox is a documentation failure, not a
  process violation.

## Line-anchor note for every `scripts/model-factory/README.md:N` citation

**Every `scripts/model-factory/README.md:N` line number in this book is against
the revision `704ab09` unless it says otherwise** — the sha, not the name
`main`, which pointed at `704ab09` while this book was written and points at
`587fb9a` now. That move does not disturb this table (the file is byte-identical
at both: `git show 704ab09:scripts/model-factory/README.md | wc -l` → 336, and
the same at `587fb9a`), but it disturbed the grep table above, so the anchors
are pinned to the sha regardless. The lab-book work inserts a
`## Lab book` section at line 22 of that file, so on branch `labbook` every
anchor below line 22 shifts down. The table below is measured at `59b0515`, the
the commit that contains this note; the reproducer beside it is the part that
does not rot.

| text | `704ab09` | branch `labbook` | reproducer on `labbook` |
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
file gained 367 − 336 = 31 lines, which `git diff --numstat 704ab09 labbook --
scripts/model-factory/README.md` reports as `31 0` (run again after this pass;
the same command with `main` in place of the sha also returns `31 0` today,
which is exactly the coincidence not to rely on). The wrong figure arose the
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
The entry's own subject, demonstrated on itself four times now — twice in this
table's line numbers, once in the grep count above, and once in the *fix* for
that grep count: **a line number, a hit count, a pathspec and a command's exit
code are all provenance claims, and each is only true of a stated revision —
including when the revision is the one you are writing.** When the thing being
counted is the book itself, the number is not evidence at all until it is both
pinned to a revision and scoped away from the book's own paths. And per O010:
the revision has to be a sha, and the command has to be **run** there, because
reasoning about what it would return is how the fourth one happened.

**Anchors that defer to this note:** P001 (`## Eval gate`), P002 (`**Leakage
rule:**`), O006 (the goals-ledger checkbox), and — added by the consolidation —
O003 and P005 (the dataset-manifest spec, 173-175 / 204-206). Each states both
columns inline so none of them depends on a reader finding this table.

**Checked after the consolidation (O009).** That pass rewrote
`scripts/model-factory/README.md`'s "Lab book" section, replacing an
eight-line block with an eight-line block, so the file is still 367 lines on
this branch against 336 at `704ab09` and **every anchor in the table above still
resolves exactly**. It was luck that the replacement was the same length; the
right-hand column is what was actually re-run to confirm it. Two anchors
*inside this book* did move in that pass — `O002:72-77` and `O001:60-61`, both
because the entries they point into received merged content — and P004 and H001
were corrected to the new numbers with a grep beside each. Same lesson, one
directory closer to home.

**Checked again after O010.** The consolidation's *fix* to the grep count in
this entry was itself wrong (it claimed an exit code at a revision nobody ran it
at) and the name `main` moved out from under three of this entry's citations
between `0fe0883` and now. The grep table above is now a run matrix; the
line-anchor pin above is now a sha. The `main:README.md:N` shorthand still
appears in this entry's drift table and in six sibling entries; it is a
shorthand for `704ab09:` under the declaration at the top of this section, and
`diff <(git show 704ab09:scripts/model-factory/README.md) <(git show
587fb9a:...)` is empty, so every one of those anchors still resolves. Rewriting
the prefix to the sha in eight files is recorded as open in O010 rather than
done here.

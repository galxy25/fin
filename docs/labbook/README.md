# Model Factory Lab Book — Year 1

Opened 2026-09-06 on Levi's directive: *"lets start a lab book for the model
factory, year 1 where we record experiments, observations, hypothesis and
processes like this."*

The subject is `scripts/model-factory/` — the pipeline that builds the small
fine-tuned Gemma that runs Fin as the foreman of a software factory. Its gate
is `evals/tmux-routing` (51 tiered scenarios) plus `evals/goals-ledger`, and
its promotion authority is `eval_gate.py` against `evals-champions.json`.

## The two rules that make this a lab book and not a wiki

**1. Append-only.** An entry is dated and never rewritten. A wrong entry is
corrected by a *later* entry that names it — exactly as you correct a paper
notebook: you do not erase the page, you write the correction on the next one
and draw the line back. Each entry is its own file so a diff to an existing
entry is visible and reviewable as the anomaly it is. Every entry carries
`Corrections:` and `Superseded-by:` header fields; the correcting entry fills
in the first, and the corrected entry is amended **only** to add the
`Superseded-by:` back-pointer. That one back-pointer edit is the sole
permitted modification to a published entry.

**Which regime is in force.** That rule is written for a book in use, and it
was broken on day one: the audit commit `cdb895a` rewrote 8 of this book's 13
entries (and 15 of the sibling book's 20) in place and added zero correction
entries. The full record is in
`scripts/model-factory/labbook/year-1/O008-2026-09-06-append-only-broken-on-day-one.md`.
Until branch `labbook` merges to `main`, or an entry here is cited from outside
this directory — whichever comes first — this book is a **draft** and in-place
correction is the honest fix, because a wrong number should be removed rather
than enshrined. Two conditions hold in the draft phase too: the rewrite is
never silent (the entry says what the earlier text said, so the wrong number
stays legible), and **no entry ever asserts a compliance it does not have**.
After the merge, the append-only rule above is the only route.

**2. Every number traces to an artifact.** A lab book whose numbers cannot be
checked is worse than no lab book, because it launders recollection into
fact. Every quantity in an entry cites one of: a git sha, a file path with a
line number, a log line, an S3 key, or a command that reproduces it. A number
that is only remembered is written **RECOLLECTION — UNSOURCED**, together with
the artifact that would settle it. Never quietly promote a memory to a
measurement.

Honest negative results are first-class. An approach that was abandoned, with
the reason it was abandoned, is among the most valuable things in this book —
it is the only record that stops the same road being walked twice.

## Entry kinds

| kind | id | what it is |
| --- | --- | --- |
| EXPERIMENT | `E001` | a question, a method, a result. Ran something, measured something. |
| OBSERVATION | `O001` | something noticed. No intervention in the system under study. |
| HYPOTHESIS | `H001` | a claim not yet tested, stated with the test that would settle it. |
| PROCESS | `P001` | a reusable protocol — the way we do a thing, written down so it is done the same way twice. |

**Instrumentation is not intervention.** An OBSERVATION may import a module,
wrap a function in a counter and run it, provided the wrapper does not change
what the system does — a counting wrapper that calls the original and returns
its value unchanged leaves the output bit-identical, so what is recorded is the
system as it already behaves. What makes an entry an EXPERIMENT is a question
posed in advance and a method built to answer it, not the mere fact that code
was executed. `entries/O001` (read-only counter over the label filter) and
`entries/E002` (a census run to answer a stated question) use the same
machinery and sit on opposite sides of that line for that reason.

Numbering is per kind, monotonic, never reused. A retracted entry keeps its
number and gains a `Superseded-by:`.

Filename: `entries/<KIND-ID>-<YYYY-MM-DD>-<slug>.md`. Everything lives flat in
`entries/`; this book has no year directories.

**Next free ids: `E005`, `O006`, `H003`, `P003`.** Take the next one for the
kind, add the entry, and add its row to the index below in the same commit —
the index is maintained by hand and an entry missing from it is effectively
lost.

### Permitted `status` values

This book records status in prose rather than a field, but the vocabulary is
the same one the sibling book uses, and a new entry should use these words:

| kind | permitted status |
| --- | --- |
| EXPERIMENT | `open` · `closed` · `abandoned` (say why) |
| OBSERVATION | `standing` · `superseded` |
| HYPOTHESIS | `untested` · `testing` · `supported` · `refuted` |
| PROCESS | `active` · `proposed` · `retired` |

### Entry header block

All 13 entries in this book use a bold-field header, not YAML. Copy this:

```markdown
# E005 — One line, specific, no marketing

- **Kind:** EXPERIMENT
- **Date:** 2026-09-06
- **Corrections:** —          <!-- ids this entry corrects -->
- **Superseded-by:** —        <!-- filled in later, when something corrects THIS -->

## Question            (EXPERIMENT / HYPOTHESIS)
## Method              (EXPERIMENT: exactly what was run, reproducibly)
## Result              (EXPERIMENT: numbers in a table)
## What was observed   (OBSERVATION)
## Prediction / Test   (HYPOTHESIS: what confirms it, what refutes it)
## Protocol            (PROCESS: numbered steps)
## What this does not show
## Open / unsourced
```

`- **Corrections:**` and `- **Superseded-by:**` are this book's names for the
fields the sibling book at `scripts/model-factory/labbook/` writes as YAML
`corrects:` and `superseded-by:`. **They are the same two fields**, so a check
for un-back-pointed entries across the branch has to match both spellings:

```sh
grep -rLE '(\*\*Superseded-by:\*\*|^superseded-by:)' docs/labbook/entries \
  scripts/model-factory/labbook/year-1
```

Reconciling the two spellings — like reconciling the two books' colliding ids
(see `scripts/model-factory/labbook/README.md`, "Provenance of this directory")
— is Levi's call and has not been made.

### Reproduction commands

Write them against a **revision**, never against a worktree that happens to
exist today, and never write output under `/tmp`. `git worktree add
../fin-wt-<purpose> <sha>` and a scratch directory beside the repo; the sibling
book's P003:111 has the rule and its E003:104 has the incident that produced
it.

## Index

| id | date | title |
| --- | --- | --- |
| [E001](entries/E001-2026-09-06-corpus-bit-exact-reproduction.md) | 2026-09-06 | The training corpus reproduces bit-for-bit — and names the commit it was built at |
| [E002](entries/E002-2026-09-06-corpus-census.md) | 2026-09-06 | Corpus census: where 4,527 generated candidates become 2,363 training rows |
| [E003](entries/E003-2026-09-06-mlx-split-recovery.md) | 2026-09-06 | Recovering the unscripted train/valid split from its artifacts |
| [E004](entries/E004-2026-09-06-bits-per-example.md) | 2026-09-06 | How many bits of information are in a training example? |
| [O001](entries/O001-2026-09-06-baseline-filter-never-fires.md) | 2026-09-06 | The "correct twice over" label filter rejected zero examples |
| [O002](entries/O002-2026-09-06-validation-split-in-distribution.md) | 2026-09-06 | The validation split is in-distribution; the loss curve measures memorization *(title overstates — the entry's opening note withdraws the "memorization" half)* |
| [O003](entries/O003-2026-09-06-prompt-skew-mid-run.md) | 2026-09-06 | A prompt edit landed mid-run and opened train/serve skew |
| [O004](entries/O004-2026-09-06-stale-champion-record.md) | 2026-09-06 | The recorded champion is a round-0 number; the shipped prompt scores 13 higher |
| [O005](entries/O005-2026-09-06-factory-docs-drift.md) | 2026-09-06 | The factory README's status checklist has drifted behind the run |
| [H001](entries/H001-2026-09-06-hard-tier-regression.md) | 2026-09-06 | Training on baseline labels will pull the hard tier toward the baseline |
| [H002](entries/H002-2026-09-06-best-checkpoint-is-not-last.md) | 2026-09-06 | The best checkpoint is not the final one |
| [P001](entries/P001-2026-09-06-reproduce-a-dataset.md) | 2026-09-06 | Protocol: reproduce a dataset bit-for-bit before you trust a number about it |
| [P002](entries/P002-2026-09-06-leakage-gate.md) | 2026-09-06 | Protocol: the leakage rule, what the gate checks, and what it does not |

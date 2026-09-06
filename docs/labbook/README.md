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
| OBSERVATION | `O001` | something noticed. No intervention, no manipulation. |
| HYPOTHESIS | `H001` | a claim not yet tested, stated with the test that would settle it. |
| PROCESS | `P001` | a reusable protocol — the way we do a thing, written down so it is done the same way twice. |

Numbering is per kind, monotonic, never reused. A retracted entry keeps its
number and gains a `Superseded-by:`.

Filename: `entries/<KIND-ID>-<YYYY-MM-DD>-<slug>.md`.

## Index

| id | date | title |
| --- | --- | --- |
| [E001](entries/E001-2026-09-06-corpus-bit-exact-reproduction.md) | 2026-09-06 | The training corpus reproduces bit-for-bit — and names the commit it was built at |
| [E002](entries/E002-2026-09-06-corpus-census.md) | 2026-09-06 | Corpus census: where 4,527 generated candidates become 2,363 training rows |
| [E003](entries/E003-2026-09-06-mlx-split-recovery.md) | 2026-09-06 | Recovering the unscripted train/valid split from its artifacts |
| [E004](entries/E004-2026-09-06-bits-per-example.md) | 2026-09-06 | How many bits of information are in a training example? |
| [O001](entries/O001-2026-09-06-baseline-filter-never-fires.md) | 2026-09-06 | The "correct twice over" label filter rejected zero examples |
| [O002](entries/O002-2026-09-06-validation-split-in-distribution.md) | 2026-09-06 | The validation split is in-distribution; the loss curve measures memorization |
| [O003](entries/O003-2026-09-06-prompt-skew-mid-run.md) | 2026-09-06 | A prompt edit landed mid-run and opened train/serve skew |
| [O004](entries/O004-2026-09-06-stale-champion-record.md) | 2026-09-06 | The recorded champion is a round-0 number; the shipped prompt scores 13 higher |
| [O005](entries/O005-2026-09-06-factory-docs-drift.md) | 2026-09-06 | The factory README's status checklist has drifted behind the run |
| [H001](entries/H001-2026-09-06-hard-tier-regression.md) | 2026-09-06 | Training on baseline labels will pull the hard tier toward the baseline |
| [H002](entries/H002-2026-09-06-best-checkpoint-is-not-last.md) | 2026-09-06 | The best checkpoint is not the final one |
| [P001](entries/P001-2026-09-06-reproduce-a-dataset.md) | 2026-09-06 | Protocol: reproduce a dataset bit-for-bit before you trust a number about it |
| [P002](entries/P002-2026-09-06-leakage-gate.md) | 2026-09-06 | Protocol: the leakage rule, what the gate checks, and what it does not |

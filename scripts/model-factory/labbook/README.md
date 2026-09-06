# Model Factory Lab Book

Opened 2026-09-06 on Levi's instruction: *"lets start a lab book for the model
factory, year 1 where we record experiments, observations, hypothesis and
processes like this."*

The subject is `scripts/model-factory/` — the pipeline that builds the small
fine-tuned Gemma that runs Fin as the foreman of a software factory. Its
promotion authority is `scripts/model-factory/eval_gate.py` scoring
`evals/tmux-routing/scenarios.json` (51 tiered scenarios) against
`scripts/model-factory/evals-champions.json`. `evals/goals-ledger/` is a
second corpus that the factory trains on but does not yet gate on (see O006).

This is the honest internal record. It is not a marketing surface and it never
softens a result for publication. Anything published externally cites this
book; the link runs one way only.

---

## The two rules that make this a lab book

### 1. Append-only

An entry is dated and never rewritten. A wrong entry is corrected by a **later
entry that names it**, exactly the way you correct a paper notebook: you do not
erase the page, you write the correction on the next page and draw the line
back to the old one.

The format enforces it:

- Each entry is its own file, so any diff to an already-published entry shows
  up in review as the anomaly it is.
- Every entry carries `corrects:` and `superseded-by:` in its front matter.
  The correcting entry fills in `corrects:`; the corrected entry is amended
  **only** to add the `superseded-by:` back-pointer.
- That back-pointer is the **sole permitted modification** to a published
  entry. Fixing a typo is fine before the entry is committed and not after.

**When the rule starts binding, and what the draft phase allows.** The rule
above is written for a book in use. It was broken on day one by the audit
passes that were fixing the book — 23 already-committed entries rewritten in
place, zero correction entries written — and O008 records that in full, with
the counts and the reproducer. The regime, stated so the next person knows
which one they are in:

| phase | in force from | in-place edits |
| --- | --- | --- |
| **draft** | the book's first commit | allowed, and the honest fix: a wrong number is removed, not enshrined. **Never silent** — the entry says it was rewritten and what the earlier text said, so the wrong number stays legible even though the sentence carrying it is gone. |
| **published** | the merge of branch `labbook` into `main`, or the first citation of an entry from outside this directory, whichever comes first | forbidden. "How a correction works" below is the only route, and `superseded-by:` is the only edit. |

And in both phases: **no entry ever asserts compliance it does not have.** O004
was rewritten while containing the sentence "the entry is kept rather than
rewritten"; that is the failure O008 exists to record, and it is worse than the
rewriting.

A superseded entry keeps its id forever. Ids are never reused and never
renumbered, because things outside this directory (commit messages, published
posts, the claims ledger in `content/`) cite them.

### 2. Every number traces to an artifact

A lab book whose numbers cannot be checked is worse than no lab book, because
it launders recollection into fact. Every quantity in an entry cites one of:

| artifact class | how to cite it | durable? |
| --- | --- | --- |
| a commit | short sha + subject, e.g. `d98a031` | yes — in git |
| a file | repo-relative path + line, e.g. `eval_gate.py:110-112` | yes — in git |
| a log line | path + the line quoted verbatim | **no** — see below |
| a reproducing command | the exact command, so a reader re-derives the number | yes |
| an S3 key | full `s3://` URI | yes, if the object survives |
| a **memory note** or a **session transcript** | filename + line, or transcript uuid + ISO timestamp, **and the text quoted verbatim** | **no** — see below |

A file citation is only true of a revision. Prefix it (`main:…`,
`cd64914:…`) whenever the file differs across branches, or when the citing
entry lives on a branch that has edited it — O005's line-anchor note is the
worked example, and it got this wrong twice before it got it right. The same
applies to a **branch name**, which is a moving target and not a citation:
O003's `imac-site:` references drifted within a single afternoon. Pin to a sha.

**`datasets/` and `models/` are gitignored** — `/datasets/` by `a823271`
("Model factory scaffold", 2026-09-05 12:59) and `/models/` plus
`scripts/model-factory/.venv/` by `062f896` ("Ignore the local training venv and
candidate model artifacts", 19:46) — so training logs, checkpoints and corpora
exist only on the iMac's disk. An entry citing them says so with the tag
`local-artifact`. When such a file is the only source for a number, quote the
line verbatim in the entry — the quote may outlive the file.

**Memory notes and session transcripts are the weakest class and are cited
throughout this book.** The "memory note X" citations (E002, E003, H001, H002,
O004, P003, and this README's own provenance section) name files under
`~/.claude/projects/-Users-deepspacenine-forges-levi-fin/memory/`; the
transcript citations (E002, E003) name `…/<uuid>.jsonl` in the directory above
it. Neither is in any git repository — `git -C <that directory> rev-parse`
returns "fatal: not a git repository" — neither has history, memory notes are
rewritten in place, and a reader holding only a clone of this repo can resolve
none of them. Treat both as `local-artifact` and **always quote the line
verbatim**. E003's "Where the 24 GB comes from, and what class of artifact that
is" section is the worked example.

A number that is only remembered is written **UNSOURCED**, in capitals,
together with the artifact that would settle it. Never quietly promote a
memory to a measurement. Two of the entries here rest partly on UNSOURCED
recollections (E003 in particular); saying so is the point.

**Honest negative results are first-class.** An abandoned approach, with the
reason it was abandoned, is among the most valuable things in this book: it is
the only record that stops the same road being walked twice. E001 (a prompt
revision that scored worse and was reverted) and E002 (a base model chosen,
downloaded, smoke-trained and deleted) are here because they failed.

---

## The four entry kinds

| kind | id | what it is |
| --- | --- | --- |
| **EXPERIMENT** | `E001` | a question, a method, a result. Something was run and something was measured. |
| **OBSERVATION** | `O001` | something noticed. No intervention, no manipulation — just a fact about the system that someone had to go and look at. |
| **HYPOTHESIS** | `H001` | a claim not yet tested, stated together with the experiment that would settle it. A hypothesis without a falsifying test does not belong here. |
| **PROCESS** | `P001` | a reusable protocol — the way we do a thing, written down so it is done the same way twice. |

Numbering is **per kind**, monotonic, never reused: `E001, E002, …` and
`O001, O002, …` run independently. Numbering does not restart at a new year;
`year-2/` continues from wherever year 1 stopped, so an id identifies exactly
one entry for the life of **this** book.

**That guarantee does not hold across the branch as it currently stands**, and
the qualifier is not pedantry — see "Provenance of this directory" at the end of
this file. A second, independently-numbered lab book sits at `docs/labbook/` on
the same branch, and **thirteen ids collide with different subjects**. Until the
two are reconciled, a bare `O002` is ambiguous on branch `labbook`.

### Status values

| kind | permitted `status` |
| --- | --- |
| EXPERIMENT | `open` (running or unfinished) · `closed` (result recorded) · `abandoned` (stopped without a result — say why) |
| OBSERVATION | `standing` · `superseded` |
| HYPOTHESIS | `untested` · `testing` · `supported` · `refuted` |
| PROCESS | `active` · `proposed` (written but never yet followed) · `retired` |

A status change is itself an append: write a new entry that records the change
and set `superseded-by:` on the old one. Do not silently edit `status:` in
place — except on an `open` EXPERIMENT, whose closure is the one case where
the original entry is the right place for the result. An open experiment says
so in its `status` and names the event that will close it.

---

## Directory layout

```
scripts/model-factory/labbook/
├── README.md      the conventions (this file)
├── INDEX.md       every entry, chronological, maintained by hand
└── year-1/        entries opened between 2026-09-06 and 2027-09-05
    └── <ID>-<YYYY-MM-DD>-<slug>.md
```

`year-N/` is a filing convenience, not a semantic boundary: year 1 runs from
the day the book opened (2026-09-06) to the day before its anniversary. When
year 2 opens, add `year-2/` and keep writing; ids continue, `INDEX.md` stays
one table.

The date in a filename is the date the entry was **written**, which is not
always the date the work happened. Every entry front matter therefore carries
both `date:` (written) and `occurred:` (when the thing being described
happened). Most of the first day's entries are written 2026-09-06 about work
done 2026-09-05.

---

## Entry template

Copy this into `year-1/<ID>-<date>-<slug>.md`:

```markdown
---
id: E007
date: 2026-09-14          # when this entry was written
occurred: 2026-09-13      # when the work happened; "—" if same as date
kind: EXPERIMENT          # EXPERIMENT | OBSERVATION | HYPOTHESIS | PROCESS
title: One line, specific, no marketing
status: closed
tags: [training, gate, memory]
sources:
  - d98a031 — "RESULTS.md: reworked-prompt scores"
  - evals/tmux-routing/RESULTS.md:25-27
  - "local-artifact: models/candidates/…/train.log:175"
related: [O002, H003]
corrects: []              # ids this entry corrects
superseded-by: null       # filled in later, by hand, when something corrects THIS
---

## Question            (EXPERIMENT / HYPOTHESIS)
## Method              (EXPERIMENT: exactly what was run, reproducibly)
## Result              (EXPERIMENT: numbers in a table)
## What was observed   (OBSERVATION)
## Prediction / Test   (HYPOTHESIS: what would confirm it, what would refute it)
## Protocol            (PROCESS: numbered steps)
## What this does not show
## Open / unsourced
```

Not every heading applies to every kind. `## What this does not show` applies
to all four and is the heading most likely to be the useful one a year later.

**Use that heading verbatim.** In the 20 entries written on day one it appears
as written in 10, is renamed in 9 ("What this run cannot show" E004, "What this
hypothesis is not" H001, "The ceiling this cannot break" H002, "What this
hypothesis does not address" H003, "What this hypothesis does not claim" H004,
"What it does not imply" O001, "What this protocol does not cover" P001, "What
this does not cover" P003, "What this does not do" P004) and is absent from
P002, which uses "Four things the gate does not check". Each variant reads
better in place, and the cost is that the one heading a future reader is told to
rely on cannot be extracted with a grep:

```sh
grep -rL '^## What this does not show' scripts/model-factory/labbook/year-1
```

The day-one entries are left as they are — renaming ten headings would be a
silent rewrite of ten entries for a cosmetic gain, which is the trade O008 is
about. New entries use the exact heading, and a variant belongs as a *second*
heading underneath it, not instead of it.

## How to add an entry

1. Pick the kind and the next free number for that kind — check `INDEX.md`.
2. Write `year-1/<ID>-<YYYY-MM-DD>-<slug>.md` from the template.
3. Every number in it gets a citation or the word UNSOURCED.
4. Add one row to `INDEX.md`. **The index is maintained by hand** — nothing
   generates it, so an entry that is not in it is effectively lost.
5. Commit the entry and the index row together. One entry per commit where
   practical, so `git log` over this directory reads as the lab notebook's own
   chronology.

## How a correction works

Say `E004` records a number that later turns out to be wrong.

1. Write a **new** entry (usually an OBSERVATION) that states the correct
   number, cites the artifact, and explains how the earlier number arose.
2. Set `corrects: [E004]` in the new entry.
3. Edit **only** `superseded-by:` in `E004` to name the new entry. Change
   nothing else in it — not the prose, not the wrong number. The wrong number
   staying visible is what makes the correction readable.

If an entry is wrong in one detail but sound overall, the correcting entry
says so and `E004` keeps `status:` as it was. `superseded-by:` means "read
this alongside", not "ignore".

---

## Provenance of this directory

The location `scripts/model-factory/labbook/` follows the record in the
project memory note `labbook-and-publishing` (2026-09-06), which fixes it
alongside a separate publishing pipeline under `content/`.

A parallel draft of the same book exists on this branch at `docs/labbook/`,
committed the same morning (`4705b67`, 2026-09-06 11:21) by a sibling agent
working from an overlapping set of facts. Its 13 entries are numbered in their
own sequence and **its ids do not correspond to the ids here**.

### The collision, stated exactly

Branch `labbook` carries both books: `4705b67` (`docs/labbook/`, 13 entries) and
`a02cec3` (`scripts/model-factory/labbook/`, 20 entries). **Thirteen ids appear
in both with different subjects** — every id the smaller book uses:

| id | `docs/labbook/` | `scripts/model-factory/labbook/` |
| --- | --- | --- |
| E001 | corpus bit-exact reproduction | router prompt rounds 0-4 |
| E002 | corpus census | base-model selection |
| E003 | mlx split recovery | memory ceiling / grad-checkpoint |
| E004 | bits per example | run 1, the E4B LoRA |
| O001 | baseline filter never fires | zero loss, flat validation |
| O002 | validation split in distribution | stale champion |
| O003 | prompt skew mid-run | three prompts, no parity |
| O004 | stale champion record | late-run loss excursion |
| O005 | factory docs drift | no provenance in verdicts |
| H001 | hard-tier regression | bits per example |
| H002 | best checkpoint is not last | high-information subset |
| P001 | reproduce a dataset | the promotion protocol |
| P002 | the leakage gate | the leakage rule |

Note the crossings, which are what make bare ids actively dangerous rather than
merely ambiguous: the stale champion is `O004` in one book and `O002` in the
other; bits per example is `E004` in one and `H001` in the other; "the best
checkpoint is not the last" is `H002` there and `H003` here.

### The rule until it is reconciled

1. **Cite entries across books by path, never by bare id.** Inside one book, a
   bare id means an entry of that same book — that is how the cross-references
   in all 20 entries here should be read, and it is the only reading under which
   they are correct.
2. **Neither book renumbers.** Ids are never reused and never renumbered (rule
   1); a merge that renumbered one of them would break every cross-reference in
   it and every external citation of it.
3. **`scripts/model-factory/README.md`'s reading list points at both**, so
   neither is orphaned while the question is open.

**Reconciling the two into one canonical location is Levi's call and has not
been made.** It wants making before this branch merges, not after: the longer
both live on `main`, the more outside references accumulate against ambiguous
ids. The location `scripts/model-factory/labbook/` follows the memory note
`labbook-and-publishing`; that is a reason, not a decision.

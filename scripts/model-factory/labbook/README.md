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

**`datasets/` and `models/` are gitignored** (`062f896`), so training logs,
checkpoints and corpora exist only on the iMac's disk. An entry citing them
says so with the tag `local-artifact`. When such a file is the only source for
a number, quote the line verbatim in the entry — the quote may outlive the
file.

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
one entry for the life of the book.

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
working from an overlapping set of facts. Its entries are numbered in their
own sequence and **its ids do not correspond to the ids here** — its `E001`
is a corpus-reproduction entry, this book's `E001` is the router prompt
sweep. Reconciling the two into one canonical location is Levi's call and has
not been made. Until it is, treat `docs/labbook/` as an independent draft and
cite entries by path, not by bare id.

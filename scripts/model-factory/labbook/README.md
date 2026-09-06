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
place at `cdb895a`, zero correction entries written — and O008 records that in
full, with the counts pinned to their commits and the reproducer. A third pass,
the consolidation of two books into this one, did the same at larger scale and
is recorded in O009. The regime, stated so the next person knows which one they
are in:

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

### A count of the book by itself is not evidence

The book is inside the repository it writes about, so a `grep` over the
repository counts the book. A hit count, an exit code and a line number are all
provenance claims, and one that includes this directory measures the hour it was
taken rather than the thing it claims to be about.

Two forms are permitted and nothing else is:

1. **Cite counts of things outside the book.** Exclude this directory from the
   command, with the pathspec written into the entry so a reader runs the same
   thing:

   ```sh
   git grep -n '<pattern>' <rev> -- ':(exclude)scripts/model-factory/labbook'
   ```

2. **When the book itself is the subject** — O008 counting its own rewritten
   entries, or a census of headings across `year-1/` — **pin the count to an
   explicit revision**, because an unpinned count of a living book changes every
   time someone writes in it.

The worked example is O005, which cited "**24 hits**" for
`git grep 'datasets/mlx'` on this branch as evidence that nothing in the factory
references the path. Every one of those hits was a lab-book entry saying so. The
same command at `0fe0883` returns **30**. The arithmetic was never the problem:
the number measured the book, and updating it would only reset the clock. O009
records the sweep that applied this rule to every entry.

### And run it at every revision it names

The rule above says *which* command to cite. This one says what you owe before
citing it, and it exists because the fix for the "24 hits" claim broke this way
within the same commit, and it was the **third** consecutive round in which a
correction to a provenance claim shipped a new provenance error (O010 has the
sequence).

> **A command cited as evidence must be RUN AT EVERY REVISION IT CLAIMS, not
> reasoned about.** "This exits 1 at `X` and at `Y`" is two measurements. Run it
> twice. A single `<rev>`-parameterised command with a list of revisions beside
> it is a claim about each of them separately, and it is not licensed by having
> run any one.

Two corollaries, both learned the hard way:

- **The revisions a claim spans change when history changes underneath it.** The
`0fe0883` grep needed *two* `:(exclude)` pathspecs because two lab books existed
there; the consolidation deleted one book, made one pathspec sufficient *going
forward*, and rewrote the old citation as though the repository had always had
that shape. Do not retrofit today's repository onto yesterday's revision.
- **A branch name is not a revision.** `main` is a moving pointer: it was
`704ab09` while this book was written and is `587fb9a` now, and `git grep
'datasets/mlx' main` changed answer between those two without anyone touching
the factory. Cite the sha. If prose needs the name, give the sha beside it and
say when it was read.

The check that catches this is mechanical: for each command in an entry, run it
at each revision named, paste the exit code and the output, and only then write
the sentence. If a command is expensive to run at four revisions, that is a
reason to cite fewer revisions, not a reason to reason about the fourth.

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

**Instrumentation is not intervention.** An OBSERVATION may import a module,
wrap a function in a counter and run it, provided the wrapper does not change
what the system does — a counting wrapper that calls the original and returns
its value unchanged leaves the output bit-identical, so what is recorded is the
system as it already behaves. What makes an entry an EXPERIMENT is a question
posed in advance and a method built to answer it, not the mere fact that code
was executed. O007 (a read-only counter over the label filter) and E007 (a
census run to answer a stated question) use the same machinery and sit on
opposite sides of that line for that reason. This convention arrived with the
consolidation (O009); it was the deleted book's, and it is the better statement
of the distinction.

Numbering is **per kind**, monotonic, never reused: `E001, E002, …` and
`O001, O002, …` run independently. Numbering does not restart at a new year;
`year-2/` continues from wherever year 1 stopped, so an id identifies exactly
one entry for the life of **this** book.

For one day that guarantee did not hold across the branch: a second,
independently-numbered lab book sat at `docs/labbook/` and thirteen of its ids
collided with ids here while meaning different things. It was consolidated into
this book and deleted on 2026-09-06 — **there is one book, and a bare id is
unambiguous again.** Four of its entries were renumbered into these sequences,
once, at that moment; nothing is renumbered again. O009 carries the id map and
the whole account, and "Provenance of this directory" at the end of this file is
the short version.

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

**Use that heading verbatim.** It is not used consistently, and the census is
pinned to a revision because it is a count of the book by itself (see the rule
above). **At `0fe0883`, across the 21 entries this book then held:** the exact
heading appears in 11, is renamed in 9 ("What this run cannot show" E004, "What
this hypothesis is not" H001, "The ceiling this cannot break" H002, "What this
hypothesis does not address" H003, "What this hypothesis does not claim" H004,
"What it does not imply" O001, "What this protocol does not cover" P001, "What
this does not cover" P003, "What this does not do" P004), and is absent from
P002, which uses "Four things the gate does not check". The four entries the
consolidation brought over from the deleted book (E006, E007, E008, P005) use
their own closing headings and are not counted in those 21.

Do not carry those three numbers forward by hand — re-run the census, which is
the part that does not rot:

```sh
git grep -L '^## What this does not show' <rev> -- scripts/model-factory/labbook/year-1
```

Each variant reads better in place, and the cost is that the one heading a
future reader is told to rely on cannot be extracted with a grep. The existing
entries are left as they are — renaming ten headings would be a silent rewrite
of ten entries for a cosmetic gain, which is the trade O008 is about. New
entries use the exact heading, and a variant belongs as a *second* heading
underneath it, not instead of it.

## Reproduction commands

Write them against a **revision**, never against a worktree that happens to
exist today, and never write output under `/tmp`. `git worktree add
../fin-wt-<purpose> <sha>` and a scratch directory beside the repo; P003:111 has
the rule and E003:136 has the incident that produced it — a `/tmp/fin-wt-train`
worktree wiped by a reboot, which is why some of E003's numbers are UNSOURCED
today. (Both anchors are against `0fe0883`.) This convention arrived with the
consolidation (O009), from the deleted book's README; E006 and P005 are the
entries that follow it most closely.

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

The location `scripts/model-factory/labbook/` follows the record in the project
memory note `labbook-and-publishing` (2026-09-06), which fixes it alongside a
separate publishing pipeline under `content/`. It is also the argument that
settled the consolidation below: **the lab book belongs with the factory it
records.**

### There were two books, and now there is one

A parallel draft of the same book existed on this branch at `docs/labbook/`,
committed the same morning (`4705b67`, 2026-09-06 11:21:40) by a sibling agent
working from an overlapping set of facts — **sixteen minutes** before this
book's first commit, `a02cec3` (11:37:55; the gap is 16m15s). Its 13 entries were numbered in their own sequence and
**every one of its ids collided with an id here, with a different subject behind
it.** The crossings were the dangerous part: the stale champion was `O004` there
and `O002` here; bits per example was `E004` there and `H001` here; "the best
checkpoint is not the last" was `H002` there and `H003` here.

**The two books were consolidated into this one on 2026-09-06 and
`docs/labbook/` was deleted.** Nine of its entries were merged into the entry
here that shared their subject; four were renumbered into this book's sequence
and kept whole:

| `docs/labbook/` | subject | now |
| --- | --- | --- |
| E001 | corpus reproduces bit-for-bit | **E006** |
| E002 | corpus census | **E007** |
| E003 | mlx split recovery | **E008** |
| E004 | bits per example | merged into **H001** |
| H001 | hard-tier regression | merged into **H004** |
| H002 | best checkpoint is not last | merged into **H003** |
| O001 | baseline filter never fires | merged into **O007** |
| O002 | validation split in distribution | merged into **O001** (excursion half → **O004**) |
| O003 | prompt skew mid-run | merged into **O003** |
| O004 | stale champion record | merged into **O002** |
| O005 | factory docs drift | merged into **O005** |
| P001 | reproduce a dataset | **P005** |
| P002 | the leakage gate | merged into **P002** |

**O009 is the full record** — why two books existed, which draft won each merge
and what the other contributed, what a merge cost that a renumber did not, and
the two findings the pass fixed on the way through. Every entry that received
merged content carries a "Merged from two drafts" note naming both original
filenames, so the fact that there were two survives the file that proved it.

The deleted book can still be read as itself at `git show 0fe0883:docs/labbook/`.

### What this changed about the rules

Three of this book's conventions came out of that pass and are stated above
rather than here, because they apply to every future entry and not just to the
merge:

- **A count of the book by itself is not evidence** — rule 2's new subsection.
  It came from O005 citing a hit count that the writing of the book had inflated.
- **Instrumentation is not intervention** — the EXPERIMENT/OBSERVATION line,
  taken from the deleted book's README, which stated it better.
- **Reproduction commands are written against a revision** — also the deleted
  book's, and the reason E006 and P005 read the way they do.

A fourth arrived one round later, from the round that was fixing the first
three:

- **And run it at every revision it names** — rule 2's other new subsection,
  added by O010, because the consolidation's fix for the hit-count above
  asserted an exit code at a revision nobody ran it at. Correcting a provenance
  claim is itself making a provenance claim, and this book has now got that
  wrong three rounds running.

One thing did *not* change, and it is worth saying: ids are still never reused
and never renumbered. The four entries that moved were renumbered exactly once,
at the moment two independent sequences became one, and the map above is
permanent. Nothing here is renumbered again.

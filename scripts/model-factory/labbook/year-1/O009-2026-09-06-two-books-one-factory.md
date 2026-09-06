---
id: O009
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Two lab books existed for one factory — the consolidation, and the id map it needed
status: standing
tags: [meta, conventions, provenance, consolidation]
sources:
  - 4705b67 — "Open the model factory lab book: year 1, day 1" (2026-09-06 11:21:40) — `docs/labbook/`, 13 entries
  - a02cec3 — "Model factory lab book, year 1: the dated record the factory did not have" (2026-09-06 11:37:55) — `scripts/model-factory/labbook/`, 20 entries
  - cdb895a — "Lab book audit pass: correct every number that did not trace to its artifact" — 26 files modified, 0 added
  - 0fe0883 — "Lab book, round 2: fix the anchors that moved and record the rule we broke" — the state both books were in when this entry was written (21 entries here, 13 there)
  - "local-artifact: memory note labbook-and-publishing (2026-09-06) — fixes the location as scripts/model-factory/labbook/ alongside a publishing pipeline under content/"
  - "git log --diff-filter=D --name-only -- docs/labbook — the deleted book, recoverable at 0fe0883"
related: [O008, O010, O001, O002, O003, O005, O007, H001, H003, H004, P002, E006, E007, E008, P005]
corrects: []
superseded-by: O010
---

## What was observed

Two lab books were opened for one factory on the morning of 2026-09-06,
**sixteen minutes** apart, by two agents working from an overlapping set of
facts. Neither knew it was the second.

| | `docs/labbook/` | `scripts/model-factory/labbook/` |
| --- | --- | --- |
| opened | `4705b67`, 11:21:40 | `a02cec3`, **11:37:55** |
| entries at `0fe0883` | 13 | 21 |
| entry format | bold-field header (`- **Kind:**`) | YAML front matter |
| numbering | its own sequence | its own sequence |
| ids colliding with the other book | **13 of 13** | 13 of 21 |

Every id the smaller book used also existed in the larger one, with a different
subject behind it — and the crossings were the dangerous part, not the
duplication: the stale champion was `O004` in one book and `O002` in the other;
bits per example was `E004` in one and `H001` in the other; "the best checkpoint
is not the last" was `H002` there and `H003` here. A bare id on branch `labbook`
did not name an entry.

Both books knew. This book's README carried a section called "The collision,
stated exactly" with the full 13-row table, a rule ("cite across books by path,
never by bare id"), and the note that reconciliation "wants making before this
branch merges, not after: the longer both live on `main`, the more outside
references accumulate against ambiguous ids." The other book's README said the
same thing in fewer words. Neither book could fix it, because the choice of
which location survives was not theirs to make.

**It has now been made: this location wins.** The lab book belongs with the
factory it records, `scripts/model-factory/labbook/` is where the memory note
`labbook-and-publishing` fixes it, and this was already the more complete book —
21 entries against 13, including O008, the entry recording that the append-only
rule was broken on day one. `docs/labbook/` is deleted. This entry is the record
of what that cost and what it moved.

## Why two books existed

Not a merge conflict and not a mistake either agent could have seen. Both were
told to open a lab book for the model factory; both did; nothing in the
repository at 11:21 said one already existed, because the first one was still
being written. The window between the two first commits was **16m15s** —
`4705b67` at 11:21:40 and `a02cec3` at 11:37:55, both `%ad` from `git log`.

The deeper cause is that neither book was reachable from anywhere a second
author would look first. `scripts/model-factory/README.md` gained its "Lab book"
section in `a02cec3` — *after* `4705b67` had already written thirteen entries
somewhere else. A directory nobody links to cannot be found by someone checking
whether it exists.

That is the durable lesson and it is smaller than it sounds: **the index of a
thing has to land before the thing does.** A one-line pointer in the factory
README at 11:20 would have cost nothing and saved this entry.

## The id map

Old id → new id, for every entry of the deleted book. **Nine were merged** into
an existing entry here whose subject was the same; **four were renumbered** and
kept whole. No content was discarded.

| `docs/labbook/` entry | subject | disposition | new id |
| --- | --- | --- | --- |
| `E001-…-corpus-bit-exact-reproduction` | the corpus reproduces from committed source | renumbered | **E006** |
| `E002-…-corpus-census` | 4,527 candidates → 2,363 rows, per class | renumbered | **E007** |
| `E003-…-mlx-split-recovery` | recovering the unscripted train/valid split | renumbered | **E008** |
| `E004-…-bits-per-example` | how many bits are in a training example | merged | **H001** |
| `H001-…-hard-tier-regression` | baseline labels will pull the hard tier down | merged | **H004** |
| `H002-…-best-checkpoint-is-not-last` | the best checkpoint is not the final one | merged | **H003** |
| `O001-…-baseline-filter-never-fires` | the "correct twice over" filter rejected zero | merged | **O007** |
| `O002-…-validation-split-in-distribution` | in-distribution split; zero loss proves nothing | merged | **O001** (its late-run-rise section → **O004**) |
| `O003-…-prompt-skew-mid-run` | a prompt edit landed mid-run | merged | **O003** |
| `O004-…-stale-champion-record` | the champion record is a round-0 number | merged | **O002** |
| `O005-…-factory-docs-drift` | the README checklist has drifted behind the run | merged | **O005** |
| `P001-…-reproduce-a-dataset` | protocol: reproduce a dataset bit-for-bit | renumbered | **P005** |
| `P002-…-leakage-gate` | protocol: the leakage rule and what it misses | merged | **P002** |

The four renumbered entries keep their bodies. Three things about them changed
and are recorded in a note at the top of each: the header block was converted
from bold fields to this book's YAML front matter, the cross-references were
repointed at this book's ids, and — in E008 only — a self-referential grep count
was replaced under the rule below.

**The old ids are dead, not reserved.** `docs/labbook/`'s `E001` and this book's
`E006` are the same entry; `docs/labbook/`'s `E001` is not a thing that exists
any more. Anything outside this book that cited an id of the deleted book —
nothing does, which is the only reason this was cheap — resolves through the
table above.

## What was merged away, pair by pair

For each merged subject: which draft survived, why, and what the other one
contributed. In every case the surviving entry names both original filenames in
a "Merged from two drafts" note, so the fact that there were two is not lost
with the file that proved it.

| subject | survivor | why it won | what the other contributed |
| --- | --- | --- | --- |
| bits per example | **H001** | it is the falsifiable form — refutation criteria, the (corpus, base, tokenizer, code) provenance constraint, the pool-is-durable rule | the four-estimator method, the extra label statistics (2,147 distinct user texts, the 113× repeated label), the account of what the optimizer actually sees, and the reproducer |
| best checkpoint is not last | **H003** | it enumerates what continued training might be doing instead of assuming one mechanism, and carries the statistical-power threshold and the serving confound | the overall-score predictions, the reading of a flat result as corpus saturation, the proof that `gate_sweep.sh` is not on a runnable branch, the 250/500/750 follow-up |
| stale champion | **O002** | the commit-ordering proof, the tier-split re-partition finding, the 12-vs-13 derivation, three unchosen fixes | the residual-miss reading (c01 is the only core blocker) and the check that no re-record has happened (`models/gate-sweep/champion.txt` absent) |
| the leakage rule | **P002** | "Four things the gate does not check", the O007 qualification of the vocabulary claim, the Open items | the abandoned seed-from-the-gate approach that produced the rule, the assertion quoted from source, the runnable detector self-test |
| prompt divergence | **O003** | wider scope: four texts across two branches, the Swift paraphrases, and the branch-is-not-a-revision lesson | the mid-run timeline, the character-level reading of `7a591f4`, the manual pre-gate check command |
| labels are baseline output | **O007** | the caps analysis, the vocabulary-survival measurement, the three consequences, the labeler competence table | the reproducer, the "tripwire not a validator" framing, the instrumentation-vs-intervention rationale |
| hard tier regression | **H004** | it partitions the outcome space into three non-overlapping bands and says what each means for corpus 2 | the evidence for the 3-scenario threshold (`RESULTS.md:48`), the generator's defensive step, the per-checkpoint shape prediction |
| zero loss / in-distribution split | **O001** | it separates what the observation licenses from what it does not, at length | the windowed train-loss table, and its own withdrawal of the "measures memorization" half of its title |
| factory docs drift | **O005** | it treats the drifted checklist as one symptom of a factory that records no provenance at all | two more drift rows, and the argument for why a docs bug belongs in a lab book |

Two subjects that *look* like pairs and were deliberately **not** merged:

- **E007 (corpus census) and O007 (labels are baseline output)** share one table
  — the routing caps — because both were derived from the same instrumentation
  run. Their subjects are different: one is a census of what the generator
  produces, the other is an argument about what the labels are. They now
  cross-reference each other.
- **E005 (the baselines reproduce their eval scores) and E006 (the corpus
  reproduces bit-for-bit)** are both reproduction experiments on different
  artifacts — eval scores versus the training corpus. Nothing overlaps but the
  word.

## The rule this pass adds: a count of the book by itself is not evidence

Three entries cited "**24 hits**" for `git grep 'datasets/mlx'` on branch
`labbook` — this book's O005 in three places, and the deleted book's E003. The
same command at `0fe0883` returns **30**. Nothing about the factory changed; the
count went up because the books kept being written, and every hit was a lab-book
entry discussing the fact that nothing in the factory references the path.

The number was a measurement of the book, taken by the book, cited as if it were
about the factory. Correcting 24 to 30 would have fixed the arithmetic and left
the defect intact — it would rot again on the next commit, including this one.

The rule, now in the README's conventions and applied everywhere in the book:

> **A count of the book by itself is not evidence.** A `grep`, a hit count or an
> exit code cited as a fact about the *system* must exclude the book's own paths
> — `-- ':(exclude)scripts/model-factory/labbook'` — so the number answers the
> question actually asked. When the book itself is the subject, as in O008
> counting its own rewritten entries, the count must instead be **pinned to an
> explicit revision**, because an unpinned count of a living book measures the
> hour it was taken. A command with neither the exclusion nor the revision is
> not a citation.

Swept for other instances: O008's `git grep -c 'superseded-by: null' cdb895a --
scripts/model-factory/labbook/year-1` is pinned to `cdb895a` and is about the
book on purpose — it complies. The same class of rot showed up twice more in
this pass, in line anchors rather than counts: `O002:72-77` and `O001:60-61`
both moved when those entries received merged content, breaking the citations in
P004 and H001. Both were repointed **and** given a `grep` that resolves them at
any revision, which is the form O005's line-anchor note has been prescribing
since the first audit. A number that identifies a location is the same kind of
claim as a number that counts one. The README's census of the `## What this does not
show` heading counted a book that has since grown, so it is now pinned to
`0fe0883` with the reproducer beside it. E003's and E004's log-report counts are
already stated with the offset they were read at, which is the same discipline
applied to a file rather than to a repository.

**Amended by O010.** The replacement this section describes — swapping the "24
hits" row for `git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook'`,
asserted to exit 1 "at `main` and at `0fe0883`" — was **not run at `0fe0883`**.
It exits 0 there, with 11 hits, because `docs/labbook/` still existed at that
revision and the new one-pathspec form excludes only this book. The pass applied
a rule written for the repository it was creating to a citation about the
repository as it had been, and deleted the "**Both qualifiers are load-bearing**"
sentence that made the old form correct. Every site is fixed (O005's table is
now a run matrix, E008 carries the command at each of three revisions), and
O010 is the entry about *why* a correction pass keeps producing this shape.

## A second correction this pass made

O001's closing paragraph asserted that the iteration-1 validation gives "a
corpus-level `bits_base` in its first log line at no cost". Two entries that
cite O001 for that number — E004 and H001 — explicitly withdraw the word
"corpus-level" and state the denominator: one validation pass covers 25 of the
118 rows in `valid.jsonl`, about 870 answer tokens, redrawn per pass, with no
variance estimate. O001 was the source of the phrasing they were correcting and
still carried it. It now states the denominator itself.

## What this entry is, in the book's own terms

O008 exists to record that the append-only rule was broken by the audit passes
that were fixing the book, and to say which regime is in force. This pass is the
third such event and the largest: it **deleted 13 published entries** (nine by
merging their content into another entry, four by moving and renumbering them),
rewrote nine entries of this book in place to receive that content, rewrote two
more for the two findings above, and replaced this book's README section on the
collision with the mapping table above.

Under O008's regime table that is a **draft-phase** action — branch `labbook`
has not merged to `main`, and no entry has been cited from outside the two books
— and it satisfies the two conditions the draft phase carries: it is not silent
(this entry, plus a note in every entry that changed), and no entry asserts
compliance it does not have. The wrong numbers it removed stay legible: 24 is
quoted in O005 beside 30 and the reason it moved, and "corpus-level" is quoted
in O001 beside the denominator it omitted.

It is worth being exact about what was lost anyway, because "nothing was
discarded" is a claim about content and not about form. Thirteen files that
existed and were committed no longer exist. Their prose survives inside other
entries, sometimes reworded to fit; their structure, their headings and their
authorial voice do not. `git show 0fe0883:docs/labbook/` is the only place the
deleted book can still be read as itself, and that is a worse record than not
having needed the merge.

## What this does not show

- **It does not show the merges preserved every nuance.** Nine entries were
  folded into nine others by hand. The claim is that no *fact* and no *citation*
  was dropped; it is not a claim that a sentence-level diff would come out
  empty, and the merged entries are longer and less unified in voice than the
  drafts they came from.
- **It does not settle the append-only question.** O008 does that, and this pass
  is another instance of the same draft-phase behaviour it records, not a
  resolution of it. The rule binds at the merge to `main`; after that a
  consolidation like this one would need thirteen correction entries and would
  not be worth doing, which is the argument for doing it now.
- **It does not show the surviving book is right.** It shows there is one of it.
  Every finding either book recorded is still a finding, and the audit that
  produced this pass found two more.

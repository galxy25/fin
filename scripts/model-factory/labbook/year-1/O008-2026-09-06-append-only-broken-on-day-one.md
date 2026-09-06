---
id: O008
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: The append-only rule was broken on day one, by the audit passes that were fixing the book
status: standing
tags: [meta, conventions, provenance, honesty]
sources:
  - 4705b67 — "Open the model factory lab book: year 1, day 1" (docs/labbook/, 13 entries, 14 files added)
  - a02cec3 — "Model factory lab book, year 1: the dated record the factory did not have" (scripts/model-factory/labbook/, 20 entries added)
  - cdb895a — "Lab book audit pass: correct every number that did not trace to its artifact" (26 files modified, **0 added**; 23 of the 26 are already-published entry files)
  - "git show --name-status cdb895a --format='' | grep -c '^A' → 0"
  - scripts/model-factory/labbook/README.md — rule 1 and "How a correction works"
  - docs/labbook/README.md — the same rule, stated more briefly
related: [O004, O005, P001]
corrects: []
superseded-by: null
---

## What was observed

The book's first rule is append-only. The commit immediately after the book was
written broke it, and no entry said so.

`scripts/model-factory/labbook/README.md` states the rule and its one exception
exactly: every entry carries `corrects:` and `superseded-by:`, a wrong entry is
corrected by a *later* entry that names it, and the `superseded-by:`
back-pointer is *"the **sole permitted modification** to a published entry.
Fixing a typo is fine before the entry is committed and not after."*
`docs/labbook/README.md` says the same thing in fewer words. The procedure has
a name in the README — "How a correction works" — and three numbered steps.

What actually happened:

| commit | entry files added | entry files modified in place | correction entries written |
| --- | ---: | ---: | ---: |
| `4705b67` | 13 (`docs/labbook/`) | 0 | — |
| `a02cec3` | 20 (`year-1/`) | 0 | — |
| `cdb895a` | **0** | **23** (8 in `docs/labbook/entries/`, 15 in `year-1/`) | **0** |

`cdb895a`'s subject line is *"Lab book audit pass: correct every number that did
not trace to its artifact"* — a commit whose whole purpose was correction, which
used the documented correction procedure zero times. Every entry in both books
still reads `corrects: []` and `superseded-by: null`. Nothing in either book
mentions the pass.

Reproduce:

```sh
git show --name-status cdb895a --format='' | awk '{print $1}' | sort | uniq -c
git log --name-status --format='%h %s' -- scripts/model-factory/labbook/year-1/
git grep -c 'superseded-by: null' cdb895a -- scripts/model-factory/labbook/year-1 | wc -l  # 20 of 20
```

**And this pass is the second one.** The commit that ships this entry rewrites
**27 already-published entry files** in place (10 in `docs/labbook/entries/`, 17
in `year-1/`), amends both READMEs and `INDEX.md`, and adds exactly one file:
this entry. That is how every finding in the second audit round was fixed. It is
the same procedure `cdb895a` used, with two differences: every rewritten passage
now names the figure it withdrew and why (so the wrong number stays legible),
and the pass is recorded here instead of being silent. Recording it in the same
entry that criticises the first pass is the only version of this observation
that is not self-serving.

Reproduce the counts for either pass:

```sh
git show --name-status <sha> --format='' | grep -E 'entries/|year-1/' \
  | awk '{print $1}' | sort | uniq -c
```

## Why it happened, and why the rule as written invited it

The rule is right for a lab book in use and wrong for a book being written. On
day one the entries were hours old, unpublished, uncited from outside, and
substantially wrong in ways that traced to sloppy citation rather than to
genuine belief — wrong line numbers, a shift computed against the wrong
revision, figures that did not reproduce from the artifacts printed beside
them. Writing 30 correction entries to fix 30 wrong line numbers would have
produced a book that is mostly errata about itself, and a reader a year later
would have to reconstruct the true anchor by composing three entries.

But "the book was still a draft" is a reason, not a licence, and it does not
excuse the two specific things that went wrong:

1. **The rewrites were silent.** No note in either README, no entry, no line in
   a commit body. A reader running `git log` over the directory — which the
   README's "How to add an entry" step 5 explicitly invites, since one entry per
   commit is supposed to make the log read as the notebook's chronology — finds
   a mass rewrite and no explanation.
2. **One entry asserted the opposite of what it did.** `O004` was rewritten —
   title, opening sentence, the erroneous figure deleted outright — while
   containing the sentence *"The entry is kept rather than rewritten around the
   mistake"*. That is not a draft being tidied; that is a false claim about the
   book's own compliance, in the book. O004 now records this against itself.

The second is the one that matters. A discipline that is quietly suspended is
recoverable; a discipline that is *claimed* while being suspended is worse than
having no rule, because it makes the record actively misleading.

## The rule, restated so it can be followed

Appended to the READMEs alongside this entry:

- **The rule binds from the moment the book is cited from outside itself.**
  Concretely: from the merge of branch `labbook` into `main`. Before that the
  book is a draft and in-place correction is the honest fix — a wrong number is
  removed, not enshrined.
- **A draft-phase rewrite is never silent.** It says, in the entry, that the
  entry was rewritten and what the earlier text said. Every correction in the
  second audit pass does this — each one names the withdrawn figure and why it
  was wrong, so the wrong number stays legible even though the sentence that
  carried it is gone.
- **After the rule binds, the three steps in "How a correction works" are the
  only route,** and the `superseded-by:` back-pointer is the only edit.
- **No entry ever asserts compliance it does not have.** If an entry was
  rewritten, it says so. That is the specific failure this entry exists to
  record.

## What this does not show

- **It does not show any current number in the book is wrong.** The audit passes
  fixed real errors, and the corrected values are the ones that reproduce today.
  The defect is procedural, in how they were fixed and in the silence about it.
- **It does not settle where the book lives.** Two independently-numbered books
  with 13 colliding ids sit on this branch; that reconciliation is Levi's call
  and is still open (README.md, "Provenance of this directory").
- **It does not claim the append-only rule is wrong.** It is the right rule for
  a book that is being read. The error was applying its language to a book that
  was being written, and then not saying which regime was in force.

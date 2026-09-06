---
id: O010
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Three rounds of correcting provenance claims, three new provenance errors — a fix to a citation is itself a citation
status: standing
tags: [meta, conventions, provenance, honesty, method]
sources:
  - "git grep -n 'datasets/mlx' <rev> [-- <pathspecs>] run at 704ab09, 4705b67, a02cec3, cdb895a, 0fe0883, 5305044 and 587fb9a — the full 7x3 matrix is in O005; every cell was executed, none inferred"
  - "git log -1 --format=%ad --date=format:'%Y-%m-%d %H:%M:%S' <sha> for 4705b67, a02cec3, cdb895a, 0fe0883, 5305044, 704ab09, 587fb9a, a823271, d4901d4, d98a031"
  - "git reflog show labbook --date=format:'%Y-%m-%d %H:%M:%S' — 704ab09 labbook@{2026-09-06 11:07:25}: branch: Created from main, which is what fixes what `main` meant while this book was written"
  - 0fe0883:docs/labbook/entries/E003-2026-09-06-mlx-split-recovery.md:13-16 — the deleted draft that said "Both qualifiers are load-bearing"
  - 5305044 — "Lab book consolidation: two books become one, with the id map", the commit that deleted the qualifier while applying the new rule
  - "587fb9a:content/claims-ledger.md — the sibling ledger's §8 entry on a 22-minute bug lifetime stated as 'a day' in five places; verified here with git log -S CARVE_OUT_RE -- content/check-claims.py"
related: [O005, O008, O009, E008, H001, P002, E005]
corrects: [O005, O009, E008, H001, P002, E005]
superseded-by: null
---

## What was observed

Three consecutive rounds of work on this book had, as their whole purpose,
correcting a claim about provenance. **Each one shipped a new claim about
provenance that was false.** Not the same error three times — three different
errors, each introduced by the machinery built to prevent the previous one.

| round | the claim being fixed | the claim the fix introduced | how it was wrong |
| --- | --- | --- | --- |
| 1 — `cdb895a`, the first audit | "`git grep 'datasets/mlx'` exits 1 with no output" (true at `704ab09`, false on this branch) | "a bare `git grep` on `labbook` exits 0 with **24 hits**" | a count of the book taken by the book. True at `cdb895a`; **30** at `0fe0883`, **32** at `5305044`. It moved because the fix was being written |
| 2 — the sibling content ledger, `e84f4fd`…`17c7db1` | a rationale resting on an unchecked README checkbox | "the checker spent **a day** granting its own exemption" | the bug lived **22m17s** (`e84f4fd` 12:44:30 → `17c7db1` 13:06:47). Overstated ~65x (1,440 min ÷ 22.28), in five places. Recorded there, not here, but it is the same failure and it is why this entry says "three" |
| 3 — `5305044`, the consolidation | the "24 hits" count from round 1 | "`git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook'` → exit 1, no output, **at `main` and at `0fe0883`**" | never run at `0fe0883`. It exits **0** there with **11** hits from `docs/labbook/entries/*` — the second book still existed at that revision and the pathspec excludes only the first |

Round 3 is the one this entry is named for, because of one detail: the draft
that the consolidation replaced **had it right**.

## Round 3, exactly

At `0fe0883` the pre-consolidation draft of this subject lived at
`docs/labbook/entries/E003-2026-09-06-mlx-split-recovery.md`, and said:

> *"`git grep 'datasets/mlx' main` exits 1 with no output, and so does `git grep
> 'datasets/mlx' -- ':(exclude)docs/labbook'
> ':(exclude)scripts/model-factory/labbook'` on this branch. **Both qualifiers
> are load-bearing.**"*

The consolidation deleted that file, moved its content into `E008`, and rewrote
the passage under the rule the same pass was adopting — *exclude this
directory*. One pathspec is correct for the repository the consolidation
produced. It is not correct for `0fe0883`, which the rewritten sentence still
cited. The qualifier that said so was deleted in the same edit, and with it the
only warning in the book that the count of lab books had ever been two.

Three sites carried the false form: `O005`'s front-matter source, `O005`'s
command table, and `E008`'s body. `E008`'s **own front matter** carried the
correct two-exclusion form at the same time, so the entry stated two
contradictory results for one question and neither round caught it — a
front-matter `sources:` list and the prose beneath it are the same claim, and
nothing was comparing them.

### The measurements, run

Every cell run on 2026-09-06 after the consolidation, at the revision naming its
row. Exit code first, hit count second:

| revision | bare | `-- ':(exclude)scripts/model-factory/labbook'` | both `:(exclude)` pathspecs |
| --- | --- | --- | --- |
| `704ab09` | **1**, none | **1**, none | **1**, none |
| `4705b67` | 0, 9 | 0, 9 | **1**, none |
| `a02cec3` | 0, 22 | 0, 9 | **1**, none |
| `cdb895a` | 0, **24** | 0, 9 | **1**, none |
| `0fe0883` | 0, **30** | 0, **11** | **1**, none |
| `5305044` | 0, 32 | **1**, none | **1**, none |
| `587fb9a` | 0, 1 | 0, 1 | 0, 1 |

Read down the middle column: the form the consolidation adopted becomes correct
at `5305044` and at no revision before it, because `5305044` is the commit that
deleted `docs/labbook/`.

## The second thing that moved: `main`

The bottom row is a separate failure with the same shape, and no edit to this
book caused it.

`main` is a name, not a revision. `git reflog show labbook` records
`704ab09 labbook@{2026-09-06 11:07:25}: branch: Created from main` — so while
this book was being written, `main` meant `704ab09`, and at `704ab09` the bare
grep genuinely exits 1 with no output. `main` now means `587fb9a`
(2026-09-06 13:38:26), which merged the sibling publishing pipeline, and
`content/claims-ledger.md:416` there quotes `mlx_lm lora --data datasets/mlx` as
evidence for an unrelated claim. So:

```
$ git grep -n 'datasets/mlx' 704ab09
$ echo $?
1
$ git grep -n 'datasets/mlx' 587fb9a -- ':(exclude)docs/labbook' ':(exclude)scripts/model-factory/labbook'
587fb9a:content/claims-ledger.md:416:| RPI-22 | … invoking `mlx_lm lora --data datasets/mlx` | …
$ echo $?
0
```

The **finding** is unaffected — a ledger row quoting a launch script is not a
script that builds `datasets/mlx/`, and no committed thing in the factory
produces it. But the sentence "exits 1 with no output at `main`" became false
between `0fe0883` and now, without anybody touching the factory or the book.
Every `main:scripts/model-factory/README.md:N` anchor in this book was exposed
to the same risk and survived it only by luck: the file is byte-identical at
`704ab09` and `587fb9a` (`diff <(git show 704ab09:…) <(git show 587fb9a:…)` is
empty), so all of them still resolve. O005's line-anchor note is now pinned to
the sha rather than the name.

## The rule this adds

Now rule 2's second subsection in the README:

> **A command cited as evidence must be RUN AT EVERY REVISION IT CLAIMS, not
> reasoned about.** "This exits 1 at `X` and at `Y`" is two measurements. Run it
> twice. A `<rev>`-parameterised command with a list of revisions beside it is a
> claim about each of them separately, and running it at one licenses none of
> the others.

With the two corollaries this round paid for:

1. **The revisions a claim spans change when history changes underneath it.** A
correction pass is exactly the moment this bites, because the pass is *itself*
changing the repository. The consolidation deleted a directory and then
described a revision where that directory existed. When you rewrite a citation,
the question is never "is this true?" — it is "is this true at each revision
this sentence still names, including the ones I am about to make stale?"
2. **A branch name is not a revision.** Cite the sha. If the prose wants the
name, give the sha beside it and say when it was read.

And the meta-rule, which is the actual lesson of three rounds: **a fix to a
provenance claim is a provenance claim, and it deserves the same evidence
standard as the claim it replaces — applied at the moment of writing, not at the
next audit.** Every one of these three errors was introduced by someone who had
just finished reading the rule they went on to break. Knowing the rule is not
the control. Running the command is the control.

## What was corrected in this pass

Provenance errors (round 3's, and one from round 1 that survived it):

| site | was | is | evidence |
| --- | --- | --- | --- |
| `O005` front matter | one `<rev>` pathspec, "exit 1 … at main and at 0fe0883" | the matrix, with the revision-dependence stated | the 7×3 table above |
| `O005` command table | 4 rows, one command per row | 7 revisions × 3 forms, every cell run | same |
| `O005` line-anchor note | "against `main` at `704ab09`" | "against the revision `704ab09`", sha not name, with the byte-identity check | `diff` of the two blobs is empty |
| `O005` shift derivation | `git diff --numstat main labbook` | `git diff --numstat 704ab09 labbook` | both return `31 0` today; the sha is the one that will keep doing so |
| `E008` body | `<rev>` block, "At `main` and at `0fe0883` that exits 1" | three commands, each at a named sha, each run | above |
| `E008` draft table | three drafts | four drafts, the fourth being the consolidation's fix | above |
| `O009` rule section | described the replacement as done | amended to record that it was wrong and how | above |

Timestamps and durations, re-derived from `git log` rather than repeated:

| site | was | is | git |
| --- | --- | --- | --- |
| `O009` table, `a02cec3` | 11:33 | **11:37:55** | `git log -1 --format=%ad a02cec3` |
| `O009` ×2 and `README.md` | "twelve minutes" between the two books' first commits | **16m15s** (sixteen minutes) | 11:21:40 → 11:37:55; 1788719875 − 1788718900 = 975 s |
| `P002` | `a823271`, 2026-09-05 **13:03** | **12:59:51** — the same sha is cited correctly as 12:59 in O002, P001 and P005 | `git log -1 --format=%ad a823271` |
| `E005` | "roughly 20 hours" after `RESULTS.md` | **22h17m** (`d98a031` 2026-09-05 13:08:33 → ~11:26 on 09-06) | `git log -1 --format=%ad d98a031` |
| `H001` | "five minutes before the stated observation and twelve before this book's first commit" | the second half is right (**12m17s**, `d4901d4` 11:25:38 → `a02cec3` 11:37:55) and now says so exactly; the first half named an interval with only one endpoint — no observation time is stated in H001 — and is cut | `git log -1 --format=%ad d4901d4` |

**Every other timestamp and duration in the book was checked the same way and
traces.** The ones re-derived and found correct: `4705b67` 11:21:40; `6b1c95f`
12:17:20; `22005c7` 12:38:52; `f0040f5` 12:46:33; `fcb10b2` 12:54:12; `e7460cd`
13:01:20; `99ed9d9` 13:07:36; `d98a031` 13:08:33; `96ea006` 11:54:00; `8aa690c`
19:26:16; `d9100b6` 08:05:50; `7a591f4` 09:52:18; `e025413` 12:45:28; `b623a50`
12:48:21; `b0f7fea` 13:36:53; `d4901d4` 11:25:38; `b67129f` 12:01:02. And the
derived durations: E001's "51 minutes" across five scored runs (12:17:20 →
13:08:33 = 51m13s); E001's "reverted 6 minutes after" (13:01:20 → 13:07:36 =
6m16s); E006's "20 minutes after `8aa690c`" (19:26:16 → 19:46); E002's "nine
minutes later" (20:06:27 → 20:15:29 = 9m02s); E004's 54,351 s ÷ 3,750 = 14.49
s/iter and 58,289 s ÷ 4,000 = 14.57, and its 65.6-minute span (11:21:20 →
12:26:58 = 65m38s); H002's 60.3 min/250 iters over 14 intervals (50,674 s ÷ 14 =
3,619.6 s) and 60.4 over 15 (54,351 ÷ 15 = 3,623.4), and the ≈18.1 h that H003
rounds to "18 hours"; E005's branch-creation time 11:07, which the reflog
confirms to the second (`labbook@{2026-09-06 11:07:25}`).

## What this does not show

- **It does not show the findings moved.** Nothing in the factory produces
`datasets/mlx/`; the champion is still stale; the gate still records no
provenance. Three rounds of correction have changed the *citations* and not one
*conclusion*. That is worth saying plainly, because an entry this long about
being wrong can read as though the subject matter were in doubt. It is not.
- **It does not show the rule will hold.** The previous two rules were also
written by people who had just been burned, and both were broken by the next
round. The only reason to expect better of this one is that it names an action
(run it) rather than a property (be careful), and an action can be checked in a
diff.
- **It does not show three is the total.** Three is the number of rounds that
have been audited. Rounds 1 and 2 each looked clean when they shipped.

## Open / unsourced

Known and deliberately not fixed in this round, recorded here instead of opening
another one:

1. **`main:…README.md:N` shorthand, 16 sites across `O003` (2), `O005` (8),
`O006` (2), `P001` (1), `P002` (2), `P005` (1).** Every one of them resolves —
the file is byte-identical at `704ab09` and `587fb9a`, verified — and O005's
line-anchor note now declares the pin as a sha. The prefix itself is still a
moving name, and rewriting it in eight files is a mechanical change worth doing
in the next pass that touches those entries, not in this one.
2. **The sibling ledger's own version of this bug, still live.**
`587fb9a:content/claims-ledger.md` §8 says `git log -S CARVE_OUT_RE --
content/check-claims.py` "returns exactly two commits". Run at `17c7db1` it does.
Run at `9e6ceaa` — **the commit that wrote that sentence** — it returns three,
because the same commit reintroduced the token `CARVE_OUT_RE` into
`check-claims.py`'s docstring while narrating the story. Verified here; that file
is on `main` and not this book's to edit, and it is flagged for whoever next
works on `content/`. It is round 2's failure recurring inside round 2's own fix,
which is the strongest evidence available that this shape is structural and not
carelessness.
3. **Nothing compares an entry's `sources:` block against its prose.** Round 3's
error survived because `E008` asserted one thing in front matter and its
contradiction eight lines below. A checker that extracted every command from
every `sources:` list and ran it would have caught rounds 1 and 3 both. There is
no such checker; `content/check-claims.py` is the sibling pipeline's equivalent
and stops at the repository boundary. Cheapest real defence available and
unbuilt.

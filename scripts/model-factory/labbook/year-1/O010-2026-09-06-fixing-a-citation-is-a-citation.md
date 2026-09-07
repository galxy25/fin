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
superseded-by: O013
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
Every `main:` anchor in this book was exposed to the same risk. Round 3's sweep
of that exposure was itself under-counted: it swept only the
`main:scripts/model-factory/README.md:N` anchors and silently omitted the seven
`main:` anchors naming other files. The full census, taken at `59b0515` — the
round-3 tip, the state the sweep was describing — with the pathspec written out
so it reproduces:

```
$ git grep -hoE 'main:[A-Za-z0-9_./-]+\.[a-z]+(:[0-9]+(-[0-9]+)?)?' 59b0515 \
    -- scripts/model-factory/labbook | wc -l
24
$ git grep -hoE 'main:[A-Za-z0-9_./-]+\.[a-z]+(:[0-9]+(-[0-9]+)?)?' 59b0515 \
    -- scripts/model-factory/labbook | grep -v 'README.md' | sort | uniq -c
   1 main:daemon/Sources/FinAgentCore/SessionRouting.swift
   1 main:daemon/Sources/FinAgentCore/SessionRouting.swift:352
   1 main:evals/goals-ledger/run_evals.py:131
   2 main:evals/tmux-routing/run_evals.py:195
   1 main:goals-ledger/run_evals.py:131
   1 main:tmux-routing/run_evals.py:195
```

**24 `main:` anchors, of which 17 name a README and 7 name something else.** The
seven omitted ones were the dangerous half: `scripts/model-factory/README.md` is
the same blob `c2e35895…` at `704ab09`, `587fb9a` and `077d970`, so the README
anchors survived by luck, while `evals/tmux-routing/run_evals.py` genuinely
differs across the branches this book cites — 202 lines on the `main` line of
history, 217 at `cd64914`/`f0ca4af`, 219 at `78e6c36` — and E005 shipped the
wrong line count for it because of exactly this omission. A sweep that excludes
part of its own subject is not a sweep. All 24 are pinned to shas in round 4.

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

## Round 4: the control stopped being editorial

Round 4 audited round 3 and found the same defect again, in four places at once
— including `O003` asserting that the book's `main:` anchors resolved "because
`main` has not moved", in a commit made **12m50s after `main` moved**, while two
other entries in that same commit correctly recorded the move. The book
contradicted itself inside one commit.

That is four rounds. Every round had read the rule; round 3 *wrote* the rule and
broke it in the same commit as writing it. The conclusion is not that the writers
were careless. It is that **"a branch name is not a revision" is not enforceable
by reading**, because a branch citation looks correct at the instant it is
written and is falsified later by someone else's commit, in a file nobody reopens.

So the control is now a program: **`scripts/model-factory/labbook/check_citations.py`**.
It scans every entry plus `README.md` and `INDEX.md` and fails, with `file:line`,
on five rules:

| rule | fires on |
| --- | --- |
| `BRANCH-ANCHOR` | `<ref>:<path>` where `<ref>` is not a 7-40 char hex sha |
| `BRANCH-LOCUS` | "at/on/against `<branch>`" with no sha pinned on the same line |
| `BRANCH-LINE` | a line number stated against a branch name — `` (`main`, line 154) `` |
| `STASIS` | any assertion that a branch "has not moved" / "is unchanged" / "still resolves" |
| `SHA-EXISTS` | a cited sha that `git cat-file -e` cannot resolve |

`--verify-lines` additionally re-derives every `<sha>:<path>:N` against the blob
and re-derives stated line counts; `--fix-suggestions` prints the sha each cited
branch currently resolves to, so pinning is mechanical rather than a research
task; `--self-test` builds a fixture with one planted defect per rule and
asserts each rule fires and that a clean fixture stays clean, so the checker is
itself checked.

Three things it caught that four rounds of human audit had not:

1. **`E005`'s `imac-site` line count.** The book said `run_evals.py` is 217
lines with the exit rule at 210. True at `cd64914` and `f0ca4af`; the tip
`78e6c36` (13:22:14) made it **219 and 212**, 29 minutes before round 3 shipped
the sentence.
2. **`O002`/`P004`/`H003`'s "`gate_sweep.sh` is not on main".** True when
written. At 13:31:14 `919cfcb` put a *different* 140-line `gate_sweep.sh` (blob
`c0c2f72e…`) at that path on the `main` line of history, so the sentence is now
false while the claim it stood for — `d9100b6`'s 115-line script never merged,
never ran — is still true. Three entries said the false version.
3. **Its own miss.** The first version of `BRANCH-LOCUS` did not match
`on **main**`, because markdown emphasis broke the pattern — and `O003`, the
entry the rule exists for, wrote it that way. The self-test now carries a
bolded fixture. A checker is a provenance claim too.

**The waivers are part of the control, not an escape from it.**
`citation-waivers.txt` holds the 14 places a branch name is legitimate, each
keyed by the exact sentence and each carrying one of five permitted reasons
(`quoted-defect`, `asserted-absence`, `shorthand-subject`, `future-state`,
`not-a-git-object`). Keying on text rather than line number means a waiver dies
the moment its sentence is reworded — you cannot inherit an excuse.

What this does **not** do: it does not run the commands in `sources:` blocks
(open item 3 below), and it does not know whether a pinned sha is the *right*
sha. It closes exactly one failure mode, which is the one that recurred four
times.

### The branch moved again while round 4 was pinning it

Not a hypothetical. `main` moved twice more during this pass:

| `main` was | at | what happened |
| --- | --- | --- |
| `704ab09` | 2026-09-06 08:02:48 | the revision this book was written against |
| `587fb9a` | 13:38:26 | moved 12m50s before round 3 committed the claim that it hadn't |
| `077d970` | 13:38:50 | the tip when round 4 began pinning, read 14:05 PDT |
| `b9876c1` | **14:09:09** | `Merge bits-curriculum`, landed mid-pass |

`b9876c1` is the interesting one, because it touched a file this book cites
17 times. `scripts/model-factory/README.md` went from **336 lines to 1,102** —
`git diff --numstat 704ab09 b9876c1 -- scripts/model-factory/README.md` returns
`766 0`, and the first 336 lines are byte-identical, so it is a pure append from
the `bits-curriculum` line of work (`d4901d4` … `a8951f8`).

Two things follow, and they point in opposite directions:

- **Every round-4 citation still resolves exactly**, because they name
`704ab09` and a sha is immutable. Had this pass merely re-checked the `main:`
anchors and left them named `main`, all 17 would now be anchors into a
different, three-times-longer file.
- **They would have survived anyway, by luck, for the third time** — the append
lands past line 336, so every cited line number is unmoved. That is worth
stating plainly rather than claiming a save the evidence does not support. The
argument for pinning has never been that the anchors break often. It is that
whether they broke is not knowable from the citation, and "we got away with it"
is not a property you can check in a diff.

The blob comparison is the whole method, and it takes one command:

```
$ git rev-parse 704ab09:scripts/model-factory/README.md \
                077d970:scripts/model-factory/README.md \
                b9876c1:scripts/model-factory/README.md
c2e35895badcd08e4270ab04f4ac866a76c66554
c2e35895badcd08e4270ab04f4ac866a76c66554
9bb81ef97d62…
```

Same blob at the first two, different at the third. Round 3 asserted this
relationship instead of running it, and got it wrong. Round 4 ran it — and then
made the running of it a `git`-less precondition of committing, because round 4
has no reason to believe it is more careful than rounds 1 through 3.

## What this does not show

- **It does not show the findings moved.** Nothing in the factory produces
`datasets/mlx/`; the champion is still stale; the gate still records no
provenance. Three rounds of correction have changed the *citations* and not one
*conclusion*. That is worth saying plainly, because an entry this long about
being wrong can read as though the subject matter were in doubt. It is not.
- **It does not show the rule will hold.** The previous three rules were also
written by people who had just been burned, and each was broken by the next
round — including this entry's own, broken in the commit that wrote it. That is
the whole reason round 4 stopped writing rules and wrote a program instead. The
checker will hold for the cases it matches and for nothing else; the honest
claim is that one failure mode is now mechanical, not that the book is correct.
- **It does not show three is the total.** Three is the number of rounds that
have been audited. Rounds 1 and 2 each looked clean when they shipped.

## Open / unsourced

Known and deliberately not fixed in this round, recorded here instead of opening
another one:

1. ~~**`main:…README.md:N` shorthand, 16 sites…**~~ **Closed in round 4, and the
count was wrong.** The item deferred the rewrite and, in doing so, stated a
count of the book by the book without pinning it — the exact thing the section
above this one forbids. Re-derived at `59b0515`, the tip it was describing:

```
$ git grep -hoE 'main:(scripts/model-factory/)?README\.md:[0-9]+(-[0-9]+)?' \
    59b0515 -- scripts/model-factory/labbook | wc -l
14
$ git grep -coE 'main:(scripts/model-factory/)?README\.md:[0-9]+(-[0-9]+)?' \
    59b0515 -- scripts/model-factory/labbook
…/O003-…:2   …/O005-…:6   …/O006-…:2   …/P001-…:1   …/P002-…:2   …/P005-…:1
```

**14, not 16, and `O005` had 6, not 8.** The two extra came from counting
`O005`'s two README mentions that carry *no* line number — the "Eval gate"
section reference and the sentence naming the `main:README.md:N` shorthand as a
topic — as though they were `:N` anchors. Round 3 wrote "16" by reading its own
prose rather than running a command, in the entry whose thesis is that you must
run the command. Every one of the 14 is pinned to `704ab09` in round 4.
2. **The sibling ledger's own version of this bug, still live.**
`587fb9a:content/claims-ledger.md` §8 says `git log -S CARVE_OUT_RE --
content/check-claims.py` "returns exactly two commits". Run at `17c7db1` it does.
Run at `9e6ceaa` — **the commit that wrote that sentence** — it returns three,
because the same commit reintroduced the token `CARVE_OUT_RE` into
`check-claims.py`'s docstring while narrating the story. Verified here; that file
is at `077d970` and not this book's to edit, and it is flagged for whoever next
works on `content/`. It is round 2's failure recurring inside round 2's own fix,
which is the strongest evidence available that this shape is structural and not
carelessness.
3. **Nothing runs the commands in an entry's `sources:` block.** Round 3's error
survived because `E008` asserted one thing in front matter and its contradiction
eight lines below. `check_citations.py` now checks that `sources:` entries *cite*
revisions rather than branches, and `--verify-lines` re-derives their line
anchors — which is why round 4 caught `E005` — but it does not execute the
`git grep …` and `shasum …` commands the blocks quote, so a command whose output
has changed still passes. That is the remaining half of this defence and it is
still unbuilt. `content/check-claims.py` is the sibling pipeline's equivalent
and stops at the repository boundary.

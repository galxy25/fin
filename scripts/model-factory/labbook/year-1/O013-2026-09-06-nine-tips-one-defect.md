---
id: O013
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Nine unpinned branch-tip claims, one defect — and why the checker written to catch it did not
status: standing
tags: [citations, provenance, checker, corrections, audit]
sources:
  - "every branch resolved by hand and every command re-run at 2026-09-06 20:52:57 PDT; the resolution script is quoted in full below"
  - 2d5bb29 — "Merge imac-site: resident site installer, and a tmux boundary that is honest about what it is" (committed 2026-09-06 20:27:23)
  - 78e6c36 — "Name your tmux server, or nothing" (committed 2026-09-06 13:22:14)
  - 6ea70e9 — "Lab book round 4: make the branch-citation rule mechanical, not editorial" (committed 2026-09-06 14:24:25)
  - 2d5bb29:scripts/model-factory/labbook/check_citations.py — the checker this entry extends
  - "measured 2026-09-06 21:35 PDT against the checker as `d2f40b0` shipped it and again after widening: the substitution table and the T007 fixture result, both pasted below"
  - "measured 2026-09-06 21:35 PDT over this book's 33 files: 132 prose branch mentions in logical lines, 117 of them with no read declaration — the cost of the structural rule, pasted below"
  - 2d5bb29:scripts/model-factory/labbook/year-1/P001-2026-09-06-promotion-protocol.md:82-84 — the retired sentence, still in the body
  - 2d5bb29:scripts/model-factory/labbook/year-1/O010-2026-09-06-fixing-a-citation-is-a-citation.md:88 — the "now means" sentence
  - 2d5bb29:scripts/model-factory/labbook/year-1/O005-2026-09-06-no-provenance-in-verdicts.md:102 — the table row labelled with a branch name
  - 2d5bb29:scripts/model-factory/labbook/year-1/O005-2026-09-06-no-provenance-in-verdicts.md:211-212 — the "points at … now" sentence
related: [O003, O005, O008, O009, O010, E005, E008, E009, P001, P002]
corrects: [P001, O005, O010, E008, O003]
superseded-by: null
---

## What was observed

Round 4 (O010) made the branch-citation rule mechanical: `check_citations.py`
runs before every commit and fails on any citation that names a branch instead
of a revision. It exited **0** on the merged book.

It exited 0 while the book contained **nine sentences** that make an unpinned or
now-false claim about a branch tip, in **five entries** — including one sentence
that the same commit's E005 explicitly quotes as *retired*, and two inside O010
itself, the entry whose thesis is that a tip is a fact with a timestamp.

A checker that misses the defect it was written for is worse than none, because
its exit code is read as a warrant. This entry does three things: resolves every
one of the nine, works out why each slipped past, and extends the checker so it
fires on all nine.

## Everything resolved, once, with the read time

Every branch below was resolved to a sha and every command re-run at
**2026-09-06 20:52:57 PDT**. A tip is a fact with a timestamp; this is the
timestamp.

| branch | sha, read 2026-09-06 20:52:57 PDT | commit date | subject |
| --- | --- | --- | --- |
| `main` | **`2d5bb29`** | 2026-09-06 20:27:23 | Merge imac-site: resident site installer… |
| `imac-site` | **`78e6c36`** | 2026-09-06 13:22:14 | Name your tmux server, or nothing |
| `labbook` | **`6ea70e9`** | 2026-09-06 14:24:25 | Lab book round 4: make the branch-citation rule mechanical |
| `bits-curriculum` | **`a8951f8`** | 2026-09-06 14:03:24 | Bits curriculum: one parity bound, per token |
| `content-scaffold` | **`9e6ceaa`** | 2026-09-06 13:30:17 | content/: one price for every exemption |

Re-run the resolution rather than trusting the table:

```sh
date '+%Y-%m-%d %H:%M:%S %Z'
for b in main imac-site labbook bits-curriculum content-scaffold; do
  printf "  %-16s %s  %s\n" "$b" "$(git rev-parse --short $b)" \
    "$(git log -1 --format=%ad --date=format:'%Y-%m-%d %H:%M:%S' $b)"
done
```

**The default branch moved three times between round 4 and this reading**:
`b9876c1` → `7fb54b5` (14:49:35, the gate run) → `3ea4a65` (20:27:14, the lab
book merge) → `2d5bb29` (20:27:23, the `imac-site` merge). The lab book, the
gate result and the site work have all landed, which is why several claims below
changed truth value without anyone editing the sentence that carries them.

The count in the README's own census has moved too. Re-run at the same instant:

```sh
git reflog show main --date=format:'%Y-%m-%d %H:%M:%S' | grep -c 2026-09-06   # 11
```

**Eleven, not the eight the README recorded** — and **eight distinct tips from
this book's merge base onward**, not five: `704ab09`, `919cfcb`, `587fb9a`,
`077d970`, `b9876c1`, `7fb54b5`, `3ea4a65`, `2d5bb29`. The README's sentence is
updated in this commit; the number is a count of the repository rather than of
the book, so re-running it is the maintenance the README itself prescribes.

## The nine, each with its correct value

### 1. P001's body contradicts P001's own front matter, in one commit

`2d5bb29:…/P001-2026-09-06-promotion-protocol.md:82-84` still carries, verbatim:

```text
On `imac-site` that file is 217 lines rather than 202 and the same statement
is at line 210
```

The **same commit** carries E005, which quotes that sentence as a *retired
defect* and replaces it with a four-revision table, and P001's own **front
matter** already carries the corrected figures — "the same statement is at 210
of 217 at `cd64914` and `f0ca4af`, and at 212 of 219 at `78e6c36`". One file
disagrees with itself across the front-matter boundary, and with a sibling entry
across the directory.

Re-derived at 2026-09-06 20:52:57 PDT:

```sh
git show <rev>:evals/tmux-routing/run_evals.py | wc -l
git show <rev>:evals/tmux-routing/run_evals.py | grep -n 'core_passed == core_total'
```

| revision | lines | `core_passed == core_total` at |
| --- | ---: | ---: |
| `704ab09` | 202 | 195 |
| `cd64914` | 217 | 210 |
| `f0ca4af` | 217 | 210 |
| `78e6c36` | **219** | **212** |
| `2d5bb29` | **219** | **212** |

So the body sentence has been **false of the `imac-site` tip since 13:22:14**,
and it is false of `2d5bb29` too, which inherited the 219-line file at 20:27:23.
The correct statement, with no branch name in it: *202 lines with the rule at
195 at `704ab09`; 217/210 at `cd64914` and `f0ca4af`; 219/212 at `78e6c36` and
at `2d5bb29`.* P001's front matter was right; its body was never updated to
match.

### 2. O010 contradicts itself inside one file, 187 lines apart

`2d5bb29:…/O010-2026-09-06-fixing-a-citation-is-a-citation.md:88`:

```text
`main` now means `587fb9a` (2026-09-06 13:38:26)
```

That same entry, 187 lines further down, carries a drift table whose last row
records `b9876c1` at **14:09:09** — a tip that had already replaced `587fb9a`
twice over when the entry was committed. The entry contains both, and the
sentence at 88 was false at the moment it was written.

**Correct, read 2026-09-06 20:52:57 PDT: the default branch was `2d5bb29`.**
`587fb9a` is five tips behind it. The sha beside the claim was never the
problem — the sha is real and the commit date is real. The problem is the word
**"now"**, which names a moment the sentence does not record and a reader cannot
check. This is the third time this book has published a "now" about a tip (O003
records the first, shipped at 13:51:16, 29 minutes after the tip it named had
been replaced) and the first time the checker existed and let it through.

### 3. O005's line-anchor note, twice

`2d5bb29:…/O005-2026-09-06-no-provenance-in-verdicts.md:211-212`, inside the
section whose whole subject is *"the sha, not the name"*:

```text
which pointed at `704ab09` while this book was written and points at
`587fb9a` now
```

and `…:102`, a table row labelled:

```text
| `587fb9a` — `main` today |
```

Both were false at commit time — the default branch was `077d970` at 13:38:50
and `b9876c1` at 14:09:09 while round 4 was running — and both are further false
at this reading. **Correct, read 2026-09-06 20:52:57 PDT: `2d5bb29`.**

The row's *measurement* is unaffected: `git grep -n 'datasets/mlx' 587fb9a`
still exits 0 with 1 hit, because `587fb9a` is a sha. Only the caption rotted.
That is the cleanest possible demonstration of the rule — the data was pinned
and survived, the caption was not and did not.

### 4-8. Five more the audit did not find, and the rule does

The four sentences above are what a human audit found by reading. The extended
checker finds five more of exactly the same shape. They are corrected here
rather than left standing, because the point of a census is that it is complete.

**4. `E008:68`** — a table cell asserting a grep result "at" the default branch
"today", pinned to `587fb9a`. Re-run at 2026-09-06 20:52:57 PDT:

```sh
git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook'
```

| revision | exit | hits |
| --- | ---: | ---: |
| `704ab09` | 1 | 0 |
| `587fb9a` | 0 | 1 |
| `2d5bb29` | 0 | **25** |

Still non-empty, but for a different reason and by a factor of 25. The one hit
at `587fb9a` was a prose citation in `content/claims-ledger.md`. The 25 hits at
`2d5bb29` are in six files, and **five of them are inside
`scripts/model-factory/` itself** — `README.md` (9), `run_bits_experiment.sh`
(8), `score_bits.py` (3), `select_curriculum.py` (3),
`tests/test_bits_curriculum.py` (1), plus `content/claims-ledger.md` (1). The
bits-curriculum merge (`b9876c1`, 14:09:09) gave the factory real references to
`datasets/mlx`. **This materially changes O005's central finding**, which was
that nothing in the factory references the path: at `2d5bb29` that is no longer
true.

**5. `O005:235`** — a numstat asserted against a branch name "today". Re-run at
2026-09-06 20:52:57 PDT:

```sh
git diff --numstat 704ab09 <rev> -- scripts/model-factory/README.md
```

| revision | numstat |
| --- | --- |
| `6ea70e9` | `31 0` |
| `2d5bb29` | **`797 0`** |

The coincidence O005 explicitly warned against relying on has ended.
`scripts/model-factory/README.md` is 336 lines at `704ab09`, 367 at `6ea70e9`
and **1,133** at `2d5bb29`. Any README anchor written against the default branch
and below the append point is an anchor into a file three times longer than the
one the number was derived from. O010's "they would have survived anyway, by
luck, for the third time" does not extend to a fourth.

**6. `O005:216`** — an insertion point stated against a branch name rather than
a sha. Re-derived at 2026-09-06 20:52:57 PDT:

```sh
git show <rev>:scripts/model-factory/README.md | grep -n '^## Lab book'
```

`## Lab book` lands at **22** at `6ea70e9` and at **22** at `2d5bb29`. The claim
happens to still hold; it is listed because *whether it holds is not the point*.
It was stated against a moving name, so nobody could have known without running
the command — and the +31 shift the same paragraph describes is +797 at
`2d5bb29`.

**7. `O005:277`** — "moved out from under three of this entry's citations
between `0fe0883` and now". The "now" there meant `b9876c1`. At this reading it
would mean `2d5bb29`, three further tips on, and the count "three" is a count
taken at an unrecorded instant.

**8. `O003:39`** — a claim that the Swift paraphrase differs between two
branches. Resolved at 2026-09-06 20:52:57 PDT:

```sh
git rev-parse <rev>:daemon/Sources/FinAgentCore/SessionRouting.swift
```

| revision | blob |
| --- | --- |
| `704ab09` | `61e68770212c5456999ccc8d79dfaad9043ab572` |
| `7a591f4` | `4fe57911b5d325243f704244fbf4eb6315433374` |
| `78e6c36` | `d8d332b29345435d267646d0241f2b32ac58fa37` |
| `2d5bb29` | `d8d332b29345435d267646d0241f2b32ac58fa37` |

**The two are byte-identical at the tips named**, because the site branch merged
at 20:27:23. The sentence was true of `704ab09` against `7a591f4` and is false
of the tips it names. O003's count of **four** prompt texts is likewise a count
across two branches that are one at this reading, and the same merge moved
`evals/tmux-routing/prompts/router.md` from `c511bab2…` to `936c93e8…` — the
change E009 records as the reason `gate_sweep.sh` would refuse to run from the
tip.

One sentence produces four findings (P001:82 trips `BRANCH-LOCUS`,
`BRANCH-SUBJECT`, `BRANCH-LINE` and `BRANCH-LINECOUNT`), which is a reasonable
amount of noise for a sentence that is wrong four ways. **Nine sentences,
twelve findings.**

Four further sentences fire and are *not* defects: two quotations of a false
sentence that the surrounding paragraph corrects (O003:146, O010:240), one more
quotation of a superseded claim inside O010's own round-by-round table
(O010:30), and O010:85's opening sentence, which names the branch precisely in
order to declare that it is not a revision. Those four are waived
under reasons the book already had — `quoted-defect` and `shorthand-subject` —
and they are the reason a waiver file exists at all. **Thirteen sentences fire;
nine of them are wrong.**

## Why the checker missed them: three gaps, five rules

The checker was not lightly written. It already absorbed markdown emphasis,
skipped fenced blocks, and shipped a self-test. It failed for three reasons that
are each mechanical and each invisible to review.

### Gap A — the pattern was case-sensitive

`LOCUS_RE_TMPL` was compiled without `re.IGNORECASE`, and its preposition
alternation is `at|on|against|from|in|onto|to`, all lowercase. P001's sentence
begins with a capitalised "On". **A sentence-initial preposition — the single
most common place in English prose for a preposition to appear — never
matched.** Demonstrated before anything was changed:

```python
>>> re.search(LOCUS, "but never fail a run. On `imac-site` that file is 217 lines")
None
>>> re.search(LOCUS, "but never fail a run. On `imac-site` that file is 217 lines", re.I)
<re.Match object; span=(21, 36), match='On `imac-site`'>
```

**Fix:** `(?i:at|on|against|from|in|onto|to)` — case-folding the *preposition*
only. Folding the branch alternation too would start matching "Main" and "Head"
as ordinary words.

### Gap B — the scanner was line-oriented; the book is hard-wrapped

Every rule ran against one physical line at a time. The book wraps at ~76
columns, so a single sentence is two or three physical lines, and the checker
never saw the two halves of a claim together:

| claim, as it sits in the file | branch on line | the rest on line |
| --- | ---: | ---: |
| P001's "217 lines … at line 210" | 82 | **83** |
| O005's "points at `587fb9a` now" | 211 | **212** |

`BRANCH-LINE` looks for a line number within 40 characters of a branch name; in
P001 the two are 58 characters apart *and on different physical lines*. It could
not have fired.

**Fix:** prose lines are joined into **logical lines** before the rules run, and
a finding is reported at the physical line its token sits on. Table rows,
headings, blockquotes and horizontal rules stand alone — joining a table would
invent adjacency between rows that are separate claims. `BRANCH-LINE`'s window
widened 40 → 80, since joining puts P001's two halves 58 characters apart.

### Gap C — a branch used as a SUBJECT matched nothing at all

This is the big one, and it is the shape of every named finding.
`BRANCH-LOCUS` requires a **preposition immediately before** the branch name.
All three of these are invisible to it:

```text
`main` now means `587fb9a`
the name `main`, which … points at `587fb9a` now
| `587fb9a` — `main` today |
```

There is no "at", no "on", no "against". The branch is the **grammatical
subject**, and the rule only ever looked for it as an object.

Worse, the two proximity tests that did exist would have passed anyway: a sha
sits *right beside* each of those claims. `sha_pinned_near` asks "is a sha within
70 characters", and the answer is yes for all three. **The sha was never the
missing thing.** What is missing is *when the tip was read*, and a commit date
sitting next to a branch name — `(2026-09-06 13:38:26)` in O010 — is
indistinguishable from a read time to any reader and to any regex.

**Fix, two rules:**

- **`BRANCH-SUBJECT`** closes the grammatical gap: a branch as the subject of a
  tip predicate (`means`, `points at`, `resolves to`, `is`, `was`, `moved to`,
  `tip is`) with no sha in the same clause.
- **`BRANCH-TIP`** carries the temporal load, and it is the rule that actually
  fires on all three sentences above: a branch in the same sentence as `now`,
  `today`, `currently` or `at present` must carry an explicit **read
  declaration** — `read at`, `resolved at`, `when read`, `at the time of
  reading`. **A sha does not discharge it.** The README's own worked example
  already has the right words in it: *"… was `78e6c36` when read at 2026-09-06
  13:22:14"*.

### The limit these two rules still have

The paragraph above says `BRANCH-SUBJECT` "closes the grammatical gap". As
written at `d2f40b0` that overstated what was shipped, and the round-5 audit
showed it by substituting **one word**. Demonstrated against the checker as
`d2f40b0` had it:

```
  O013's own sentence              ['BRANCH-TIP']
  temporal swap: presently         NO FINDING     ← `main` means `587fb9a` presently
  temporal swap: at this writing   NO FINDING
  temporal swap: as things stand   NO FINDING
```

`TIP_PREDICATE` is a closed list of verbs and `TIP_NOW_RE` a closed list of
temporal phrases. The two overlap enough to catch each other's single
substitutions in the *predicate* — swap `means` for `designates` and `now` still
fires `BRANCH-TIP` — but a swap on the temporal side alone had nothing behind
it, and that is a one-word edit to the very sentence this entry is built on.

**What was done:** both lists are wider (`presently`, `nowadays`, `at this
writing`, `as things stand`, `as of this writing`, `at the tip`, `for now` on
the temporal side; `designates`, `equals`, `refers to`, `sits on`, `stands on`
on the predicate side), one guard was added so a *negated* predicate is not read
as a tip claim — O009 says a bare id on one branch did not name the entry the
other book named, which is a claim about what a branch failed to do and not
about where it points — and fixture **`T007-substituted.md`** plants the
substituted wording so the widening cannot silently regress. Re-run:

```
  T007-substituted.md expect ['BRANCH-TIP']
                   got    ['BRANCH-TIP']  PASS
```

**What was not done, and will not be by widening:** a wider closed list is still
a closed list. Both of these still escape, and they were run, not imagined:

```
  verb + temporal both off the list   NO FINDING
     "`main` tracks `587fb9a` as of this afternoon."
  no tip predicate at all             NO FINDING
     "The tip we scored against was `main`, i.e. `587fb9a`."
```

**The structural alternative was measured before being declined.** The rule that
does not depend on vocabulary is: *every prose mention of a branch name must
carry a read declaration in its logical line, unconditionally* — no verb list,
no adverb list. Both counts, run 2026-09-06 21:35 PDT over this book's 33 files:

```sh
# what the branch rules find today (live + waived, every BRANCH-* rule)
35 findings at 27 distinct file:line sites

# what the structural rule would find
prose branch mentions (logical lines, fences skipped):        132
  ...with no read declaration in the same logical line:       117
```

**117 against 27 sites.** In an append-only book that is roughly ninety
additional waiver lines, and a rule that needs a waiver nine times out of ten is
the cry-wolf failure the six precision guards above exist to prevent. So the
structural rule is the right rule and it is not affordable against a book
already written; it would be affordable against a book that adopted it on day
one.

*(The 35/27 above is also the measurement that shows the widening cost nothing:
the checker as `d2f40b0` shipped it produces the same 35 findings at the same 27
sites on the same book. The wider lists fire on `T007` and on nothing that was
already written.)*

**The honest statement of what this checker does**, replacing "closes the
grammatical gap": *`BRANCH-SUBJECT` and `BRANCH-TIP` catch the nine sentences
this book actually shipped, plus the substitutions nearest to them. They are
enumerative, not structural, and a writer who does not know the lists can evade
them without trying.* The checker is a floor under the failure mode that has
recurred five times, not a proof of its absence — and this entry's opening
claim, that "a checker that misses the defect it was written for is worse than
none, because its exit code is read as a warrant", applies to this checker too.

### And one more the rules found on their own

**`BRANCH-LINECOUNT`.** `LINE-CLAIM` re-derives a stated line count only when it
sits beside a `<sha>:<path>` anchor. A count asserted against a **branch** — the
"217 lines" in P001 — was never checked at all, by any rule. It now is.

### Precision work, so the output stays readable

A rule that cries wolf gets skimmed, which is how a checker stops working. Six
guards were added, each in response to a specific false positive the new rules
produced on the existing book, and each named below so the next person can tell
a guard from an exemption:

| guard | why it was needed |
| --- | --- |
| left word boundary `(?<![\w/-])` on every branch token | without it, `labbook` matched inside the worktree path `fin-wt-labbook` |
| `main` as an English adjective | "the main checkout is undisturbed" (P005) and "the … line of history" (O010) are not tip claims |
| table **header** rows exempt | a header cell is a column label; the shas are in the rows beneath it |
| subjunctive guard | "Had this pass left them named … all 17 **would** now be anchors" describes a world that did not happen |
| a clock time is not a line number | the bare-colon arm matched `:07` inside `labbook@{2026-09-06 11:07:25}`; widening the window to 80 made this the largest false-positive class |
| `BRANCH-SUBJECT` pins by **clause**, not by a 70-character window | "what … meant while this book was written" sits 85 characters from the `704ab09` that pins it, inside one citation |

Two deliberate tightenings in the other direction, both forced by line-joining:

- `sha_pinned_near` is now **clamped to the sentence**. An unclamped window
  reaches into the next sentence, and a sha over there pins nothing over here.
  This is not theoretical: it silently disabled the checker's own `BRANCH-LINE`
  fixture the moment joining arrived, which is how it was found.
- `LINE-CLAIM`'s line-count check is scoped to the **sentence** containing the
  anchor rather than the whole line, because a joined paragraph can hold an
  anchor at one sha and a line count about a different revision. Blaming the
  anchor for it would be a false attribution.

## A sixth waiver reason, forced by append-only

Nine of these sentences live in **published** entries. O008's regime says the
published phase forbids in-place edits and `superseded-by:` is the only
permitted change. So the checker will keep firing on them forever, and the book
must reconcile a mechanical rule with an append-only record.

The reconciliation is a sixth waiver reason:

> **`corrected-elsewhere`** — the sentence is a published defect that a later
> entry corrects. Append-only forbids rewriting it; the waiver names the
> correcting entry, so a reader is pointed at the correction instead of past it.

The README says adding a sixth *reason* is a change to the rules and belongs in
an entry rather than a waiver line. This is that entry.

**And it is checked mechanically, not trusted.** A waiver whose reason begins
`corrected-elsewhere` must name an entry id; that entry must exist in `year-1/`;
and its `corrects:` front matter must list the waived entry's id. A waiver that
points nowhere fails the run. That is what stops the sixth reason becoming the
excuse the other five are not.

## Self-tests

Three fixtures were added to `--self-test`, one per gap, each planting the exact
sentence that got through:

| fixture | plants | must fire |
| --- | --- | --- |
| `T004-wrapped.md` | P001's sentence, hard-wrapped across two lines exactly as the book wraps it | `BRANCH-LOCUS`, `BRANCH-LINE`, `BRANCH-LINECOUNT` |
| `T005-subject.md` | the two subject-form claims and the table-row caption | `BRANCH-TIP` |
| `T006-tip-ok.md` | the same three claims written correctly, with "read at" | nothing |
| `T007-substituted.md` | the same claims with one word swapped off each closed list — "means … presently", "designates … at this writing", "sits on … as things stand" | `BRANCH-TIP` |

The third is the one that matters most: a checker that fires on everything
teaches nothing. `T006` proves the rule can be satisfied and shows the exact
wording that satisfies it.

`T007` was added by the round-5 audit and is the one that keeps the widened
lists wide. It is not evidence that the vocabulary gap is closed — see *the
limit these two rules still have*, above — only that the three substitutions
that were demonstrated to escape no longer do.

## What this does not show

- **It does not show the census is complete.** It is complete *with respect to
  these rules*. Nine sentences is what five rules find; a sixth rule would
  probably find more, and the honest reading of "the audit found four and the
  rules found nine" is that reading does not scale, not that nine is the total.
- **It does not show the rules are hard to evade.** They are closed word lists
  and a one-word substitution walked through them until the round-5 audit;
  two demonstrated substitutions still do. The section above states the limit
  and the measured cost (117 findings) of the structural rule that would not
  have it.
- **It does not check that a sha is the *right* sha.** `SHA-EXISTS` proves a sha
  resolves; nothing proves it is the revision the claim is about. The four-way
  contradiction in item 1 involved no unresolvable sha.
- **It does not run the commands.** O010's open item 3 is still open: the checker
  verifies that citations name revisions, not that the commands beside them were
  executed there. Everything under "Everything resolved, once" was run by hand,
  and that is still the only control on that class.
- **It does not fix the entries.** Nine sentences remain wrong in the book, on
  purpose, with waivers pointing here. A reader who lands on P001:82 without
  following the waiver still reads a false sentence. That is the cost
  append-only charges; O008 already argued it is worth paying, and this entry
  makes the size of the bill visible for the first time.
- **A waiver keyed to a snippet dies when the snippet is reworded.** In a book
  that never rewords published text, that safeguard never fires. It protects
  future drafts, not these nine.

## Open

- **Six entries still carry the `<branch>:scripts/model-factory/README.md:N`
  shorthand.** O010 recorded this as open and it stays open; item 5 above raises
  the cost, since that file is 1,133 lines at `2d5bb29` against the 336 the
  anchors were derived from. *Settled by:* a sweep that rewrites the prefix to
  `704ab09:` in all eight files, which `--verify-lines` would then check.
- **O005's central finding needs re-stating, not just annotating.** "Nothing in
  the factory references `datasets/mlx`" is false at `2d5bb29` — 25 hits, 24 of
  them inside `scripts/model-factory/`. That is a change in the world rather
  than an error in O005, and it deserves its own entry.
- **`BRANCH-SUBJECT` and `BRANCH-TIP` are enumerative and a structural rule
  exists.** Requiring a read declaration beside every prose branch mention needs
  no word lists and cannot be evaded by vocabulary; it fires 117 times on this
  book against these rules' 13, which is ~104 waivers append-only would have to
  carry forever. *Settled by:* adopting it in a book that starts with it, or by
  a `--strict` mode that a new entry must pass while the published corpus is
  scanned under the enumerative rules. Neither is done.
- **The checker has no test for the waiver validation it just gained.**
  `--self-test` proves the rules fire; it does not yet plant a
  `corrected-elsewhere` waiver pointing at a non-existent entry and assert that
  loading it fails.

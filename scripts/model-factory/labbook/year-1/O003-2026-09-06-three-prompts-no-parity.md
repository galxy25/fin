---
id: O003
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Four router prompt texts exist across two branches, only one ever scored, with no parity test
status: standing
tags: [prompt, skew, evals, production]
sources:
  - "git show 704ab09:evals/tmux-routing/prompts/router.md | git hash-object --stdin → c511bab2bf99…, 166 lines, 9,272 B (same blob at 077d970)"
  - "git show 7a591f4:evals/tmux-routing/prompts/router.md | git hash-object --stdin → a4f7db7ad695…, 178 lines, 10,040 B (also reachable as cd64914, the imac-site tip when this entry was written; the branch has since moved twice — see the note at the end)"
  - 7a591f4 — "Close the tmux guard's parser holes" (2026-09-06 09:52), NOT an ancestor of 077d970
  - 704ab09:daemon/Sources/FinAgentCore/SessionRouting.swift — promptSection() at 329-409, prompt literal 345-408 (blob 61e68770…, unchanged at 077d970)
  - cd64914:daemon/Sources/FinAgentCore/SessionRouting.swift:353 — the "ONE DELIBERATE EXCEPTION" comment, which exists ONLY on the imac-site line of history (line 376 at both f0ca4af and 78e6c36)
  - daemon/Tests/FinAgentDaemonTests/DaemonRoutingPromptTests.swift — 3 tests, no text comparison
  - scripts/model-factory/build_dataset.py — docstring: "training and inference must see byte-identical framing"; 704ab09:scripts/model-factory/README.md:154
  - "grep -n 'router.md\|prompts/' evals/tmux-routing/router_baseline.py → nothing (the offline baseline does not read the prompt)"
  - "merged from docs/labbook/entries/O003-2026-09-06-prompt-skew-mid-run.md (the parallel book, 4705b67) — see the merge note below"
related: [E001, E004, E006, O002, O005, P002, P005]
corrects: []
superseded-by: O013
---

**Merged from two drafts.** Both books wrote up the `router.md` divergence on
2026-09-06 and both numbered it `O003`: this entry,
`scripts/model-factory/labbook/year-1/O003-2026-09-06-three-prompts-no-parity.md`,
and `docs/labbook/entries/O003-2026-09-06-prompt-skew-mid-run.md`. Same id,
overlapping subject, different scope — this one counts four prompt texts across
two branches and the Swift paraphrases; the other took one of them, `7a591f4`,
and worked out what a mid-run edit does to a candidate. The consolidation (O009)
kept this entry as the wider frame and folded the other's timeline, its
character-level reading of the edit, and its manual pre-gate check into the
sections below. Neither draft contradicted the other.

## What was observed

The router's system prompt exists in **four** texts across two branches, and no
mechanism keeps any of them consistent. (The entry originally counted three; the
Swift paraphrase differs between `main` and `imac-site` too, which is the same
failure the entry is about, so it is counted here.)

| # | where | size | git blob sha1 | scored? |
| --- | --- | --- | --- | --- |
| 1 | `evals/tmux-routing/prompts/router.md` on **main** (round 3, `99ed9d9`) | 166 lines, 9,272 B | `c511bab2bf99495603e199fbfe82a6b9f5c9dab5` | yes — 49/51 (`d98a031`) |
| 2 | the same path at **`7a591f4`** (round 3 + a 2026-09-06 correction; `cd64914` was the `imac-site` tip when this was written) | 178 lines, 10,040 B | `a4f7db7ad695b1d7fd6d0b561ca9d86dc06d94fd` | **never** |
| 3 | `SessionRouting.swift` at **`704ab09`** — a hand-written Swift paraphrase (`promptSection()` 329-409, prompt literal 345-408) | — | `61e68770212c…` | never, and not comparable |
| 4 | the same file at **`7a591f4`**, which that commit also edits (+11/−1) | — | — | never |

Both `router.md` hashes were computed with `git hash-object`; #1 and the round-3
commit `fcb10b2` hash identically, confirming `99ed9d9` was an exact revert
(E001). Only **one** of the four texts has a score attached to it.

### The property the whole builder rests on, and when it broke

`build_dataset.py`'s docstring and the factory README
(`704ab09:scripts/model-factory/README.md:154`) state
the design in one line:

> training and inference must see byte-identical framing

It is enforced by construction — both the eval adapter and the generator build
the system message through `router_llm._system_prompt`, which reads
`evals/tmux-routing/prompts/router.md`. That makes the framing byte-identical
*at a given repo state*, and silently divergent across states. The timeline is
what turns that from a design note into this entry:

| event | when |
| --- | --- |
| corpus built | 2026-09-05 19:46 (`datasets/sft-train-2026-09-05.jsonl` mtime) |
| training started | 2026-09-05 20:15:29 (`train.log:1`) |
| **`router.md` edited (`7a591f4`)** | **2026-09-06 09:52 — mid-run** |
| training still running | iteration 3,775 of 4,490 at the time of writing |

`7a591f4` replaces one sentence and adds a **seven**-line HTML correction
comment: +13/−1 lines overall (4 lines of replacement prose, a blank, the
7-line `<!-- Corrected 2026-09-06: … -->` block, a trailing blank), taking the
file from 9,172 to 9,936 characters. **764 characters**, every one of them
inside the system message of every routing example — which is why regenerating
the corpus at the edited state changes exactly the 890 routing rows and nothing
else (E006).

The failure mode is quiet and asymmetric: nothing errors, nothing warns, the
candidate is simply scored under framing it was not trained on, and any
resulting score change is indistinguishable from a real capability change.

### #2 has never been measured, and says so itself

`7a591f4` added a factual correction to the prompt — the old wording
("sessions you create yourself are added to the registry automatically") was
never true; nothing in the codebase writes the registry. The correction is
right. It also carries its own admission, inside an HTML comment that the model
*sees*, because `_prompt_block()` reads the file raw:

> `<!-- Corrected 2026-09-06: … the offline corpus (router_baseline.py) does not read this file; re-score router_llm.py against it when a local endpoint is up again. -->`

So the moment `imac-site` merges, the gate's candidate side changes under a
champion number that is already stale from the other direction (O002).

### #3 and #4 are production, and they are paraphrases of two different vintages

`SessionRouting.promptSection()` builds the routing prompt the app and daemon
actually send. It is not a copy of `router.md`; it is a hand-maintained
restatement. At `704ab09` the function spans lines **329-409** and the prompt
string literal **345-408**, and it carries this comment at
`704ab09:daemon/Sources/FinAgentCore/SessionRouting.swift:341-344`:

> *"Guidance text tracks evals/tmux-routing/prompts/router.md (round-3 prompt,
> 49/51 on the corpus) — edit THERE first, re-score, then sync here."*

A second comment records a deliberate divergence:

> *"ONE DELIBERATE EXCEPTION: the 'OFF-LIMITS means writing, not looking'
> paragraph is production-only and is NOT mirrored into router.md."*

**That second quote is at line 353 of `cd64914` and exists on that line of
history only.** `git grep -n "DELIBERATE EXCEPTION" 704ab09 --
daemon/Sources/FinAgentCore/SessionRouting.swift` returns nothing; at `cd64914`
it returns line 353. The entry originally attributed it to the file with no
branch qualifier — in an entry whose whole subject is prompt provenance across
branches, which is the error it exists to warn about. The first correction
supplied the branch name, which was still not enough, for the reason recorded
at the end of this entry.

The sharpest evidence for this entry's thesis is on the other side of the same
divergence: **`704ab09:daemon/Sources/FinAgentCore/SessionRouting.swift:352`
carries the sentence `7a591f4` corrected as never-true** — "Sessions you create
yourself are added to the registry automatically". The correction was made in
`router.md` and in the Swift text at `cd64914`; at `704ab09` — and still at
`077d970`, same blob `61e68770…` — the production prompt ships the false
sentence.

### A branch name is not a revision — this entry drifted within the day

Every `imac-site:` citation above has been repinned to a **commit**, because
the branch moved between this entry being written and being re-read the same
afternoon — and then moved twice more while this book was being corrected. The
tip is a fact with a timestamp, so it is recorded as one:

| `imac-site` was | at | subject |
| --- | --- | --- |
| `cd64914` | 2026-09-06 10:29:25 | "Close the tmux guard's wrapper holes" — the tip when this entry was written |
| `3d8fa17` | 11:28:44 | "A private tmux socket, not a parser" |
| `f0ca4af` | 12:22:52 | "Close the four remaining routes off Fin's tmux socket" — the tip named by round 2 |
| `78e6c36` | 13:22:14 | "Name your tmux server, or nothing" — the tip when read, 2026-09-06 14:05 PDT |

An earlier draft of this section said "`imac-site` … is `f0ca4af` now". It was
`f0ca4af` for exactly one hour. Round 3 shipped that sentence at 13:51:16,
**29 minutes after `78e6c36` had already replaced it.** The word "now" is what
made the sentence unrepairable: it named a moment it did not record.

The values themselves, re-derived at each revision:

| citation | at `cd64914` | at `f0ca4af` | at `78e6c36` |
| --- | --- | --- | --- |
| `router.md` blob | `a4f7db7a…`, 178 lines, 10,040 B | `936c93e8…`, 181 lines, 10,228 B | `936c93e8…`, 181 lines, 10,228 B |
| "ONE DELIBERATE EXCEPTION" in `SessionRouting.swift` | line 353 | line **376** | line **376** |

So a reader running the entry's own front-matter command
(`git show imac-site:… | git hash-object --stdin`) gets a hash the entry does
not mention and concludes the record is wrong. It is not wrong; it was
under-specified. **A branch name is a moving target and is not a citation** —
the same class of error as an unqualified line number, one step further out.

The `main:` anchors in this entry have been rewritten to name `704ab09`
directly. They were *checked*, not assumed: `git rev-parse
704ab09:daemon/Sources/FinAgentCore/SessionRouting.swift` and the same at
`077d970` both return `61e68770212c5456999ccc8d79dfaad9043ab572`, so
`promptSection` 329-409, the literal 345-408, the comment 341-344 and the
never-true sentence at 352 hold at both. An earlier draft said the anchors held
"because `main` has not moved" — `main` had moved from `704ab09` to `587fb9a`
12m50s before that sentence was committed, and it has since moved again to
`077d970`. The assertion is deleted. What replaces it is the blob comparison
above, which is what should have been run in the first place.

`daemon/Tests/FinAgentDaemonTests/DaemonRoutingPromptTests.swift` has three
test functions and keys on the string markers `"Session routing:"` and
`"OFF-LIMITS"` only. **No test compares the two texts.** The sync is a
convention held by a comment.

## Why it matters

1. **A published number is only true of one text.** "49/51" belongs to #1
   alone — one of four. Quoting it for production behaviour attributes a score
   to a text that was never scored.
2. **The gate is not hermetic across branches.** Merging a branch changes what
   `eval_gate.py` measures, silently, with no error and no warning.
3. **Run 1's training data froze #1 into 890 system messages.** The corpus was
   written 2026-09-05 19:46 and training started 20:15:29; `7a591f4` landed
   2026-09-06 09:52, mid-run. The candidate has never seen those 764 characters
   and cannot have learned them. **E006 demonstrated the consequence directly**
   (it was the sibling book's experiment before the consolidation): regenerating
   the corpus at `704ab09` reproduces `sha256 9552ac13…` exactly, while
   regenerating at `cd64914` produces `sha256 4f25702b…` —
   **differing in exactly 890 lines**, the routing count, the other 1,473
   byte-identical.
4. **The factory's own claim is narrower than it reads.**
   `scripts/model-factory/README.md` says training and inference "see
   byte-identical framing". True of *eval* inference. Not true of the app or
   the daemon.

## What would fix it

- A test that asserts a documented relationship between `router.md` and
  `SessionRouting.swift` — even just "every rule heading in router.md appears
  in the Swift text, modulo the one recorded exception".
- A prompt hash recorded with every score (O005), so a number cannot be quoted
  against the wrong text.
- Re-scoring #2 before `imac-site` merges.
- **The corpus recording the prompt it was built from.** The factory README
  specifies a per-build manifest — "source list, example counts per track,
  per-split sha256, corpus git commit, build date"
  (`704ab09:scripts/model-factory/README.md:173-175`; the same text is at
  204-206 of the 367-line copy at `59b0515`, see O005's line-anchor note) — and nothing writes
  one. A manifest carrying the sha256 of `prompts/router.md` beside the corpus
  sha256 would turn this entry from archaeology into an assertion the gate could
  make on its own. P005 is the protocol that works around its absence.

Until then the check is manual and belongs in the gate protocol:

```sh
# does the prompt the gate will use still match the one the corpus was built from?
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- evals/tmux-routing/prompts/router.md
# must be at or before the corpus mtime; 99ed9d9 (2026-09-05 13:07) for sha256:9552ac13…
```

## What this does not show

- **It does not show the four texts disagree behaviourally.** Nobody has scored
  #2, #3 or #4. The divergence is textual and unmeasured; it might cost nothing,
  and there is no evidence either way.
- **It does not show `7a591f4` was wrong to land.** The correction it makes is
  factually right and was worth making. The gap is that no re-score followed.

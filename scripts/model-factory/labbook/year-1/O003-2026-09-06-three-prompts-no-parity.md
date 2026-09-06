---
id: O003
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Four router prompt texts exist across two branches, only one ever scored, with no parity test
status: standing
tags: [prompt, skew, evals, production]
sources:
  - "git hash-object evals/tmux-routing/prompts/router.md — main: c511bab2bf99…, 166 lines"
  - "git show imac-site:evals/tmux-routing/prompts/router.md | git hash-object --stdin → a4f7db7ad695…, 178 lines"
  - 7a591f4 — "Close the tmux guard's parser holes" (2026-09-06 09:52), NOT an ancestor of main
  - main:daemon/Sources/FinAgentCore/SessionRouting.swift — promptSection() at 329-409, prompt literal 345-408
  - imac-site:daemon/Sources/FinAgentCore/SessionRouting.swift:353 — the "ONE DELIBERATE EXCEPTION" comment, which exists ONLY on that branch
  - daemon/Tests/FinAgentDaemonTests/DaemonRoutingPromptTests.swift — 3 tests, no text comparison
related: [E001, O002, O005, E004]
corrects: []
superseded-by: null
---

## What was observed

The router's system prompt exists in **four** texts across two branches, and no
mechanism keeps any of them consistent. (The entry originally counted three; the
Swift paraphrase differs between `main` and `imac-site` too, which is the same
failure the entry is about, so it is counted here.)

| # | where | size | git blob sha1 | scored? |
| --- | --- | --- | --- | --- |
| 1 | `evals/tmux-routing/prompts/router.md` on **main** (round 3, `99ed9d9`) | 166 lines, 9,272 B | `c511bab2bf99495603e199fbfe82a6b9f5c9dab5` | yes — 49/51 (`d98a031`) |
| 2 | the same path on **`imac-site`** (round 3 + a 2026-09-06 correction, `7a591f4`) | 178 lines, 10,040 B | `a4f7db7ad695b1d7fd6d0b561ca9d86dc06d94fd` | **never** |
| 3 | `SessionRouting.swift` on **main** — a hand-written Swift paraphrase (`promptSection()` 329-409, prompt literal 345-408) | — | — | never, and not comparable |
| 4 | the same file on **`imac-site`**, which `7a591f4` also edits (+11/−1) | — | — | never |

Both `router.md` hashes were computed with `git hash-object`; #1 and the round-3
commit `fcb10b2` hash identically, confirming `99ed9d9` was an exact revert
(E001). Only **one** of the four texts has a score attached to it.

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
restatement. On `main` the function spans lines **329-409** and the prompt string
literal **345-408**, and it carries this comment at `main:341-344`:

> *"Guidance text tracks evals/tmux-routing/prompts/router.md (round-3 prompt,
> 49/51 on the corpus) — edit THERE first, re-score, then sync here."*

A second comment records a deliberate divergence:

> *"ONE DELIBERATE EXCEPTION: the 'OFF-LIMITS means writing, not looking'
> paragraph is production-only and is NOT mirrored into router.md."*

**That second quote is on `imac-site` only, at line 353.** `git grep -n "DELIBERATE
EXCEPTION" main -- daemon/Sources/FinAgentCore/SessionRouting.swift` returns
nothing; on `imac-site` it returns line 353. The entry originally attributed it
to the file with no branch qualifier — in an entry whose whole subject is prompt
provenance across branches, which is the error it exists to warn about.

The sharpest evidence for this entry's thesis is on the other side of the same
divergence: **`main:daemon/Sources/FinAgentCore/SessionRouting.swift:352` still
carries the sentence `7a591f4` corrected as never-true** — "Sessions you create
yourself are added to the registry automatically". The correction was made in
`router.md` and in the Swift text on `imac-site`; on `main` the production prompt
still ships the false sentence.

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
   and cannot have learned them. A sibling survey demonstrated the consequence
   directly: regenerating the corpus at main (`704ab09`) reproduces
   `sha256 9552ac13…` exactly, while regenerating at the `imac-site` checkout
   (`cd64914`) produces `4f25702b…` — **differing in exactly 890 lines**, the
   routing count, the other 1,473 byte-identical.
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

## What this does not show

- **It does not show the four texts disagree behaviourally.** Nobody has scored
  #2, #3 or #4. The divergence is textual and unmeasured; it might cost nothing,
  and there is no evidence either way.
- **It does not show `7a591f4` was wrong to land.** The correction it makes is
  factually right and was worth making. The gap is that no re-score followed.

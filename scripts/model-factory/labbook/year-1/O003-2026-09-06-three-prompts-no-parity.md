---
id: O003
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Three router prompts exist in three places, one of them never scored, with no parity test
status: standing
tags: [prompt, skew, evals, production]
sources:
  - "git hash-object evals/tmux-routing/prompts/router.md — main: c511bab2bf99…, 166 lines"
  - "git show imac-site:evals/tmux-routing/prompts/router.md | git hash-object --stdin → a4f7db7ad695…, 178 lines"
  - 7a591f4 — "Close the tmux guard's parser holes" (2026-09-06 09:52), NOT an ancestor of main
  - daemon/Sources/FinAgentCore/SessionRouting.swift:325-400 — the production paraphrase
  - daemon/Tests/FinAgentDaemonTests/DaemonRoutingPromptTests.swift — 3 tests, no text comparison
related: [E001, O002, O005, E004]
corrects: []
superseded-by: null
---

## What was observed

The router's system prompt exists in three texts, and no mechanism keeps them
consistent.

| # | where | size | git blob sha1 | scored? |
| --- | --- | --- | --- | --- |
| 1 | `evals/tmux-routing/prompts/router.md` on **main** (round 3, `99ed9d9`) | 166 lines | `c511bab2bf99495603e199fbfe82a6b9f5c9dab5` | yes — 49/51 (`d98a031`) |
| 2 | the same path on **`imac-site`** (round 3 + a 2026-09-06 correction, `7a591f4`) | 178 lines | `a4f7db7ad695b1d7fd6d0b561ca9d86dc06d94fd` | **never** |
| 3 | `SessionRouting.swift:325-400` — a hand-written Swift paraphrase | — | — | never, and not comparable |

All three hashes were computed today with `git hash-object`; #1 and the
round-3 commit `fcb10b2` hash identically, confirming `99ed9d9` was an exact
revert (E001).

### #2 has never been measured, and says so itself

`7a591f4` added a factual correction to the prompt — the old wording
("sessions you create yourself are added to the registry automatically") was
never true; nothing in the codebase writes the registry. The correction is
right. It also carries its own admission, inside an HTML comment that the model
*sees*, because `_prompt_block()` reads the file raw:

> `<!-- Corrected 2026-09-06: … the offline corpus (router_baseline.py) does not read this file; re-score router_llm.py against it when a local endpoint is up again. -->`

So the moment `imac-site` merges, the gate's candidate side changes under a
champion number that is already stale from the other direction (O002).

### #3 is production, and it is a paraphrase

`daemon/Sources/FinAgentCore/SessionRouting.swift:325-400` builds the routing
prompt the app and daemon actually send. It is not a copy of `router.md`; it is
a hand-maintained restatement, with one deliberate divergence recorded in its
own comment:

> *"Guidance text tracks evals/tmux-routing/prompts/router.md (round-3 prompt,
> 49/51 on the corpus) — edit THERE first, re-score, then sync here."*
> *"ONE DELIBERATE EXCEPTION: the 'OFF-LIMITS means writing, not looking'
> paragraph is production-only and is NOT mirrored into router.md."*

`daemon/Tests/FinAgentDaemonTests/DaemonRoutingPromptTests.swift` has three
test functions and keys on the string markers `"Session routing:"` and
`"OFF-LIMITS"` only. **No test compares the two texts.** The sync is a
convention held by a comment.

## Why it matters

1. **A published number is only true of one text.** "49/51" belongs to #1
   alone. Quoting it for production behaviour attributes a score to a text that
   was never scored.
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

- **It does not show the three texts disagree behaviourally.** Nobody has
  scored #2 or #3. The divergence is textual and unmeasured; it might cost
  nothing, and there is no evidence either way.
- **It does not show `7a591f4` was wrong to land.** The correction it makes is
  factually right and was worth making. The gap is that no re-score followed.

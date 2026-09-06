---
title: "<Say what the reader can now do, in their words>"
kind: feature-announcement
status: draft            # draft | review | approved | published
audience: "<who this is for: Fin users on iPhone; developers evaluating Fin; TestFlight testers>"
claims: []               # e.g. [FK-01, FK-02] — ids in content/claims-ledger.md
labbook: []              # lab-book entry ids this cites. If writing one of these
                         # pieces makes you want a number the book does not have,
                         # README.md §1's four conditions govern the entry you
                         # write: from the run's own outputs, dated today, marked
                         # retrospective, and saying that a draft prompted it.
                         # The book never gets written to suit a post.
channel: blog            # blog | app-store-release-notes | testflight-whats-new | social
date: YYYY-MM-DD
author: "<who wrote it>"
approved_by: ""          # Levi, in his own words, before this leaves review/
published_at: ""         # ISO date + the URL it went out at
---

<!--
FEATURE ANNOUNCEMENT — a user-visible capability that has SHIPPED.

Before writing, decide which kind of claim this piece actually makes:
  capability   = the code is on main. Cite the commit.
  availability = a user can do it right now. Cite the BUILD NUMBER.
Announcing a capability in availability voice is the most common way this
template gets someone in trouble. If there is no build, write it as capability
("this is in Fin now") and do not say "available today".

Length: 400-900 words. Longer than a release note, shorter than a result post.
-->

# <Title: what the reader can now do>

<!--
LEAD (1 short paragraph). What can somebody do today that they could not do
before? In their language, not the codebase's. No preamble, no "we're excited".

Test: if you deleted every other paragraph, would this one still be useful?
-->

## Why it exists

<!--
The problem, concretely, from the user's side. A real friction: what did they
have to do instead, and what did it cost them?

Do NOT invent a user or quote one who does not exist (STYLE.md §2). Describe
the situation, not a persona.

Connect to the frame (README.md §6). Levi's framing for Fin is "a terminal
agent with a voice interface and resilient distributed decentralized consensus
cloud brain" — ledger row CB-4, kind `framing`.

REINFORCE it; do not paste it. The directive asks that copy reinforce the frame
and not dilute it, which is a direction, not a sentence to copy — and four of
its words (resilient, distributed, decentralized, consensus) describe machinery
with no capability row behind it, so they are never asserted as description in
Fin's own voice. Quote the sentence only with attribution to Levi. The short
form for running prose is CB-5.

A feature post should make one of those pillars more true, and the reader
should be able to feel which one. The way to reinforce the frame is to say what
Fin actually does.
-->

## How it works

<!--
Enough mechanism that a reader can predict the behavior. Two or three
paragraphs.

Rules:
- No infrastructure names (README.md §6). "A cloud computer", "the Mac in your
  study", "Fin's computers" — never the service that runs them.
- One Fin. Never imply the user is picking between agents or managing bodies.
- Name the guardrail as part of the feature, not as a caveat: what Fin does NOT
  touch, and what it asks about instead.
-->

## What it does when it is wrong

<!--
REQUIRED SECTION. Fin acts on real machines; a reader deserves an accurate
model of the failure case.

Answer three things:
  - What does the wrong outcome look like?
  - How does the user notice?
  - What can they do about it?

If the honest answer is "we do not know yet", say that. Do not skip the
section — an announcement without it reads as a promise of infallibility, and
STYLE.md §3 forbids that.
-->

## Getting to it

<!--
Where it is in the app, in the fewest words. Platform availability, exactly:
if it is iPhone and Mac but not Apple TV, say so.

This paragraph is almost always an AVAILABILITY claim. It needs a build number
in the ledger.
-->

---

## Claims in this piece

<!--
Every claim id from the front matter, with its sentence, so a reviewer can
check this section against content/claims-ledger.md without switching files.
Delete the example row.
-->

| id | sentence | kind | evidence |
|---|---|---|---|
| XX-01 | "<exact sentence from the piece>" | capability | `<commit sha>` |

## Pre-flight

- [ ] Every factual sentence has a ledger row, and every row is `verified`
- [ ] The title has a ledger row like any other sentence
- [ ] Every number carries model + prompt revision + corpus + tiering (STYLE.md §4)
- [ ] Guardrails are written as decisions Fin makes, never as interlocks
      ("Fin asks you to register it" — never "Fin only touches…", never
      "Fin cannot…"). STYLE.md §3, and claims-ledger.md §7 `CB-1`
- [ ] No infrastructure names anywhere in the reader-facing text
- [ ] "What it does when it is wrong" is written and specific
- [ ] No invented quotes, no competitor mentions, no unfalsifiable superlatives
- [ ] Availability sentences cite a build number, not a commit
- [ ] Reinforces the product framing rather than diluting it
- [ ] **Levi has approved this piece, in his own words** — no agent publishes

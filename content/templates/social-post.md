---
title: "<internal label — not the post text>"
kind: social-post
status: draft            # draft | review | approved | published
audience: "<who scrolls past this>"
claims: []               # yes, short posts need ledger rows too
labbook: []
channel: social
date: YYYY-MM-DD
author: "<who wrote it>"
long_form: ""            # path to the piece this points at, if any
approved_by: ""
published_at: ""
---

<!--
SOCIAL POST — short form.

Short form is where honest work goes wrong, because the qualifiers do not fit
and the number does. So this template has one hard rule, and it is not
negotiable:

  ┌──────────────────────────────────────────────────────────────────────┐
  │ THE HARD RULE                                                        │
  │                                                                      │
  │ A social post carries the SAME qualifiers as the long form —         │
  │ model, prompt revision, corpus, tiering — or it carries NO NUMBER    │
  │ AT ALL.                                                              │
  │                                                                      │
  │ There is no third option. Not "49/51 (details in the post)". Not     │
  │ "~96%". Not "nearly perfect". A number stripped of the thing that    │
  │ makes it mean something is not a shortened claim, it is a            │
  │ different and false one.                                            │
  └──────────────────────────────────────────────────────────────────────┘

Why this rule and not a softer one: the repo's own example is that the SAME
untuned model scores 36/51 and 49/51 depending only on the prompt. A bare
"49/51" attributes a prompt's gain to a model. Nobody who reads it, quotes it,
or screenshots it will ever see the correction.

When the qualifiers do not fit, the working move is to post the SHAPE of the
finding and link the long form:

  "Same model, same corpus, a rewritten prompt closed most of the gap — and
   the next round broke three things it had already fixed. The rounds, the
   regressions and the two it still gets wrong: <link>"

That post has no number in it at all, it is true, and the see-saw is more
interesting than the score.

The near-miss to watch for: "13 more of 51 scenarios right" reads like a
shape and is a number — two of them. A bare delta is exactly what gets
screenshotted without its link, and "51" without the 26/25 split is the
tiering deleted. If a digit is in the post, the four qualifiers are in the
post. There is no shape-shaped exemption.

Also: a claim is a claim at any length. Every assertion below gets a ledger
row, exactly as it would in a 900-word post. Short does not mean unaudited.
-->

## Post text

<!--
The literal characters that go out. Nothing else in this file gets posted.
Write it here so the ledger can quote it verbatim.

Style (STYLE.md): plain, specific, no emoji, no hype, no thread-bait, no
invented quotes, no competitor mentions. If it would survive on a competitor's
account unchanged, it says nothing.

Keep the platform's limit in mind and write to two-thirds of it.
-->

```
<the exact post text>
```

**Link:** `<url of the long form, or none>`

<!--
If there is an image or screenshot: it is subject to every rule the text is.
A screenshot of a results table must show the qualifying columns, not a
cropped headline number. A screenshot of the app must be of a real build, not
a mockup, unless it is labeled as a mockup in the image itself.
-->

**Media:** `<path, or none>` — <what it shows, and which build/run it is from>

---

## Claims in this post

| id | sentence | kind | evidence |
|---|---|---|---|
| XX-01 | "<exact sentence from the post text>" | performance | `<path @ sha>` |

## Pre-flight

- [ ] **The hard rule:** full qualifiers, or no number. Check the post text
      again, right now, for a stray digit
- [ ] No percentage standing in for a fraction; no "~", "nearly", "up to"
- [ ] Every assertion has a `verified` ledger row
- [ ] The linked long form actually contains the qualifiers, and it is published
- [ ] Media shows a real build or a real run, and is not cropped past its
      qualifiers
- [ ] Reads as one Fin; no infrastructure names
- [ ] No emoji, no hype, no competitor mention, no invented quote
- [ ] **Levi has approved this exact text** — an agent never posts, and never
      "just retweets"

---
title: "<Build NN — one line>"
kind: release-note
status: draft            # draft | review | approved | published
audience: "TestFlight testers | App Store users"
claims: []               # every line in the note that asserts something
labbook: []
channel: app-store-release-notes   # or testflight-whats-new
date: YYYY-MM-DD
author: "<who wrote it>"
build: ""                # REQUIRED: the App Store Connect build number
platforms: []            # [ios, macos, tvos, visionos] — exactly what this build covers
approved_by: ""
published_at: ""
---

<!--
RELEASE NOTE — what changed in a build, in App Store / TestFlight voice.

Every line here is an AVAILABILITY claim: a reader can open the app and check
it. So the ledger evidence for these rows is the BUILD NUMBER, not a commit.
A change that is on main but not in this build does not appear in this note.

Hard limits:
  - App Store "What's New": 4000 characters, but aim for under 500. Nobody
    reads a scroll.
  - TestFlight "What to Test": short, and it should say what you want tested,
    not just what changed.
  - Fin ships as a universal purchase (app id 6801892480, bundle
    dev.levischoen.fin). If a change lands on only some platforms, say which.

The signing, keychain, build-number and upload mechanics are NOT here: the
`apple-publish` skill owns them. This file is only the words.

Submission still waits for Levi's explicit word (README.md §4).
-->

# Build <NN>

<!--
Optional one-line framing sentence, only if the build has a theme. Skip it for
a maintenance build; a forced theme reads as filler.

If it is there, it should sound like the product: a terminal agent you talk to,
one Fin across your computers.
-->

**New**

<!--
2-5 bullets. Each one: what the user can now do, in their words. Start with a
verb where you can.

  - Ask Fin to do something with your voice and hear the answer back.
  - Give Fin a key to a computer from inside the app.

Not:
  - Implemented model-invoked notify tool via control-plane APNs path.

No infrastructure names, ever (README.md §6). No version numbers of internal
components. No "under the hood" paragraphs — if the user cannot see it, it is
not a release note line.
-->

- <line>

**Fixed**

<!--
Only bugs a user could have hit and would recognize. Describe the symptom they
saw, not the defect we found.

  Good: "Fin no longer replays old messages after it restarts."
  Bad:  "Fixed ledger high-water seeding on first run."

If there is nothing user-visible to say, delete this heading rather than
padding it.
-->

- <line>

**Known issues**

<!--
Optional but strongly encouraged for TestFlight. Testers who know the sharp
edges file better reports and trust the build more. One line each, with what to
do instead if there is a workaround.
-->

- <line>

---

## Claims in this note

| id | sentence | kind | evidence |
|---|---|---|---|
| XX-01 | "<exact line as it appears in the note>" | availability | build `<NN>`, App Store Connect app id 6801892480 |

## Pre-flight

- [ ] Every line is true of **this build**, verified against the build number
- [ ] Platform coverage stated where it is not all platforms
- [ ] No infrastructure names, no internal component names, no code identifiers
- [ ] No numbers unless they carry their qualifiers (they rarely fit — omit)
- [ ] No guardrail written as an interlock (STYLE.md §3); a note line saying
      what Fin will not touch describes a decision, not a mechanism
- [ ] Fixed-lines describe symptoms, not defects
- [ ] Reads as one Fin across the user's computers
- [ ] Under the character limit for the channel
- [ ] **Levi has explicitly approved this submission** — the same gate as every
      App Store / TestFlight submission in this repo; see the `apple-publish`
      skill for the mechanics, and note that the mechanics are not the approval

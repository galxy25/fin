# content/ — Fin's external writing

Blog posts, marketing posts, release notes, and social copy about Fin: the
features it ships and the results it measures.

This directory is the **outward** artifact. It has exactly one counterpart:
the model-factory **lab book** at `scripts/model-factory/labbook/`, which is
the **inward** artifact. Keeping them separate is the point of the whole
structure, so it is the first rule below and every other rule serves it.

---

## 1. Two artifacts, one direction of travel

| | lab book (`scripts/model-factory/labbook/`) | content (`content/`) |
|---|---|---|
| audience | us, and whoever audits us later | users, developers, App Store reviewers, the public |
| form | append-only entries: EXPERIMENT / OBSERVATION / HYPOTHESIS / PROCESS | drafts, release notes, posts |
| obligation | be complete and honest, including negative results | be *true*, be clear, and be traceable back to the book |
| edits | append a correcting entry; never rewrite history | drafts are edited freely until published |
| failures | kept, in full, forever | may be omitted, but never contradicted |

**The one-way link: published work CITES the book. The book never softens for
publication.**

Concretely:

- A post may quote a lab-book entry. A lab-book entry never quotes a post.
- If a post needs a number the book does not have, the fix is to run the
  measurement and write the entry — not to estimate in the post.
- If an experiment fails, the book records the failure and the post about that
  work is either cancelled or rewritten around what was actually found. The
  book does not get a friendlier second version.
- If a published claim later turns out wrong, the correction starts in the
  book (an entry saying what was wrong and how we know), and the post is
  amended or retracted from there.
- Nothing in `content/` is ever an input to a decision about the model. The
  book is the record; this is the retelling.

A marketing surface that can edit the record is not a record. A record that
gets written with an audience in mind is not a record either. That is why they
are two directories with a wall between them.

---

## 2. Lifecycle

```
idea  ──▶  drafts/  ──▶  claims audit  ──▶  review/  ──▶  approval  ──▶  published/
                              │                                │
                              └── every claim gets a row  ──────┴── Levi's explicit word
                                  in content/claims-ledger.md       (see §4)
```

| stage | where it lives | what has to be true to leave it |
|---|---|---|
| **idea** | a line in a draft's front matter, or nowhere | somebody wants it written |
| **draft** | `content/drafts/<date>-<slug>.md`, `status: draft` | the piece says something specific and every factual sentence has a candidate source |
| **claims audit** | `content/claims-ledger.md` | every external claim in the piece has a ledger row naming its evidence, and each row has been checked against the artifact by a human or an agent who opened the artifact |
| **review** | move to `content/review/`, `status: review` | audit complete; ledger rows are `verified`; the piece reads in Fin's voice (`STYLE.md`) |
| **approved** | stays in `review/`, `status: approved` | **Levi said yes, in his own words** |
| **published** | move to `content/published/`, `status: published`, with `published_at` and the channel/URL | it went out; the ledger rows become `published` and carry their re-check dates |

Moving a file between stage directories is the state change. Front matter
`status` must agree with the directory; if they disagree, the directory wins
and the front matter is wrong.

---

## 3. THE CLAIM RULE

> **No external claim ships without a row in `content/claims-ledger.md` naming
> its evidence.**

An "external claim" is any sentence a reader could be wrong about because of
us: a number, a capability, an availability statement, a promise about the
future. Opinion and description are not claims ("Fin is meant to feel like
handing work to somebody" is voice; "Fin routes 96% of requests correctly" is
a claim).

Evidence is an **artifact**, not a memory and not a conversation:

- a lab-book entry id,
- a commit sha (with the file path if the sha alone does not make it obvious),
- a file path plus the sha the file was read at,
- a build number in App Store Connect,
- an eval artifact (`evals/<model-id>/<run-id>.json`, `RESULTS.md` at a sha,
  `models/champion.json`).

"Levi told me" is not evidence. "I remember measuring it" is not evidence. If
the artifact does not exist yet, the claim is not ready and the sentence comes
out of the draft.

The rule is mechanical on purpose. A reviewer should be able to sit with the
ledger and the repo and check the piece line by line without asking anyone
anything. Anything that cannot be checked that way does not go out.

---

## 4. The approval gate

**Nothing in this directory is ever posted, published, submitted, uploaded, or
sent anywhere by an agent on its own initiative.** Not a blog post, not a
tweet, not a release note, not a screenshot, not a "small" correction. Agents
draft, audit, and move files between stage directories. Publishing is a human
act.

Publishing requires **Levi's explicit word for that specific piece.** A
standing "yes, ship content" does not exist and cannot be created here. This
mirrors how App Store and TestFlight submissions already work in this repo —
builds are prepared continuously, submissions wait for Levi — and the signing,
keychain, and upload mechanics for those live in the **`apple-publish` skill**,
which is the authority for them. This document does not duplicate that; it
only notes that the approval discipline is the same one.

The continuous-merge policy in `CLAUDE.md` ("push and merge continuously")
covers **code**. It does not cover this directory. Merging a draft into `main`
is fine and expected; publishing it is not the same act and never becomes
automatic.

---

## 5. House style, in one screen

The full version is `STYLE.md`. The non-negotiable part:

- **Plain and specific over superlative.** "The router prompt went from 36/51
  to 49/51 on the corpus" beats "dramatically improved routing accuracy."
- **Name the limits in the same breath as the result.** Every scientific-result
  piece carries a "What this does not show" section, and it is written before
  the headline, not after.
- **No invented user quotes.** No composite customers, no illustrative
  testimonials, no "one developer told us." If a real person said something and
  agreed to be quoted, quote them and say who they are.
- **No competitor claims.** We do not benchmark against products we did not
  measure, and we do not characterize what other tools can or cannot do.
- **No fabricated benchmarks.** No estimated numbers presented as measured, no
  rounded-up scores, no "up to."
- **Numbers always carry model + prompt revision + corpus + tiering.** A score
  is a property of a *configuration at a moment*, never of "the model." The
  repo's own cautionary example: `scripts/model-factory/evals-champions.json`
  records `google/gemma-4-e4b` at **36/51**, and
  `evals/tmux-routing/RESULTS.md` records the *same untuned model* at **49/51**
  — two prompt revisions, two headline numbers. Either number published without
  its prompt revision, its corpus, and its 26-core/25-hard split is a number
  with no meaning, and would mislead.
- **Say what Fin does when it is wrong.** Fin is an agent acting on real
  terminals. Copy that implies it does not make mistakes is false, and it makes
  the guardrails — registration, `refuse`, `clarify`, `request_input` — invisible,
  which is the opposite of what we want a reader to understand.

---

## 6. The frame every piece reinforces

Quoted from `CLAUDE.md` (standing directive, Levi, 2026-09-05):

> **Fin is a terminal agent with a voice interface and resilient distributed
> decentralized consensus cloud brain.** The interface pillar is voice AND the
> native apps (iOS and macOS; tvOS/visionOS ride along). This is the product
> framing for ALL app-submission materials and features — copy, screenshots,
> review notes, and feature priorities should reinforce it, not dilute it.

Every piece in this directory is checked against that frame. A post about a
routing eval is a post about *how the terminal agent decides where your words
go*. A post about the daemon is a post about *Fin staying reachable when a
device goes away*. If a draft cannot be connected back to the frame without
straining, that is a signal the subject is internal and belongs in the lab
book or in `docs/`, not here.

**And the frame's corollary, from `docs/SITES.md` §1:** the user talks to *one
Fin*. Where Fin's hands are at a given moment — a cloud computer, the Mac in
the study, a machine someone brought themselves, the phone in your pocket — is
the app's job to abstract away. Those are **sites**: interchangeable bodies for
one agent, not separate agents.

So, in user-facing copy: **infrastructure names never appear.** No EC2, no
Lambda, no DynamoDB, no S3, no instance ids, worker ids, site ids, hostnames,
or tailnet names. Say "a cloud computer", "the Mac in your study", "Fin's
computers". The rule in SITES.md is that nothing below the agent reaches the
conversation; the same rule holds for everything we publish. Internal writing —
the lab book, `docs/`, commit messages — names infrastructure freely, because
that is what internal writing is for.

---

## 7. Directory map

```
content/
  README.md              this file — the pipeline and its rules
  STYLE.md               Fin's voice for external writing
  claims-ledger.md       the audit surface: every external claim, with evidence
  templates/
    feature-announcement.md
    scientific-result.md
    release-note.md
    social-post.md
  drafts/                being written; not audited yet
  review/                audited, waiting on approval
  published/             went out; frozen except for marked corrections
```

## 8. Channels

`channel` in a piece's front matter names where it is *intended* to go. It is a
plan, not a permission — see §4.

| channel | typical kind | notes |
|---|---|---|
| `blog` | feature-announcement, scientific-result | the long form; the place a claim can carry its full qualifiers |
| `app-store-release-notes` | release-note | character-limited; framing-compliant; `apple-publish` skill owns the mechanics |
| `testflight-whats-new` | release-note | shorter still; testers already have context |
| `social` | social-post | see the hard rule in `templates/social-post.md` |
| `docs` | — | **not a content channel.** Product documentation lives in `docs/` and is not governed by this pipeline |

---

## 9. When in doubt

Cut the sentence. A shorter true post is worth more than a longer one with a
claim that cannot be checked, because the second kind costs us the first kind's
credibility. If a fact is interesting and unsupported, that is a request for a
measurement, and the right next move is a lab-book entry — not a hedge.

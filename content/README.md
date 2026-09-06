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
- **Writing a lab-book entry because a draft needed one is the moment the wall
  is most likely to fail**, so it has four conditions and they are not
  optional. A backfilled entry is (1) written from the run's own outputs, never
  from the draft; (2) dated the day it is written, not the day of the run;
  (3) marked **retrospective**, saying what was reconstructed and what was not
  recoverable; and (4) explicit that a draft prompted it. An append-only record
  whose framing was chosen by a marketing piece has had its direction of travel
  reversed, and nothing downstream can detect that later. The same four
  conditions govern a **correction owed upstream**: a correction may only move
  an artifact toward what the run outputs show, never toward what a draft
  needs, and if those two point the same way that is a coincidence to be stated
  rather than relied on.
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
idea ─▶ drafts/ ─▶ claims audit ─▶ reader check ─▶ review/ ─▶ approval ─▶ published/
                        │               │                        │
                        │               │                        └── Levi's explicit
      every claim gets a row  ──────────┘                            word (see §4)
      in content/claims-ledger.md   can the reader open what we cited?
```

| stage | where it lives | what has to be true to leave it |
|---|---|---|
| **idea** | a line in a draft's front matter, or nowhere | somebody wants it written |
| **draft** | `content/drafts/<date>-<slug>.md`, `status: draft` | the piece says something specific and every factual sentence has a candidate source |
| **claims audit** | `content/claims-ledger.md` | every external claim in the piece has a ledger row naming its evidence, and each row has been checked against the artifact by a human or an agent who opened the artifact |
| **reader check** | a pre-flight box in the piece | for every artifact the piece *cites to the reader*, somebody has said whether the reader can open it — and named what goes in its place when they cannot (see below) |
| **review** | move to `content/review/`, `status: review` | audit complete; ledger rows are `verified`; the piece reads in Fin's voice (`STYLE.md`) |
| **approved** | stays in `review/`, `status: approved` | **Levi said yes, in his own words** |
| **published** | move to `content/published/`, `status: published`, with `published_at` and the channel/URL — **a human makes this move; see §4** | it went out; the ledger rows become `published` and carry their re-check dates |

Moving a file between stage directories is the state change. Front matter
`status` must agree with the directory; if they disagree, the directory wins
and the front matter is wrong.

### The reader check

`STYLE.md` §5 says "link to artifacts, not to prose", and the claims audit makes
every row cite a path at a sha. Both are right, and together they produce a
piece full of citations **nobody outside can follow**: this repository is
private (`git remote -v` → `git@levi.github.com:galxy25/fin.git`). A reproduction
section that hands a reader commands against files they do not have is not
reproducible; it is a claim of reproducibility.

So, before `review/`, walk the citations the *piece* makes — not the ledger's,
which are internal and stay paths — and for each one record either **"the reader
can open this"** or **what goes in its place**. What goes in its place is
normally a quoted excerpt inside the piece, marked as coming from an internal
repository, so the reader sees the evidence even though they cannot fetch it.

**And the obvious remedy is itself a decision with consequences.** Making the
eval tree public would resolve the citations and would also publish, among other
things: an AWS account id and a bucket name in `scripts/model-factory/README.md`;
a tailnet hostname and a username in `docs/SITES.md`; and Levi's real project
names, task vocabularies and home paths in
`evals/tmux-routing/registry.example.json`. That is a disclosure decision, it is
Levi's, and it is not a side effect of wanting a citation to resolve. Note what
it is not: a *content* problem. `content/` itself carries none of those strings,
and `check-claims.py` fails any piece that introduces one.

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

The rule is mechanical on purpose, and **there is a machine**:

```sh
python3 content/check-claims.py          # exits non-zero on any defect
```

`check-claims.py` is pure Python, no dependencies, and it does not read the
network or the repo's history — it reads this directory (and the lab-book
directory, only to resolve `labbook:` ids). It walks **both directions**, and
the second one is the claim rule itself.

**Rows → piece.** It fails on:

- a `claims:` id with no ledger row, and a ledger row naming a piece that does
  not list it;
- **a ledger row whose exact claim sentence does not appear verbatim in the
  piece it names** — the check that stops a row from auditing a well-qualified
  sentence while the piece ships a bare one;
- a piece in `review/` with a row that is not `verified` or better;
- a `performance` row with an empty or `n/a` re-check; an `availability` row
  whose evidence names no build number; a `framing` row whose evidence names no
  dated directive or that does not name its own unsupported mechanism words; a
  row marked `verified` with no verifier or no ISO date; an unknown `kind` or
  `status`; a duplicate id.

**Piece → rows** — added 2026-09-06, after an injected `published/` piece with
`claims: []`, a fabricated accuracy number, a ledger-rejected sentence, two
banned phrases and a real tailnet name passed the checker green. It fails on:

- **a score (`\d+/\d+`) in a piece's prose that appears in no row the piece
  declares** — the direction that actually enforces "no external claim ships
  without a row";
- a results table carrying scores with no `<!-- table-claims: … -->` marker, or
  a marker naming an id the piece does not declare (ledger §4 step 5);
- **a sentence the ledger `rejected` appearing in a piece**, with nothing
  marking it as refused — rejected copy is the copy most likely to be pasted
  forward;
- a banned phrase from `STYLE.md` §2, and an infrastructure name — account id,
  access key, ARN, S3 URI, tailnet hostname, bucket, instance id, cloud product
  name — in reader-facing prose. Fenced code blocks are skipped, which is
  exactly the width of `STYLE.md` §2's written exemption.

**Row → itself** — added 2026-09-06, after `RPI-12` shipped "still reads 36/51"
with no model, no corpus and no tier split *and* passed green, because the
number did appear in a row's claim text and that was the whole test. **Coverage
is not qualification** (`claims-ledger.md` §8). It fails on:

- **a rowed score whose sentence names no model, no corpus, or no core/hard
  tier split** — unless the row's **re-check** column declares the §4 step 3
  carve-out, or marks the figure a *negated number*: one present only in order
  to be refused, which must not acquire qualifiers;
- **a row that declares the carve-out and then spends it on a heading or the
  piece's `title:`**, which §4 step 3 forbids outright. The carve-out exists for
  a number that cannot travel alone; a headline is the line that travels.

**Stage and approval.** It fails on a `status` that disagrees with its
directory; `approved_by` filled on anything in `drafts/`; any piece at
`approved` or `published` with an empty `approved_by` or one carrying no quote
and no date; an empty `published_at`; a published scientific result with no
lab-book entry, or a `labbook:` id that does not resolve; a release note in
`review/` or `published/` whose `build:` has no number; **a ticked pre-flight
box whose own text says `NOT DONE` or `PENDING`**; **an *unticked* box in a
piece that calls itself approved or published**; any unticked box at all in
`published/`; and a `CB` copy block that has drifted from `STYLE.md`, a rejected
one sitting there unmarked, or a prescribed quoted sentence in `STYLE.md` §1/§3
with no `CB` row.

What the checker still cannot do is **open an artifact and read it** — the part
that matters most. It cannot tell a real approval quote from a typed one; it
cannot see a claim that is neither a score nor a phrase it knows; it cannot
judge whether a qualifier is honest. So it is a floor, not the audit. A reviewer
should still be able to sit with the ledger and the repo and check the piece
line by line without asking anyone anything. Anything that cannot be checked
that way does not go out. The checker exists so that the *checkable* failures
are caught by something other than an agent's own honesty about its own work.

---

## 4. The approval gate

**Nothing in this directory is ever posted, published, submitted, uploaded, or
sent anywhere by an agent on its own initiative.** Not a blog post, not a
tweet, not a release note, not a screenshot, not a "small" correction. Agents
draft, audit, and move files between `drafts/` and `review/`. Publishing is a
human act.

**`published/` is not an agent-writable directory.** The move into
`content/published/` *is the record that something went out*, so an agent never
creates, moves, edits, or deletes anything there — not as housekeeping, not to
"file" a finished piece, not even to fix a typo. A piece an agent believes is
finished stays in `review/` at `status: approved` until a human moves it. The
stage-move permission in the paragraph above stops at `review/`.

Publishing requires **Levi's explicit word for that specific piece.** A
standing "yes, ship content" does not exist and cannot be created here.

**What counts as approval, and what goes in `approved_by`.** Approval is the
highest-stakes fact in this pipeline, so it carries the same evidence standard
as a number (`claims-ledger.md` §3, "'Levi told me' is not evidence"). The
`approved_by` field takes three things or it is empty:

1. **the words**, quoted verbatim — what Levi actually said, not a paraphrase
   and not an interpretation of assent;
2. **the date**, ISO;
3. **where he said it** — the transcript, the message, the channel.

An agent **never fills this field**, not even by transcribing something it read
in its own context. An agent that believes it has been approved writes what it
saw into a `notes:` field and leaves `approved_by` empty; a human puts their
own words in. An empty `approved_by` on anything in `published/` is a defect
the checker fails on, and a filled one that carries no quote and no date is
treated as empty. This
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

Read what that asks for: pieces **reinforce** the frame and do not dilute it.
It does not ask that the sentence be pasted into copy, and it is not evidence
that the machinery it names exists — four of its words describe a mechanism
that has no capability row and that `docs/SITES.md` §1 contradicts. The frame
is quoted as Levi's framing, with attribution, and never asserted in Fin's own
voice as description. `claims-ledger.md` §2 (the `framing` kind) and §7 rows
`CB-4` and `CB-5` carry the detail; `STYLE.md` §1 carries the wording.

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
  check-claims.py        the mechanical floor: run it before moving anything
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
| `docs` | — | **not a content channel**, and not a source of product vocabulary either. `docs/` on `main` holds `ARCHITECTURE.md`, `SITES.md` (a design document, pinned at an older sha) and `STORYBOOK.md`. **`STORYBOOK.md` is superseded and must not be quoted:** it is unchanged since the initial commit (`40a3854`, 2026-08-18), it contains no mention of an agent, of voice, or of a cloud brain, and it opens "Fin is a terminal on your phone… just a way to SSH into a server" — a description of the product that §6's frame and `STYLE.md` §1 both reject. Vocabulary comes from `CLAUDE.md`, `STYLE.md` §1, and `docs/SITES.md` §1 |

---

## 9. When in doubt

Cut the sentence. A shorter true post is worth more than a longer one with a
claim that cannot be checked, because the second kind costs us the first kind's
credibility. If a fact is interesting and unsupported, that is a request for a
measurement, and the right next move is a lab-book entry — not a hedge, and
under §1's four conditions for an entry a draft prompted: written from the run's
outputs, dated today, marked retrospective, and saying that a draft asked for
it.

And when the artifact you cited turns out to be wrong, the correction goes
upstream **toward what the run outputs show** — never toward what the draft
needs. If those two happen to agree, say so in the correction rather than
letting the coincidence do the work.

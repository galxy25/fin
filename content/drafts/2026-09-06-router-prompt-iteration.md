---
title: "Same model, rewritten prompt: 36/51 to 49/51 on Fin's routing corpus"
kind: scientific-result
status: draft
audience: "Developers evaluating Fin, and anyone who wants to know how we measure the model that decides where your words go"
claims: [RPI-01, RPI-02, RPI-03, RPI-04, RPI-05, RPI-06, RPI-07, RPI-08, RPI-09, RPI-10, RPI-11, RPI-12, RPI-13]
labbook: []              # PENDING — see "Lab-book link" below. Must be filled before this leaves review/.
channel: blog
date: 2026-09-06
author: "Claude Opus 5 (drafted), session_01Q7CMy25QeJ4JiqWjznnUZ3"
long_form: ""
approved_by: ""
published_at: ""
---

> **DRAFT — NOT APPROVED, NOT PUBLISHED.**
> This piece has not been approved by Levi and must not be posted, uploaded,
> shared, or quoted outside the repository. It is in `content/drafts/`, which
> is the pre-audit stage: the claims below have been checked by an agent
> against the repo artifacts, but no human has counter-checked them and no
> approval exists. See `content/README.md` §4.
>
> **Lab-book link: PENDING.** The model-factory lab book
> (`scripts/model-factory/labbook/`) is being written in parallel and had no
> entry ids when these rows were verified, so every claim here cites the
> primary artifact directly. Before this piece moves to `review/`, the
> lab-book entry for the prompt-iteration experiment must be added to the
> front matter and cited in the body — a published result cites the book.

# Same model, rewritten prompt: 36/51 to 49/51 on Fin's routing corpus

Fin has to decide, before it does anything else, *where your words should go*.
You have several terminals open with long-running work in them. You say "fix
the widget build." That is a routing decision, and getting it wrong means
typing into somebody's live session.

We rewrote the prompt that makes that decision and re-scored it on our
51-scenario corpus. The untuned `google/gemma-4-e4b`, served locally through LM
Studio at temperature 0, went from **36/51** with the original prompt to
**49/51** with the prompt we kept. Nothing about the model changed — same
weights, same serving stack, same settings, no fine-tune. The prompt was the
whole intervention.

The interesting part is not the 13-point gain. It is that the next round of
prompt work fixed both remaining failures and broke three things that were
already working, which is what most of this post is about.

## The question

Fin's router emits one of four decisions for every request: `route` it to an
existing registered session, `start` a new one, `clarify` when it is genuinely
ambiguous, or `refuse` when the target exists on the machine but was never
registered with Fin. Registration is the guardrail: a terminal that merely
exists is invisible to Fin and off-limits to type into.

A first model run scored 36/51 and failed in ways that looked like *missing
rules* rather than missing capability. The question was whether that was true —
whether the gap was prompt-fixable at all, and how far prompt work could go
before it ran into the model itself. The decision it informed was concrete: if
prompt work could not clear the corpus, the next move is a fine-tune; if it
could, the fine-tune budget goes elsewhere first.

## Method

- **Model:** `google/gemma-4-e4b`, **untuned**. No fine-tune has been run for
  this task; the model factory's first training run is still gated on an
  explicit human go.
- **Serving:** LM Studio at `http://localhost:1234/v1`, temperature 0, with a
  30-second per-call timeout enforced by the harness. A call that exceeds it
  degrades to `clarify` and is scored as a miss, so timeouts show up in the
  numbers and are marked separately (see Results).
- **Prompt:** `evals/tmux-routing/prompts/router.md`. Five revisions, rounds 0
  through 4; the kept one is round 3, committed at `99ed9d9`.
- **Corpus:** `evals/tmux-routing/scenarios.json` — 51 labeled scenarios,
  **26 core** and **25 adversarial** (`h01`–`h25`). It is hand-written and
  hermetic: every scenario is a `(query, registry, live_sessions)` triple
  scored offline against an expected decision, with no tmux involved.
- **Held out:** the corpus is the gate, so it is held out of any training data
  by rule. This result involves no training at all, but the rule is why the
  number means something later.
- **Scoring:** `evals/tmux-routing/run_evals.py`, exact match on the decision
  (and on the session name for `route`). All 26 core scenarios passing is the
  exit-code gate.
- **Runs:** **one scored run per prompt revision.** No repeats, no averaging,
  no best-of. Everything below inherits that.

### The corpus

The 26 core scenarios cover the four decisions on ordinary phrasing. The 25
adversarial ones exist to break a router that pattern-matches on vocabulary:
sessions named in analogies and asides, requests that mention a session while
targeting another, contrast clauses ("unlike the newsletter rollout…"), and
registered sessions that are *absent from the live session list*, where the
right answer is to recreate them rather than refuse.

That last class is the one worth understanding, because it is where the
original prompt collapsed. A registered session that is not currently running
is **dead**, not **unregistered**. Dead means `start`. Unregistered means
`refuse`. The original prompt conflated them.

## Results

Both tables are reproduced from `evals/tmux-routing/RESULTS.md` at commit
`d98a031`.

| router | overall | route | start | clarify | refuse | core | hard |
|---|---|---|---|---|---|---|---|
| deterministic baseline (no model) | 29/51 (57%) | 12/24 | 6/13 | 7/10 | 4/4 | 26/26 | 3/25 |
| model, original prompt | 36/51 (71%) | 21/24 | 4/13 | 7/10 | 4/4 | 21/26 | 15/25 |
| model, round-3 prompt (kept) | **49/51 (96%)** | 23/24 | 13/13 | 9/10 | 4/4 | **25/26** | **24/25** |

The deterministic baseline is worth keeping in view: it passes all 26 core
scenarios and 3 of 25 adversarial ones. That shape — perfect on the easy tier,
near-zero on the hard one — is exactly what a keyword matcher looks like, and
it is why the corpus has two tiers at all. A single 51-scenario headline would
have hidden it.

Round by round:

| round | prompt change | overall | core | hard | misses |
|---|---|---|---|---|---|
| 0 | original | 36/51 | 21/26 | 15/25 | s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |
| 1 | three-classes rewrite | 46/51 | 25/26 | 21/25 | c01 h01 h07 h08 h21† |
| 2 | imperative-first, honest vocab, start = lifecycle | 48/51 | 24/26 | 24/25 | r01† f01 h08 |
| 3 | route ⊆ registry, start-object test — **kept** | **49/51** | **25/26** | **24/25** | c01 h08 |
| 4 | generic-phrase clamp, anti-contrast rule — **reverted** | 48/51 | 25/26 | 23/25 | r06 h01 h12 |

† `h21` (round 1) and `r01` (round 2) were 30-second endpoint timeouts, not
wrong answers: the harness degrades a timed-out call to `clarify` and scores it
as a miss. One in each of rounds 1 and 2; none in rounds 3 or 4.

The gain is concentrated in one decision type. `start` went from 4/13 to 13/13,
while `route` moved 21/24 to 23/24, `clarify` 7/10 to 9/10, and `refuse` stayed
4/4 throughout. The rewrite did not make the model broadly smarter about
routing; it fixed one confusion that happened to account for nine scenarios.

## What we changed and what it cost

**Round 1** targeted the three failure classes the first run exposed:
*dead ≠ unregistered* (a registered session missing from the live list means
recreate, never refuse), *explicit-new synonym coverage* (recognize a
new-session request by meaning rather than from a list of verbs), and
*mention ≠ target* (analogies, asides and physical-world words neither route
nor refuse). It fixed all fifteen round-0 misses in those classes — and
introduced four new ones: over-clarifying on a domain paraphrase (`h01`), a
false "two targets" reading (`h07`), reading "set that up" as `start` (`h08`),
and hallucinating vocabulary that was not in the registry (`c01`).

**Rounds 2 and 3** clamped the over-corrections with two structural rules
rather than more prose: `route` may only name a session that is actually in the
registry — `f01` had routed into an unregistered `main` — and `start` requires
a session or agent as its object, not a feature or a plan. Multi-clause
requests target the main imperative.

**Round 4** went after the last two misses with a stronger generic-phrase clamp
and an explicit anti-contrast rule. It fixed both. It also broke three
scenarios that rounds 2 and 3 had passed: `r06`'s direct session-name mention
got second-guessed as a generic phrase, `h01`'s domain paraphrase got
re-labeled generic, and `h12` refused on an adjectival "main". Net 48/51 —
worse than the round it was trying to improve.

So round 3 stands. Not because it is complete, but because it is the best point
on this model's curve, and rounds 2 and 4 both demonstrated the same see-saw:
tighten a rule far enough to catch its last failure and it starts catching its
neighbors.

## Where it still fails

Two scenarios, one in each tier.

**`c01` (core).** "run the tests" routes to `fin`, rationalizing bare "tests"
as belonging to fin's "testing and app development" domain. The right answer is
to ask, because "the tests" names no session. For this model, the
domain-paraphrase allowance — the thing that makes `h01`–`h03` work — and the
no-generic-words rule sit on a knife edge. Round 4's harder clamp fixed `c01`
and cost `r06`, `h01` and `h12`.

**`h08` (hard).** "unlike the newsletter rollout, the widget release needs a
phased rollout — set that up" routes to `africanintellect`. The noun in the
contrast clause still outweighs the imperative's "widget", which is literally
in the other session's registered vocabulary. The explicit anti-contrast rule
that fixed this in round 4 was the one that broke three others.

`c01` is the gate blocker: core stands at 25/26, and the gate requires 26/26.

Both look like model-capacity limits at this prompt length rather than missing
rules — each has a rule in the prompt that the model applies inconsistently,
and strengthening either one tips its neighbors. **That reading is a
hypothesis, not a measurement.** We have not tested it. The way to test it is a
stronger local model under the same 30-second contract, or a shorter compiled
prompt, and neither has been run.

## What this does not show

- **Single run per arm.** Every number in this post comes from one scored run.
  No repeats, no variance, no confidence interval. A 1–2 scenario difference
  between adjacent rounds is within the range a re-run could plausibly move, so
  round 3 at 49 and rounds 2 and 4 at 48 should not be read as a firm ordering.
  The 36 → 49 gap is large enough to survive that caveat; the 48-vs-49
  comparisons are not.
- **The harness had flakes.** One 30-second endpoint timeout in round 1 and one
  in round 2 were scored as misses. Rounds 3 and 4 had none — which is luck as
  much as anything, and it means round 3's headline is compared against two
  rounds that each ate a flake.
- **One model, one corpus, one registry shape.** 51 hand-written scenarios over
  a small registry, all authored by the same people who wrote the prompt. This
  says nothing about routing performance on someone else's sessions, someone
  else's vocabulary, or a registry with fifty entries.
- **Prompt-only.** No fine-tune, no training data, no model change. This is not
  a result about the model factory; it is a result about prompts, and it is
  partly a result about *this* model's sensitivity to them.
- **This is the eval harness, not the app.** The 49/51 was measured through
  `router_llm.py`, which assembles the prompt its own way. Fin's in-app router
  (`SessionRouter.promptSection` in `FinAgentCore`) carries guidance that tracks
  the round-3 prompt, but it is different code and has not been scored end to
  end in the app. **Nobody should read this post as "Fin routes correctly 96%
  of the time."** That number does not exist yet.
- **It does not move the champion.** `scripts/model-factory/evals-champions.json`
  still reads 36/51, because the champion record tracks *models*, and a prompt
  change does not promote a model. A candidate promotes only by passing all 26
  core scenarios and beating the champion on core + hard combined.
- **Bigger local models were not evaluated.** Two were tried and excluded on
  operational grounds, not on quality: `gemma-4-12b-qat` spends around 40
  seconds per call on reasoning tokens, over the harness's contract, and
  `gemma-4-26b-a4b` would not load on the box for lack of memory. We do not
  know how either would score.

## Reproduce it

Serve any OpenAI-compatible endpoint with the model loaded, then:

```sh
# deterministic baseline — no model, no endpoint needed
python3 evals/tmux-routing/run_evals.py

# model-backed, round-3 prompt (the kept one)
FIN_ROUTER_BASE_URL=http://localhost:1234/v1 \
FIN_ROUTER_MODEL=google/gemma-4-e4b \
  python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py
```

The harness prints every miss with expected-vs-actual JSON and the scenario
note, and exits non-zero if any scenario fails. To reproduce an earlier round,
check out `evals/tmux-routing/prompts/router.md` at that round's commit — round
4 is `e7460cd`, and round 3 is `99ed9d9`, the current file.

Expect your numbers to differ. Different LM Studio builds, different hardware
and a different 30-second timeout margin all move single-run results.

---

## Claims in this piece

Full rows, with evidence and re-check conditions, in
`content/claims-ledger.md` § "RPI".

| id | sentence | kind | evidence |
|---|---|---|---|
| RPI-01 | "The corpus is 51 labeled scenarios in `evals/tmux-routing/scenarios.json`: 26 core scenarios and 25 adversarial ones written to break a router that pattern-matches on vocabulary." | capability | `evals/tmux-routing/RESULTS.md @ d98a031`; `scenarios.json @ 704ab09` |
| RPI-02 | "The deterministic baseline router, which uses no model at all, scores 29/51: 26/26 on core and 3/25 on the adversarial set." | performance | `RESULTS.md @ d98a031`, Overall table |
| RPI-03 | "With the original prompt, `google/gemma-4-e4b` — untuned, served through LM Studio at temperature 0 with a 30-second per-call timeout — scored 36/51: core 21/26, hard 15/25." | performance | `RESULTS.md @ d98a031`, Overall table + run conditions; `evals-champions.json` |
| RPI-04 | "With the round-3 prompt — the same model, the same endpoint, the same corpus, the same settings — the score is 49/51: core 25/26, hard 24/25." | performance | `RESULTS.md @ d98a031`; `prompts/router.md @ 99ed9d9` |
| RPI-05 | "Nothing about the model changed between those two runs: same weights, same serving stack, same settings, no fine-tune. The prompt was the whole intervention." | performance | `RESULTS.md @ d98a031` run conditions; `scripts/model-factory/README.md @ 704ab09` Status |
| RPI-06 | "Round 1 scored 46/51 and round 2 scored 48/51." | performance | `RESULTS.md @ d98a031`, rounds table |
| RPI-07 | "Round 4 fixed both of round 3's remaining misses and broke three scenarios that round 3 had passed — `r06`, `h01`, `h12` — for a net 48/51, so round 3 is the prompt we kept." | performance | `RESULTS.md @ d98a031`, rounds table row 4 + analysis; commit `99ed9d9` |
| RPI-08 | "Two scenarios still fail under the round-3 prompt: `c01` in the core set and `h08` in the hard set." | performance | `RESULTS.md @ d98a031`, rounds table row 3 + residual-misses table |
| RPI-09 | "Two of the misses recorded in rounds 1 and 2 were 30-second endpoint timeouts rather than wrong answers — one in each round — and rounds 3 and 4 recorded none." | performance | `RESULTS.md @ d98a031`, dagger footnote |
| RPI-10 | "Two larger local models were unusable under the harness's 30-second per-call contract: `gemma-4-12b-qat` spends about 40 seconds per call on reasoning tokens, and `gemma-4-26b-a4b` would not load on the box for lack of memory." | performance | `RESULTS.md @ d98a031`, run conditions |
| RPI-11 | "This number describes the eval harness, not the shipped app: Fin's in-app router carries guidance that tracks the round-3 prompt, but it is assembled by different code and has not been scored end to end in the app." | capability | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`, `promptSection` |
| RPI-12 | "The champion record in `scripts/model-factory/evals-champions.json` still reads 36/51, because it was seeded from the pre-rework run and a prompt change does not promote a champion." | performance | `evals-champions.json @ 704ab09`; promotion rule in `scripts/model-factory/README.md @ 704ab09` |
| RPI-13 | "The gain is concentrated in one decision type: `start` went from 4/13 to 13/13, while `route` moved 21/24 to 23/24, `clarify` 7/10 to 9/10, and `refuse` stayed 4/4." | performance | `RESULTS.md @ d98a031`, Overall table per-action columns |

## Pre-flight

- [x] Every number has a ledger row citing a run artifact
- [x] Every number carries model + prompt revision + corpus + tiering, in the sentence
- [x] The losing arms and the regressions are in the results table
- [x] Flake/timeout counts are reported and marked as non-semantic
- [x] Run count is stated; no averaging or best-of is implied
- [x] "What this does not show" names the inference a reader would wrongly make
      (the "Fin routes 96% of the time" reading, cut off explicitly)
- [ ] **Reproduction command was actually run as written** — NOT DONE. The
      commands are transcribed from `RESULTS.md` and `scripts/model-factory/README.md`;
      nobody re-ran them while drafting this. Somebody must, against a live
      endpoint, before this leaves `review/`.
- [ ] **Lab-book entry ids are in the front matter and cited in the body** —
      NOT DONE; the book did not exist when this was drafted.
- [x] No claim generalizes a configuration into a product capability
- [x] No infrastructure names in reader-facing text
- [ ] **Levi has approved this piece, in his own words** — NOT DONE. Nothing
      here is published.

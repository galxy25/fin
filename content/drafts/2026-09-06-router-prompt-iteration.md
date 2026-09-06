---
title: "Same untuned `google/gemma-4-e4b`, two router prompts: 36/51 with the original, 49/51 with round 3, on the 51-scenario tmux-routing corpus (26 core, 25 hard)"
kind: scientific-result
status: draft
audience: "Developers evaluating Fin, and anyone who wants to know how we measure the model that decides where your words go"
claims: [RPI-01, RPI-02, RPI-03, RPI-04, RPI-05, RPI-06, RPI-07, RPI-08, RPI-09, RPI-10, RPI-11, RPI-12, RPI-13, RPI-14, RPI-15, RPI-16, RPI-17, RPI-18, RPI-19, RPI-20, RPI-21, RPI-22, RPI-23, RPI-24, RPI-25, RPI-26, RPI-27, RPI-28, RPI-29, RPI-30, RPI-31, RPI-32, RPI-33, RPI-34, RPI-35, RPI-36, RPI-37]
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
>
> **Blocking: the prompt this piece measures has since been corrected and not
> re-scored.** Commit `7a591f4`, on the unmerged `imac-site` branch, rewrites
> the registry paragraph of `evals/tmux-routing/prompts/router.md` and says in
> its own inline comment to "re-score `router_llm.py` against it when a local
> endpoint is up again." Until that re-score exists, 49/51 describes a prompt
> revision the tree is already moving away from. See "Corrections owed
> upstream" at the bottom.

# Same untuned `google/gemma-4-e4b`, two router prompts: 36/51 with the original, 49/51 with round 3, on the 51-scenario tmux-routing corpus (26 core, 25 hard)

Fin has to decide, before it does anything else, *where your words should go*.
You have several terminals open with long-running work in them. You say "fix
the widget build." That is a routing decision, and getting it wrong means
typing into somebody's live session.

We rewrote the router prompt in the eval harness — not in the app — and
re-scored it there. With the original router prompt
(`evals/tmux-routing/prompts/router.md @ 96ea006`), the
untuned `google/gemma-4-e4b` — served through LM Studio at temperature 0 with a
30-second per-call timeout — scored 36/51 on the 51-scenario tmux-routing
corpus: core 21/26, hard 15/25. With the round-3 prompt
(`evals/tmux-routing/prompts/router.md @ 99ed9d9`) — the same untuned
`google/gemma-4-e4b`, the same endpoint, the same settings, the same
51-scenario corpus — the score is 49/51: core 25/26, hard 24/25. Nothing about
the model changed between those two runs — same weights, same serving stack,
same settings, the untuned model in both arms — so the prompt was the whole
intervention.

The interesting part is not the gap. It is what happened next: the following
round of prompt work traded the failures it fixed for new ones, which is what
most of this post is about.

## The question

Fin's router emits one of four decisions for every request: `route` to an
existing registered session, `start` a new one, `clarify` when the request is
genuinely ambiguous, or `refuse` when the target is a live session that was
never registered with Fin.

That last one deserves care, because it is easy to write up as a safety
interlock and it is not one. `refuse` is a decision, not an interlock: on
`main` the router's answer to a live-but-unregistered target is to say what it
found and ask you to register it, and nothing in the daemon's send path
enforces that answer. What this eval scores is whether the model *reaches* that
decision on 51 labeled cases — not what the running system does with it.

`evals/tmux-routing/` is both the spec and the gate for the model factory's
first fine-tune target, so the question was how far prompt work could go
against that gate before it ran into the model itself. Routing is still the
model factory's first fine-tune target, and a first training run against it
started on 2026-09-05.

## Method

- **Model:** `google/gemma-4-e4b`, **untuned**, in both arms. No fine-tuned
  candidate has been scored against this corpus: the champion record in
  `scripts/model-factory/evals-champions.json` is still the untuned model, and
  the first fine-tune run — a QLoRA adapter over
  `mlx-community/gemma-4-E4B-it-qat-4bit`, started 2026-09-05 at 20:15:29 and
  still training on 2026-09-06 — has not been fused, served, or gated; no
  adapter enters either arm of this result.
- **Serving:** LM Studio at `http://localhost:1234/v1`, temperature 0, with a
  30-second per-call timeout enforced by the harness. A call that exceeds it
  degrades to `clarify` and is scored as a miss, so timeouts show up in the
  numbers and are marked separately (see Results). `RESULTS.md` records no
  quantization level and no LM Studio build, so the identifier
  `google/gemma-4-e4b` does not by itself pin the weights a reader would load.
- **Prompt:** `evals/tmux-routing/prompts/router.md`. Five revisions, rounds 0
  through 4: round 0 is the harness's original prompt at `96ea006`, round 3 is
  the one we kept (introduced at `fcb10b2`, restored as the current file at
  `99ed9d9` — byte-identical at both), and round 4 is `e7460cd`.
- **Corpus:** `evals/tmux-routing/scenarios.json` — 51 labeled scenarios,
  **26 core** and **25 adversarial** (`h01`–`h25`). It is hand-written and
  hermetic: every scenario is a `(query, registry, live_sessions)` triple
  scored offline against an expected decision, with no tmux involved.
- **Held out by rule, and not checkable from the repo:**
  `scripts/model-factory/README.md` states the leakage rule — the corpus is the
  gate, so its literal scenarios never appear in `train.jsonl` or `val.jsonl` —
  and marks the seed dataset build as deriving from the eval corpus itself, a
  caveat it says synthetic variants and telemetry must clear before a real
  training run. `datasets/` and `models/` are both gitignored, so no reader can
  check either the rule or the caveat against an actual training split. Nothing
  in this result depends on that: it is prompt-only, and no training split
  enters it.
- **Scoring:** exact match on the decision (and on the session name for
  `route`), and the harness's exit code gates on the core tier alone:
  `run_evals.py` returns 0 only when all 26 core scenarios pass.
- **Runs:** `RESULTS.md` records one score per prompt revision and no repeats;
  the number of times each configuration was actually scored is not recorded in
  any artifact in the repo, so nothing here should be read as an average, a
  best-of, or a variance estimate.

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
`refuse`. `RESULTS.md` names *dead ≠ unregistered* as the first of the three
prompt-fixable failure classes the original run exposed, and the rewrite was
built around it.

## Results

The scores in both tables are reproduced from `evals/tmux-routing/RESULTS.md`
at commit `d98a031`, which records them without prompt shas; the `prompt`
column is recovered from `git log -- evals/tmux-routing/prompts/router.md`,
whose commit subjects name each round. Every row is the same untuned
`google/gemma-4-e4b` on the same 51-scenario corpus except the first, which
uses no model at all; the `core` and `hard` columns are the 26-core/25-hard
split.

<!-- table-claims: RPI-02, RPI-03, RPI-04, RPI-13 -->

| router | overall | route | start | clarify | refuse | core | hard |
|---|---|---|---|---|---|---|---|
| deterministic baseline (no model) | 29/51 (57%) | 12/24 | 6/13 | 7/10 | 4/4 | 26/26 | 3/25 |
| model, original prompt (`96ea006`) | 36/51 (71%) | 21/24 | 4/13 | 7/10 | 4/4 | 21/26 | 15/25 |
| model, round-3 prompt (`99ed9d9`, kept) | **49/51 (96%)** | 23/24 | 13/13 | 9/10 | 4/4 | **25/26** | **24/25** |

The deterministic baseline router, which uses no model at all, scores 29/51 on
the same 51-scenario corpus: 26/26 on core and 3/25 on the adversarial set.
That shape — perfect on the easy tier, near-zero on the hard one — is exactly
what a keyword matcher looks like, and it is why the corpus has two tiers at
all. A single 51-scenario headline would have hidden it.

Round by round, all on the same corpus and the same untuned model, varying only
the prompt revision:

<!-- table-claims: RPI-03, RPI-04, RPI-06, RPI-07, RPI-08, RPI-20, RPI-29 -->

| round | prompt | prompt change | overall | core | hard | misses |
|---|---|---|---|---|---|---|
| 0 | `96ea006` | original | 36/51 | 21/26 | 15/25 | s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |
| 1 | `22005c7` | three-classes rewrite | 46/51 | 25/26 | 21/25 | c01 h01 h07 h08 h21† |
| 2 | `f0040f5` | imperative-first, honest vocab, start = lifecycle | 48/51 | 24/26 | 24/25 | r01† f01 h08 |
| 3 | `99ed9d9` | route ⊆ registry, start-object test — **kept** | **49/51** | **25/26** | **24/25** | c01 h08 |
| 4 | `e7460cd` | generic-phrase clamp, anti-contrast rule — **reverted** | 48/51 | 25/26 | 23/25 | r06 h01 h12 |

† `h21` (round 1) and `r01` (round 2) were 30-second endpoint timeouts, not
wrong answers: the harness degrades a timed-out call to `clarify` and scores it
as a miss. Two of the misses recorded in rounds 1 and 2 were 30-second endpoint
timeouts rather than wrong answers — one in each round — and rounds 3 and 4
recorded none.

Round 1 scored 46/51 and round 2 scored 48/51 on that corpus. The gain from
round 0 to round 3 is concentrated in one decision type: `start` went from 4/13
to 13/13, while `route` moved 21/24 to 23/24, `clarify` 7/10 to 9/10, and
`refuse` stayed 4/4. Nine of the thirteen scenarios gained between round 0 and
round 3 are `start` decisions the original prompt got wrong — arithmetic on the
per-action columns above, not a separately measured figure. Reading that as one
fixed confusion rather than a broadly better model is our interpretation; the
artifact records the columns, not the cause.

## What we changed and what it cost

**Round 1** targeted the three failure classes the first run exposed:
*dead ≠ unregistered* (a registered session missing from the live list means
recreate, never refuse), *explicit-new synonym coverage* (recognize a
new-session request by meaning rather than from a list of verbs), and
*mention ≠ target* (analogies, asides and physical-world words neither route
nor refuse).

Round 1 fixed fourteen of the fifteen round-0 misses and introduced four new
ones — `h01`, `h07`, `h08` and `h21`, the last a 30-second endpoint timeout
rather than a wrong answer — while `c01` failed in round 0 and failed again in
round 1. Reading the miss sets across the table is worth doing slowly: `c01` is
not a casualty of the rewrite, it is the one round-0 failure the rewrite never
touched, and it is still failing under the prompt we kept. (`RESULTS.md`'s
prose says round 1 "fixed all fifteen round-0 misses" and lists `c01` among the
new over-corrections; that contradicts its own rounds table two lines above it.
The table is right. See "Corrections owed upstream".)

**Rounds 2 and 3** clamped the over-corrections with two structural rules
rather than more prose: `route` may only name a session that is actually in the
registry — `f01` had routed into an unregistered `main` — and `start` requires
a session or agent as its object, not a feature or a plan. Multi-clause
requests target the main imperative.

**Round 4** went after the last two misses with a stronger generic-phrase clamp
and an explicit anti-contrast rule. Round 4 fixed both of round 3's remaining
misses and broke three scenarios that round 3 had passed — `r06`, `h01`, `h12`
— for a net 48/51, so round 3 is the prompt we kept: `r06`'s direct
session-name mention got second-guessed as a generic phrase, `h01`'s domain
paraphrase got re-labeled generic, and `h12` refused on an adjectival "main".

So round 3 stands. Not because it is complete, but because it is the best point
on this model's curve, and rounds 2 and 4 both demonstrated the same see-saw:
tighten a rule far enough to catch its last failure and it starts catching its
neighbors.

## Where it still fails

Two scenarios still fail under the round-3 prompt: `c01` in the core set and
`h08` in the hard set.

**`c01` (core).** "run the tests" routes to `fin`, rationalizing bare "tests"
as belonging to fin's "testing and app development" domain. The right answer is
to ask, because "the tests" names no session. For this model, the
domain-paraphrase allowance — the thing that makes `h01`–`h03` work — and the
no-generic-words rule sit on a knife edge. Round 4's harder clamp fixed `c01`
and cost `r06`, `h01` and `h12`.

**`h08` (hard).** "unlike the newsletter rollout, the widget release needs a
phased rollout — set that up" routes to the newsletter session. The expected
answer is the app session, whose registered task vocabulary contains "widget";
the noun in the contrast clause still outweighs the imperative that names the
target. The explicit anti-contrast rule that fixed this in round 4 was the one
that broke three others.

`c01` is the gate blocker: core stands at 25/26 under the round-3 prompt, and
the harness's exit-code gate requires 26/26.

Both look like model-capacity limits at this prompt length rather than missing
rules — each has a rule in the prompt that the model applies inconsistently,
and strengthening either one tips its neighbors. **That reading is a
hypothesis, not a measurement.** We have not tested it. The way to test it is a
stronger local model under the same 30-second contract, or a shorter compiled
prompt, and neither has been run.

## What this does not show

- **No held-out split, and the prompt was written against the scored misses.**
  Rounds 1 through 4 were each authored by reading the miss list the previous
  round produced on these same 51 scenarios — the round-by-round section above
  is the record of it. 49/51 therefore measures how well the round-3 prompt
  fits this corpus, not how it would score on scenarios written after it, and
  nothing here predicts performance on a corpus its authors had not seen. The
  "held out by rule" note in Method is about training data and does not apply
  to prompt work; a prompt-only result has no held-out split at all.
- **No run count is recorded.** `RESULTS.md` gives one score per prompt
  revision and records no repeats, and there are no run logs in the repo, so
  the number of scored runs behind each row is unknown. Treat every figure here
  as a single observation: no variance, no confidence interval, nothing that
  supports "consistently". With no repeats recorded, this piece establishes no
  ordering between any two rounds — the round-3 and round-4 scores alike — and
  it says nothing about whether the round-0 to round-3 gap would replicate.
- **The harness had flakes.** One 30-second endpoint timeout in round 1 and one
  in round 2 were scored as misses. Rounds 3 and 4 had none — which is luck as
  much as anything, and it means round 3's headline is compared against two
  rounds that each ate a flake.
- **One model, one corpus, one registry shape.** 51 hand-written scenarios over
  a small registry, all authored by the same people who wrote the prompt. This
  says nothing about routing performance on someone else's sessions, someone
  else's vocabulary, or a registry with fifty entries.
- **Prompt-only.** Both arms are the untuned model; no training data and no
  adapter enters either one. The fine-tune described in Method is not in these
  numbers. This is not a result about the model factory; it is a result about
  prompts, and it is partly a result about *this* model's sensitivity to them.
- **This is the eval harness, not the app.** This number describes the eval
  harness, not the shipped app: Fin's in-app router carries guidance that
  tracks the round-3 prompt, but it is assembled by different code and has not
  been scored end to end in the app. **Nobody should read this post as "Fin
  routes correctly 96% of the time."** That number does not exist yet.
- **It scores a decision, not an enforcement.** A `refuse` in this corpus means
  the model produced the right JSON, and nothing more. It is not evidence about
  what a running Fin does with that decision, and it is not a safety property:
  the send-path allow-list that would make it one lives on an unmerged branch.
- **The prompt has moved since.** The round-3 prompt was corrected on
  2026-09-06 by `7a591f4` (unmerged), which is explicit that a re-score is
  owed. 49/51 is a fact about `99ed9d9`, not about whatever ships next.
- **It does not move the champion.** The champion record in
  `scripts/model-factory/evals-champions.json` still reads 36/51, because it
  was seeded from the pre-rework run and a prompt change does not promote a
  champion. A candidate promotes only by passing all 26 core scenarios and
  beating the champion on core + hard combined.
- **Bigger local models were not evaluated.** Two larger local models were
  unusable under the harness's 30-second per-call contract: `gemma-4-12b-qat`
  spends about 40 seconds per call on reasoning tokens, and `gemma-4-26b-a4b`
  did not fit in the available memory on the machine we scored on. They were
  excluded on operational grounds, not on quality; we do not know how either
  would score.

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

The harness prints every miss with expected-vs-actual JSON, and exits non-zero
unless all 26 core scenarios pass. To reproduce a particular round, check out
`evals/tmux-routing/prompts/router.md` at that round's commit: round 0 is
`96ea006`, round 1 `22005c7`, round 2 `f0040f5`, round 3 `99ed9d9`, round 4
`e7460cd`. Round 3 is the file as of `main @ 704ab09`; it is **not** the newest
revision in the repository — see the note about `7a591f4` above.

Expect your numbers to differ. Different LM Studio builds, different hardware
and a different 30-second timeout margin all move single-run results. The
artifact does not record which LM Studio build or quantization produced ours,
so that comparison has a floor.

**And every path above is in a repository that is not public.** As things
stand, these commands are runnable by us and readable by everyone else — that
is a limit of this piece, not a detail of it. Opening the eval tree would fix
it and is a separate decision with its own consequences; until it is made, the
honest thing is to say so here rather than to write reproduction instructions
that only look reproducible. See the pre-flight box on the reader check.

---

## Corrections owed upstream

This piece found three defects in the artifacts it cites. Per `README.md` §1
the correction belongs in the internal record first; none is fixed by this
draft, and all three should be before it publishes. A correction may only move
an artifact toward what the run outputs show — never toward what this draft
needs.

1. **`evals/tmux-routing/RESULTS.md`** — the prose under the rounds table says
   round 1 "fixed all fifteen round-0 misses" and lists `c01` among the
   over-corrections round 1 introduced. Its own rounds table has `c01` failing
   in round 0. The correct count is fourteen fixed, `c01` persisting, and four
   new misses (`h01`, `h07`, `h08`, `h21†`).
2. **`evals/tmux-routing/run_evals.py`** — the module docstring says "Exit
   status: 0 if every scenario passes, 1 otherwise", but `main()` returns
   `0 if core_passed == core_total else 1`: the gate is the core tier, not the
   whole corpus. The code is the intended behavior and the docstring is stale.
   A reader who follows "Reproduce it" will open that file.
3. **`scripts/model-factory/README.md`** — its Status list still carries
   "First fine-tune run (**human go required**)" as an unchecked box, while a
   QLoRA run for that target has been training since 2026-09-05. The list no
   longer describes the working tree. This one is the reason the Method section
   above cites a training log rather than that checkbox: a plan document's
   unchecked box is not evidence that the work has not happened, and reading it
   as evidence is the `EX-BAD-2` error run backwards.

## Claims in this piece

Full rows, with evidence and re-check conditions, in
`content/claims-ledger.md` § "RPI". Every sentence below appears verbatim in
the body above; `content/check-claims.py` fails if one does not.

| id | sentence | kind | evidence |
|---|---|---|---|
| RPI-01 | see the ledger | method | `RESULTS.md @ d98a031`; `scenarios.json @ 704ab09` |
| RPI-02 | see the ledger | performance | `RESULTS.md @ d98a031`, Overall table |
| RPI-03 | see the ledger | performance | `RESULTS.md @ d98a031`; `prompts/router.md @ 96ea006`; `evals-champions.json` |
| RPI-04 | see the ledger | performance | `RESULTS.md @ d98a031`; `prompts/router.md @ 99ed9d9` |
| RPI-05 | see the ledger | performance | `RESULTS.md @ d98a031`; `scripts/model-factory/README.md @ 704ab09` |
| RPI-06 | see the ledger | performance | `RESULTS.md @ d98a031`, rounds table |
| RPI-07 | see the ledger | performance | `RESULTS.md @ d98a031`, rounds table row 4; commit `99ed9d9` |
| RPI-08 | see the ledger | performance | `RESULTS.md @ d98a031`, rounds table row 3 |
| RPI-09 | see the ledger | performance | `RESULTS.md @ d98a031`, dagger footnote |
| RPI-10 | see the ledger | performance | `RESULTS.md @ d98a031`, run conditions |
| RPI-11 | see the ledger | method | `SessionRouting.swift @ 704ab09` |
| RPI-12 | see the ledger | performance | `evals-champions.json @ 704ab09` |
| RPI-13 | see the ledger | performance | `RESULTS.md @ d98a031`, per-action columns |
| RPI-14 | the title | performance | `RESULTS.md @ d98a031`; both prompt shas |
| RPI-15 | see the ledger | capability | `SessionRouting.swift @ 704ab09` |
| RPI-16 | see the ledger | capability | `SessionRouting.swift`, `AgentTurnEngine.swift @ 704ab09` |
| RPI-17 | see the ledger | method | `run_evals.py @ 704ab09` |
| RPI-18 | see the ledger | method | `scripts/model-factory/README.md @ 704ab09` |
| RPI-19 | see the ledger | performance | `RESULTS.md @ d98a031`; `run_evals.py @ 704ab09` |
| RPI-20 | see the ledger | performance | `RESULTS.md @ d98a031`, rounds table rows 0–1 |
| RPI-21 | see the ledger | method | `scripts/model-factory/README.md @ 704ab09` |
| RPI-22 | see the ledger | roadmap | `scripts/model-factory/README.md @ 704ab09` Status |
| RPI-23 | see the ledger | method | `RESULTS.md @ d98a031`; absence of run logs |
| RPI-24 | see the ledger | method | `RESULTS.md @ d98a031` rework paragraph |
| RPI-25 | see the ledger | method | `models/candidates/fin-foreman-e4b-mlx/train.log`; `evals-champions.json @ 704ab09` |
| RPI-26 | see the ledger | method | this piece's own round-by-round section; `RESULTS.md @ d98a031` |
| RPI-27 | see the ledger | method | `RESULTS.md @ d98a031`; absence of run logs |
| RPI-28 | see the ledger | performance | `RESULTS.md @ d98a031`, rounds table rows 3–4 |
| RPI-29 | see the ledger | method | `RESULTS.md @ d98a031`; `git log -- evals/tmux-routing/prompts/router.md` |
| RPI-30 | see the ledger | method | `RESULTS.md @ d98a031`, run conditions |
| RPI-31 | see the ledger | performance | `RESULTS.md @ d98a031`, per-action columns |
| RPI-32 | see the ledger | performance | `RESULTS.md @ d98a031` remaining-misses table; `scenarios.json @ 704ab09` |
| RPI-33 | see the ledger | performance | `RESULTS.md @ d98a031` remaining-misses table; `scenarios.json`, `registry.example.json @ 704ab09` |
| RPI-34 | see the ledger | method | `SessionRouting.swift @ 704ab09`; `run_evals.py @ 704ab09` |
| RPI-35 | see the ledger | method | `.gitignore @ 704ab09`; `scripts/model-factory/README.md @ 704ab09` |
| RPI-36 | see the ledger | method | `scripts/model-factory/README.md @ 704ab09` Status; `train.log` |

The sentences are not duplicated here: a second copy is a second thing to keep
in sync, and the ledger is the copy that gets audited.

## Pre-flight

- [x] Every number has a ledger row citing a run artifact, and every row is
      `verified`
- [x] The title carries all four qualifiers (it is `RPI-14`), or would carry no
      number at all
- [x] Every quotable sentence carries model + prompt revision + corpus +
      tiering, in the sentence; secondary numbers name their round and tier
      (`claims-ledger.md` §4 step 3)
- [x] The losing arms and the regressions are in the results table
- [x] Flake/timeout counts are reported and marked as non-semantic
- [x] Run count is stated as **unrecorded**; no averaging or best-of is implied
- [x] "What this does not show" names the inference a reader would wrongly make
      (the "Fin routes 96% of the time" reading, cut off explicitly)
- [x] No claim generalizes a configuration into a product capability
- [x] No guardrail is described as an interlock (`STYLE.md` §3)
- [x] The limits section names the absence of a held-out split, and says the
      prompt was written against this corpus's own miss lists (`RPI-26`)
- [x] No infrastructure names in reader-facing text, except the loopback
      endpoint and the model identifier inside "Reproduce it" — the one written
      exemption in `STYLE.md` §2, which covers reproduction commands only
- [ ] **Reproduction command was actually run as written** — NOT DONE. The
      commands are transcribed from `RESULTS.md` and `scripts/model-factory/README.md`;
      nobody re-ran them while drafting this. Somebody must, against a live
      endpoint, before this leaves `review/`.
- [ ] **Lab-book entry ids are in the front matter and cited in the body** —
      NOT DONE; the book did not exist when this was drafted.
- [ ] **The measured prompt is the current one, or the piece says which one it
      is not** — PARTIAL. The body says it; the re-score `7a591f4` asks for has
      not happened. `RPI-03`, `RPI-04`, `RPI-08`, `RPI-13`, `RPI-14`, `RPI-19`,
      `RPI-28`, `RPI-31`, `RPI-32` and `RPI-33` all go `stale` the moment that
      branch merges.
- [ ] **All three upstream corrections are filed** — NOT DONE. See "Corrections
      owed upstream"; a post should not be the only place a repo's own numbers
      are stated correctly.
- [ ] **Levi has decided that his own project names may appear** — NOT DONE,
      and this is a repo-visibility decision, not a wording one. The prose here
      names only `fin` and calls the other two sessions "the newsletter
      session" and "the app session" — but this piece also tells the reader to
      open `evals/tmux-routing/RESULTS.md @ d98a031`, whose remaining-misses
      table names the third project outright, and
      `evals/tmux-routing/registry.example.json` carries all three project
      names with their task vocabularies and `~/forges/levi/…` paths.
      Paraphrasing the names out of the prose withholds nothing from anyone who
      follows the citation this piece supplies. The real question is whether
      those files become readable, and it is his.
- [ ] **Each cited artifact has been checked for what a reader can actually
      open** — NOT DONE. See `README.md` §2's reader check. Every citation in
      this piece is a path in a private repository, so as things stand no
      external reader can resolve one; opening the eval tree to make them
      resolvable is the disclosure decision in the box above.
- [ ] **Levi has approved this piece, in his own words** — NOT DONE. Nothing
      here is published.

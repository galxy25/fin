# Claims ledger

Every external claim Fin publishes has a row here naming the artifact that
makes it true. This is the audit surface: a reviewer should be able to sit with
this file and the repo and check a piece line by line without asking anyone
anything.

**The rule (from `README.md` §3): no external claim ships without a row here.**

A claim is any sentence a reader could be wrong about because of us — a number,
a capability, an availability statement, a promise about the future. Voice and
description are not claims. When in doubt, write the row; a needless row costs
nothing and a missing one costs the piece.

---

## 1. Columns

| column | what goes in it |
|---|---|
| **id** | `<PIECE>-<nn>`. The piece prefix is short and stable (`RPI` = router prompt iteration). Ids are never reused, never renumbered, and survive the piece being retitled. |
| **piece** | the file the claim appears in, relative to `content/`. A claim reused in a second piece gets a **new row with a new id**, because the surrounding qualifiers differ — never a shared row. |
| **claim** | the **exact sentence as it will be published**, verbatim, in quotes. Not a summary of it. If the sentence changes by a word, the row is re-verified. If it carries two claims, split the sentence. |
| **kind** | `performance` \| `capability` \| `availability` \| `roadmap`. See §2. |
| **evidence** | the artifact, precisely enough to open: lab-book entry id, commit sha, `path @ sha`, build number, or eval artifact path. Several are fine and often necessary. **Never** a person, a memory, or a conversation. |
| **verified by** | who opened the artifact and confirmed the sentence against it. An agent may verify; write `(agent)` after the name so a reader knows a human has not yet counter-checked. |
| **verified** | ISO date of that check. |
| **status** | `proposed` \| `verified` \| `approved` \| `published` \| `stale` \| `retired` \| `rejected`. See §3. |
| **re-check** | what would falsify this row, and when to look. Every `performance` row has one. `"never"` is only correct for a historical statement of fact about a moment (see EX-1). |

## 2. Kinds, and what each one's evidence has to be

- **performance** — a measurement. Evidence must be the run artifact, and the
  sentence must carry model + prompt revision + corpus + tiering (`STYLE.md`
  §4). A performance row without a re-check date is malformed.
- **capability** — "Fin can do X." Evidence is the commit that implements it,
  plus the test or eval that shows it working if one exists. A capability row
  proves the code exists **on `main`**; it does not prove a user can use it.
- **availability** — "You can do X today, in the app." Evidence must include a
  **build number** in App Store Connect (app id 6801892480, bundle
  `dev.levischoen.fin`) and its state. This is the kind most often written by
  accident as `capability`; the test is whether the sentence would be false for
  a reader who opens the app right now.
- **roadmap** — "We are building X." Evidence is the design doc or the tracking
  entry. The sentence must be in future or in-progress voice; a roadmap item
  written in the present tense is a false availability claim.

## 3. Status lifecycle

```
proposed ──▶ verified ──▶ approved ──▶ published ──▶ stale
    │                                                  │
    └──▶ rejected                                      └──▶ retired
```

- **proposed** — written into a draft; evidence named but not yet checked.
- **verified** — someone opened the artifact and confirmed the exact sentence.
- **approved** — Levi approved the piece containing it (`README.md` §4).
- **published** — it went out. The row is now frozen: corrections are new rows
  plus a note, never an edit to a published row's sentence.
- **stale** — the re-check condition fired (new prompt, new model, new build).
  The claim may still be true; nobody has confirmed it. **A stale row may not
  be reused in a new piece until it is re-verified.**
- **retired** — deliberately withdrawn; the note says why and where the
  correction was published.
- **rejected** — failed the audit. Kept, with the reason. Rejected rows are the
  most useful part of this file for the next person writing a draft, so they
  are never deleted.

## 4. How to verify a row

1. Open the artifact named in **evidence**. Not a search result about it, not a
   memory of it — the file, at the sha given.
2. Read the **exact sentence** in the claim column next to the artifact and ask
   `STYLE.md` §6's question: taken literally and checked, is it exactly true?
3. Check the qualifiers are *in the sentence*, not merely in the surrounding
   paragraph. Sentences get quoted alone; a qualifier that lives one paragraph
   away is a qualifier that will be lost.
4. For `performance`: confirm the number, the denominator, the tiering split,
   the model identifier, the prompt revision, and the run count all match the
   artifact. Confirm the sentence does not generalize from a configuration to a
   product.
5. For `availability`: confirm the build number exists and is in the state the
   sentence implies.
6. Write **verified by** and **verified**, set **status**, and write the
   **re-check** note as a falsification condition, not a calendar reminder.

---

## 5. Examples

Two rows that pass and two that fail, with the reasoning. These are teaching
examples; they are not claims in any live piece.

### EX-1 — passes (performance)

| field | value |
|---|---|
| **id** | `EX-1` |
| **piece** | *example only* |
| **claim** | "On the 51-scenario tmux-routing corpus (26 core, 25 adversarial), the untuned `google/gemma-4-e4b` served through LM Studio at temperature 0 scored 36/51 with the original router prompt on 2026-09-05 — the score recorded as the champion baseline in `scripts/model-factory/evals-champions.json`." |
| **kind** | performance |
| **evidence** | `scripts/model-factory/evals-champions.json` (records core 21/26, hard 15/25, overall 36/51, `modelId: google/gemma-4-e4b`, `recordedAt: 2026-09-05`, `note: "untuned local model via LM Studio"`); corroborated by `evals/tmux-routing/RESULTS.md @ d98a031` overall table, row "model, original prompt"; corpus `evals/tmux-routing/scenarios.json` |
| **verified by** | Claude Opus 5 (agent) |
| **verified** | 2026-09-06 |
| **status** | verified |
| **re-check** | never — it is a dated statement about one recorded run, and it names the prompt that produced it. **But** it goes `stale` the moment a fine-tuned candidate promotes and `evals-champions.json` is rewritten, because the clause "the score recorded as the champion baseline" is a present-tense claim about that file. Re-check on any change to `evals-champions.json` or `models/champion.json`. |

**Why it passes.** It names the model *and* that it is untuned, the prompt
revision, the corpus with its size, the 26/25 tiering, the serving stack, the
temperature, and the date. A reader who takes it literally and opens the file
finds exactly that. Critically, it does **not** say "Fin scores 36/51" — the
number belongs to a configuration, not to the product.

### EX-2 — passes (capability, with the availability trap marked)

| field | value |
|---|---|
| **id** | `EX-2` |
| **piece** | *example only* |
| **claim** | "Fin can decide on its own that something is worth telling you about and send you a notification — it is a tool the model chooses to call, not a fixed alert rule." |
| **kind** | capability |
| **evidence** | commit `3a02e1fff3d26e02b9c4741485f048e56484924d` ("Add a model-invoked notify tool: Fin's proactively-social copilot lever"), on `main` |
| **verified by** | Claude Opus 5 (agent) |
| **verified** | 2026-09-06 |
| **status** | verified |
| **re-check** | on any change to the notify tool's definition or gating. |

**Why it passes as `capability` and would fail as `availability`.** The commit
proves the code is on `main`. It does **not** prove any user has it: that needs
a build number in App Store Connect and its release state. Rewriting the
sentence as "Fin sends you a notification when it needs you — available today
on iPhone" turns it into an `availability` claim, and that row would be
`rejected` until a build number is in the evidence column.

### EX-BAD-1 — fails (performance without qualifiers)

| field | value |
|---|---|
| **id** | `EX-BAD-1` |
| **piece** | *example only* |
| **claim** | "Fin's local model scores 49/51 on routing." |
| **kind** | performance |
| **evidence** | `evals/tmux-routing/RESULTS.md` |
| **verified by** | — |
| **verified** | — |
| **status** | **rejected** |
| **re-check** | n/a |

**Why it fails — four separate ways, any one of them fatal:**

1. **No prompt revision.** The *same untuned model* scores 36/51 with the
   original prompt and 49/51 with the round-3 prompt. The number is a property
   of the model **and** the prompt together; naming only the model attributes
   the whole gain to the wrong thing. This is the repo's own cautionary example
   and the reason this ledger exists.
2. **No corpus, no tiering.** "51" is not a corpus and it hides that 26 are
   core and 25 are adversarial hard cases, and that the one remaining core
   failure (`c01`) is the gate blocker. A reader cannot tell whether 49/51 is
   near-perfect on easy cases or strong on hard ones.
3. **"Fin's local model" is not a model identifier.** `google/gemma-4-e4b`,
   untuned, is. "Fin's model" also implies a fine-tune that has not been run.
4. **"On routing" generalizes a corpus into a domain.** The measurement is
   against 51 labeled scenarios in one registry shape, scored offline. It is
   not a claim about routing in general, and it is not a claim about the app —
   the shipped Swift router assembles its prompt in different code (see
   `RPI-11` below).

The repairable version is EX-1's shape. If the sentence cannot carry all four
qualifiers — as in a social post — the rule is to **omit the number entirely**
and link to the piece that can (see `templates/social-post.md`).

### EX-BAD-2 — fails (unshipped work written as fact)

| field | value |
|---|---|
| **id** | `EX-BAD-2` |
| **piece** | *example only* |
| **claim** | "Fin's fine-tuned foreman model beats the untuned baseline on the routing gate." |
| **kind** | performance |
| **evidence** | `scripts/model-factory/README.md` |
| **verified by** | — |
| **verified** | — |
| **status** | **rejected** |
| **re-check** | n/a |

**Why it fails.** No fine-tune has been run. `scripts/model-factory/README.md`
lists "First fine-tune run (**human go required**)" as an unchecked box, and
`evals-champions.json` records only the untuned model. The cited artifact is a
*plan*; the sentence is written as a *result*. Kind is also wrong: at best this
is `roadmap` ("a fine-tuned model is next, and it only ships if it beats the
untuned score on the same corpus"), and that version cites the promotion rule
in the same README, which does exist.

---

## 6. Live ledger

Rows for pieces currently in `drafts/`, `review/`, or `published/`.

Legend: `path @ sha` means the file as of that commit. `(agent)` after a
verifier means no human has counter-checked; the approval gate in `README.md`
§4 requires Levi regardless.

### RPI — `drafts/2026-09-06-router-prompt-iteration.md` (status: draft, unapproved)

Lab-book link: **pending.** The model-factory lab book
(`scripts/model-factory/labbook/`) is being created in parallel and had no
entry ids at the time these rows were verified. Each row below therefore cites
the primary artifacts directly. **Before this piece leaves `review/`, add the
lab-book entry id for the prompt-iteration experiment to every row here** — the
published piece must cite the book, not only the repo.

| id | piece | claim (exact sentence as published) | kind | evidence | verified by | verified | status | re-check |
|---|---|---|---|---|---|---|---|---|
| RPI-01 | drafts/2026-09-06-router-prompt-iteration.md | "The corpus is 51 labeled scenarios in `evals/tmux-routing/scenarios.json`: 26 core scenarios and 25 adversarial ones written to break a router that pattern-matches on vocabulary." | capability | `evals/tmux-routing/RESULTS.md @ d98a031` ("51 scenarios (26 original + 25 adversarial `h01`–`h25`)"); corpus file `evals/tmux-routing/scenarios.json @ 704ab09` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to `scenarios.json`; the counts are the qualifier |
| RPI-02 | drafts/2026-09-06-router-prompt-iteration.md | "The deterministic baseline router, which uses no model at all, scores 29/51: 26/26 on core and 3/25 on the adversarial set." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table, row "baseline (`router_baseline.py`)" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to `router_baseline.py` or `scenarios.json` |
| RPI-03 | drafts/2026-09-06-router-prompt-iteration.md | "With the original prompt, `google/gemma-4-e4b` — untuned, served through LM Studio at temperature 0 with a 30-second per-call timeout — scored 36/51: core 21/26, hard 15/25." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table row "model, original prompt" and the run-conditions paragraph ("LM Studio at `http://localhost:1234/v1`, model `google/gemma-4-e4b`, temperature 0, 30s/call timeout"); same figures in `scripts/model-factory/evals-champions.json` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run, model change, or corpus change |
| RPI-04 | drafts/2026-09-06-router-prompt-iteration.md | "With the round-3 prompt — the same model, the same endpoint, the same corpus, the same settings — the score is 49/51: core 25/26, hard 24/25." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table row "model, reworked prompt" and Prompt-iteration-rounds table row 3; prompt `evals/tmux-routing/prompts/router.md @ 99ed9d9` (commit "Settle on the round-3 prompt: round 4's clamp cost more than it bought"), unchanged as of `main @ 704ab09` | Claude Opus 5 (agent) | 2026-09-06 | verified | **the moment `prompts/router.md` changes, or the model changes.** This row is a claim about a (model, prompt) pair; either half moving voids it |
| RPI-05 | drafts/2026-09-06-router-prompt-iteration.md | "Nothing about the model changed between those two runs: same weights, same serving stack, same settings, no fine-tune. The prompt was the whole intervention." | performance | `evals/tmux-routing/RESULTS.md @ d98a031` (one run-conditions paragraph governs every model row in both tables; the rounds table varies only the prompt); `scripts/model-factory/README.md @ 704ab09` Status list, "First fine-tune run" unchecked | Claude Opus 5 (agent) | 2026-09-06 | verified | on the first fine-tune run — after that, "no fine-tune" must be re-stated as "no fine-tune at that time" |
| RPI-06 | drafts/2026-09-06-router-prompt-iteration.md | "Round 1 scored 46/51 and round 2 scored 48/51." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Prompt-iteration-rounds table, rows 1 and 2 | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run of those prompt revisions |
| RPI-07 | drafts/2026-09-06-router-prompt-iteration.md | "Round 4 fixed both of round 3's remaining misses and broke three scenarios that round 3 had passed — `r06`, `h01`, `h12` — for a net 48/51, so round 3 is the prompt we kept." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table row 4 (48/51, misses `r06 h01 h12`) and the paragraph "Round 4 fixed the last two (c01, h08) but its stronger generic-word clamp regressed three others"; the keep decision is commit `99ed9d9` | Claude Opus 5 (agent) | 2026-09-06 | verified | if round 4 or a later round is ever re-scored |
| RPI-08 | drafts/2026-09-06-router-prompt-iteration.md | "Two scenarios still fail under the round-3 prompt: `c01` in the core set and `h08` in the hard set." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table row 3 (misses `c01 h08`) and the "Remaining misses (round-3 prompt)" table | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run; a single-run miss set is not guaranteed stable |
| RPI-09 | drafts/2026-09-06-router-prompt-iteration.md | "Two of the misses recorded in rounds 1 and 2 were 30-second endpoint timeouts rather than wrong answers — one in each round — and rounds 3 and 4 recorded none." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table daggers on `h21` (round 1) and `r01` (round 2) with the footnote "= 30s endpoint timeout, not a semantic miss (`decide()` degrades to clarify). One flake each in rounds 1–2, none in rounds 3–4." | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run — flake counts are per-run and will differ |
| RPI-10 | drafts/2026-09-06-router-prompt-iteration.md | "Two larger local models were unusable under the harness's 30-second per-call contract: `gemma-4-12b-qat` spends about 40 seconds per call on reasoning tokens, and `gemma-4-26b-a4b` would not load on the box for lack of memory." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, run-conditions paragraph | Claude Opus 5 (agent) | 2026-09-06 | verified | hardware- and build-specific; re-check on any change of machine, model build, or the 30s timeout |
| RPI-11 | drafts/2026-09-06-router-prompt-iteration.md | "This number describes the eval harness, not the shipped app: Fin's in-app router carries guidance that tracks the round-3 prompt, but it is assembled by different code and has not been scored end to end in the app." | capability | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`, `SessionRouter.promptSection` — doc comment "derived from evals/tmux-routing/prompts/router.md" and the in-body comment "Guidance text tracks evals/tmux-routing/prompts/router.md (round-3 prompt, 49/51 on the corpus) — edit THERE first, re-score, then sync here"; no in-app scoring artifact exists under `evals/` | Claude Opus 5 (agent) | 2026-09-06 | verified | when an app-level routing eval lands, this sentence must be rewritten rather than dropped |
| RPI-12 | drafts/2026-09-06-router-prompt-iteration.md | "The champion record in `scripts/model-factory/evals-champions.json` still reads 36/51, because it was seeded from the pre-rework run and a prompt change does not promote a champion." | performance | `scripts/model-factory/evals-champions.json @ 704ab09` (overall 36/51, `note: "untuned local model via LM Studio; the score to beat until a fine-tuned candidate promotes"`); promotion rule in `scripts/model-factory/README.md @ 704ab09` § "Eval gate" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any edit to `evals-champions.json` or the first promotion |
| RPI-13 | drafts/2026-09-06-router-prompt-iteration.md | "The gain is concentrated in one decision type: `start` went from 4/13 to 13/13, while `route` moved 21/24 to 23/24, `clarify` 7/10 to 9/10, and `refuse` stayed 4/4." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table, per-action columns for rows "model, original prompt" and "model, reworked prompt" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run; the per-action split is single-run like the totals |

**Notes on the RPI rows.**

- RPI-04 and RPI-03 are the two halves of the result and must never be
  published apart. A piece quoting 49/51 without 36/51 in the same passage is
  the EX-BAD-1 failure with extra steps.
- RPI-08 and RPI-09 are the honesty rows. If a reviewer cuts either for length,
  the piece stops being a scientific result and becomes an announcement, and it
  should be re-filed as one.
- RPI-11 is the row most likely to be argued away as pedantic. It is not: the
  difference between "our eval scores 49/51" and "Fin routes correctly 96% of
  the time" is the entire distance between a result and a marketing number.
- Every RPI row is single-run. The draft says so; do not let an edit remove it.

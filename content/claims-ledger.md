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
| **piece** | the file the claim appears in, relative to `content/`. **The title, subheads, pull quotes and image captions count as text in the piece** — a headline is the sentence most likely to be quoted alone, so it is the sentence most in need of a row. A claim reused in a second piece gets a **new row with a new id**, because the surrounding qualifiers differ — never a shared row. |
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
- **method** — a fact about how something was measured, what an artifact
  contains, or what has *not* been measured ("the corpus is 51 scenarios";
  "no run count is recorded"; "this describes the harness, not the app").
  Evidence is the artifact the fact is read off. A method row is not a claim
  about the product and must never be verified by looking for "the commit that
  implements it" — there often is none, and for a negative statement the point
  is that none exists. This kind exists because the first four had no bucket
  for provenance facts, and rows were being mis-filed as `capability`.

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

   **The one carve-out, stated precisely so it cannot be widened.** A number
   that is *structurally attached* to its qualifiers may inherit them: a cell
   in a results table whose header row and caption carry the model, corpus and
   tier split; or a sentence that names the round or arm it belongs to, inside
   a section whose own headline sentence carries all four. Such a number must
   still name its tier split or its round, and it must **never** be the piece's
   most quotable sentence — not the title, not a subhead, not a pull quote, not
   the lede. Everything outside that carve-out carries all four in the
   sentence. The test: if a screenshot cropped to this one line went out on its
   own, would a reader believe something false? If yes, the carve-out does not
   apply, whatever the surrounding paragraph says.

   Rows that use the carve-out say so in the **re-check** column, so a later
   reviewer knows the omission was a decision and not an oversight.
4. For `performance`: confirm the number, the denominator, the tiering split,
   the model identifier, the prompt revision, and the run count all match the
   artifact. Confirm the sentence does not generalize from a configuration to a
   product. **If the artifact does not record a run count, the row may not
   assert one.** The verifier writes what the artifact actually shows — "one
   score recorded per arm; the number of runs behind it is not recorded" — and
   the piece says the same. Inferring "one run" from "one score" is exactly the
   move this ledger exists to catch, and it is the easiest one to make because
   it feels like reading rather than guessing.
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
| **evidence** | `scripts/model-factory/evals-champions.json` (records core 21/26, hard 15/25, overall 36/51, `modelId: google/gemma-4-e4b`, `recordedAt: 2026-09-05`, `note: "untuned local model via LM Studio; the score to beat until a fine-tuned candidate promotes"`); corroborated by `evals/tmux-routing/RESULTS.md @ d98a031` overall table, row "model, original prompt"; corpus `evals/tmux-routing/scenarios.json` |
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

The **claim** column is the exact text as it appears in the piece.
`check-claims.py` fails if a claim sentence is not present verbatim in the file
the **piece** column names, so a row and its sentence cannot drift apart
silently. That check is why the rows below read like prose from the draft
rather than summaries of it: a summary that carries qualifiers the shipped
sentence lacks is how an unqualified headline passes a checked-off audit.

### RPI — `drafts/2026-09-06-router-prompt-iteration.md` (status: draft, unapproved)

Lab-book link: **pending.** The model-factory lab book
(`scripts/model-factory/labbook/`) is being created in parallel and had no
entry ids at the time these rows were verified. Each row below therefore cites
the primary artifacts directly. **Before this piece leaves `review/`, add the
lab-book entry id for the prompt-iteration experiment to every row here** — the
published piece must cite the book, not only the repo.

**Standing hazard on this whole block.** The prompt these rows describe has
already been corrected on an unmerged branch: `7a591f4` (2026-09-06, branch
`imac-site`, not an ancestor of `main @ 704ab09`) rewrites the registry
paragraph of `evals/tmux-routing/prompts/router.md`, and its own inline comment
says to "re-score `router_llm.py` against it when a local endpoint is up
again." Every row whose re-check names the prompt goes `stale` on that merge.
A ledger that only ever looks at `main` cannot see this coming, so it is
written down here instead: **before this piece moves out of `review/`, diff
`prompts/router.md` across every live branch, not just `main`.**

| id | piece | claim (exact text as published) | kind | evidence | verified by | verified | status | re-check |
|---|---|---|---|---|---|---|---|---|
| RPI-01 | drafts/2026-09-06-router-prompt-iteration.md | "`evals/tmux-routing/scenarios.json` — 51 labeled scenarios, **26 core** and **25 adversarial** (`h01`–`h25`)." | method | `evals/tmux-routing/RESULTS.md @ d98a031` ("51 scenarios (26 original + 25 adversarial `h01`–`h25`)"); corpus file `evals/tmux-routing/scenarios.json @ 704ab09` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to `scenarios.json`; the counts are the qualifier. Re-filed from `capability` to `method` on 2026-09-06: it is a fact about an artifact, not something Fin can do |
| RPI-02 | drafts/2026-09-06-router-prompt-iteration.md | "The deterministic baseline router, which uses no model at all, scores 29/51 on the same 51-scenario corpus: 26/26 on core and 3/25 on the adversarial set." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table, row "baseline (`router_baseline.py`)" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to `router_baseline.py` or `scenarios.json`. **Carve-out (§4.3):** no model qualifier, because this arm uses no model — the sentence says so; corpus and tiering are in the sentence |
| RPI-03 | drafts/2026-09-06-router-prompt-iteration.md | "With the original router prompt (`evals/tmux-routing/prompts/router.md @ 96ea006`), the untuned `google/gemma-4-e4b` — served through LM Studio at temperature 0 with a 30-second per-call timeout — scored 36/51 on the 51-scenario tmux-routing corpus: core 21/26, hard 15/25." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table row "model, original prompt" and the run-conditions paragraph ("LM Studio at `http://localhost:1234/v1`, model `google/gemma-4-e4b`, temperature 0, 30s/call timeout"); same figures in `scripts/model-factory/evals-champions.json`; the prompt revision is `evals/tmux-routing/prompts/router.md @ 96ea006` — the harness's initial commit, established by `git log -- evals/tmux-routing/prompts/router.md`, whose next touch is round 1 at `22005c7` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run, model change, or corpus change. **Note:** neither `RESULTS.md` nor `evals-champions.json` records a prompt sha for this arm — the sha above is recovered from the file's commit history, and it is the weakest link in the row. Anyone re-running this must record the prompt sha in the artifact |
| RPI-04 | drafts/2026-09-06-router-prompt-iteration.md | "With the round-3 prompt (`evals/tmux-routing/prompts/router.md @ 99ed9d9`) — the same untuned `google/gemma-4-e4b`, the same endpoint, the same settings, the same 51-scenario corpus — the score is 49/51: core 25/26, hard 24/25." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table row "model, reworked prompt" and rounds table row 3; prompt `evals/tmux-routing/prompts/router.md @ 99ed9d9` ("Settle on the round-3 prompt"), byte-identical to `fcb10b2` where round 3 was introduced (blob `c511bab`), unchanged as of `main @ 704ab09` | Claude Opus 5 (agent) | 2026-09-06 | verified | **the moment `prompts/router.md` changes on any branch, or the model changes.** This row is a claim about a (model, prompt) pair; either half moving voids it. **Already pending:** `7a591f4` on `imac-site` changes that file and asks for a re-score — see the standing hazard above. This row goes `stale` on that merge |
| RPI-05 | drafts/2026-09-06-router-prompt-iteration.md | "Nothing about the model changed between those two runs — same weights, same serving stack, same settings, no fine-tune — so the prompt was the whole intervention." | performance | `evals/tmux-routing/RESULTS.md @ d98a031` (one run-conditions paragraph governs every model row in both tables; the rounds table varies only the prompt); `scripts/model-factory/README.md @ 704ab09` Status list, "First fine-tune run" unchecked | Claude Opus 5 (agent) | 2026-09-06 | verified | on the first fine-tune run — after that, "no fine-tune" must be re-stated as "no fine-tune at that time" |
| RPI-06 | drafts/2026-09-06-router-prompt-iteration.md | "Round 1 scored 46/51 and round 2 scored 48/51 on that corpus." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table, rows 1 and 2 | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run of those prompt revisions. **Carve-out (§4.3):** a secondary number inside the Results section, whose table row names the prompt sha and the tier split, and whose section headline carries all four qualifiers. It is not quotable alone as a claim about the product because it names a round, not Fin |
| RPI-07 | drafts/2026-09-06-router-prompt-iteration.md | "Round 4 fixed both of round 3's remaining misses and broke three scenarios that round 3 had passed — `r06`, `h01`, `h12` — for a net 48/51, so round 3 is the prompt we kept" | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table row 4 (48/51, misses `r06 h01 h12`) and the paragraph "Round 4 fixed the last two (c01, h08) but its stronger generic-word clamp regressed three others"; the keep decision is commit `99ed9d9`; round 4 is `e7460cd` | Claude Opus 5 (agent) | 2026-09-06 | verified | if round 4 or a later round is ever re-scored. Carve-out (§4.3): names its round |
| RPI-08 | drafts/2026-09-06-router-prompt-iteration.md | "Two scenarios still fail under the round-3 prompt: `c01` in the core set and `h08` in the hard set." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table row 3 (misses `c01 h08`) and the "Remaining misses (round-3 prompt)" table | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run; a miss set from one recorded score is not guaranteed stable. Goes `stale` with RPI-04 when the prompt changes. Carve-out (§4.3): names its prompt revision and both tiers |
| RPI-09 | drafts/2026-09-06-router-prompt-iteration.md | "Two of the misses recorded in rounds 1 and 2 were 30-second endpoint timeouts rather than wrong answers — one in each round — and rounds 3 and 4 recorded none." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table daggers on `h21` (round 1) and `r01` (round 2) with the footnote "= 30s endpoint timeout, not a semantic miss (`decide()` degrades to clarify). One flake each in rounds 1–2, none in rounds 3–4." | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run — flake counts are per-run and will differ. Carve-out (§4.3): names its rounds; it is a count of flakes, not a score |
| RPI-10 | drafts/2026-09-06-router-prompt-iteration.md | "Two larger local models were unusable under the harness's 30-second per-call contract: `gemma-4-12b-qat` spends about 40 seconds per call on reasoning tokens, and `gemma-4-26b-a4b` did not fit in the available memory on the machine we scored on." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, run-conditions paragraph ("`gemma-4-12b-qat` spends ~40s/call on reasoning tokens; `gemma-4-26b-a4b` refuses to load for lack of memory") | Claude Opus 5 (agent) | 2026-09-06 | verified | hardware- and build-specific; re-check on any change of machine, model build, or the 30s timeout. **Wording note:** `RESULTS.md` says "on the box"; `STYLE.md` §1 puts "boxes" on the never-say list for the machines Fin runs on, so the published sentence says "the machine we scored on" |
| RPI-11 | drafts/2026-09-06-router-prompt-iteration.md | "This number describes the eval harness, not the shipped app: Fin's in-app router carries guidance that tracks the round-3 prompt, but it is assembled by different code and has not been scored end to end in the app." | method | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`, `SessionRouter.promptSection` — doc comment "derived from evals/tmux-routing/prompts/router.md" and the in-body comment "Guidance text tracks evals/tmux-routing/prompts/router.md (round-3 prompt, 49/51 on the corpus) — edit THERE first, re-score, then sync here"; no in-app scoring artifact exists anywhere under `evals/` at `704ab09` | Claude Opus 5 (agent) | 2026-09-06 | verified | when an app-level routing eval lands, this sentence must be rewritten rather than dropped. Re-filed from `capability` to `method` on 2026-09-06: it is a statement about what has **not** been measured, and a verifier applying the `capability` procedure would go looking for an implementing commit that by construction does not exist |
| RPI-12 | drafts/2026-09-06-router-prompt-iteration.md | "The champion record in `scripts/model-factory/evals-champions.json` still reads 36/51, because it was seeded from the pre-rework run and a prompt change does not promote a champion." | performance | `scripts/model-factory/evals-champions.json @ 704ab09` (overall 36/51, `note: "untuned local model via LM Studio; the score to beat until a fine-tuned candidate promotes"`); promotion rule in `scripts/model-factory/README.md @ 704ab09` § "Eval gate" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any edit to `evals-champions.json` or the first promotion |
| RPI-13 | drafts/2026-09-06-router-prompt-iteration.md | "The gain from round 0 to round 3 is concentrated in one decision type: `start` went from 4/13 to 13/13, while `route` moved 21/24 to 23/24, `clarify` 7/10 to 9/10, and `refuse` stayed 4/4." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, Overall table, per-action columns for rows "model, original prompt" and "model, reworked prompt" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run; the per-action split comes from the same recorded scores as the totals. Carve-out (§4.3): names both rounds, inside the Results section |
| RPI-14 | drafts/2026-09-06-router-prompt-iteration.md | "Same untuned `google/gemma-4-e4b`, two router prompts: 36/51 with the original, 49/51 with round 3, on the 51-scenario tmux-routing corpus (26 core, 25 hard)" | performance | the title and H1; the numbers are RPI-03 and RPI-04's evidence — `evals/tmux-routing/RESULTS.md @ d98a031` Overall table, with `prompts/router.md @ 96ea006` (original) and `@ 99ed9d9` (round 3) | Claude Opus 5 (agent) | 2026-09-06 | verified | goes `stale` whenever RPI-03 or RPI-04 does. **This row exists because the title is the sentence most likely to travel alone.** It carries the model, both prompt revisions by round, the corpus and the tiering; it deliberately does not say "Fin", because a headline naming Fin and a score is the EX-BAD-1 failure |
| RPI-15 | drafts/2026-09-06-router-prompt-iteration.md | "Fin's router emits one of four decisions for every request: `route` to an existing registered session, `start` a new one, `clarify` when the request is genuinely ambiguous, or `refuse` when the target is a live session that was never registered with Fin." | capability | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`, `enum RoutingDecision` — the four cases with their doc comments ("Deliver to an existing, registered session", "Create a new coding-agent session for this task", "Ambiguous — ask the user instead of guessing", "Target exists but is not registered/fin-created — off-limits") and `var action` returning exactly `route`/`start`/`clarify`/`refuse`; same contract in `evals/tmux-routing/prompts/router.md @ 99ed9d9` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to `RoutingDecision`'s cases or the JSON contract |
| RPI-16 | drafts/2026-09-06-router-prompt-iteration.md | "`refuse` is a decision, not an interlock: on `main` the router's answer to a live-but-unregistered target is to say what it found and ask you to register it, and nothing in the daemon's send path enforces that answer." | capability | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`: `decide()` arms its guardrail branch only when the query matches `sessionContextPattern` (`\b(session\|window\|tmux\|terminal)\b`), and the branch returns `.refuse` with "register it before Fin will send keys there"; `daemon/Sources/FinAgentCore/AgentTurnEngine.swift @ 704ab09` `executeSendInput`, whose only gate is `DestructiveCommandHeuristic.isDestructive` — there is no registry allow-list check; `TmuxCommandGuard.swift` is **absent** from `main` (`git ls-tree -r main -- daemon/Sources/FinAgentCore/`) and exists only on the unmerged `imac-site` branch (`17a566a`, hardened by `7a591f4`, `cd64914`, `3d8fa17`) | Claude Opus 5 (agent) | 2026-09-06 | verified | **when `imac-site` merges this row must be rewritten**, because the enforcing guard will then be on `main` and the honest sentence changes. Until then, no piece may say Fin "only touches", "cannot type into", or "will not touch" an unregistered session — see `STYLE.md` §3 and `CB-1` below |
| RPI-17 | drafts/2026-09-06-router-prompt-iteration.md | "the harness's exit code gates on the core tier alone: `run_evals.py` returns 0 only when all 26 core scenarios pass." | method | `evals/tmux-routing/run_evals.py @ 704ab09`, `main()`: `return 0 if core_passed == core_total else 1` | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to the exit-code logic. **Known artifact defect:** the same file's module docstring says "Exit status: 0 if every scenario passes, 1 otherwise", which contradicts the code. The code is right; the docstring is stale and is listed under "Corrections owed upstream" in the piece. A reader following the reproduction instructions opens that file, so the correction should land before publication |
| RPI-18 | drafts/2026-09-06-router-prompt-iteration.md | "the corpus is the gate, so its literal scenarios are held out of training data by rule — and the only dataset built so far derives from that corpus, which is why `scripts/model-factory/README.md` blocks the first fine-tune on synthetic variants replacing it." | method | `scripts/model-factory/README.md @ 704ab09`: the Leakage rule ("`evals/tmux-routing/scenarios.json` (core + hard) is the gate, so its literal scenarios are **held out** — they never appear in `train.jsonl` or `val.jsonl`"), the dataset-builder caveat ("**Leakage caveat:** the seed build derives from the eval corpus itself; synthetic variants + telemetry must replace it before a real training run"), and the unchecked Status item "Synthetic expansion of the routing taxonomy (satisfies the leakage rule; unblocks the first real fine-tune)" | Claude Opus 5 (agent) | 2026-09-06 | verified | when synthetic expansion lands or the first fine-tune runs. **The exception is the load-bearing half of this row:** stating the rule without the caveat would tell a leakage-conscious reader something the repo's own README contradicts |
| RPI-19 | drafts/2026-09-06-router-prompt-iteration.md | "`c01` is the gate blocker: core stands at 25/26 under the round-3 prompt, and the harness's exit-code gate requires 26/26." | performance | `evals/tmux-routing/RESULTS.md @ d98a031` ("Core stands at 25/26 — c01 is the only gate blocker") and rounds table row 3; the gate itself is `evals/tmux-routing/run_evals.py @ 704ab09` `main()` (see RPI-17) | Claude Opus 5 (agent) | 2026-09-06 | verified | goes `stale` with RPI-04 and RPI-08 when the prompt or the corpus changes. Carve-out (§4.3): names its prompt revision and its tier |
| RPI-20 | drafts/2026-09-06-router-prompt-iteration.md | "Round 1 fixed fourteen of the fifteen round-0 misses and introduced four new ones — `h01`, `h07`, `h08` and `h21`, the last a 30-second endpoint timeout rather than a wrong answer — while `c01` failed in round 0 and failed again in round 1." | performance | `evals/tmux-routing/RESULTS.md @ d98a031`, rounds table rows 0 and 1, read as sets: round 0 misses `s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23` (15), round 1 misses `c01 h01 h07 h08 h21†` (5), so 14 fixed, `c01` persisting, 4 new; the dagger footnote marks `h21` as a 30s timeout | Claude Opus 5 (agent) | 2026-09-06 | verified | on any re-run of round 0 or round 1. **This row corrects the prose in its own source artifact**, which says round 1 "fixed all fifteen round-0 misses" and lists `c01` as one of the over-corrections it introduced — contradicting the table two lines above it. The table is the evidence; the correction is owed upstream and the piece says so. The error is not cosmetic: it converts a persistent core failure into an artifact of the rewrite, which flatters the intervention |
| RPI-21 | drafts/2026-09-06-router-prompt-iteration.md | "`evals/tmux-routing/` is both the spec and the gate for the model factory's first fine-tune target, so the question was how far prompt work could go against that gate before it ran into the model itself." | method | `scripts/model-factory/README.md @ 704ab09`, "Fine-tune targets, in priority order: 1. **tmux session management** — routing/discrimination between sessions. `evals/tmux-routing/` is both the spec and the gate." | Claude Opus 5 (agent) | 2026-09-06 | verified | on any change to the fine-tune target list. **Replaces an unsourced sentence** in the first draft of this piece ("if prompt work could not clear the corpus, the next move is a fine-tune; if it could, the fine-tune budget goes elsewhere first") — no artifact recorded that decision, and the README's priority order says the opposite. A motive is a claim |
| RPI-22 | drafts/2026-09-06-router-prompt-iteration.md | "Routing remains the model factory's first fine-tune target: prompt work moved this score, and the first fine-tune run is still an unchecked, human-gated item in `scripts/model-factory/README.md`." | roadmap | `scripts/model-factory/README.md @ 704ab09`, Status list: "- [ ] First fine-tune run (**human go required** — see Hard rule)" and "- [ ] Synthetic expansion of the routing taxonomy", with routing listed first under Fine-tune targets | Claude Opus 5 (agent) | 2026-09-06 | verified | when the first fine-tune runs, or when the target order changes. Written in present/in-progress voice deliberately: it is a statement about a plan, not about a capability |
| RPI-23 | drafts/2026-09-06-router-prompt-iteration.md | "`RESULTS.md` records one score per prompt revision and no repeats; the number of times each configuration was actually scored is not recorded in any artifact in the repo, so nothing here should be read as an average, a best-of, or a variance estimate." | method | `evals/tmux-routing/RESULTS.md @ d98a031` — records date, endpoint, model, temperature and timeout, and one score per table row, and states no run count anywhere; `git ls-tree -r 704ab09 -- evals/tmux-routing/` lists nine files, none of them run logs | Claude Opus 5 (agent) | 2026-09-06 | verified | when a run artifact that records repeats exists — at which point this row is replaced by one that states the real count. **This row replaces "one scored run per prompt revision", which the first draft asserted as a method fact.** No artifact says that. One score recorded is not one run performed, and the honest sentence is the weaker one |
| RPI-24 | drafts/2026-09-06-router-prompt-iteration.md | "`RESULTS.md` names *dead ≠ unregistered* as the first of the three prompt-fixable failure classes the original run exposed, and the rewrite was built around it." | method | `evals/tmux-routing/RESULTS.md @ d98a031`: "The rework targeted the three prompt-fixable failure classes the first model run exposed: **dead ≠ unregistered** (a registered session absent from the live list means recreate/`start`, never `refuse`), **explicit-new synonym coverage** …, and **mention ≠ target** …" | Claude Opus 5 (agent) | 2026-09-06 | verified | on any rewrite of that paragraph. Attributed to the artifact on purpose: "the original prompt conflated them" would be a causal claim about a model's failure that no run artifact establishes |

**Notes on the RPI rows.**

- RPI-04 and RPI-03 are the two halves of the result and must never be
  published apart. A piece quoting 49/51 without 36/51 in the same passage is
  the EX-BAD-1 failure with extra steps. RPI-14, the title, carries both for
  the same reason.
- RPI-08, RPI-09, RPI-19, RPI-20 and RPI-23 are the honesty rows. If a reviewer
  cuts any of them for length, the piece stops being a scientific result and
  becomes an announcement, and it should be re-filed as one. RPI-20 in
  particular is the row that costs us something: it says the intervention did
  less than its own source artifact claims.
- RPI-11 and RPI-16 are the rows most likely to be argued away as pedantic.
  They are not. RPI-11 is the distance between "our eval scores 49/51" and "Fin
  routes correctly 96% of the time". RPI-16 is the distance between a decision
  and a guarantee, and it is the one that could get a user's production
  terminal typed into.
- No RPI row asserts a run count. The artifact does not record one; see RPI-23
  and §4 step 4. Do not let an edit "tidy" this into "one run".
- Six rows (RPI-03, RPI-04, RPI-08, RPI-13, RPI-14, RPI-19) are claims about a
  (model, prompt) pair whose prompt half is already superseded on an unmerged
  branch. See the standing hazard above.

---

## 7. Copy blocks outside a piece

`STYLE.md` §3 contains sentences written to be **lifted verbatim** into posts,
App Store descriptions, and review notes. That makes them the most-copied text
in this directory — and until 2026-09-06 they were the least-audited, because
the ledger's scope was "pieces in `drafts/`, `review/`, `published/`" and
`STYLE.md` is none of those.

**A sentence written to be copied is a claim before it is copied.** Ready-made
copy gets a row here, re-verified against `main` on the day it is used. The
`CB` rows below are the standing ones.

| id | source | claim (exact text) | kind | evidence | verified by | verified | status | re-check |
|---|---|---|---|---|---|---|---|---|
| CB-1 | `STYLE.md` §3, until 2026-09-06 | "Fin only touches sessions you registered." | capability | — | Claude Opus 5 (agent) | 2026-09-06 | **rejected** | n/a — kept as the teaching case. It asserts an interlock. On `main @ 704ab09` nothing in the send path enforces it: `AgentTurnEngine.executeSendInput` gates only on `DestructiveCommandHeuristic`, the deterministic router's `refuse` branch arms only when the query contains a session-ish word (`sessionContextPattern`), and `TmuxCommandGuard.swift` — the allow-list that would make the sentence true — is absent from `main` and lives on the unmerged `imac-site` branch. A reader who took it literally could leave an unregistered production terminal open on that assurance |
| CB-2 | `STYLE.md` §3, replacement | "When a request names a terminal that is running on the machine but was never registered with Fin, the designed answer is to say what it found and ask you to register it, rather than type into it." | capability | `daemon/Sources/FinAgentCore/SessionRouting.swift @ 704ab09`, `RoutingDecision.refuse` and `decide()` step 1; `evals/tmux-routing/prompts/router.md @ 99ed9d9` ("Live but not registered → OFF-LIMITS: never send keys to it … say what you found and ask the user to register it") | Claude Opus 5 (agent) | 2026-09-06 | verified | rewrite when `imac-site` merges and the enforcement exists — at that point a stronger sentence becomes available and this one becomes needlessly weak. Note it describes a *decision*: it says what Fin is built to do, not what is impossible |
| CB-3 | `STYLE.md` §3, until 2026-09-06 | "a message lands in the wrong session, and you can see which session every message went to and move it" | availability | — | Claude Opus 5 (agent) | 2026-09-06 | **rejected** | n/a — kept as the teaching case. It describes an app affordance that does not exist: `git grep -n "sessionName\|routedTo\|targetSession" main -- fin` returns nothing, and no view under `fin/Views/` implements per-message session attribution or a move/reassign control. It is an `availability` claim, so it would need a build number even if the code existed. Ready-to-paste copy that is provably false in the app is worse than no copy: it is false in exactly the place the copy was meant to build trust |

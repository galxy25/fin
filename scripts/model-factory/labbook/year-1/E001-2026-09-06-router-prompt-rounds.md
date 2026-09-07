---
id: E001
date: 2026-09-06
occurred: 2026-09-05
kind: EXPERIMENT
title: Router prompt iteration, rounds 0-4 — 36/51 to 49/51, and one revision reverted
status: closed
tags: [prompt, evals, routing, negative-result]
sources:
  - 96ea006 — harness + original prompt (2026-09-05 11:54)
  - 6b1c95f — "Model-backed router adapter + first scored run (36/51 vs baseline 29/51)" (12:17)
  - 22005c7 — round 1 (12:38) · f0040f5 — round 2 (12:46) · fcb10b2 — round 3 (12:54) · e7460cd — round 4 (13:01)
  - 99ed9d9 — "Settle on the round-3 prompt: round 4's clamp cost more than it bought" (13:07)
  - d98a031 — "RESULTS.md: reworked-prompt scores — 49/51, core 25/26, hard 24/25" (13:08)
  - evals/tmux-routing/RESULTS.md (the full record, 4,532 bytes)
related: [O002, O003, E005, P001]
corrects: []
superseded-by: null
---

## Question

How far can prompt engineering alone carry an untuned local model on the
tmux-routing corpus, and where does it stop paying?

## Method

One model, one corpus, one endpoint; only the prompt changed.

- **Model:** `google/gemma-4-e4b`, served by LM Studio at
  `http://localhost:1234/v1`, temperature 0, 30 s per-call timeout.
- **Corpus:** `evals/tmux-routing/scenarios.json`, 51 scenarios — 26 core
  (`r01`-`r11`, `s01`-`s06`, `c01`-`c05`, `f01`-`f04`) + 25 adversarial hard
  (`h01`-`h25`). Verified today by parsing the file: 51 total, 25 flagged
  `hard`, expected actions route 24 / start 13 / clarify 10 / refuse 4.
- **Command:**
  ```sh
  FIN_ROUTER_MODEL=google/gemma-4-e4b \
    python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py
  ```
- **Discipline:** one commit per round, each touching only
  `evals/tmux-routing/prompts/router.md`. The whole campaign ran between
  **12:17 and 13:08 on 2026-09-05** — 51 minutes, five scored runs.

The larger local models were not options under the 30 s contract:
`gemma-4-12b-qat` spends ~40 s/call on reasoning tokens; `gemma-4-26b-a4b`
refuses to load for lack of memory (`RESULTS.md`, run-conditions block).

## Result

| round | overall | core | hard | misses |
| --- | --- | --- | --- | --- |
| 0 (original prompt) | 36/51 | 21/26 | 15/25 | s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |
| 1 (three-classes rewrite) | 46/51 | 25/26 | 21/25 | c01 h01 h07 h08 h21† |
| 2 (imperative-first, honest vocab, start=lifecycle) | 48/51 | 24/26 | 24/25 | r01† f01 h08 |
| **3 (route⊆registry, start-object test) — KEPT** | **49/51** | **25/26** | **24/25** | c01 h08 |
| 4 (generic-phrase clamp, anti-contrast rule) — reverted | 48/51 | 25/26 | 23/25 | r06 h01 h12 |

† = a 30 s endpoint timeout, not a semantic miss (`decide()` degrades to
`clarify`). One flake each in rounds 1-2, none in rounds 3-4 — so rounds 1 and
2 have semantic ceilings of 47 and 49, and the round-2-vs-round-3 comparison is
one point tighter than the table suggests.

For reference on the same corpus: the deterministic
`evals/tmux-routing/router_baseline.py` scores **29/51 — core 26/26, hard
3/25** (reproduced today, E005).

What each round changed, with the size of the prompt after it. Sizes are `wc`
on the file at that commit; hashes are `git hash-object` (git blob sha1, not
a plain content sha1):

| sha | time | change | lines/words | blob sha1 |
| --- | --- | --- | --- | --- |
| `96ea006` | 11:54 | original block, created with the harness | 46 / 423 | `9180af5c5312…` |
| `22005c7` | 12:38 | dead ≠ unregistered; explicit-new synonyms; mention ≠ target (+114/−20) | 140 / 1241 | — |
| `f0040f5` | 12:46 | imperative-first; "vocabulary is evidence, not a whitelist"; start = lifecycle only; "do not imagine registry contents" (+30/−14) | 156 / 1424 | — |
| `fcb10b2` | 12:54 | route target MUST be a registry name; start's object must be a session/agent/terminal, not a feature or plan (+16/−6) | 166 / 1552 | `c511bab2bf99…` |
| `e7460cd` | 13:01 | generic-phrase two-session test; "unlike X, Y needs…" targets Y (+8/−2) | 172 / 1631 | — |
| `99ed9d9` | 13:07 | **revert to round 3** (−8/+2) | 166 / 1552 | `c511bab2bf99…` |

The revert is exact: `git hash-object` of `router.md` at `fcb10b2` and at
`99ed9d9` are both `c511bab2bf99495603e199fbfe82a6b9f5c9dab5` — verified today,
not assumed.

## The negative result: round 4

Round 4 is the most useful row in the table. It did exactly what it was
designed to do and was still worse.

Its two rules fixed both remaining misses — c01 and h08, the only two the kept
prompt gets wrong — and broke three scenarios that round 3 gets right
(`99ed9d9`'s message):

| scenario | round 3 | round 4 | why round 4 broke it |
| --- | --- | --- | --- |
| r06 | pass | fail | a direct session-name mention got second-guessed as "generic tests" |
| h01 | pass | fail | a domain paraphrase got re-labeled as generic |
| h12 | pass | fail | refused on an adjectival "main" |

Net −1 overall, hard 23 vs 24. It was reverted 6 minutes after it was
committed.

**The finding that generalizes:** rounds 2 and 4 both demonstrate a see-saw.
Tightening the "don't route on generic words" rule buys c01/h08 and costs
r06/h01/h12; loosening it does the reverse. The two rules the model needs —
*allow domain paraphrase* (for h01-h03) and *refuse generic vocabulary
matches* (for c01) — are in direct tension at this model size, and prose cannot
separate them.

## Where it stopped

Round 3 is kept at 49/51. The two residual misses (`RESULTS.md`, "Remaining
misses"):

- **c01 (core, expected `clarify`)** — "run the tests" routes to `fin`, the
  model rationalizing bare "tests" as fin's "testing and app development"
  domain. This is the **only core blocker**; core 25/26 fails P001's
  non-negotiable gate.
- **h08 (hard, expected `route`→`fin`)** — "unlike the newsletter rollout, the
  widget release needs a phased rollout - set that up" routes to
  `africanintellect`: the contrast-clause noun outweighs the imperative's
  "widget", which is literally in fin's vocabulary.

`RESULTS.md`'s own conclusion, which is the sentence to keep: *"Both residual
misses look like model-capacity limits at this prompt length rather than
missing rules… A stronger local model under the 30s contract, or a shorter
compiled prompt, is the likelier path to 26/26 than more prose."*

That conclusion is the reason the fine-tune (E004) exists.

## What this does not show

- **It does not show 49/51 is stable.** Every model-backed score here is a
  single run of 51 scenarios at temperature 0 against a local endpoint. No
  repeat runs, no variance estimate. Two rounds contain a timeout flake, which
  is direct evidence that a rerun can move a number by a point.
- **It does not show the numbers still hold.** Nothing has re-scored any of
  these since 2026-09-05 13:08. See O002.
- **Rounds 1, 2 and 4 have no per-action breakdown.** `RESULTS.md` records
  route/start/clarify/refuse columns only for round 0 and round 3. All four
  prompt revisions are recoverable by sha, so the gap is fillable.
- **UNSOURCED: no raw run artifact exists for any of the five scored runs.**
  `README.md` promises that "every scored run — promoted or not — writes its
  raw output to `evals/<model-id>/<run-id>.json`", and no such file exists
  anywhere in the repo. These numbers trace to `RESULTS.md` prose and commit
  messages written at the time — a contemporaneous record, not captured
  stdout. *Settled by:* re-running each revision through `eval_gate.py`, whose
  verdict JSON does embed `runOutput`.

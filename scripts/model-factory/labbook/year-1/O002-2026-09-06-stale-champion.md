---
id: O002
date: 2026-09-06
occurred: 2026-09-05 / 2026-09-06
kind: OBSERVATION
title: The recorded champion is a round-0 number — the gate would promote a candidate 12 points worse than the base model
status: standing
tags: [gate, champion, promotion, risk]
sources:
  - scripts/model-factory/evals-champions.json — one commit ever (a823271, 2026-09-05 12:59), never edited
  - evals/tmux-routing/RESULTS.md:25-27 (36/51 round 0 vs 49/51 round 3, same model)
  - 6b1c95f (12:17, the 36/51 run) vs 22005c7 (12:38, first edit to router.md)
  - evals/tmux-routing/router_llm.py — _prompt_block() reads prompts/router.md at call time
  - scripts/model-factory/eval_gate.py:110-112 (the rule); d9100b6 gate_sweep.sh:13-17 (the repo's own diagnosis)
related: [P001, P004, E001, O003, O005]
corrects: []
superseded-by: null
---

## What was observed

`scripts/model-factory/evals-champions.json` records the bar a candidate must
beat as **36/51 (core 21/26, hard 15/25)** for `google/gemma-4-e4b`. That number
was measured with the **round-0** router prompt — a 46-line, 423-word file that
has not existed in the tree since 12:38 on 2026-09-05.

The prompt that is actually shipped on `main` is the round-3 keeper, 166 lines,
git blob `c511bab2bf99…`. **The same untuned model, on the same 51 scenarios,
scores 49/51 with it** (`RESULTS.md:27`).

Ordering, which is what makes this certain rather than likely: the 36/51 run is
commit `6b1c95f` at 2026-09-05 **12:17**; the first edit to `router.md` after
its creation is `22005c7` at **12:38**. No revision of the prompt exists
between `96ea006` (11:54) and the run.

### The tier split in that record was not printed by the harness

Worth stating plainly, because a reader who re-derives from `6b1c95f` will
otherwise be stranded. `git show 6b1c95f:evals/tmux-routing/scenarios.json`
parses to **51 scenarios, none of them flagged `hard`**. Tiering arrives one
minute later in `2234284` ("Tier the routing corpus: core gates, hard
benchmarks", 12:18), a child of `6b1c95f`, which rewrites `scenarios.json`
(+509/−56) and `run_evals.py` (+16/−2). So the `core: 21/26` / `hard: 15/25`
fields stored in `evals-champions.json` **cannot have been printed by the
harness at the time of that run** — they are a post-hoc re-partition of the same
51 results.

The re-partition is legitimate, and that is checkable: diffing the two revisions
of `scenarios.json` shows identical scenario ids, queries, `expected` objects and
registry/live context, with only `hard` flags and `note` fields added; and
E001's round-0 miss list splits 5-core / 10-hard, exactly as recorded. The
overall 36/51 is untouched by any of this. The record is a re-partition, not a
re-measurement, and nothing in the file says so.

## Why it matters

`eval_gate.py` serves a candidate through `router_llm.py`, whose
`_prompt_block()` reads `prompts/router.md` **at scoring time**. So a candidate
is scored under round 3 and compared against a number produced under round 0.

| | prompt used | score |
| --- | --- | --- |
| candidate side (today) | round 3, 166 lines | whatever it gets |
| champion side (stored) | round 0, 46 lines | 36/51 |
| what the champion side *should* be | round 3, 166 lines | 49/51 |

**The false-promotion window:** any candidate that passes core 26/26 and scores
**37-49 overall** promotes, while being no better than — and up to **12** points
worse than — the untuned base model measured on the same prompt. Under a
correctly re-recorded champion the same candidate would need ≥50/51.

12, not 13, because `beats()` is *strict* (`eval_gate.py:75-80`, quoted in
P001): against a stored 36/51 the worst candidate that still promotes scores
**37**, and 49 − 37 = 12. 13 is the separate and also-true number — the gap
between the stored champion record and what the base actually scores under the
shipped prompt (49 − 36). The record is 13 points too low; the candidate can be
12 points worse.

Either way the quantity is the base model's own prompt engineering (E001) being
credited to the fine-tune.

## Status: diagnosed, not fixed

This is the repo's own finding, not an outside audit. `gate_sweep.sh`'s header
(`d9100b6`, 2026-09-06 08:05) states it:

> *"RE-RECORD THE CHAMPION. evals-champions.json still holds 36/51, which was
> measured with the round-0 router prompt; the kept round-3 prompt scores 49/51
> on the same untuned model. Scoring a candidate against the stale number would
> flatter it into a false promotion."*

and its last line is `champion: … || echo 'NOT RE-RECORDED — do not promote on
the stale 36/51'`.

But:

- `evals-champions.json` still reads 36/51 — one commit, `a823271`, never
  edited since 2026-09-05 12:59.
- `gate_sweep.sh` is **not on main** (`git merge-base --is-ancestor d9100b6
  main` fails) and has never been run: `models/gate-sweep/` does not exist.
- The guard is runbook text, not code. `eval_gate.py` never reads `recordedAt`;
  nothing in the gate can notice that a champion is stale.

## What would fix it

Three options, none chosen — recorded so the choice is deliberate when it is
made:

1. **Re-record in place.** Score the untuned model under the current prompt and
   overwrite the JSON. Loses the historical marker.
2. **Add a second entry** keyed by prompt revision, and have the gate select
   the champion whose prompt hash matches the one it is about to score under.
   Requires O005's provenance fields first.
3. **Fail closed.** Have `eval_gate.py` refuse to run when the champion record
   carries no prompt hash, or when the hash does not match. Turns a silent
   flattering into an error.

There are also potentially **three** champion records with no reconciliation
code: `evals-champions.json` in the repo, `models/champion.json` in S3 (which
`README.md` calls "the authoritative record" — **UNSOURCED**, not read, AWS is
read-only here), and `gate_sweep.sh`'s scratch file
`models/gate-sweep/champion.txt`.

## What this does not show

- **It does not show a false promotion has happened.** No candidate has been
  gated at all; run 1 is still training (E004).
- **It does not show 49/51 is the right bar either.** That number is also a
  single un-repeated run from 2026-09-05 and has not been re-measured since
  (E001). The correct bar is whatever the untuned model scores *today*, under
  *the prompt the candidate will be scored under*, on *the server the candidate
  is served from* — a measurement nobody has yet made.

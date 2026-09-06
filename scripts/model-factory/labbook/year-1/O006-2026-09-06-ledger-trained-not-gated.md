---
id: O006
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: A third of the corpus teaches goals-ledger, which nothing gates
status: standing
tags: [gate, goals-ledger, data, coverage]
sources:
  - scripts/model-factory/evals-champions.json — exactly one key, "tmux-routing"
  - "grep -n 'goals-ledger' scripts/model-factory/eval_gate.py → no matches"
  - evals/goals-ledger/RESULTS.md — baseline only, 24/35
  - evals/goals-ledger/scenarios.json — 35 scenarios, 21 core + 14 hard (parsed today)
  - e025413 (2026-09-05 12:45) · b623a50 (12:48) · b0f7fea (13:36) — the ledger work that did merge
  - main:scripts/model-factory/README.md:44 — "[ ] goals-ledger eval joins the gate (that branch has not merged)" (branch labbook: 75; verify with `grep -n '^- \[ \]' scripts/model-factory/README.md` — see the line-anchor note in O005)
related: [P001, O005, E005]
corrects: []
superseded-by: null
---

## What was observed

Run 1's corpus is **769 of 2,363 examples (32.5%)** goals-ledger tick
decisions. Nothing measures whether the fine-tune helps or hurts on them.

| | tmux-routing | goals-ledger |
| --- | --- | --- |
| training examples | 890 | **769** |
| eval scenarios | 51 (26 core + 25 hard) | 35 (21 core + 14 hard) |
| baseline scored | yes — 29/51 | yes — 24/35 |
| **model-backed adapter** | yes — `router_llm.py` | **none exists** |
| in `evals-champions.json` | yes | **no** |
| referenced by `eval_gate.py` | yes | **no** — grep returns nothing |

So a candidate could get materially worse at ledger ticks and still promote,
because promotion reads one number from one corpus (P001).

## Detail

`evals/goals-ledger/RESULTS.md` has never recorded anything but the
deterministic baseline:

```
goals-ledger evals: 24/35 passed (69%)  [offline]
  core (gates): 21/21   hard (benchmark): 3/14
  clarify 4/4 | drive 5/6 | idle 4/5 | ingest 6/12 | report 5/8
```

(reproduced exactly today — E005). Its closing line has been an IOU since
2026-09-05 12:48: *"A model-backed tick adapter scored on this same corpus goes
here next, as in `evals/tmux-routing/RESULTS.md`."* It has not happened.

The hard-tier failure families it names are worth keeping, because they are the
judgment the fine-tune is supposed to supply and the baseline demonstrably
cannot:

| family | scenarios | what the baseline does wrong |
| --- | --- | --- |
| paraphrase / typo attach | h01, h02, h05, h11 | mints a duplicate goal instead of attaching |
| ordinary-word traps | h06, h09, h10 | "review" of a grant read as the app review; a two-word unblock; a status paraphrase |
| ball-in-your-court | h03 | ingests a nudge on a goal that is blocked on the user, instead of answering with the blocker |
| judgment over clocks | h04, h07, h08 | ignores a stated deadline; reports an explained wait; drives a fourth identical failed attempt |

Three hard scenarios (h12-h14) are model traps the baseline clears by being
simple, and are labeled as such in the corpus — a good practice worth copying:
the hard tier is not uniformly "the baseline fails here".

## Why the README's explanation is stale

`main:README.md:44` — line 75 on branch `labbook`, where this entry lives —
blames an unmerged branch. That is no longer true in the sense
it was written: `e025413` (the eval corpus), `b623a50` (the
`decide(tick_input)` contract) and `b0f7fea` ("the eval-proven design lands in
production") are all on main as of 2026-09-05 13:36. The *design* merged; the
*gate wiring* was never written. Two different things behind one checkbox
(O005).

## What it would take

1. A `policy_llm.py` adapter for `evals/goals-ledger`, mirroring
   `evals/tmux-routing/router_llm.py`.
2. A recorded champion for `goals-ledger` in `evals-champions.json` — measured
   under the prompt the candidate will be scored with (O002's lesson, applied
   before the mistake rather than after).
3. `eval_gate.py` extended to require **both** corpora: all core scenarios pass
   on both, and the combined total strictly beats the champion. The
   generalization is straightforward; the promotion rule (P001) does not have
   to change shape, only iterate over corpora.

## What this does not show

- **It does not show the fine-tune will regress on ledger decisions.** No
  measurement exists in either direction. That is the entire point.
- **It does not show the 769 ledger examples were a mistake to include.**
  Training a foreman on ledger ticks is one of the factory's three stated
  targets. The gap is measurement, not curriculum.

---
id: E005
date: 2026-09-06
occurred: 2026-09-06
kind: EXPERIMENT
title: Both deterministic baselines reproduce their recorded scores exactly, a day later
status: closed
tags: [evals, reproducibility, baseline]
sources:
  - "measured 2026-09-06 ~11:26 PDT in the labbook worktree on branch labbook, then at 4705b67 — commands and full output below"
  - evals/tmux-routing/RESULTS.md:25 (the recorded 29/51 row)
  - evals/goals-ledger/RESULTS.md (the recorded 24/35 block)
  - 704ab09:evals/tmux-routing/run_evals.py:195 (202 lines) · 704ab09:evals/goals-ledger/run_evals.py:131 (135 lines) — the exit rule; both blobs are unchanged at 077d970
related: [E001, O007, H004, P001]
corrects: []
superseded-by: O010
---

## Question

Do the deterministic baselines — the functions that label every routing and
ledger training example (O007) — still produce the numbers the repo records for
them?

This matters for two reasons. It is the only score in the entire measurement
history that can be re-derived today without a served model. And because those
baselines are the corpus's labelers, their behaviour today *is* the corpus's
label distribution.

## Method

Pure python, offline, no model, no GPU, from the labbook worktree on branch
`labbook`. The branch was created from `704ab09` at 11:07 and the measurement
was taken at ~11:26, by which time the branch had already advanced to `4705b67`
("Open the model factory lab book", 11:21:40) — so **`4705b67` is the checkout
these numbers were produced from**, not `704ab09`. It makes no difference to the
measurement: `4705b67` adds files under `docs/labbook/` only, and `evals/` is
byte-identical between the two.

```sh
python3 evals/tmux-routing/run_evals.py
python3 evals/goals-ledger/run_evals.py
```

Run 2026-09-06 at ~11:26, **22h17m** and several commits after the numbers in
`RESULTS.md` were written (`d98a031`, 2026-09-05 13:08:33). An earlier version
of this line said "roughly 20 hours", which was rounded from nothing — the two
endpoints were never subtracted.

## Result

```
tmux-routing evals: 29/51 passed (57%)  [offline]
  core (gates): 26/26   hard (benchmark): 3/25
  clarify  7/10
  refuse   4/4
  route    12/24
  start    6/13
exit 0
```

```
goals-ledger evals: 24/35 passed (69%)  [offline]
  core (gates): 21/21   hard (benchmark): 3/14
  clarify  4/4
  drive    5/6
  idle     4/5
  ingest   6/12
  report   5/8
exit 0
```

Both match their recorded values exactly, including every per-class column:

| | recorded | reproduced today |
| --- | --- | --- |
| tmux-routing overall | 29/51 (57%) | 29/51 (57%) ✓ |
| tmux-routing core / hard | 26/26 · 3/25 | 26/26 · 3/25 ✓ |
| goals-ledger overall | 24/35 (69%) | 24/35 (69%) ✓ |
| goals-ledger core / hard | 21/21 · 3/14 | 21/21 · 3/14 ✓ |

Corpus shapes, verified in the same session by parsing the JSON:
tmux-routing **51 scenarios, 25 flagged hard**, expected actions route 24 /
start 13 / clarify 10 / refuse 4. goals-ledger **35 scenarios, 14 hard**.

Both harnesses exit 0 because the exit rule is core-only —
`return 0 if core_passed == core_total else 1`
(`704ab09:evals/tmux-routing/run_evals.py:195` in a 202-line file,
`704ab09:evals/goals-ledger/run_evals.py:131` in a 135-line file; both blobs
are byte-identical at `59b0515`, the `labbook` commit this entry was last read
at). Hard-tier misses report but never fail a run.

The tmux-routing anchor is revision-sensitive, and this is the worked example of
why a branch name cannot carry it. That file has three different shapes in this
repository, each read with `git show <rev>:evals/tmux-routing/run_evals.py`:

| revision | read at | lines | `core_passed == core_total` at |
| --- | --- | --- | --- |
| `704ab09` (merge base of this book) | — | 202 | 195 |
| `077d970` (`main` tip at 13:38:50) | 2026-09-06 14:05 PDT | 202 | 195 |
| `cd64914`, `f0ca4af` (`imac-site`, 10:29:25 / 12:22:52) | — | 217 | 210 |
| `78e6c36` (`imac-site` tip at 13:22:14) | 2026-09-06 14:05 PDT | **219** | **212** |

An earlier draft of this entry said "on `imac-site` that file is 217 lines and
the same statement is at line 210". That was true of `cd64914` and `f0ca4af`
and became false when `78e6c36` landed at 13:22:14, two lines further down —
the branch moved 28 minutes before the round-3 commit that shipped the claim.
The sentence is replaced by the table because a tip is a fact with a timestamp.
Quote the line rather than trust any of these numbers: `grep -n 'core_passed ==
core_total' evals/tmux-routing/run_evals.py` resolves it at any revision.

## What this shows

1. **The offline half of the gate is deterministic and stable.** Any future
   argument about a score movement can rule the baselines out as a source of
   drift.
2. **The baselines are strong on core and near-useless on hard.** 26/26 and
   21/21 on the gate tiers; **3/25** and **3/14** on the adversarial tiers.
   The failure taxonomy the harness prints is itself the record of what a rule
   engine cannot do: paraphrase with zero vocabulary overlap (`h01`-`h03`),
   voice-transcription damage (`h04`-`h06`: "pockerdj", "test flight",
   "african intellect … pack it"), multi-clause misdirection (`h07`-`h09`),
   ordinary-word traps where a registered name appears as an ordinary word
   (`h10`-`h13`), and phrasal-verb variants of "start a new session"
   (`h15`-`h18`).
3. **The corpus's labels inherit exactly this shape.** The 890 routing and 769
   ledger training rows are this policy's outputs (O007), so the fine-tune is
   distilling a policy measured at 3/25 on the tier that decides promotion.
   H004 is the prediction that follows.

## What this does not show

- **Nothing about the model-backed scores.** Every `google/gemma-4-e4b` number
  in `RESULTS.md` (36, 46, 48, 49, 48 out of 51) requires a served endpoint and
  has not been re-run since 2026-09-05 13:08. Reproducing them is blocked today
  by the no-GPU rule while E004 trains.
- **It does not validate the labels.** A deterministic function reproducing its
  own output is a determinism check, not independent verification. `8aa690c`'s
  commit message describes the generator's label pass as reproducing "an
  independent baseline re-derivation"; it is not independent — it is the same
  function run twice. Recorded here as a correction to that commit message.

---
id: O012
date: 2026-09-06
occurred: 2026-09-06 14:38 — 14:48
kind: OBSERVATION
title: A monotonic decline called on three points, contradicted by the fourth — and the caller had predicted the shape
status: standing
tags: [measurement, statistics, gate, run-1, bias]
sources:
  - "local-artifact: models/gate-sweep/results.tsv — the four rows, in the order they were written: 1000 → hard 21/25, 2250 → 18/25, 3500 → 16/25, final → 19/25"
  - "local-artifact: models/gate-sweep/sweep.log — the checkpoints are scored and printed one at a time, in that order"
  - E009 — the sweep this happened inside
  - 2d5bb29:scripts/model-factory/labbook/year-1/H003-2026-09-06-best-checkpoint-not-last.md:88-92 — the ≥3-scenario power threshold this book set for itself before the fact
  - 2d5bb29:scripts/model-factory/labbook/year-1/H004-2026-09-06-baseline-labels-cap-hard-tier.md:62-70 — the same threshold, arrived at independently by the other draft, citing the two timeout misses at evals/tmux-routing/RESULTS.md:48
  - 7fb54b5 — "Gate run 1: champion re-recorded at 49/51, no candidate promotes"
related: [E009, H003, H004, O011, O001, P004]
corrects: []
superseded-by: null
---

## What was observed

`gate_sweep.sh` scores checkpoints one at a time and prints each result as it
lands. The hard-tier column arrived in this order:

| checkpoint | 1000 | 2250 | 3500 | **final (4490)** |
| --- | ---: | ---: | ---: | ---: |
| hard | 21/25 | 18/25 | 16/25 | **19/25** |

After the third number, the session running the sweep reported the hard tier as
**"falling monotonically"** and offered it as evidence that the last checkpoint
would not be the best one.

> **That quotation is UNSOURCED, and it is this entry's central evidence.** The
> four scores are artifacts — `results.tsv` and `sweep.log`, quoted above and in
> the front matter. The claim made *about* them while the sweep was still
> running is not. It survives only as this entry's own account of what the
> session said, and as the commit message of `d2f40b0`, which is the commit that
> published this entry. Searched for, not assumed:
>
> ```sh
> $ grep -ic monoton models/gate-sweep/sweep.log models/gate-sweep/results.tsv
> models/gate-sweep/sweep.log:0
> models/gate-sweep/results.tsv:0
> $ git log --all --grep=monoton --oneline     # in this repository
> d2f40b0 Lab book round 5: run 1 gated and closed, …   ← this entry's own commit
> 011577a Auto-increment TestFlight build numbers; …    ← unrelated
> ```
>
> So an entry whose whole subject is over-reading a partial measurement rests
> on a self-report with no artifact behind it. O011 flags its own unsourced
> item — "the broken sweep's start and end times are UNSOURCED" — and at
> `d2f40b0` this entry flagged nothing, which is the same asymmetry it is
> complaining about, pointed the other way. *Settled by:* a transcript or a
> written note timestamped between the third and fourth rows. Neither exists.
>
> **What does not depend on the quotation:** the four scores, the ≥3-scenario
> threshold H003 and H004 wrote down in advance, and the rule below. Those stand
> on artifacts. The *narrative* — that someone said it, and when — does not.

The fourth number was 19. **The final checkpoint was the best candidate** on the
overall total (45/51, the highest of the four) and second-best on the hard tier.

## Why this was wrong before the fourth number arrived, not after

Three points always admit a monotone reading; two of the six orderings of three
distinct values are monotone, and any three declining numbers look like a line
if you want one. That is not the interesting part. The interesting parts are
these:

**1. The book had already written down the threshold that forbids this.** H003
set it in advance: *"the hard tier is 25 scenarios, so one scenario is 4
percentage points and a difference of 1-2 scenarios is not evidence of
anything. Only a difference of ≥3 hard scenarios ... should count as support."*
H004 arrived at the same 3-scenario threshold independently, citing
`RESULTS.md:48`, where a 30-second endpoint timeout cost exactly one scenario in
each of two rounds — misses that were not semantic at all. **The 21 → 18 step is
3 and the 18 → 16 step is 2.** Under the book's own stated rule, one of those
two steps is not evidence and the other is exactly at the line. Neither licenses
a curve.

**2. There is no variance estimate anywhere in this book.** Every score in it is
a single un-repeated run: 51 scenarios, scored once, no seeds, no repeats, no
confidence interval. A 25-scenario tier scored once has a standard error of
roughly ±2 scenarios on a binomial reading before any model difference is
considered. The observed spread across all four checkpoints — 16 to 21, five
scenarios — is barely outside that, and it is the *range* of four draws, which
is the statistic most inflated by noise.

**3. The person who called the trend had predicted its shape.** H003 says the
hard tier *"peaks somewhere in 1000-2500 and declines after"*. The three numbers
21, 18, 16 are that sentence made of data. The session was not reading a curve
out of the measurements; it was recognizing the curve it already held, and
stopping when the recognition was complete. The fourth measurement was already
scheduled, already cheap, already running — and the claim was published before
it landed.

That third point is the one worth carrying forward. The threshold in (1) was
known. The absence of variance in (2) was known. What made the error happen
anyway was that the numbers agreed with the hypothesis, and agreement stops
inspection in a way disagreement never does.

## The rule, stated plainly

> **A single run cannot support a curve.**
>
> Three points from one run of one configuration are three numbers, not a
> trend. Say "the four scores were 21, 18, 16, 19" and stop. To claim a shape
> you need repeats — the same checkpoint scored more than once — or an effect
> larger than the threshold you wrote down *before* you looked.
>
> And the person most likely to over-read a partial result is the one who
> predicted the shape it is falling into. When a partial result matches your
> hypothesis, that is the moment to wait for the rest of it, not the moment to
> report.

The book already believed the first half; H003 and H004 both wrote the
threshold down in advance and this entry adds nothing to it. The second half is
new, and it is the half that failed: **knowing the threshold was not the
control.** The same sentence appears in O010 about citations — "knowing the rule
was never the control; running the command is the control" — and it is the same
failure with a different subject. The control here is procedural and costs
nothing: **do not report a partial sweep.**

## What follows for how a sweep is run

- **Report a sweep when it is complete, not as it streams.** The intermediate
  rows are operational progress, not results. `gate_sweep.sh` prints each row as
  it lands because that is useful for knowing the job is alive (O011 is about
  exactly that), and the cost is that partial data is in front of a reader who
  has a hypothesis.
- **A shape claim needs a repeat, and a repeat is cheap for one checkpoint.**
  Scoring a single fused checkpoint twice is one fuse and one 51-scenario pass.
  Nothing in this book has ever done it, so the measurement noise floor of the
  gate is unmeasured — which is why every threshold here is a guess with a
  reason rather than an estimate.
- **When a result matches a prediction, that is when to say what would falsify
  it.** H003's refutation clause was written in advance and is what stopped this
  from being recorded as a confirmation: the final checkpoint did not take the
  maximum hard score, so H003 is not refuted either. E009 records the full
  reading; the short version is that the sweep settles neither direction.

## What this does not show

- **It does not show the hard tier is flat.** 16 to 21 across four checkpoints
  may well be a real effect; this entry says only that four un-repeated points
  cannot demonstrate it, in either direction. Refusing to call a trend is not
  the same as calling it flat, and the flat reading would be the same error
  wearing the opposite sign.
- **It does not show that checkpoint choice does not matter.** It shows this
  measurement cannot resolve it. Those are different claims and the second one
  is the one H002 would like an answer to.
- **It is not a claim about anyone's competence.** The threshold was in the
  book, written by the same line of work, one day earlier. The failure was
  structural — a partial result arriving in front of a held hypothesis — and it
  is recorded so the structure is what gets fixed.
- **The order effect is unmeasured.** The checkpoints were scored in ascending
  iteration order, which is the order that makes a monotone reading available.
  Whether a shuffled order would have prevented the claim is not knowable from
  one run, and shuffling would cost nothing.

## Open

- **The gate's own noise floor is unmeasured.** *Settled by:* scoring one fused
  checkpoint three times and publishing the spread. Until that exists, every
  threshold in this book (±3 scenarios, in H003, H004 and here) is reasoned, not
  measured, and should be described that way.

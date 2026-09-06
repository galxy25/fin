---
title: "<The finding, stated plainly — not the topic. THE TITLE IS A CLAIM and gets its own ledger row: it either carries model + prompt revision + corpus + tiering, or it carries no number at all. It is the sentence most likely to be screenshotted alone.>"
kind: scientific-result
status: draft            # draft | review | approved | published
audience: "<developers evaluating Fin; people who care how the model was measured>"
claims: []               # every number in this piece has an id here
labbook: []              # REQUIRED before publish: the entry ids that recorded these runs
channel: blog
date: YYYY-MM-DD
author: "<who wrote it>"
approved_by: ""
published_at: ""
---

<!--
SCIENTIFIC RESULT — a measured finding.

The bar: a reader should be able to reproduce it, and should finish the piece
knowing exactly what it does NOT establish.

The order of sections below is deliberate. Write "What this does not show"
BEFORE you write the headline. If the limits section makes the headline
embarrassing, the headline is wrong, not the limits.

A result post cites the lab book. If a run is not in the book, it is not
publishable.

If the run happened before anyone wrote it up, the entry still has to exist —
but a backfilled entry is NOT the same artifact as a contemporaneous one, and
it must never be written from the draft. Write it from the run's own outputs,
date it the day you write it, mark it retrospective, and say in the entry that
a draft prompted it. Then the book records the one thing that matters here:
that this entry was written by someone who already knew the headline. An
append-only record whose framing was chosen by a marketing piece has had its
direction of travel reversed, which is the single failure this whole structure
exists to prevent (README.md §1).
-->

# <Title: the finding>

<!--
LEAD (2-4 sentences). The finding, with its qualifiers, in the first
paragraph. A reader who stops here should have a true belief, not an
approximate one.

Bad:  "We dramatically improved Fin's routing."
Bad:  "Rewriting the router prompt took the same untuned model from 36/51 to
       49/51 on our 51-scenario corpus."   <- no model id, no prompt revision,
                                              no tiering: fails the pre-flight
                                              box at the bottom of this file
Good: "With the original router prompt (`evals/tmux-routing/prompts/router.md
       @ 96ea006`), the untuned `google/gemma-4-e4b` — served through LM Studio
       at temperature 0 with a 30-second per-call timeout — scored 36/51 on the
       51-scenario tmux-routing corpus: core 21/26, hard 15/25. With the
       round-3 prompt (`… @ 99ed9d9`) — the same model, endpoint, settings and
       corpus — the score is 49/51: core 25/26, hard 24/25."

Yes, the good one is longer. It is also the only one a reader can check, and
it is the shape STYLE.md §4 spells out. Copy that shape, not a paraphrase of
it: the paraphrase is how the qualifiers get lost on the first use.
-->

## The question

<!--
What were we actually trying to find out, phrased so it could have come out
the other way? A question with only one possible answer was not an experiment.

State the decision this was meant to inform.
-->

## Method

<!--
Everything a reader needs to judge the number. Be exhaustive; this section is
allowed to be boring.

  - Model: exact identifier, tuned or untuned, quantization if it matters
  - Serving stack: what served it, on what hardware, with what settings
    (temperature, timeouts, context window)
  - Prompt: which revision, cited to a path @ sha
  - Corpus: name, size, how it was built, and — say this explicitly — whether
    any of it was seen in training (the leakage rule)
  - Tiering: the split, and what makes the hard tier hard
  - Scoring: what counts as correct, what the exit-code gate is
  - Runs: HOW MANY. One run is one run. Say so.
-->

## Corpus

<!--
Often worth its own section. What is in it, who wrote it, what it is trying to
catch, and its known blind spots. A result is only as interesting as the corpus
is adversarial, so show the reader why it is hard.
-->

## Results

<!--
A table. Include every arm you ran, including the ones that lost — especially
those. A results table that only contains the winning configuration is a
marketing chart.

Mark flakes, timeouts, and infrastructure failures distinctly from wrong
answers, with a footnote, and give their counts.
-->

| configuration | overall | <tier A> | <tier B> | notes |
|---|---|---|---|---|
| <baseline> | | | | |
| <arm 1> | | | | |
| <arm 2 — kept> | | | | |

<!-- † mark and explain any non-semantic failures here -->

## What we changed and what it cost

<!--
For an iterative result: what each round targeted, what it fixed, and what it
broke. Regressions go in the body, not a footnote. If there was a see-saw —
an intervention that fixed N and broke M — that IS the finding and it belongs
near the top.
-->

## Where it still fails

<!--
The residual failures, one line of analysis each. Name them by id so a reader
can look them up in the corpus. Say whether each looks like a missing rule, a
model-capacity limit, or a corpus problem — and say which of those is a guess.
-->

## What this does not show

<!--
REQUIRED, and written first. Be specific, in a list. Typical entries:

  - single run per arm; no variance measured, no repeats, no confidence interval
  - one model, one corpus, one registry shape
  - the intervention was X only — no fine-tune, no retraining, no data change
  - measured in the eval harness, which is not the shipped app's code path
  - infrastructure flakes were present in some rounds (give counts)
  - the corpus was written by the same people who wrote the prompt
  - nothing here says anything about <the adjacent thing a reader will assume>

The last one matters most. Write down the inference a motivated reader would
make, and cut it off explicitly.
-->

## Reproduce it

<!--
The exact command, with the environment variables, against a stated endpoint.
Plus what a reader needs that they may not have (a served model, the corpus at
a sha). If it cannot be reproduced outside our machines, SAY SO here rather
than implying otherwise.
-->

```sh
<the exact command>
```

## What is next

<!--
Optional. If included, it is a ROADMAP claim: future or in-progress voice
only, and it gets its own ledger row (claims-ledger.md §2).
-->

---

## Claims in this piece

| id | sentence | kind | evidence |
|---|---|---|---|
| XX-01 | "<exact sentence>" | performance | `<path @ sha>` |

## Pre-flight

- [ ] Every number has a ledger row citing a run artifact, and every row is `verified`
- [ ] **The title has a row**, and carries all four qualifiers or no number
- [ ] Every quotable sentence carries model + prompt revision + corpus +
      tiering, **in the sentence**; secondary numbers use the carve-out in
      claims-ledger.md §4 step 3 and their rows say so
- [ ] The run count is stated as the artifact records it — and if the artifact
      records none, the piece says that instead of inferring one
- [ ] The losing arms and the regressions are in the results table
- [ ] Flake/timeout counts are reported and marked as non-semantic
- [ ] No averaging, best-of, or implied confidence interval
- [ ] No guardrail is described as an interlock (STYLE.md §3)
- [ ] "What this does not show" names the inference a reader would wrongly make
- [ ] Reproduction command was actually run as written
- [ ] Lab-book entry ids are in the front matter and cited in the body
- [ ] No claim generalizes a configuration into a product capability
- [ ] **Levi has approved this piece, in his own words** — no agent publishes

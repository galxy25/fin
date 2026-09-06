---
id: H001
date: 2026-09-06
occurred: 2026-09-06
kind: HYPOTHESIS
title: Bits per example is the right currency for a training curriculum
status: untested
tags: [curriculum, information, bits, data]
sources:
  - "memory note training-bits-per-example — Levi's directive 2026-09-06, quoted verbatim below"
  - "local-artifact: train.log:9 — 'Iter 1: Val loss 2.463' measured before any gradient step (trainer.py:284-286)"
  - "sibling-worktree, UNCOMMITTED: /Users/deepspacenine/forges/levi/fin-wt-bits/scripts/model-factory/{score_bits.py,select_curriculum.py,run_bits_experiment.sh} on branch bits-curriculum (704ab09), untracked as of 2026-09-06 11:30"
  - "corpus compression measurements by a sibling survey on sha256 9552ac13… (xz -9e, gzip -9, generator source size)"
related: [H002, O001, O004, O007, E004]
corrects: []
superseded-by: null
---

## The claim

**Cross-entropy is information, so the bits an example costs a model is a
measurable quantity — and it is the right thing to select a curriculum on,
because two examples with the same loss contribution are worth the same to a
run regardless of how they look.**

Levi's directive, 2026-09-06, written while watching the loss excursion of
O004:

> *"that sounds like excellent signal to measure the bits of information per
> example, can you record that so that as we collect and train on different
> examples we find the best mix of high value examples to allow us to do the
> fewest training iterations / lower the computational and time domain
> complexity of training runs for our model factory?"*

## The measure

For one example, sum `-log2 p(token)` over the **answer tokens only** — exactly
the mask training uses (`--mask-prompt`). Loss in nats × 1.4427 = bits. Four
quantities:

| quantity | definition | what a high value means |
| --- | --- | --- |
| `bits_base` | surprise under the **untuned base** | the base does not know this; it can teach something |
| `bits_tuned` | surprise under the candidate | still unlearned after training |
| `learned_bits` | `bits_base − bits_tuned` | the run actually acquired this information from this example |
| `residual_bits` | `bits_tuned` | genuinely hard **or mislabeled** — and on a synthesized corpus, mislabeled is the likelier cause, which makes it a bug in `gen_training_data.py`, not a hard case |

**A corpus-level `bits_base` is already on record and cost nothing.** Run 1's
first validation runs before any gradient step, so its 2.463 nats = **3.553
bits per answer token** is the untuned base's surprise on the held-out split.
Against a val loss of 0.012 nats (0.017 bits) at iteration 3500, whole-corpus
`learned_bits` ≈ **3.536 bits/token**. Every future run gets the same
measurement free in its first log line.

## Why this corpus in particular

Four independent estimators agree that this corpus is very small in
information terms, all computed on `sha256 9552ac13…` (2,363 examples,
16,142,664 bytes):

| estimator | value |
| --- | --- |
| distinct assistant strings | 991 of 2,363 |
| label entropy H(Y) | **8.585 bits/example** (ceiling log₂991 = 9.953) |
| decision-class entropy | 3.351 bits over 11 classes (ceiling 3.459) |
| **H(label \| input)** | **0 exactly** — all 2,363 (system, user) pairs are distinct |
| `gzip -9` | 1,074,174 B = 3,637 bits/example |
| **`xz -9e`** | **58,020 B = 196 bits/example** |
| **the generator's own source** | **50,743 B = 172 bits/example** |

`xz` and the generator source agree within 14% — two estimators on different
principles converging on the same answer: **the whole 16 MB corpus is roughly
50 KB of information.** Total label entropy is 2,363 × 8.585 = 20,286 bits ≈
2.5 KB.

And of that 16 MB, the optimizer only ever differentiates the labels: system
messages are 13,510,803 characters (**83.7%**, entirely masked) and assistant
labels are 272,847 characters (**1.69%**).

Zero conditional entropy is the signature of label-by-construction and explains
O001 directly: with no ambiguity anywhere in 2,363 rows, a training loss of
zero is attainable and proves nothing.

## The prediction

If bits are the right currency:

1. **A large fraction of examples will have near-zero `bits_base`** — the base
   already produces those labels — and removing them will not change the gate
   score.
2. **`learned_bits` will be concentrated**, not uniform: a minority of examples
   will account for most of the information the run acquired.
3. **The O004 excursion window (iterations 3525-3775) will show high
   `residual_bits`** relative to the corpus median. If instead it looks
   ordinary, the excursion has another cause and the bits story loses a
   supporting case.
4. **High-`residual_bits` examples will, on inspection, be mislabeled more
   often than they are hard** — the synthesized-corpus prediction.

## The experiment that would settle it

1. Score every row of `datasets/mlx/train.jsonl` under the untuned base →
   `bits_base` per example.
2. Score every row under the run-1 adapter → `bits_tuned`; join to get
   `learned_bits` and `residual_bits`.
3. Check prediction 3 by replaying the deterministic batch order (seed 17 —
   see O004) and intersecting with the excursion window.
4. Inspect the top `residual_bits` decile by hand for label errors.
5. Then H002 tests whether selection actually saves iterations.

**Tooling status — in flight, not yet committed.** `score_bits.py` (29,767 B),
`select_curriculum.py` (30,454 B), `run_bits_experiment.sh` and a `tests/`
directory exist in a sibling worktree at
`/Users/deepspacenine/forges/levi/fin-wt-bits/scripts/model-factory/` on branch
`bits-curriculum`, and are **untracked** there as of 2026-09-06 11:30 —
`git status --short` lists all four as `??`. They are on no branch yet and this
entry cannot cite a sha for them. `score_bits.py`'s docstring records the
fidelity requirements that make its numbers comparable to a training loss:
tokenize through mlx-lm's `TokenizerWrapper` rather than the raw HF tokenizer,
compute the prompt offset the way `ChatDataset.process` does under
`--mask-prompt`, and report the honest answer-token count alongside the
trainer's off-by-one (`L − offset + 1`, which includes a trailing pad).

## Two constraints that must survive into any implementation

Both from Levi's refinement of the same directive, and both easy to violate:

1. **A bits score is only valid for a (corpus, base model, tokenizer, scoring
   code) tuple.** When the base changes — a new Gemma, a new quantization, even
   a re-tag — every score is stale, because the new base may already know what
   the old one found surprising. Score files must carry that provenance in a
   header and the selector must **refuse** a score file whose base-model id
   does not match the run it is selecting for. A cached "golden set" reused
   across base models is the trap this rule exists to prevent.
2. **The pool is durable; the selection is ephemeral.** Keep every example
   forever with provenance. Re-score per base model rather than curating a
   permanent best-of. A selection is an output of a scoring run, never an input
   to the next one.

## What this hypothesis is not

- **Bits never certify a model.** `evals/tmux-routing` + `eval_gate.py` remain
  the only arbiter of promotion (P001). Bits choose what to train on; the gate
  says whether that worked.
- **Bits do not measure the thing the hard tier measures.** An example can be
  information-rich and still teach the wrong policy — which is exactly the
  corpus's situation (O007). Curriculum selection over a corpus whose labels
  cap out at 3/25 on hard cannot lift the hard tier; it can only reach the same
  ceiling faster. That is H002's claim and it is deliberately the weaker one.

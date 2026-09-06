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
  - "d4901d4 on branch bits-curriculum (2026-09-06 11:25:38) — 'Bits per example: measure what each training example actually teaches': score_bits.py, select_curriculum.py, run_bits_experiment.sh, tests/test_bits_curriculum.py, README.md, 2,640 insertions"
  - "corpus measurements re-derived here on sha256 9552ac13… (2,363 lines, 16,142,664 B): xz -9e | wc -c → 58020; per-role character sums and label entropies by parsing the jsonl; generating-program size by git cat-file -s at main"
  - "local-artifact: train.log — 'Trained Tokens 121200' at iteration 3500; assistant-string length statistics parsed from the corpus"
  - scripts/model-factory/.venv/lib/python3.11/site-packages/mlx_lm/tuner/trainer.py:273-282 (one iteration is one example)
  - "merged from docs/labbook/entries/E004-2026-09-06-bits-per-example.md (the parallel book, 4705b67) — see the merge note below"
related: [H002, O001, O004, O007, E004, E006, E007]
corrects: []
superseded-by: O010
---

**Merged from two drafts.** Two lab books were opened on 2026-09-06 and both
wrote up bits-per-example: this entry, `scripts/model-factory/labbook/year-1/H001-2026-09-06-bits-per-example.md`,
as a HYPOTHESIS, and `docs/labbook/entries/E004-2026-09-06-bits-per-example.md`
as an EXPERIMENT that measured the corpus. The consolidation (O009) kept this
one — it carries the falsifiable form, the refutation criteria and the two
provenance constraints — and folded the other's measurement method, its extra
label statistics, its account of what the optimizer actually sees and its
reproducer into "The measurement, in full" below. Their overlapping numbers
agreed exactly, including the withdrawal of the "two estimators converge"
claim, which both drafts had already corrected independently. Nothing was
dropped; the other file is deleted and this entry is the whole record.

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

**One `bits_base` reading is already on record and cost nothing — but state
its denominator.** Run 1's first validation runs before any gradient step, so
its 2.463 nats = **3.553 bits per answer token** is the untuned base's surprise
on a validation pass. Against a val loss of 0.012 nats (0.017 bits) at
iteration 3500, the difference is ≈**3.536 bits/token**.

The denominator, which an earlier version of this paragraph omitted while
calling the figure "corpus-level" and the difference "whole-corpus
`learned_bits`":

- The run passes `--val-batches 25`, so **one validation pass covers 25 of the
  118 rows in `valid.jsonl` (21%)** — roughly 870 answer tokens, not 2,363
  examples and not even the whole split (E004; **O001:99**, which moved from
  `O001:60-61` when O001 received merged content — resolve it with
  `grep -n 'Each validation pass covers' O001-2026-09-06-zero-loss-flat-validation.md`,
  not with the number).
- The two endpoints are **different 25-row draws**. `evaluate()` calls
  `iterate_batches` with no `seed=` (`trainer.py:195-200`), so the iteration-1
  and iteration-3500 passes do not see the same rows, and 3.553 − 0.017 is a
  difference of two independent small samples.
- There is **no variance estimate**. One pass each, never repeated.

So the honest reading is "the untuned base is surprised by a few bits per
answer token and the tuned model is not", not "3.536". The hypothesis below
does not depend on the third decimal — it depends on the *distribution* of
per-example bits, which is exactly what this free measurement cannot give and
what the scoring pass in "The measurement" is for. Every future run gets the
same 21%-of-the-split reading free in its first log line, with the same caveat.

## Why this corpus in particular

Several estimators, of two different kinds — entropy of the label distribution,
and description length — all put this corpus's information content in the tens
of kilobytes. All computed on `sha256 9552ac13…` (2,363 examples, 16,142,664
bytes; the fourteen class counts below sum to 2,363, which is the check that the
partition is complete):

| estimator | value |
| --- | --- |
| distinct assistant strings | 991 of 2,363 |
| label entropy H(Y) | **8.585 bits/example** (ceiling log₂991 = 9.953) |
| decision-class entropy | **3.669 bits over 14 classes** (ceiling log₂14 = 3.807) |
| **H(label \| input)** | **0 exactly** — all 2,363 (system, user) pairs are distinct |
| `gzip -9` | 1,074,174 B = 3,637 bits/example |
| **`xz -9e`** | **58,020 B = 196 bits/example** |
| **the generating program's source** | **85,536 B = 290 bits/example** |

Two of those rows were stated differently in this entry's first draft and are
corrected here, with the definitions spelled out so they can be re-derived.

**Decision-class entropy.** The 14 classes are the distinct values of the
label's `action` / `decision` / `tool` field across all 2,363 rows: `route`
(230), `start` (230), `clarify` (390), `refuse` (200), `ingest` (176), `drive`
(176), `report` (144), `idle` (113), `ask` (160), `proceed` (160),
`request_input` (128), `notify` (96), `send_input` (96), `read_terminal` (64).
H = **3.6691** bits against a ceiling of log₂14 = 3.8074. The first draft printed
3.351 over 11 classes, which reproduces exactly — but only under an unstated
grouping that collapses the four tool-use classes into one. The definition, not
the arithmetic, was the problem: a number nobody can re-derive from the entry is
the thing rule 2 exists to stop.

**The generating program.** `gen_training_data.py` is 50,743 bytes, but it is not
the program that writes the corpus. It loads `router_baseline.decide` and
`policy_baseline.decide` to label every routing and ledger row (O007) and
`router_llm._system_prompt`, which reads `prompts/router.md` at generation time.
Sizes at `main`: `router_baseline.py` 5,693 + `policy_baseline.py` 9,139 +
`router_llm.py` 7,008 + `prompts/router.md` 9,272 + `prompts/tick.md` 3,681 =
34,793 bytes beyond the generator itself. The real program is **85,536 bytes**,
which is **47% above** `xz -9e`, not 14% below it.

So the "two estimators converging" claim is withdrawn. They were never
independent — both are compression-flavoured upper bounds on the same program's
description length, and the apparent agreement came from leaving five of the six
files out of one of them. What survives, and is enough:

> **The whole 16 MB corpus is tens of kilobytes of information**, by every
> measure available — `xz -9e` at 58 KB, the generating source at 86 KB, total
> label entropy at 2,363 × 8.585 = 20,286 bits ≈ 2.5 KB, and H(label | input) =
> 0 exactly. Three orders of magnitude between the file size and the
> information, from three different directions.

And of that 16 MB, the optimizer only ever differentiates the labels. Of the
15,070,991 characters of message content, system messages are 13,510,803
(**89.6%**, entirely masked) and assistant labels are 272,847 (**1.81%**). (As
shares of the file's 16,142,664 bytes the same counts are 83.7% and 1.69%; that
denominator includes JSON syntax and escaping, so it understates both. The first
draft quoted the byte shares while calling them character shares.)

Zero conditional entropy is the signature of label-by-construction and explains
O001 directly: with no ambiguity anywhere in 2,363 rows, a training loss of
zero is attainable and proves nothing.

## The measurement, in full

From the merged draft, which posed this as a measurement question — *how much
does one training example actually tell the model?* — and answered it with four
estimators of two different kinds, each cheap and each reproducible on
`sha256 9552ac13…`:

1. **Shannon entropy of the label** — the empirical distribution over the 2,363
   assistant strings.
2. **Conditional entropy** H(label | input) over the same distribution.
3. **Compressed length** — `gzip -9` and `xz -9e`, empirical upper bounds on
   description length.
4. **Program length** — the size of the generator that emits the corpus.

### The label side, with the statistics the table above leaves out

| quantity | value | how |
| --- | --- | --- |
| examples | 2,363 | `wc -l` |
| distinct assistant strings | 991 | `Counter` over `messages[2].content` |
| label entropy H(Y) | **8.585 bits/example** | empirical; ceiling log₂991 = 9.953 |
| decision-class entropy | **3.669 bits over 14 classes** | ceiling log₂14 = 3.807 |
| most repeated single label | **113×** — `{"decision": "idle", "reason": "no message, nothing drivable…"}` | `Counter` |
| distinct `(system, user)` pairs | **2,363 of 2,363** | set over the pair |
| distinct *user* texts alone | **2,147** | 216 user strings recur under a different registry, and the system message disambiguates them |

That last row is what makes H(label | input) = 0 a statement about the corpus
rather than an artifact of how the input was defined: the pairs are distinct
even though the user texts are not, so I(input; label) = H(label) = 8.585
bits/example.

Zero conditional entropy is the signature of label-by-construction. For routing
and ledger the label *is* the deterministic baseline's output on that input
(`gen_training_data.py:276-285`, O007); for elicit and tool-use it is fixed by
the template family that emitted the input (`:798-815`, `:912-935`). No noise,
no disagreement, no ambiguity anywhere in 2,363 rows — the model is not being
taught a distribution, it is being shown a function it can in principle memorize
exactly.

### Description length, with the two rows the summary table compresses

| estimator | size | bits/example |
| --- | ---: | ---: |
| raw corpus | 16,142,664 B | 54,647 |
| `gzip -9` | 1,074,174 B | 3,637 |
| `xz -9e` | 58,020 B | **196** |
| the generating program's source (six files) | 85,536 B | **290** |

### What the optimizer actually sees

The run trains with `--mask-prompt`, so only assistant tokens carry gradient.
`Trained Tokens 121200` at iteration 3,500 → **34.6 gradient-bearing tokens per
iteration**. Assistant strings average **115.5 characters** (median 117, min 53,
max 177), ≈29 tokens at chars/4 — consistent with one example per iteration.

The merged draft first ruled out two-examples-per-iteration by claiming 17.3
tokens per label was "below even the shortest one". **That argument is
withdrawn**: the shortest assistant string in the corpus is 53 characters —
`{"tool": "read_terminal", "arguments": {"lines": 80}}` — which is ≈13.3 tokens
at the same rate, comfortably *below* 17.3. The honest form of the check is the
mean, not the minimum: 17.3 is 60% of the 29-token average, so two-per-iteration
would need the sampler to have drawn systematically short labels for 3,500
consecutive iterations. And the question is settled independently anyway, from
the trainer rather than from token arithmetic — `trainer.py:273-282` zips
`range(1, args.iters + 1)` against `iterate_batches(batch_size=1)`, so one
iteration is exactly one example, `--iters 4490` over 2,245 rows is exactly
**2.00 epochs** (E004), and the full run applies gradient to roughly 155,000
tokens.

### Three honest answers to "bits per example"

- **8.6 bits** — what the model must emit that it could not have guessed from
  the label prior alone.
- **196-290 bits** — the corpus's description length per example: 196 by
  `xz -9e`, 290 by the program that actually regenerates it. (An earlier draft
  of the merged entry said "~180 bits", the midpoint of a withdrawn pairing that
  counted `gen_training_data.py` alone at 50,743 B = 172 bits. Both books
  withdrew it; H002's source line records the same correction.)
- **0 bits** — the *residual* uncertainty in a label once the input is known.

The third is the important one, and it is the one that needs no compressor: a
corpus with zero conditional entropy has a perfectly attainable training loss of
zero, which is what the run shows (O001), and a loss of zero on such a corpus
proves nothing about the decision rules — only that ~86 KB of generator source
fits inside 6.9M LoRA parameters (`train.log:6`: "Trainable parameters: 0.093%
(6.914M/7463.013M)").

### Reproduce

```sh
python3 - <<'EOF'
import json, math
from collections import Counter
P='datasets/sft-train-2026-09-05.jsonl'   # sha256 9552ac13…
rows=[json.loads(l) for l in open(P)]
A=[r['messages'][2]['content'] for r in rows]; n=len(A); c=Counter(A)
H=-sum(v/n*math.log2(v/n) for v in c.values())
print('n=%d distinct=%d H=%.3f bits/example'%(n,len(c),H))
print('distinct (system,user) pairs:',
      len({(r['messages'][0]['content'], r['messages'][1]['content']) for r in rows}))
EOF
xz -9e -c datasets/sft-train-2026-09-05.jsonl | wc -c
```

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

## What would refute it

The README requires this section and the first draft of this entry did not have
one, which made the claim a value judgement rather than a hypothesis. Stated so
it can lose:

- **`learned_bits` is not concentrated.** (Earlier drafts headed this bullet
  `bits_base`, which is a different quantity in the table above —
  `learned_bits` is `bits_base − bits_tuned`. The test described was always the
  `learned_bits` one; only the heading was wrong.) If the `learned_bits`
  distribution over the 2,245 training rows is close to uniform — say the top
  decile carries less than 25% of the total, against the ~50%+ that
  "concentrated" implies — then
  ranking by bits gives no useful ordering and there is nothing to select on.
  This is the primary refutation and it is measurable from a single scoring pass,
  before any training run.
- **Bits do not predict what removal costs.** If dropping the *lowest*-
  `learned_bits` decile changes the gate score by more than 1 scenario, while
  dropping a random decile of the same size does not, the measure is not
  tracking what training uses.
- **H002's control comes out flat.** If a bits-selected subset and a
  random subset of the same size reach the same gate score at the same iteration
  count (H002's arm B ≈ arm C), then bits are not "the right currency for a
  curriculum" whatever else they are — they are just a description of the
  corpus.
- **The measure is unstable.** If re-scoring the same corpus under a different
  quantization of the same base model reorders the top decile substantially,
  then a bits score is too fragile to select on, and the (corpus, base,
  tokenizer, code) provenance rule below is not a safeguard but an admission.

Predictions 1, 2 and 4 above are expectations; these four are the outcomes that
would make this entry `refuted`.

## The experiment that would settle it

1. Score every row of `datasets/mlx/train.jsonl` under the untuned base →
   `bits_base` per example.
2. Score every row under the run-1 adapter → `bits_tuned`; join to get
   `learned_bits` and `residual_bits`.
3. Check prediction 3 by replaying the deterministic batch order (seed 17 —
   see O004) and intersecting with the excursion window.
4. Inspect the top `residual_bits` decile by hand for label errors.
5. Then H002 tests whether selection actually saves iterations.

**Tooling status — committed, and citable.** This entry's first draft said the
opposite: that the four files were untracked, on no branch, and that "this entry
cannot cite a sha for them". That was a recollection about a working tree, and it
was already false when it was written. The commit is **`d4901d4`** on branch
`bits-curriculum`, *"Bits per example: measure what each training example
actually teaches"*, authored and committed **2026-09-06 11:25:38** — 3m58s after
`4705b67` (11:21:40) opened the other book and 12m17s before `a02cec3`
(11:37:55) opened this one. An earlier version of this sentence also said "five
minutes before the stated observation"; no observation time is stated anywhere in
this entry, so that half named an interval with only one endpoint and has been
cut (O010). Its
`--stat` lists `score_bits.py`, `select_curriculum.py`, `run_bits_experiment.sh`,
`tests/test_bits_curriculum.py` and a 150-line `README.md`, 2,640 insertions.

Blob sizes at `d4901d4` (`git cat-file -s`): `score_bits.py` **29,756 B**,
`select_curriculum.py` **32,444 B**, `run_bits_experiment.sh` 10,586 B,
`tests/test_bits_curriculum.py` 34,028 B. The first draft quoted 29,767 and
30,454, which match neither the commit nor the working tree — sizes read off a
tree that was being edited while they were read. The worktree has since moved on
to `b67129f` ("Bits curriculum: fix the confounded control, rank on what the gate
reads", 12:01) and `git status --short` there now reports ` M`, not `??`.

Recorded at length because this is the exact failure the book's rule 2 exists to
prevent, and it happened in the one entry that declared no artifact existed.

`score_bits.py`'s docstring records the
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

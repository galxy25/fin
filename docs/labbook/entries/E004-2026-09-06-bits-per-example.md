# E004 — How many bits of information are in a training example?

- **Kind:** EXPERIMENT
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## Question

Levi, 2026-09-06, asked to measure the bits of information per training
example. The corpus is 16,142,664 bytes for 2,363 examples — 6,831 bytes
each. That number is meaningless as information content, because the corpus
is the output of a deterministic program. So: how much does one training
example actually *tell the model*, and what is the honest ceiling on what the
whole corpus can teach?

## Method

Four independent estimators, each cheap, each reproducible on
`datasets/sft-train-2026-09-05.jsonl` (sha256 `9552ac13…`, see
[E001](E001-2026-09-06-corpus-bit-exact-reproduction.md)):

1. **Shannon entropy of the label** — the empirical distribution over the
   2,363 assistant strings.
2. **Conditional entropy** H(label | input) over the empirical distribution.
3. **Compressed length** — `gzip -9` and `xz -9e`, an empirical upper bound
   on description length.
4. **Program length** — the size of the generator that emits the corpus.

## Result

### 1. The label side

| quantity | value | source |
| --- | --- | --- |
| examples | 2,363 | `wc -l` |
| distinct assistant strings | 991 | Counter over field `messages[2].content` |
| label entropy H(Y) | **8.585 bits/example** | empirical, max possible log2(991) = 9.953 |
| decision-class entropy | **3.669 bits/example over 14 classes** | max log2(14) = 3.807; classes are the distinct `action`/`decision`/`tool` values: route 230, start 230, clarify 390, refuse 200, ingest 176, drive 176, report 144, idle 113, ask 160, proceed 160, request_input 128, notify 96, send_input 96, read_terminal 64 |
| most repeated single label | 113× — `{"decision": "idle", "reason": "no message, nothing drivable…"}` | Counter |

Total label information in the corpus: 2,363 × 8.585 = **20,286 bits ≈ 2.5
kilobytes.** The entire supervision signal of a 16 MB corpus is two and a half
kilobytes of Shannon entropy.

### 2. The conditional side — the number that matters

Every `(system, user)` pair in the corpus is distinct (2,363 distinct pairs
for 2,363 rows; the *user* text alone is distinct only 2,147 times — 216 user
strings recur under a different registry, and the system message
disambiguates them). Under the empirical distribution, therefore,
**H(label | input) = 0 exactly**, and mutual information I(input; label) =
H(label) = 8.585 bits/example.

This is not a compliment to the data. It is the signature of
label-by-construction: for the routing and ledger tracks the label *is* the
deterministic baseline's output on that input
(`gen_training_data.py:276-285`, `router_baseline.decide`); for the elicit
and tool-use tracks the label is fixed by the template family that emitted the
input (`gen_training_data.py:798-815, 912-935`). There is no noise, no
disagreement, no ambiguity anywhere in 2,363 rows. The model is not being
taught a distribution; it is being shown a function it can, in principle,
memorize exactly.

### 3. Compressed length — the corpus as a message

| estimator | size | bits/example |
| --- | ---: | ---: |
| raw corpus | 16,142,664 B | 54,647 |
| `gzip -9` | 1,074,174 B | 3,637 |
| `xz -9e` | 58,020 B | **196** |
| the generating program's source | 85,536 B | **290** |

The second row is the whole program, not one file. `gen_training_data.py` is
50,743 B, but it loads `router_baseline.decide` and `policy_baseline.decide` to
label every routing and ledger row and `router_llm._system_prompt`, which reads
`prompts/router.md` at generation time. At `main`: router_baseline.py 5,693 +
policy_baseline.py 9,139 + router_llm.py 7,008 + prompts/router.md 9,272 +
prompts/tick.md 3,681 = 34,793 B beyond the generator. Counting only the one
file makes it look like `xz` and the source "agree to within 14%"; counting the
program that actually runs puts the source **47% above** `xz`, and the two were
never independent estimators in the first place — both are compression-flavoured
upper bounds on the same description length.

The conclusion does not need the coincidence: **the corpus contains a few
hundred bits per example of description-length information**, and the honest
total for the whole 16 MB thing is tens of kilobytes — the size of a handful of
Python files. Section 2's H(label | input) = 0 says the same thing from a
different direction, and it needs no compressor at all.

### 4. What the optimizer actually sees

The run trains with `--mask-prompt` (`launch-train.sh:15`), so only assistant
tokens carry gradient. From `train.log`, `Trained Tokens 121200` at iteration
3,500 → **34.6 gradient-bearing tokens per iteration**. Assistant strings
average 115.5 characters (median 117, min 53, max 177), ≈29 tokens by a
chars/4 estimate — consistent with **one example per iteration**, and
inconsistent with two (which would require 17.3 tokens per label, below even
the shortest one). So `--iters 4490` over a 2,245-row train split is exactly
**2.00 epochs**, and the full run will apply gradient to roughly 155,000
tokens.

For scale: system messages average 5,718 characters — 13,510,803 characters
in total, **83.7% of the corpus by volume** — and every one of those tokens is
masked. The corpus is 16,142,664 bytes of which the 272,847 characters of
assistant labels (**1.69%**) are all that ever receives a gradient.

## Reading

Three numbers, three different honest answers to "bits per example":

- **8.6 bits** — what the model must emit that it could not have guessed from
  the label prior alone.
- **~180 bits** — the corpus's description length per example, i.e. the size
  of the program that would regenerate it.
- **0 bits** — the *residual* uncertainty in a label once the input is known.

The third is the important one. A corpus with zero conditional entropy has a
perfectly attainable training loss of zero, which is exactly what the run
shows ([O002](O002-2026-09-06-validation-split-in-distribution.md)), and a
loss of zero on such a corpus proves nothing about the decision rules — only
that 50 KB of templates fit inside 6.9M LoRA parameters
(`train.log:6`: "Trainable parameters: 0.093% (6.914M/7463.013M)").

The lever this suggests: the corpus's information content is bounded by its
generator, so **more rows from the same generator add approximately zero
bits**. Going from 2,363 to 20,000 examples of the same 65 routing templates
× 16 domains would move the `xz` number barely at all. Growth has to come
from new template families, new label sources (real telemetry through
`raw/trajectories/`), or from examples where the label is *not* a
deterministic function of the input — cases where a human disagreed with the
baseline. That last category is the only one that adds bits the generator does
not already contain.

## Reproduce

```sh
python3 - <<'PY'
import json, math
from collections import Counter
P='/Users/deepspacenine/forges/levi/fin/datasets/sft-train-2026-09-05.jsonl'
rows=[json.loads(l) for l in open(P)]
A=[r['messages'][2]['content'] for r in rows]; n=len(A); c=Counter(A)
H=-sum(v/n*math.log2(v/n) for v in c.values())
print('n=%d distinct=%d H=%.3f bits/example'%(n,len(c),H))
print('distinct (system,user) pairs:', len({(r['messages'][0]['content'], r['messages'][1]['content']) for r in rows}))
PY
xz -9e -c "$P" | wc -c
```

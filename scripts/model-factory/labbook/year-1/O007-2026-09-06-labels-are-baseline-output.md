---
id: O007
date: 2026-09-06
occurred: 2026-09-05
kind: OBSERVATION
title: Every routing and ledger label in the corpus is deterministic-baseline output, and the filter that was meant to validate them rejected nothing
status: standing
tags: [data, labels, distillation, baseline]
sources:
  - scripts/model-factory/gen_training_data.py:276-283 (routing keep()), :540 (ledger keep())
  - 8aa690c — commit message claiming "an independent baseline re-derivation"
  - evals/tmux-routing/RESULTS.md:25-27 — baseline 3/25 hard vs model 24/25 hard
  - "measured today (E005): router_baseline 29/51 core 26/26 hard 3/25; policy_baseline 24/35 core 21/21 hard 3/14"
  - "generator instrumentation by a sibling survey, 2026-09-06: routing 3,054 baseline calls / 3,054 kept / 0 rejected; ledger 769 / 769 / 0"
related: [E005, H004, P002, O001]
corrects: []
superseded-by: null
---

## What was observed

The routing and ledger halves of the training corpus — **1,659 of 2,363
examples (70%)** — are labeled by running the deterministic baselines and
recording their answers.

`gen_training_data.py:276-283`, the routing path:

```python
def keep(query, registry, live, intended_action, intended_session=None):
    decision = router_baseline.decide(query, registry, live)
    if decision.get("action") != intended_action:
        return
    if intended_session is not None and decision.get("session") != intended_session:
        return
    system = router_llm._system_prompt(registry, live)
    assistant = _stable(decision, ROUTE_KEY_ORDER)
    out.append(_record("routing", intended_action, query,
                        _example(system, query, assistant)))
```

The assistant message is `decision` — the baseline's output object, serialized.
The ledger path (`:540`) is the same shape against `policy_baseline.decide`.

The generator's docstring calls this being "correct twice over": the template
knows the intended class, and the baseline is asked to agree before the row is
kept.

## The filter never fired

Instrumenting the generator (counting `decide` invocations against appends, run
2026-09-06 from a clean checkout at `704ab09`):

| track | baseline consulted | kept | rejected |
| --- | --- | --- | --- |
| routing | 3,054 | 3,054 | **0** |
| ledger | 769 | 769 | **0** |

It is a tripwire, not a validator. It eliminated nothing the templates did not
already guarantee — which is the expected outcome when the templates are
written to produce exactly the inputs the baseline handles well, but it means
the "correct twice over" claim carries no independent evidence.

Two corrections to `8aa690c`'s commit message, filed here:

1. It says the labels "reproduce an **independent** baseline re-derivation".
   Re-running a deterministic function on its own input is a determinism check,
   not independent verification.
2. It describes the tool-use classes as "request_input / notify / **proceed**".
   The code emits four classes and none is named `proceed`: `request_input`,
   `notify`, `send_input`, `read_terminal` (`gen_training_data.py:912-937`).
   "Proceed" is the name of a construction-rule comment at line 830-833.

## Why this is the corpus's defining property

The labeler's measured competence, on the corpus that decides promotion:

| policy | overall | core | **hard** |
| --- | --- | --- | --- |
| `router_baseline.py` — **the labeler** | 29/51 | 26/26 | **3/25** |
| `google/gemma-4-e4b`, round-3 prompt — the shipped policy | 49/51 | 25/26 | **24/25** |

So: **890 examples of a policy that scores 3/25 on the hard tier, presented
under the 24/25 policy's system prompt, trained to a loss of zero.**

Two things follow directly:

- **The corpus teaches format and the easy cases perfectly.** Every label is
  well-formed JSON in the exact contract, and the core-tier behaviours the
  baseline gets right (26/26) are densely covered.
- **The corpus contains no examples of the judgment the hard tier tests.** By
  construction: the baseline cannot produce those answers, so they cannot
  appear in the labels. The generator deliberately does not reproduce the hard
  tier (P002), and the deterministic labeler could not label it correctly if it
  did.

H004 states the falsifiable prediction that follows.

## Where labels could come from instead

Named here because the alternatives determine what a second corpus looks like:

1. **Model labels with human review** — the round-3-prompted model scores 49/51,
   so its outputs on fresh inputs are a better teacher than the baseline for
   the hard classes. Cost: it needs review, and it bakes in the model's own two
   residual errors (E001).
2. **Real telemetry** — `raw/trajectories/` decision records with `rating: 1`,
   and `rating: -1` pairs relabeled with `payload.correctedDecision`. The
   ingest path exists and is deployed; `build_dataset.py:98-133` implements the
   reader. **No evidence it has ever been used**: no synced `raw/` directory
   exists in the repo.
3. **Disagreements** — examples where a human overruled the baseline. These are
   the only category that adds information the generator does not already
   contain (H001).

## What this does not show

- **It does not show the labels are wrong.** On the classes they cover they are
  correct by construction and verified by the eval's own core tier.
- **It does not show the fine-tune will fail.** A model trained on
  format-perfect easy examples may still generalize from its base's own
  reasoning. That is H004's open question and only the gate answers it.

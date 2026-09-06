# H001 — Training on baseline labels will pull the hard tier toward the baseline

- **Kind:** HYPOTHESIS
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## The claim

The fine-tuned candidate will score **worse on the adversarial `hard` tier
than the untuned base model it is meant to beat**, and the loss will be
concentrated in exactly the scenario classes where `router_baseline.py` and
the round-3 prompt disagree.

## Why

Every routing and ledger label in the corpus is the deterministic baseline's
output — no candidate was ever rejected for disagreeing with it
([O001](O001-2026-09-06-baseline-filter-never-fires.md)), so the corpus is a
distillation of `router_baseline.decide` onto 890 fresh inputs. What that
labeler is worth is measured, in `evals/tmux-routing/RESULTS.md`:

| router | overall | core | **hard** |
| --- | ---: | ---: | ---: |
| `router_baseline.py` (the labeler) | 29/51 | 26/26 | **3/25** |
| model, round-3 prompt (what we serve) | 49/51 | 25/26 | **24/25** |

The labeler is perfect on core and gets **3 of 25** on the adversarial tier.
The prompt-engineered model gets **24 of 25**. The corpus is 890 examples of
the 3/25 policy's rules, presented under the 24/25 policy's system prompt,
optimized to a training loss near zero
([O002](O002-2026-09-06-validation-split-in-distribution.md)).

`gen_training_data.py` anticipates the risk and takes the only defensive step
available (docstring lines 33-36): the hard tier's paraphrase/typo/
misdirection patterns are deliberately not reproduced, "because the baseline
itself mislabels it, so it is not safe training signal." That is the right
call, and it prevents the model being *taught wrong answers* on those
patterns. It does not prevent the model being taught a *rule system* that
generates wrong answers on those patterns — which is what a distillation of a
3/25 policy is.

The core tier is the opposite case and should hold or improve: the labeler is
26/26 there, so 890 examples of it are 890 examples of correct core behavior,
and c01 — the untuned model's only core miss
([O004](O004-2026-09-06-stale-champion-record.md)) — is exactly the kind of
bare-vocabulary case the baseline gets right by construction.

## Prediction, stated so it can be wrong

For the final checkpoint of `fin-foreman-e4b-mlx`, scored by
`run_evals.py --router router_llm.py` at the round-3 prompt:

1. **hard < 24/25** — and most likely well below, in the low teens or worse.
2. **core ≥ 25/26**, plausibly 26/26 (c01 resolved).
3. Therefore **overall < 49/51**, and the candidate does *not* deserve
   promotion, even though it would beat the stale 36/51 record on file.

If instead hard lands ≥ 24/25, the hypothesis is wrong and something more
interesting is true: that the base model's prompt-derived competence survives
LoRA distillation of a weaker policy, which would be worth its own entry.

## The test

`scripts/model-factory/gate_sweep.sh` already runs it — it scores several
checkpoints and prints core/hard per checkpoint. The hard column across
checkpoints is the discriminator: if H001 holds, hard should *decline
monotonically with training*, highest at iteration 1,000 and lowest at the
final checkpoint, while core stays flat. That shape would be strong evidence,
because it separates "the fine-tune damaged the hard tier" from "this base
model was always weak there".

Preconditions before the test can run: the fine-tune must finish (the sweep
refuses while `mlx_lm lora` holds the GPU, `gate_sweep.sh:40-42`), and the
champion must be re-recorded at the round-3 prompt
([O004](O004-2026-09-06-stale-champion-record.md)) or the comparison is
meaningless.

---
id: P002
date: 2026-09-06
occurred: 2026-09-05
kind: PROCESS
title: The leakage rule — the eval corpus is held out, and how that is checked
status: active
tags: [data, leakage, gate, evals]
sources:
  - a823271 — dataset scaffold; scripts/model-factory/build_dataset.py:29-33 (its own capitalised LEAKAGE WARNING)
  - 8aa690c — "Model factory: synthesize held-out SFT data for the foreman fine-tune" (2026-09-05 19:26)
  - scripts/model-factory/gen_training_data.py:86 (JACCARD_NEAR), :946-958 (_load_eval_inputs), :960-979 (_leak_verdict), :1068-1071 (the assertion)
  - main:scripts/model-factory/README.md:167-171 (on branch labbook: 198-202; verify with `grep -n '^\*\*Leakage rule:\*\*' scripts/model-factory/README.md` — see the line-anchor note in O005)
  - "local-artifact: datasets/sft-2026-09-05.jsonl (51 lines) — the seed build that violates the rule"
related: [P001, O007, H004]
corrects: []
superseded-by: null
---

## The rule

`evals/tmux-routing/scenarios.json` (core **and** hard) is the promotion gate.
Its literal scenarios are therefore **held out**: they never appear in
`train.jsonl` or `valid.jsonl`. Train on generated variants and on telemetry;
score on the untouched corpus.

`main:scripts/model-factory/README.md:167-171` (branch `labbook`: 198-202) states it in one line worth keeping:
*"A gate that measures memorization measures nothing."*

The adversarial hard tier is held out for a second reason on top of the first:
it is the discriminator the model has to generalize to, and the deterministic
baseline that labels the training data mislabels most of it (3/25 — E005).
Reproducing it in training would teach the model the wrong answers.

## Protocol

The check lives in the generator and runs on every build
(`gen_training_data.py`).

1. **Build the reference set** — every eval scenario *input*: all 51
   `tmux-routing` queries plus every `goals-ledger` inbox message text
   (`_load_eval_inputs`, lines 946-958). That is **71 unique strings**.
2. **Test every candidate training input** against it with four escalating
   tests (`_leak_verdict`, lines 960-979):

   | test | what it catches |
   | --- | --- |
   | exact string identity | copy-paste |
   | normalized identity (lowercase, non-alphanumerics collapsed) | punctuation and case games |
   | containment either way, when both sides have ≥4 tokens | an eval query wrapped in extra words |
   | token Jaccard ≥ `JACCARD_NEAR` = **0.70** (line 86) | paraphrase by reshuffling |

3. **Drop every hit**, and record the counts in the build's stdout.
4. **Re-test the kept set and assert zero** (lines **1068-1071**, immediately
   after the caps are applied at 1053-1056). A leaky dataset crashes the build
   rather than writing a file. This is the important design choice: the check is
   not advisory.

Recorded result for the corpus now in training (`8aa690c`; reproduced by a
sibling survey on 2026-09-06 from a clean checkout at `704ab09`):

```
LEAKAGE CHECK vs eval inputs (71 unique eval strings)
  candidates generated: 4527  (deduped: 4527)
  dropped for overlap: 0  (exact=0, near-dup=0)
  RESULT: PASS — 0 exact-match, 0 near-duplicate in the 2363 kept training inputs.
```

**Zero drops is also what a broken detector reports.** Before trusting a PASS,
re-run the detector against the 71 literal eval inputs and against mangled
variants of them, and confirm it catches all 71 each time. A sibling survey did
this on 2026-09-06 and got 71 exact / 0 missed on the literals and 71 near / 0
missed on uppercased, punctuation-stripped and `" !!"`-suffixed variants. Re-run
that check whenever `_normalize` or `JACCARD_NEAR` changes.

Zero drops in the real build is explainable, not suspicious: the generator's
vocabulary is disjoint from the eval registry by construction — **16 invented
domains** (`DOMAINS`, `gen_training_data.py:138-155`: orchard, ledgerbook,
trailhead, …) and 10 invented unregistered names (`UNREG_NAMES`: sandbox,
staging, playground, …) against the eval registry's `fin` / `pocketdj` /
`africanintellect` and its live-but-unregistered `main` / `scratch` / `deploy` /
`demo`.

One qualification, because it is easy to over-read: **those 16 are the
generator's vocabulary, not the corpus's.** The balancing caps keep a
lexicographic slice, so only 8 of the 16 reach the kept `route` rows and 4 of 16
the kept `start` rows (O007). Disjointness is unaffected — a smaller vocabulary
cannot collide with the eval registry — but the *breadth* the sentence implies
is not what the corpus contains.

## Four things the gate does not check

1. **It reads only the user message.** System messages are never tested. They
   are **89.6% of the corpus's message characters** (13,510,803 of 15,070,991;
   83.7% of the file's 16,142,664 bytes, a denominator that also counts JSON
   syntax) and they are where an eval registry would leak if one were ever
   reused verbatim.
2. **It checks inputs, never labels.** A training row could carry a wrong
   answer to a fresh question and pass cleanly. Label quality is a separate
   problem (O007).
3. **It cannot see structural leakage.** A lexically fresh example that
   reproduces an eval scenario's *shape* — the same trap, new nouns — passes.
   This is the leak that matters most for the hard tier and there is no
   automated check for it today.
4. **It never reads `registry.example.json`.** `_load_eval_inputs` builds its
   set from scenario queries and inbox texts only, so a training example that
   reused the eval registry would not be flagged.

## The violation that is still on disk

`datasets/sft-2026-09-05.jsonl` — 51 lines, sha256
`7f0f0af7e7c06f574c16599930c73d2da1a62a2190ec1112bb36078d956e9c70` — is the
gate reformatted as training data: one row per eval scenario, user = the
scenario query, assistant = the scenario's `expected` object. It is the output
of `build_dataset.py`, whose own docstring flags it in capitals
(`build_dataset.py:29-33`, the LEAKAGE WARNING block) as a stopgap that must
never reach a real run.

It is not in `datasets/mlx/` and no training run has used it. It is left here
as the worked example of what the rule forbids. If it is ever deleted, this
entry is the record that it existed.

## Open

- **UNSOURCED:** `8aa690c`'s commit message claims a self-test of the detector,
  but the commit is one file and ships no test. The 2026-09-06 reproduction
  above is a re-derivation, not that original test. *Settled by:* a committed
  `test_leakage.py` that runs in CI.
- No committed check runs the detector against `datasets/mlx/*.jsonl` as it
  exists on disk — only against the set the generator is about to write.

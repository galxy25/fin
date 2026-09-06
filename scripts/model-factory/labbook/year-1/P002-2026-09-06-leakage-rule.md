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
  - 704ab09:scripts/model-factory/README.md:167-171 (198-202 of the 367-line copy at 59b0515; verify with `grep -n '^\*\*Leakage rule:\*\*' scripts/model-factory/README.md` — see the line-anchor note in O005)
  - "local-artifact: datasets/sft-2026-09-05.jsonl (51 lines, 249,237 B) — the seed build that violates the rule"
  - scripts/model-factory/gen_training_data.py:941-980 (the detector), :1030-1096 (the build's leakage block)
  - "detector self-test reproduced at main 704ab09: 71 literal eval inputs → 71 exact, 0 missed; uppercased / punctuation-stripped / ' !!'-suffixed variants → 71 near, 0 missed"
  - "merged from docs/labbook/entries/P002-2026-09-06-leakage-gate.md (the parallel book, 4705b67) — see the merge note below"
related: [P001, P005, O003, O007, H004, E006, E007]
corrects: []
superseded-by: O010
---

**Merged from two drafts.** Both books wrote a leakage protocol on 2026-09-06
and both numbered it `P002`: this entry,
`scripts/model-factory/labbook/year-1/P002-2026-09-06-leakage-rule.md`, and
`docs/labbook/entries/P002-2026-09-06-leakage-gate.md`. The id collision was
exact and the subjects were the same, which made this the clearest case for
merging rather than renumbering (O009). This entry won on the strength of its
"Four things the gate does not check" section, its O007 qualification of the
vocabulary claim and its Open items; the other draft contributed the abandoned
approach that produced the rule, the assertion quoted from source, and the
runnable detector self-test — all folded in below. Their recorded numbers were
identical.

## The rule

`evals/tmux-routing/scenarios.json` (core **and** hard) is the promotion gate.
Its literal scenarios are therefore **held out**: they never appear in
`train.jsonl` or `valid.jsonl`. Train on generated variants and on telemetry;
score on the untouched corpus.

`704ab09:scripts/model-factory/README.md:167-171` (198-202 of the 367-line copy
at `59b0515`) states it in one line worth keeping:
*"A gate that measures memorization measures nothing."*

The adversarial hard tier is held out for a second reason on top of the first:
it is the discriminator the model has to generalize to, and the deterministic
baseline that labels the training data mislabels most of it (3/25 — E005).
Reproducing it in training would teach the model the wrong answers.

## Why the rule exists — the approach that was abandoned

The first dataset builder seeded training data **from the eval corpus itself**.
`build_dataset.py` (`a823271`, 2026-09-05 **12:59:51**) emits one training example per
eval scenario, building the system message from the eval adapter's own
`_system_prompt` and the assistant message from the scenario's `expected` label.
Its own docstring flags it in capitals
(`704ab09:scripts/model-factory/build_dataset.py:29-33`):

> LEAKAGE WARNING […] the eval corpus is the promotion gate, so its literal
> scenarios must be HELD OUT of any real training run. This builder emits them
> today only as the scaffold's seed […] The warning prints on every build as a
> reminder.

It was **replaced, not fixed**, by `gen_training_data.py` (`8aa690c`,
2026-09-05 19:26): synthesis on fresh inputs — new session names, new project
domains, new task phrasings, new ledger goals — labeled by the deterministic
baselines rather than copied from the gate. That is the negative result worth
keeping: **a corpus that is both the training seed and the promotion gate cannot
do either job**, and the fix was to build a second corpus, not to sample the
first one more cleverly.

## Protocol

The check lives in the generator and runs on every build
(`gen_training_data.py`; the detector is `:941-980`, the build's leakage block
`:1030-1096`).

1. **Build the reference set** — every eval scenario *input*: all 51
   `tmux-routing` queries plus all 20 `goals-ledger` inbox message texts
   (`_load_eval_inputs`, lines 946-958). That is **71 unique strings**, 51 + 20.
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
   not advisory — and it is what makes this a *gate* rather than a filter:

   ```python
   assert residual_exact == 0 and residual_near == 0, (
       f"LEAKAGE GATE FAILED: … refusing to write a leaky dataset.")
   ```

   The failure mode is a crash, not a warning.

Recorded result for the corpus now in training (`8aa690c`; reproduced by a
sibling survey on 2026-09-06 from a clean checkout at `704ab09`):

```
LEAKAGE CHECK vs eval inputs (71 unique eval strings)
  candidates generated: 4527  (deduped: 4527)
  dropped for overlap: 0  (exact=0, near-dup=0)
  RESULT: PASS — 0 exact-match, 0 near-duplicate in the 2363 kept training inputs.
```

## Detector self-test — run it, do not assume it

**Zero drops is also what a broken detector reports.** A detector that reports
zero drops is indistinguishable from a detector that reports nothing, and only
the self-test tells them apart. `8aa690c`'s commit message claims a self-test
("a self-test confirms the detector flags real eval queries and their
case/punctuation variants") but **ships no test file** — the commit is one file,
`gen_training_data.py`, 1,110 lines. That original self-test is **UNSOURCED**.

Reproduced independently on 2026-09-06 at main `704ab09`:

| input fed to `_leak_verdict` | n | verdict |
| --- | ---: | --- |
| the 71 literal eval inputs | 71 | **71 exact**, 0 missed |
| uppercased, punctuation-stripped, `" !!"` appended | 71 | **71 near**, 0 missed |

```sh
# from any checkout of main @ 704ab09 — e.g.
#   git worktree add ../fin-wt-leakcheck 704ab09 && cd ../fin-wt-leakcheck
python3 -c "
import importlib.util,sys
spec=importlib.util.spec_from_file_location('g','scripts/model-factory/gen_training_data.py')
m=importlib.util.module_from_spec(spec); sys.argv=['g']; spec.loader.exec_module(m)
raw=m._load_eval_inputs(); rs=set(raw); norms=sorted({m._normalize(s) for s in raw if m._normalize(s)})
for label,xs in (('literal',raw),('variants',[s.upper().replace(',','').replace('.','')+' !!' for s in raw])):
    v=[m._leak_verdict(s,rs,norms)[0] for s in xs]
    print(label, len(xs), 'exact',v.count('exact'), 'near',v.count('near'), 'MISSED',v.count(None))
"
```

**Run this whenever the detector, `_normalize`, or `JACCARD_NEAR` changes.**

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

1. **It reads only the user message.** `_leak_verdict` is applied to
   `rec["input_text"]`; system messages are never tested. They are **89.6% of
   the corpus's message characters** (13,510,803 of 15,070,991; 83.7% of the
   file's 16,142,664 bytes, a denominator that also counts JSON syntax) and they
   are where an eval registry would leak if one were ever reused verbatim. This
   is *by design* — the system message is supposed to be byte-identical to the
   eval's framing, which is the property the whole builder rests on. The cost of
   that design decision is O003: when the framing diverges, nothing notices.
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

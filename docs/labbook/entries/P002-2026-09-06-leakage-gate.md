# P002 — Protocol: the leakage rule, what the gate checks, and what it does not

- **Kind:** PROCESS
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## The rule

From `scripts/model-factory/README.md` lines 167-171:

> **Leakage rule:** `evals/tmux-routing/scenarios.json` (core + hard) is the
> gate, so its literal scenarios are **held out** — they never appear in
> `train.jsonl` or `val.jsonl`. Train on generated variants and telemetry;
> score on the untouched corpus. A gate that measures memorization measures
> nothing.

## Why it exists — the approach that was abandoned

The first dataset builder seeded training data **from the eval corpus
itself**. `build_dataset.py` (`a823271`, 2026-09-05 13:03) emits one training
example per eval scenario, building the system message from the eval
adapter's own `_system_prompt` and the assistant message from the scenario's
`expected` label. Its own docstring flags this as a stopgap in capitals
(lines 32-38):

> LEAKAGE WARNING […] the eval corpus is the promotion gate, so its literal
> scenarios must be HELD OUT of any real training run. This builder emits them
> today only as the scaffold's seed […] The warning prints on every build as a
> reminder.

The artifact of that approach still exists and is exactly what the docstring
says it is: `datasets/sft-2026-09-05.jsonl`, 51 lines, 249,237 bytes, sha256
`7f0f0af7e7c06f574c16599930c73d2da1a62a2190ec1112bb36078d956e9c70`. Verified
today — its 51 user texts are the 51 eval queries in corpus order, and its 51
labels are the 51 `expected` objects. It is the eval set, reformatted.

It was replaced, not fixed, by `gen_training_data.py` (`8aa690c`, 2026-09-05
19:26): synthesis on fresh inputs — new session names, new project domains,
new task phrasings, new ledger goals — labeled by the deterministic baselines
rather than copied from the gate. That is the negative result worth keeping:
**a corpus that is both the training seed and the promotion gate cannot do
either job**, and the fix was to build a second corpus, not to sample the
first one more cleverly.

## What the gate checks

`gen_training_data.py:941-980` and `1030-1096`. The reference set is *every
eval scenario input*: all 51 `tmux-routing` queries plus all 20
`goals-ledger` inbox message texts — **71 unique strings**
(`_load_eval_inputs`). Every generated training input is tested against it,
in four escalating ways (`_leak_verdict`):

1. **exact** — raw string identity.
2. **normalized identity** — lowercase, non-alphanumerics collapsed to single
   spaces.
3. **containment** — either normalized string inside the other, when both have
   ≥4 tokens.
4. **token Jaccard ≥ 0.70** (`JACCARD_NEAR`).

Any hit is dropped. Then — and this is the part that makes it a gate rather
than a filter — the *kept* set is re-tested and the result asserted:

```python
assert residual_exact == 0 and residual_near == 0, (
    f"LEAKAGE GATE FAILED: … refusing to write a leaky dataset.")
```

A leaky dataset cannot be written. The failure mode is a crash, not a warning.

## The recorded result

For `sha256:9552ac13…` (the corpus now training), from the generator's own
stdout, reproduced at main `704ab09`:

```
LEAKAGE CHECK vs eval inputs (71 unique eval strings: tmux-routing queries +
goals-ledger inbox texts):
  candidates generated: 4527  (deduped: 4527)
  dropped for overlap: 0  (exact=0, near-dup=0)
  RESULT: PASS — 0 exact-match, 0 near-duplicate in the 2363 kept training inputs.
```

**Zero drops.** The fresh vocabulary is disjoint enough that nothing ever came
close — the generator's 16 invented domains (orchard, ledgerbook, trailhead,
brewlog, …) and 10 invented unregistered names (sandbox, staging, playground,
…) share no session name with the eval registry's `fin` / `pocketdj` /
`africanintellect`, nor with the eval's live-but-unregistered `main` /
`scratch` / `deploy` / `demo`.

## Detector self-test — run it, don't assume it

Zero drops is also what a *broken* detector reports. Commit `8aa690c` claims
a self-test ("a self-test confirms the detector flags real eval queries and
their case/punctuation variants") but ships no test file — the commit is one
file, `gen_training_data.py`, 1,110 lines. That original self-test is
**UNSOURCED**. Reproduced independently today, at main `704ab09`:

| input fed to `_leak_verdict` | n | verdict |
| --- | ---: | --- |
| the 71 literal eval inputs | 71 | **71 exact**, 0 missed |
| uppercased, punctuation-stripped, `" !!"` appended | 71 | **71 near**, 0 missed |

```sh
cd /Users/deepspacenine/forges/levi/fin-wt-labbook
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

**Run this whenever the detector, the normalizer, or `JACCARD_NEAR` changes.**
A detector that reports zero drops is indistinguishable from a detector that
reports nothing, and only the self-test tells them apart.

## What the gate does NOT check — read this before trusting it

1. **It only inspects the user message.** `_leak_verdict` is applied to
   `rec["input_text"]`. The system message — 84% of the corpus by volume —
   is never checked, by design (it is *supposed* to be byte-identical to the
   eval's framing). The cost of that design decision is
   [O003](O003-2026-09-06-prompt-skew-mid-run.md).
2. **It checks inputs, never labels.** Nothing verifies that a training label
   is *correct*, only that its input is novel. The labels are the baselines'
   outputs, unfiltered — [O001](O001-2026-09-06-baseline-filter-never-fires.md),
   [H001](H001-2026-09-06-hard-tier-regression.md).
3. **It cannot see structural leakage.** A training example that is
   lexically fresh but reproduces an eval scenario's *shape* — same registry
   topology, same ambiguity, same guardrail trap — passes cleanly. Novel
   surface form is what is measured; novel decision problem is what is
   wanted. No artifact currently measures the second.
4. **The eval-side inputs it loads are inputs only.** `_load_eval_inputs`
   reads `scenarios.json` queries and inbox texts; it does not read
   `registry.example.json`, so a training example that reused the eval
   registry verbatim would not be flagged. It happens not to matter here (the
   generator builds registries from its own `DOMAINS`), but the gate is not
   what is preventing it.

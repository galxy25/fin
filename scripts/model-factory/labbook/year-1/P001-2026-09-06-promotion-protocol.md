---
id: P001
date: 2026-09-06
occurred: 2026-09-05
kind: PROCESS
title: The promotion protocol — what it takes for a candidate to become the champion
status: active
tags: [gate, promotion, evals, champion]
sources:
  - a823271 — "Model factory scaffold: dataset builder, QLoRA recipe, eval gate" (2026-09-05 12:59)
  - scripts/model-factory/eval_gate.py:44-45, :75-80, :110-112, :152
  - scripts/model-factory/evals-champions.json
  - 704ab09:scripts/model-factory/README.md:240-262 (271-293 of the 367-line copy at 59b0515; verify with `grep -n '^## Eval gate' scripts/model-factory/README.md` — see the line-anchor note in O005)
  - 704ab09:evals/tmux-routing/run_evals.py:195 (the core-only exit rule, in a 202-line file; the same statement is at 210 of 217 at cd64914 and f0ca4af, and at 212 of 219 at 78e6c36 — see the table in E005)
related: [P002, P004, O002, O005, O006]
corrects: []
superseded-by: null
---

## Protocol

A fine-tuned candidate replaces the champion only by passing
`scripts/model-factory/eval_gate.py`. Nothing else promotes a model — not a
loss curve, not a val loss, not a manual read of a few outputs.

1. **Serve the candidate** on an OpenAI-compatible endpoint. The gate takes
   `--base-url` and `--model` and does not care what serves them (LM Studio,
   `mlx_lm.server`, a hosted endpoint).
2. **Run the gate:**
   ```sh
   python3 scripts/model-factory/eval_gate.py \
     --base-url http://localhost:1234/v1 \
     --model <candidate-id> \
     --out models/<candidate>/verdict.json
   ```
   It shells out to `evals/tmux-routing/run_evals.py --router router_llm.py`
   with `FIN_ROUTER_BASE_URL` / `FIN_ROUTER_MODEL` set, and scrapes two
   regexes off its stdout (`eval_gate.py:44-45`):
   ```python
   OVERALL_RE = re.compile(r"tmux-routing evals: (\d+)/(\d+) passed")
   TIERS_RE   = re.compile(r"core \(gates\): (\d+)/(\d+)\s+hard \(benchmark\): (\d+)/(\d+)")
   ```
3. **Read the two conditions** (`eval_gate.py:110-112`):
   ```python
   core_gate      = scores["core"]["passed"] == scores["core"]["total"]
   beats_champion = beats(scores["overall"], champion["scores"]["overall"])
   promoted       = core_gate and beats_champion
   ```

Stated plainly:

> **Promote if and only if (a) every core scenario passes — 26/26, non-negotiable — and (b) the core+hard total strictly beats the champion's.**

`beats()` (`eval_gate.py:75-80`) compares raw counts when the totals match and
fractions when they do not, so the rule survives a corpus that grows:

```python
def beats(candidate: dict, champion: dict) -> bool:
    """Strictly better on core+hard combined; fractions when totals differ."""
    if candidate["total"] == champion["total"]:
        return candidate["passed"] > champion["passed"]
    return (candidate["passed"] / candidate["total"]
            > champion["passed"] / champion["total"])
```

**`>` and not `>=`: ties do not promote.** A candidate that matches the
champion stays on the bench. The asymmetry is deliberate — swapping the served
model has a cost (re-verification, a new failure surface) that a tie does not
pay for.

Exit codes (`eval_gate.py:152`): `0` promoted, `1` not promoted, `2` the run
failed to score at all. `2` is not a soft `1`; it means the endpoint or the
parse broke and the run tells you nothing.

## Why the two conditions are different in kind

- **Core is a gate.** The 26 core scenarios are the behaviours a router must
  not get wrong; failing one is disqualifying regardless of the total. The
  eval harness encodes the same split independently — `run_evals.py:195` on
  `704ab09` (same blob at `59b0515`, where this entry lives) is
  `return 0 if core_passed == core_total else 1`, so hard-tier misses report
  but never fail a run. On `imac-site` that file is 217 lines rather than 202
  and the same statement is at line 210; `grep -n 'core_passed == core_total'
  evals/tmux-routing/run_evals.py` finds it on any of them.
- **Hard is a benchmark.** The 25 adversarial `h01`–`h25` scenarios are where
  candidates are ranked against each other. They are deliberately harder than
  anything the deterministic baseline can do (it scores 3/25 — see E005).

## The champion record

`scripts/model-factory/evals-champions.json`, 403 bytes, one commit ever
(`a823271`, never edited since):

```json
{"tmux-routing": {
  "modelId": "google/gemma-4-e4b",
  "note": "untuned local model via LM Studio; the score to beat until a fine-tuned candidate promotes",
  "recordedAt": "2026-09-05",
  "source": "evals/tmux-routing/RESULTS.md",
  "scores": {"core": {"passed": 21, "total": 26},
             "hard": {"passed": 15, "total": 25},
             "overall": {"passed": 36, "total": 51}}}}
```

**Before running the gate, confirm the champion number was measured with the
prompt the candidate is being scored under.** It currently was not — see O002,
which is the standing cautionary case for this whole protocol. O002 also records
a second thing about this record: the `core` / `hard` split quoted above was
**not printed by the harness** that produced the 36/51, because the corpus had
no tiers when that run happened. It is a legitimate post-hoc re-partition, and
nothing in the file says so. `recordedAt` is
a string the gate never reads (`eval_gate.py` contains no reference to it);
nothing in code prevents scoring against a stale number.

## What this protocol does not cover

- **`evals/goals-ledger` is not in the gate.** `evals-champions.json` has
  exactly one key, `tmux-routing`, and `eval_gate.py` mentions goals-ledger
  nowhere — while 769 of the 2,363 training examples are ledger examples. See
  O006.
- **Which checkpoint to gate.** The gate scores whatever you point it at. A
  run produces a checkpoint every 250 iterations and the last is not
  automatically the best; see P004 and H003.
- **Provenance.** The verdict JSON records model, base URL, timestamp, scores,
  champion, the two booleans and the raw `runOutput` — but no prompt hash and
  no corpus commit, so a verdict cannot be attributed to a `router.md` version
  after the fact. See O005.
- **The serving surface.** A candidate scored through `mlx_lm.server` and a
  champion scored through LM Studio are two quantizations on two servers; the
  gate cannot see the difference. Re-score the winner on the surface it will
  actually be served from before it goes live.

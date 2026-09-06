# O004 — The recorded champion is a round-0 number; the shipped prompt scores 13 higher

- **Kind:** OBSERVATION
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## What was noticed

`scripts/model-factory/evals-champions.json` is the promotion authority —
`eval_gate.py` compares a candidate against it and promotes only on a strict
win. It records:

```json
{"tmux-routing": {"modelId": "google/gemma-4-e4b", "recordedAt": "2026-09-05",
  "scores": {"core": {"passed": 21, "total": 26},
             "hard": {"passed": 15, "total": 25},
             "overall": {"passed": 36, "total": 51}}}}
```

That 36/51 is the **round-0 prompt** result. `evals/tmux-routing/RESULTS.md`
records the whole prompt-iteration sequence on the *same untuned model*:

| round | overall | core | hard | commit |
| --- | ---: | ---: | ---: | --- |
| baseline `router_baseline.py` (no model) | 29/51 | 26/26 | 3/25 | — |
| 0 — original prompt | **36/51** | 21/26 | 15/25 | `6b1c95f` |
| 1 — three-classes rewrite | 46/51 | 25/26 | 21/25 | `22005c7` |
| 2 — imperative-first | 48/51 | 24/26 | 24/25 | `f0040f5` |
| 3 — route⊆registry — **kept** | **49/51** | **25/26** | **24/25** | `fcb10b2` / `99ed9d9` |
| 4 — generic-phrase clamp — reverted | 48/51 | 25/26 | 23/25 | `e7460cd` |

The prompt actually shipped, and the prompt the corpus was built with
([E001](E001-2026-09-06-corpus-bit-exact-reproduction.md)), is round 3 at
49/51. The champion file still holds the number measured before three rounds
of prompt work landed — a 13-point stale gap, all of it prompt, none of it
model.

## Why this is dangerous rather than merely untidy

`eval_gate.py`'s promotion rule is "all core pass AND strictly beat the
champion on core+hard combined". A candidate scoring, say, 40/51 would be
promoted against the stored 36/51 while being **nine points worse** than the
untuned base model it is meant to replace. The stale record does not fail
safe; it fails toward a false promotion.

This is already known and guarded procedurally: `gate_sweep.sh:14-17` at
`d9100b6` — a commit on the `imac-site` line of history, so the script is not
in a `labbook` or `main` checkout — refuses
to let a candidate be judged on the stored number, and
`models/candidates/fin-foreman-e4b-mlx/fuse-and-gate.md` step 3 is "RE-RECORD
THE CHAMPION FIRST". Both are runbook text, not enforcement — `eval_gate.py`
itself will happily compare against a champion record of any age, and
`recordedAt` is a string it never reads.

## The residual misses, for the record

Under the round-3 prompt the untuned base misses exactly two scenarios
(`RESULTS.md` "Remaining misses"): **c01** (core) — "run the tests" routes
`fin` on a bare-vocabulary rationalization — and **h08** (hard) — a contrast
clause outweighing the imperative. Core therefore stands at 25/26, so **c01
is the only thing between the untuned base model and passing the gate
outright**. Any candidate that fixes c01 without breaking the other 25 clears
the non-negotiable half of the promotion rule.

## What would settle it

A recorded run of `run_evals.py --router router_llm.py` against
`google/gemma-4-e4b` at the current prompt, written back into
`evals-champions.json` with its `recordedAt` and the sha of `router.md` at
scoring time. `gate_sweep.sh` step 1 does exactly this and caches it to
`models/gate-sweep/champion.txt`; that file does not exist yet, so **no
re-record has been performed** as of this entry.

# O005 — The factory README's status checklist has drifted behind the run

- **Kind:** OBSERVATION
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## What was noticed

`scripts/model-factory/README.md`'s Status block (lines 22-45) is the
factory's front page and the first thing a reader trusts. Four of its entries
no longer describe reality at `cd64914`:

| README line | says | actual | source |
| --- | --- | --- | --- |
| "[ ] Synthetic expansion of the routing taxonomy … unblocks the first real fine-tune" | not done | **done** | `8aa690c`, 2026-09-05 19:26 |
| "[ ] First fine-tune run (**human go required**)" | not done | **running since 2026-09-05 20:15:29**, iteration 3,700 of 4,490 | `train.log:1`, pid 18405 |
| "[ ] goals-ledger eval joins the gate (that branch has not merged)" | not merged | **merged 2026-09-05 12:45** — 35 scenarios on main | `e025413`; `git ls-tree 704ab09 evals/` |
| Dataset-builder bullet's "**Leakage caveat**" | seed build derives from the eval corpus | superseded by `gen_training_data.py` | `8aa690c` |

Two more, smaller:

- The training recipe still names the wrong base. `train/qlora_config.yaml:7`
  reads `base_model: google/gemma-3-4b-it` and `train/README-local.md` names
  gemma-3, while the run in flight uses
  `mlx-community/gemma-4-E4B-it-qat-4bit` (`launch-train.sh:12`). This is
  already on the fix list — `fuse-and-gate.md` step 6 — but unfixed.
- `evals/goals-ledger` is merged, yet `eval_gate.py` has no reference to it
  (`grep -n 'goals-ledger' scripts/model-factory/eval_gate.py` → nothing). The
  gate is still the routing corpus alone, exactly as README's "Eval gate"
  section describes, so the *behavior* is honest even though the *checklist*
  is not. The ledger corpus is used for training data
  (`gen_ledger`, 769 examples) while contributing nothing to promotion — the
  one track where the factory trains on a target it does not gate.

## Why record a docs bug in a lab book

Because the Status block is load-bearing for the "human go required" rule. A
reader checking whether a fine-tune has been authorized reads an unchecked
box next to the words "human go required" while a fine-tune is running. The
run itself is legitimate — the standing rule in README lines 231-238 governs
*GPU jobs that bill by the hour*, and explicitly exempts local mlx runs
("Dataset builds, local mlx runs, and evals against an already-running
endpoint need no approval") — but a checklist that contradicts the machine's
process table is a checklist that will eventually be trusted at the wrong
moment.

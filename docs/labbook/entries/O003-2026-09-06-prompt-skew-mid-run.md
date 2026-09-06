# O003 — A prompt edit landed mid-run and opened train/serve skew

- **Kind:** OBSERVATION
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## What was noticed

The whole design of the dataset builder rests on one property, stated in
`build_dataset.py`'s docstring and repeated in the factory README (line 154):

> training and inference must see byte-identical framing

It is enforced by construction: both the eval adapter and the generator build
the system message through `router_llm._system_prompt`, which reads
`evals/tmux-routing/prompts/router.md`. That makes the framing byte-identical
*at a given repo state*, and silently divergent across states.

A commit has since changed that file:

| | |
| --- | --- |
| corpus built | 2026-09-05 19:46 (`datasets/sft-train-2026-09-05.jsonl` mtime) |
| training started | 2026-09-05 20:15:29 (`train.log:1`) |
| **`router.md` edited** | **2026-09-06 09:52 — `7a591f4`** |
| training still running | last report `Iter 3700` of 4,490 |

`7a591f4` ("Close the tmux guard's parser holes: tmux's argv, not the
shell's") replaces one sentence and adds a **seven**-line HTML correction
comment: +13/-1 lines overall (4 lines of replacement prose, a blank, the
7-line `<!-- Corrected 2026-09-06: … -->` block, a trailing blank), 9,172 →
9,936 characters. The substance is right —
the old text ("Sessions you create yourself are added to the registry
automatically") was never true of the codebase, and `TmuxCommandGuard`'s
allow-list made it actively harmful. The comment in the file says so plainly
and notes that the offline baseline does not read the prompt (confirmed:
`grep -n 'router.md\|prompts/' evals/tmux-routing/router_baseline.py` returns
nothing).

But the candidate now training has **never seen those 764 characters**, and
they sit inside the system message of every routing example. Regenerating the
corpus at the edited state changes exactly the 890 routing rows and nothing
else ([E001](E001-2026-09-06-corpus-bit-exact-reproduction.md)).

## Status and scope

`7a591f4` is **not on main** (`git merge-base --is-ancestor 7a591f4 704ab09`
→ false); it lives on the `imac-site` branch, tip `cd64914` at the time of
writing. So the skew is not yet shipped. It becomes real the moment
`imac-site` merges *and* the candidate is scored — because
`eval_gate.py`/`run_evals.py` build the eval's system prompt from whatever
`router.md` says at scoring time.

The failure mode is quiet and asymmetric: nothing errors, nothing warns, the
candidate is simply scored under framing it was not trained on, and any
resulting score change is indistinguishable from a real capability change.

## What would prevent a recurrence

The corpus should record the prompt it was built from. The factory README
(`main`, lines 173-175) specifies a per-build manifest and its contents — "source list, example counts per
track, per-split sha256, corpus git commit, build date" — but
`gen_training_data.py` writes no manifest, and neither
`datasets/sft-train-2026-09-05.jsonl` nor `datasets/mlx/` has one. A manifest
carrying the sha256 of `prompts/router.md` alongside the corpus sha256 would
turn this from archaeology into an assertion the gate could make on its own.

Until then, the check is manual and belongs in the gate protocol:

```sh
# does the prompt the gate will use still match the one the corpus was built from?
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- evals/tmux-routing/prompts/router.md
# must be at or before the corpus mtime; 99ed9d9 (2026-09-05 13:07) for sha256:9552ac13…
```

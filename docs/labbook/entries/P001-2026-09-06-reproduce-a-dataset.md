# P001 — Protocol: reproduce a dataset bit-for-bit before you trust a number about it

- **Kind:** PROCESS
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## Why this protocol exists

`datasets/` is gitignored on purpose — datasets are artifacts, not source
(`a823271`). The cost of that decision is that a dataset arrives with no
commit, no author and no provenance: it is a 16 MB file with a date in its
name. Every downstream number — a val loss, a gate score, a promotion verdict
— is a claim about *that file*, and none of them mean anything if the file
cannot be tied back to committed source.

This protocol takes a dataset from "an artifact someone made" to "the output
of commit X", which is the state E001 put `sha256:9552ac13…` into.

## The protocol

**1. Never write into `datasets/` while a run is reading it.** Generators
default to `datasets/<name>-<today>.jsonl`, which on a different day is a
*new* file next to the live one. Always pass `--out` to a scratch path.

```sh
python3 scripts/model-factory/gen_training_data.py --out "$SCRATCH/regen.jsonl"
```

**2. Reproduce from a clean worktree at a named commit, not from the working
checkout.** The working checkout carries uncommitted edits and sits on
whatever branch was last used; a dataset reproduced there is pinned to
nothing. Use a worktree so the main checkout is undisturbed and other agents
working in it are unaffected:

```sh
git worktree add ../fin-wt-<purpose> -b <purpose> main
cd ../fin-wt-<purpose>
python3 scripts/model-factory/gen_training_data.py --out "$SCRATCH/regen-main.jsonl"
```

**3. Compare sha256, not counts.** Matching example counts prove nothing —
E001's two builds both emitted 2,363 rows and differed in 890 of them.

```sh
shasum -a 256 "$SCRATCH/regen-main.jsonl" datasets/<the artifact>.jsonl
```

**4. On a mismatch, localize before theorizing.** Count differing lines
first; if the count equals a track's example count, the divergence is in that
track's shared inputs (prompt file, registry, baseline), not in the
generator. Then diff one matched pair — same user text and same label,
different system message — and read the hunk. E001 went from "the hashes
differ" to "commit `7a591f4` added 764 characters to `router.md`" in two
steps this way.

**5. Record the commit range, not just the commit.** A dataset is reproducible
from *every* state where its inputs are unchanged. Find the range by asking
when each input last changed:

```sh
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- scripts/model-factory/gen_training_data.py
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- evals/tmux-routing/prompts/router.md
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- evals/tmux-routing/scenarios.json
git log -1 --format='%h %ad' --date=format:'%F %H:%M' -- evals/goals-ledger/
```

The dataset reproduces from the latest of those commits through any descendant
that does not touch them.

**6. Write the result down where the number is used.** A model manifest citing
`dataHash: sha256:…` is only as good as the entry that says what that hash is
the output of.

## The standing gap this protocol works around

Steps 5 and 6 are manual because the generator writes no manifest. The factory
README specifies one (lines 173-175) and `build_dataset.py`'s docstring
promises it; neither `gen_training_data.py` nor `datasets/mlx/` produces one.
Until a build emits `manifest.json` carrying the corpus sha256, the input
shas, and the corpus commit, provenance is reconstructed by hand every time.
That is the single highest-leverage fix in the data pipeline, and it is
smaller than any of the entries that had to be written because it is missing —
[E001](E001-2026-09-06-corpus-bit-exact-reproduction.md),
[E003](E003-2026-09-06-mlx-split-recovery.md),
[O003](O003-2026-09-06-prompt-skew-mid-run.md).

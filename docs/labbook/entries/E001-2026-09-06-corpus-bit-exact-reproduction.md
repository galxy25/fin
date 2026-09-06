# E001 — The training corpus reproduces bit-for-bit, and names the commit it was built at

- **Kind:** EXPERIMENT
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## Question

`datasets/` is gitignored — the datasets are artifacts, not source
(`a823271`, `.gitignore` +1). So the corpus the live fine-tune is reading has
no commit of its own. Does `datasets/sft-train-2026-09-05.jsonl` actually
reproduce from committed source, and if so, from *which* repo state?

This matters because `gen_training_data.py` builds each example's system
message by importing the eval adapter's own prompt builder
(`router_llm._system_prompt`, `gen_training_data.py:98-101`), so the corpus
silently inherits whatever `evals/tmux-routing/prompts/router.md` said on the
day it ran.

## Method

Run the generator with output redirected outside `datasets/` (the live
training run is reading that directory), once from each of two repo states,
and compare sha256 against the artifact:

The commands below are written against *revisions*, not against the throwaway
worktrees this was actually run in. That is deliberate: the run used
`/Users/deepspacenine/forges/levi/fin-wt-labbook` and wrote its output under
`/tmp/scratch/`, and neither will exist a year from now — the sibling book's
P003:111 states the rule ("**Nothing under `/tmp`.** Worktrees, venvs and
training artifacts live under the repo or `~/forges`. The reboot is the
reason") and its E003:104 records a `/tmp/fin-wt-train` worktree being wiped as
exactly why some of its memory numbers are UNSOURCED today.

```sh
REPO=~/forges/levi/fin                 # any clone of this repository
SCRATCH=$REPO/../fin-scratch; mkdir -p "$SCRATCH"

# state A: branch imac-site @ cd64914
git -C "$REPO" worktree add "$SCRATCH/wt-A" cd64914
python3 "$SCRATCH/wt-A/scripts/model-factory/gen_training_data.py" \
  --out "$SCRATCH/regen.jsonl"

# state B: main @ 704ab09
git -C "$REPO" worktree add "$SCRATCH/wt-B" 704ab09
python3 "$SCRATCH/wt-B/scripts/model-factory/gen_training_data.py" \
  --out "$SCRATCH/regen-main.jsonl"

shasum -a 256 "$SCRATCH"/regen*.jsonl \
  "$REPO/datasets/sft-train-2026-09-05.jsonl"
```

## Result

| build | sha256 | verdict |
| --- | --- | --- |
| artifact `datasets/sft-train-2026-09-05.jsonl` (2,363 lines, 16,142,664 bytes, mtime 2026-09-05 19:46) | `9552ac13e49351a9d9869f089cc5bfe804d17864db047f7fcbec912188dd25b5` | — |
| regenerated at **main `704ab09`** | `9552ac13e49351a9d9869f089cc5bfe804d17864db047f7fcbec912188dd25b5` | **IDENTICAL** |
| regenerated at **imac-site `cd64914`** | `4f25702b81c6b7e5232464ada428dec4f5e01a3f237373abdd3f11b72b45a9e2` | differs |

So the corpus is fully reproducible, and it is pinned to main. The
`cd64914` build differs in **exactly 890 lines** — precisely the routing
track's example count (`gen_training_data.py` stdout: `routing 890`). The
other 1,473 lines (ledger 769, elicit 320, tooluse 384) are byte-identical
across both states.

Diffing one matched pair (same user text, same label, different system
message) localizes the change to a single hunk of `prompts/router.md`:

```
-create yourself are added to the registry automatically.
+start yourself are yours to drive — name them with a `fin-` prefix
+(`tmux new-session -d -s fin-<purpose>`), the namespace the send-keys guard
+treats as yours. […]
+<!-- Corrected 2026-09-06: the previous wording […] was never true […] -->
```

That edit is commit `7a591f4` ("Close the tmux guard's parser holes",
2026-09-06 09:52), **not an ancestor of main** (`git merge-base --is-ancestor
7a591f4 704ab09` → false). It adds 764 characters to the prompt (9,172 →
9,936 chars), and every one of them lands inside the system message of every
routing example.

Chain of custody for the corpus, then:

- generator: `scripts/model-factory/gen_training_data.py` @ `8aa690c`
  ("Model factory: synthesize held-out SFT data for the foreman fine-tune",
  2026-09-05 19:26, 1,110 lines, one file). `git diff 8aa690c --` on that path
  at `cd64914` is empty: the script itself has not changed since.
- prompt: `evals/tmux-routing/prompts/router.md` @ `99ed9d9` ("Settle on the
  round-3 prompt", 2026-09-05 13:07). `git diff 99ed9d9 704ab09 --` on that
  path is empty, so every commit from `99ed9d9` through main tip reproduces
  the corpus.
- corpus written 2026-09-05 19:46 (file mtime), 20 minutes after `8aa690c`.
- training started 2026-09-05 20:15:29
  (`models/candidates/fin-foreman-e4b-mlx/train.log:1`).

## What this establishes

`sha256:9552ac13…` is now a name that means something: "the output of
`gen_training_data.py` at any repo state between `99ed9d9` and `704ab09`."
A model manifest can cite it and the claim is checkable by anyone with the
repo. See [P001](P001-2026-09-06-reproduce-a-dataset.md) for the protocol.

The consequence of the `7a591f4` divergence is recorded separately in
[O003](O003-2026-09-06-prompt-skew-mid-run.md).

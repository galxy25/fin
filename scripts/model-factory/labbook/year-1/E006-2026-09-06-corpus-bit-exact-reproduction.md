---
id: E006
date: 2026-09-06
occurred: 2026-09-06
kind: EXPERIMENT
title: The training corpus reproduces bit-for-bit, and names the commit it was built at
status: closed
tags: [corpus, reproducibility, provenance, prompt]
sources:
  - "shasum -a 256 datasets/sft-train-2026-09-05.jsonl -> 9552ac13e49351a9d9869f089cc5bfe804d17864db047f7fcbec912188dd25b5 (2,363 lines, 16,142,664 B, mtime 2026-09-05 19:46)"
  - "regenerated at main 704ab09 -> 9552ac13...; at imac-site cd64914 -> 4f25702b81c6b7e5232464ada428dec4f5e01a3f237373abdd3f11b72b45a9e2"
  - 8aa690c — the generator commit (2026-09-05 19:26) · 99ed9d9 — the round-3 prompt (2026-09-05 13:07)
  - 7a591f4 — "Close the tmux guard's parser holes" (2026-09-06 09:52), NOT an ancestor of main
  - scripts/model-factory/gen_training_data.py:98-101 (the system message is built by router_llm._system_prompt)
related: [E007, E008, O003, O005, P005]
corrects: []
superseded-by: null
---

**Migrated entry.** Written as `docs/labbook/entries/E001-2026-09-06-corpus-bit-exact-reproduction.md`
in the parallel book opened at `4705b67`, and renumbered `E001 -> E006` when the
two books were consolidated into this one (O009). The body is unchanged apart
from its header block, which was converted from that book's bold-field form to
this book's YAML front matter, and its cross-references, which now name this
book's ids.

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
`/tmp/scratch/`, and neither will exist a year from now — P003:111 states the
rule ("**Nothing under `/tmp`.** Worktrees, venvs and training artifacts live
under the repo or `~/forges`. The reboot is the reason") and E003:136 records a
`/tmp/fin-wt-train` worktree being wiped as exactly why some of its memory
numbers are UNSOURCED today. (Both anchors are against this book at `0fe0883`.
Written in the other book these read "the sibling book's P003:111" and "its
E003:104"; P003:111 was right and E003:104 was wrong — the `/tmp/fin-wt-train`
sentence is at E003:**136**, and was at 136 when the anchor was written. The
consolidation kept the number that verifies and corrected the one that did not
rather than deleting it silently.)

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
repo. See P005 for the protocol.

The consequence of the `7a591f4` divergence is recorded separately in
O003.

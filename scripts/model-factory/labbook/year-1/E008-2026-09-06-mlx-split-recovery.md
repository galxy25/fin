---
id: E008
date: 2026-09-06
occurred: 2026-09-06
kind: EXPERIMENT
title: Recovering the unscripted train/valid split from its artifacts
status: closed
tags: [corpus, split, reproducibility, mlx]
sources:
  - "shasum -a 256: datasets/sft-train-2026-09-05.jsonl 9552ac13... (2,363 lines, 16,142,664 B); datasets/mlx/train.jsonl 4aa180a2... (2,245 lines, 15,341,147 B); datasets/mlx/valid.jsonl 23a87bab... (118 lines, 801,517 B)"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/launch-train.sh:13 (--data datasets/mlx), :17 (--seed 17)"
  - "reconstruction: random.Random(17).shuffle(range(2363)), first 118 -> valid — reproduces both files byte-for-byte including line order"
  - "git grep -n 'datasets/mlx' 0fe0883 -- ':(exclude)docs/labbook' ':(exclude)scripts/model-factory/labbook' -> exit 1, no output. BOTH exclusions are needed at this revision; the one-exclusion form exits 0 here with 11 hits. At 5305044 (docs/labbook deleted) one suffices; at 704ab09 none is needed. Full matrix in O005"
related: [E006, O001, O005, O010, P005]
corrects: []
superseded-by: [O010, O013]
---

**Migrated entry.** Written as `docs/labbook/entries/E003-2026-09-06-mlx-split-recovery.md`
in the parallel book opened at `4705b67`, and renumbered `E003 -> E008` when the
two books were consolidated into this one (O009). Body unchanged apart from the
header block, the cross-references, and the self-referential grep count in the
Question below, which the consolidation replaced under the rule the README now
carries: **a count of the book by itself is not evidence.**

**That replacement was itself wrong**, and this entry is the site where it is
easiest to see, because the draft it replaced had the correct form. O010 records
what happened; the Question below now carries the command run at each of the
three revisions it cites, and quotes the sentence the consolidation deleted.

## Question

The live fine-tune reads `--data datasets/mlx`
(`models/candidates/fin-foreman-e4b-mlx/launch-train.sh:13`), a directory
containing `train.jsonl` and `valid.jsonl`. **No committed script produces it.**
The durable form of that claim excludes the lab books from the search — and
*which* exclusions it needs depends on the revision, because the number of lab
books in this repository has been 0, then 1, then 2, then 1 again:

```sh
# at 704ab09 (what `main` pointed at when this entry was written): no exclusion needed
git grep -n 'datasets/mlx' 704ab09                                    # exit 1, no output

# at 0fe0883, while both books existed: BOTH qualifiers are load-bearing
git grep -n 'datasets/mlx' 0fe0883 \
  -- ':(exclude)docs/labbook' ':(exclude)scripts/model-factory/labbook'  # exit 1, no output

# at 5305044 and after, docs/labbook/ deleted: one suffices
git grep -n 'datasets/mlx' 5305044 \
  -- ':(exclude)scripts/model-factory/labbook'                          # exit 1, no output
```

Each of those three was run at the revision it names. The middle one is the
sentence this entry got wrong twice, in opposite directions — see the fourth
row of the table below.

A plain `grep -rn` over the working tree returns two hits, both inside
gitignored `models/`: that same `launch-train.sh:13` and `adapter_config.json:6`,
which are the run's own record of the path, not a script that builds it.

**Four** drafts of this sentence got the command wrong in four different ways,
and the sequence is the reason the exclusion is now mandatory *and* the reason
O010 exists (README, conventions):

| draft | claim | why it was wrong |
| --- | --- | --- |
| first | "`grep -rn` returns nothing outside `datasets/`" | ignored the two gitignored working-tree hits, one of which it quoted three lines later |
| second | "`git grep 'datasets/mlx'` exits 1 with no output" | true at `704ab09`, false on the branch the entry lives on — and false at `main` today (`587fb9a`), where `content/claims-ledger.md:416` quotes the path |
| third | "a bare `git grep` on `labbook` exits 0 with **24 hits**, every one of them a lab-book entry" | true at `cdb895a` and false by the next commit: the same command at `0fe0883` returns **30** and at `5305044` returns **32**, because writing more of the book created more references |
| fourth — *the fix for the third* | "`git grep -n 'datasets/mlx' <rev> -- ':(exclude)scripts/model-factory/labbook'` exits 1 with no output at `main` and at `0fe0883`" | never run at `0fe0883`, where it exits **0** with **11** hits from `docs/labbook/entries/*` — the second book still existed there and the pathspec excludes only the first |

The third is instructive: that number measured the book, not the factory, so
every entry added to the book moved it — a citation that rots on contact with
its own author. **The fourth is worse, and it is the one O010 is about.** The
draft of this entry that lived at `0fe0883:docs/labbook/entries/E003-2026-09-06-mlx-split-recovery.md`
had it right, with both pathspecs and one sentence of warning:

> *"`git grep 'datasets/mlx' main` exits 1 with no output, and so does `git grep
> 'datasets/mlx' -- ':(exclude)docs/labbook' ':(exclude)scripts/model-factory/labbook'`
> on this branch. **Both qualifiers are load-bearing.**"*

The consolidation rewrote that passage to apply the book's new one-line rule
("exclude this directory") and deleted the qualifier as it went — correctly
describing the repository *after* the consolidation, and incorrectly describing
the revision it still cited. The question the entry means to ask is *does
anything in the factory reference this path*, and only a form matched to its
revision asks it. Can the split be recovered from the artifacts alone, so the
run is reproducible?

## Method

1. Confirm the split is a partition of the corpus (byte totals, then line
   multisets).
2. Locate each valid line's index in the corpus; inspect the index pattern.
3. Probe candidate RNG constructions against that index set.
4. Reconstruct both files and compare sha256.

## Result

**It is a partition, exactly.**

| file | lines | bytes | sha256 |
| --- | ---: | ---: | --- |
| `datasets/sft-train-2026-09-05.jsonl` | 2,363 | 16,142,664 | `9552ac13e49351a9d9869f089cc5bfe804d17864db047f7fcbec912188dd25b5` |
| `datasets/mlx/train.jsonl` | 2,245 | 15,341,147 | `4aa180a204d61e2f87f0ddcbfab70fb50067452d071751294079701c03c00adb` |
| `datasets/mlx/valid.jsonl` | 118 | 801,517 | `23a87babdcf8ecb1c9a7bc1969d47af0c8e5e0134ed05ba8ebbd1234f60f9ff5` |

15,341,147 + 801,517 = 16,142,664 — byte-exact, no line rewritten. Line
multisets agree (`sorted(train+valid) == sorted(full)` → True). Neither split
preserves the corpus's line order, which ruled out head/tail and stride
splits.

**The construction is recovered.** The valid index set equals the first 118
entries of a seeded shuffle of `range(2363)`, and the seed is 17 — the same
`--seed 17` the training command uses (`launch-train.sh:17`):

```python
import random
full = open('datasets/sft-train-2026-09-05.jsonl').read().splitlines()
r = random.Random(17); ii = list(range(len(full))); r.shuffle(ii)
valid = [full[i] for i in ii[:118]]
train = [full[i] for i in ii[118:]]
```

Reconstructed sha256: valid `23a87bab…`, train `4aa180a2…` — **byte-identical
to both artifacts**, including line order. The split is `random.Random(17)`,
shuffle, first 118 → valid, remainder → train, emitted in shuffled order.

Split fraction: 118/2363 = 4.9937% — a 5% holdout, rounded down.

## What remains unsourced

The *command* that produced `datasets/mlx/` is **UNSOURCED**. Its behavior is
now fully recovered and reproducible, but nothing in the repo records who ran
it or when, and a future rebuild would depend on someone reading this entry.
The artifact that would settle it: a committed `split_dataset.py` (or an
equivalent step in a build script) that takes the corpus path, the fraction
and the seed as arguments and writes `datasets/mlx/`. Until then the split is
recoverable-by-archaeology, not reproducible-by-command — which is exactly
the state E006 rescued the corpus itself out of.

Consequence of *what* the 118 rows are, rather than how they were chosen, is
O001.

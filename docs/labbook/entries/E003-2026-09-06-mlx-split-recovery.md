# E003 — Recovering the unscripted train/valid split from its artifacts

- **Kind:** EXPERIMENT
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## Question

The live fine-tune reads `--data datasets/mlx`
(`models/candidates/fin-foreman-e4b-mlx/launch-train.sh:14`), a directory
containing `train.jsonl` and `valid.jsonl`. **No committed script produces
it.** `grep -rn 'datasets/mlx' --include='*.py' --include='*.sh'
--include='*.md' --include='*.yaml' --include='*.json'` over the repo returns
nothing outside `datasets/` itself. Can the split be recovered from the
artifacts alone, so the run is reproducible?

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
`--seed 17` the training command uses (`launch-train.sh:16`):

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
the state E001 rescued the corpus itself out of.

Consequence of *what* the 118 rows are, rather than how they were chosen, is
[O002](O002-2026-09-06-validation-split-in-distribution.md).

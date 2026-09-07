# Lab Book Index

Every entry. **Maintained by hand** — nothing generates this file, so an entry
that is not listed here is effectively lost. Add the row in the same commit as
the entry.

Conventions, entry template and the correction procedure: [README.md](README.md).

Before committing an entry, run the citation checker — it fails on any citation
that names a branch instead of a revision, which is the defect this book shipped
in four consecutive rounds (O010):

```sh
python3 scripts/model-factory/labbook/check_citations.py --verify-lines
```

Every entry so far was written on 2026-09-06, so "oldest first" does not order
them; the table is grouped by kind and runs in id order within each kind. When
dates start to differ, sort by date and keep the id column monotonic per kind.

There is **one** lab book. A second, independently-numbered book briefly existed
at `docs/labbook/` with thirteen colliding ids; it was consolidated into this one
and deleted on 2026-09-06. The id map and the account are in
[O009](year-1/O009-2026-09-06-two-books-one-factory.md), and the README's
"Provenance of this directory" carries the short version. A bare id in this book
is unambiguous.

## Year 1 — opened 2026-09-06

| id | date | kind | title | status |
| --- | --- | --- | --- | --- |
| [P001](year-1/P001-2026-09-06-promotion-protocol.md) | 2026-09-06 | PROCESS | The promotion protocol — what it takes for a candidate to become the champion | active |
| [P002](year-1/P002-2026-09-06-leakage-rule.md) | 2026-09-06 | PROCESS | The leakage rule — the eval corpus is held out, and how that is checked | active |
| [P003](year-1/P003-2026-09-06-apple-silicon-training-contract.md) | 2026-09-06 | PROCESS | Local training on Apple Silicon — the serialization rule and the memory contract | active |
| [P004](year-1/P004-2026-09-06-gate-the-checkpoints.md) | 2026-09-06 | PROCESS | Gate several checkpoints, not just the last one | proposed |
| [P005](year-1/P005-2026-09-06-reproduce-a-dataset.md) | 2026-09-06 | PROCESS | Reproduce a dataset bit-for-bit before you trust a number about it | active |
| [E001](year-1/E001-2026-09-06-router-prompt-rounds.md) | 2026-09-06 | EXPERIMENT | Router prompt iteration, rounds 0-4 — 36/51 to 49/51, and one revision reverted | closed |
| [E002](year-1/E002-2026-09-06-base-model-selection.md) | 2026-09-06 | EXPERIMENT | Base-model selection — gemma-3-4b chosen, smoke-trained, and dropped for gemma-4-E4B | closed |
| [E003](year-1/E003-2026-09-06-memory-ceiling-grad-checkpoint.md) | 2026-09-06 | EXPERIMENT | Fitting a LoRA run under a 24 GB Metal ceiling — batch 2 OOMs, grad-checkpoint + batch 1 holds at 14.978 GB | closed |
| [E004](year-1/E004-2026-09-06-run1-foreman-e4b-lora.md) | 2026-09-06 | EXPERIMENT | Run 1 — fin-foreman-e4b-mlx, a 2-epoch LoRA on gemma-4 E4B | closed (E009) |
| [E005](year-1/E005-2026-09-06-baselines-reproduce.md) | 2026-09-06 | EXPERIMENT | Both deterministic baselines reproduce their recorded scores exactly, a day later | closed |
| [E006](year-1/E006-2026-09-06-corpus-bit-exact-reproduction.md) | 2026-09-06 | EXPERIMENT | The training corpus reproduces bit-for-bit, and names the commit it was built at | closed |
| [E007](year-1/E007-2026-09-06-corpus-census.md) | 2026-09-06 | EXPERIMENT | Corpus census: where 4,527 generated candidates become 2,363 training rows | closed |
| [E008](year-1/E008-2026-09-06-mlx-split-recovery.md) | 2026-09-06 | EXPERIMENT | Recovering the unscripted train/valid split from its artifacts | closed |
| [E009](year-1/E009-2026-09-06-run1-gate-sweep.md) | 2026-09-06 | EXPERIMENT | Run 1's gate sweep — four checkpoints, a re-recorded champion, and no promotion | closed |
| [O001](year-1/O001-2026-09-06-zero-loss-flat-validation.md) | 2026-09-06 | OBSERVATION | Train loss reaches 0.000 while validation sits flat — what that does and does not imply | standing |
| [O002](year-1/O002-2026-09-06-stale-champion.md) | 2026-09-06 | OBSERVATION | The recorded champion is a round-0 number — the gate would promote a candidate 12 points worse than the base model | standing |
| [O003](year-1/O003-2026-09-06-three-prompts-no-parity.md) | 2026-09-06 | OBSERVATION | Four router prompt texts exist across two branches, only one ever scored, with no parity test | standing |
| [O004](year-1/O004-2026-09-06-late-run-loss-excursion.md) | 2026-09-06 | OBSERVATION | A late-epoch-2 training-loss excursion, with no per-example log to explain it | standing |
| [O005](year-1/O005-2026-09-06-no-provenance-in-verdicts.md) | 2026-09-06 | OBSERVATION | Nothing in the factory records provenance — no prompt hash, no corpus commit, no dataset manifest | standing |
| [O006](year-1/O006-2026-09-06-ledger-trained-not-gated.md) | 2026-09-06 | OBSERVATION | A third of the corpus teaches goals-ledger, which nothing gates | standing |
| [O007](year-1/O007-2026-09-06-labels-are-baseline-output.md) | 2026-09-06 | OBSERVATION | Every routing and ledger label is deterministic-baseline output, and the filter meant to validate them rejected nothing | standing |
| [O008](year-1/O008-2026-09-06-append-only-broken-on-day-one.md) | 2026-09-06 | OBSERVATION | The append-only rule was broken on day one, by the audit passes that were fixing the book | standing |
| [O009](year-1/O009-2026-09-06-two-books-one-factory.md) | 2026-09-06 | OBSERVATION | Two lab books existed for one factory — the consolidation, and the id map it needed | standing |
| [O010](year-1/O010-2026-09-06-fixing-a-citation-is-a-citation.md) | 2026-09-06 | OBSERVATION | Three rounds of correcting provenance claims, three new provenance errors — a fix to a citation is itself a citation | standing |
| [O011](year-1/O011-2026-09-06-ten-of-fiftyone-never-queried.md) | 2026-09-06 | OBSERVATION | Three checkpoints scored an identical 10/51 — the model was never queried at all | standing |
| [O012](year-1/O012-2026-09-06-a-trend-called-on-three-points.md) | 2026-09-06 | OBSERVATION | A monotonic decline called on three points, contradicted by the fourth — and the caller had predicted the shape | standing |
| [O013](year-1/O013-2026-09-06-nine-tips-one-defect.md) | 2026-09-06 | OBSERVATION | Nine unpinned branch-tip claims, one defect — and why the checker written to catch it did not | standing |
| [H001](year-1/H001-2026-09-06-bits-per-example.md) | 2026-09-06 | HYPOTHESIS | Bits per example is the right currency for a training curriculum | untested |
| [H002](year-1/H002-2026-09-06-high-information-subset.md) | 2026-09-06 | HYPOTHESIS | A small high-information subset reaches the same gate score in materially fewer iterations | untested |
| [H003](year-1/H003-2026-09-06-best-checkpoint-not-last.md) | 2026-09-06 | HYPOTHESIS | The best checkpoint is not the last one | untested |
| [H004](year-1/H004-2026-09-06-baseline-labels-cap-hard-tier.md) | 2026-09-06 | HYPOTHESIS | Distilling the deterministic baseline will pull the hard tier down toward it | untested |

**31 entries.** The row count of the table above equals the file count of
`year-1/`; check it with
`ls scripts/model-factory/labbook/year-1/*.md | wc -l`.

## What closes next

| entry | closed by |
| --- | --- |
| ~~E004 (open)~~ | **closed 2026-09-06 by E009** — the sweep ran; nothing promoted |
| ~~H004~~ | **settled 2026-09-06 by E009**: outcome A, hard 21/18/16/19 against the base's 24 |
| H003 | **still open after E009.** Four un-repeated points cannot resolve a 2-scenario difference (O012); it needs a repeat, not another sweep |
| H001 | a `score_bits.py` pass (`d4901d4` on `bits-curriculum`) over `datasets/mlx/train.jsonl` under base and adapter |
| H002 | the three-arm experiment (selected / random control / full) in that entry |
| ~~P004 (proposed → active)~~ | **its first actual run was 2026-09-06 14:38-14:48 (E009)** |
| P005 (standing gap) | a build that emits `datasets/<id>/manifest.json` — which also closes O005's smallest fix and O003's recurrence guard |
| E008 (open remainder) | a committed `split_dataset.py`, which would make the split reproducible-by-command instead of recoverable-by-archaeology |

## Next free ids

`E010` · `O014` · `H005` · `P006`

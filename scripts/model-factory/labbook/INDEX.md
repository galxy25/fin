# Lab Book Index

Every entry, oldest first. **Maintained by hand** — nothing generates this
file, so an entry that is not listed here is effectively lost. Add the row in
the same commit as the entry.

Conventions, entry template and the correction procedure: [README.md](README.md).

**Ids in this table are ids of *this* book.** A second lab book with an
independently-numbered sequence sits at `docs/labbook/` on this branch and
thirteen of its ids collide with these; see the README's "Provenance of this
directory". Cite across books by path.

## Year 1 — opened 2026-09-06

| id | date | kind | title | status |
| --- | --- | --- | --- | --- |
| [P001](year-1/P001-2026-09-06-promotion-protocol.md) | 2026-09-06 | PROCESS | The promotion protocol — what it takes for a candidate to become the champion | active |
| [P002](year-1/P002-2026-09-06-leakage-rule.md) | 2026-09-06 | PROCESS | The leakage rule — the eval corpus is held out, and how that is checked | active |
| [P003](year-1/P003-2026-09-06-apple-silicon-training-contract.md) | 2026-09-06 | PROCESS | Local training on Apple Silicon — the serialization rule and the memory contract | active |
| [P004](year-1/P004-2026-09-06-gate-the-checkpoints.md) | 2026-09-06 | PROCESS | Gate several checkpoints, not just the last one | proposed |
| [E001](year-1/E001-2026-09-06-router-prompt-rounds.md) | 2026-09-06 | EXPERIMENT | Router prompt iteration, rounds 0-4 — 36/51 to 49/51, and one revision reverted | closed |
| [E002](year-1/E002-2026-09-06-base-model-selection.md) | 2026-09-06 | EXPERIMENT | Base-model selection — gemma-3-4b chosen, smoke-trained, and dropped for gemma-4-E4B | closed |
| [E003](year-1/E003-2026-09-06-memory-ceiling-grad-checkpoint.md) | 2026-09-06 | EXPERIMENT | Fitting a LoRA run under a 24 GB Metal ceiling — batch 2 OOMs, grad-checkpoint + batch 1 holds at 14.978 GB | closed |
| [E004](year-1/E004-2026-09-06-run1-foreman-e4b-lora.md) | 2026-09-06 | EXPERIMENT | Run 1 — fin-foreman-e4b-mlx, a 2-epoch LoRA on gemma-4 E4B | **open** |
| [E005](year-1/E005-2026-09-06-baselines-reproduce.md) | 2026-09-06 | EXPERIMENT | Both deterministic baselines reproduce their recorded scores exactly, a day later | closed |
| [O001](year-1/O001-2026-09-06-zero-loss-flat-validation.md) | 2026-09-06 | OBSERVATION | Train loss reaches 0.000 while validation sits flat — what that does and does not imply | standing |
| [O002](year-1/O002-2026-09-06-stale-champion.md) | 2026-09-06 | OBSERVATION | The recorded champion is a round-0 number — the gate would promote a candidate 12 points worse than the base model | standing |
| [O003](year-1/O003-2026-09-06-three-prompts-no-parity.md) | 2026-09-06 | OBSERVATION | Four router prompt texts exist across two branches, only one ever scored, with no parity test | standing |
| [O004](year-1/O004-2026-09-06-late-run-loss-excursion.md) | 2026-09-06 | OBSERVATION | A late-epoch-2 training-loss excursion, with no per-example log to explain it | standing |
| [O005](year-1/O005-2026-09-06-no-provenance-in-verdicts.md) | 2026-09-06 | OBSERVATION | Nothing in the factory records provenance — no prompt hash, no corpus commit, no dataset manifest | standing |
| [O006](year-1/O006-2026-09-06-ledger-trained-not-gated.md) | 2026-09-06 | OBSERVATION | A third of the corpus teaches goals-ledger, which nothing gates | standing |
| [O007](year-1/O007-2026-09-06-labels-are-baseline-output.md) | 2026-09-06 | OBSERVATION | Every routing and ledger label is deterministic-baseline output, and the filter meant to validate them rejected nothing | standing |
| [H001](year-1/H001-2026-09-06-bits-per-example.md) | 2026-09-06 | HYPOTHESIS | Bits per example is the right currency for a training curriculum | untested |
| [H002](year-1/H002-2026-09-06-high-information-subset.md) | 2026-09-06 | HYPOTHESIS | A small high-information subset reaches the same gate score in materially fewer iterations | untested |
| [H003](year-1/H003-2026-09-06-best-checkpoint-not-last.md) | 2026-09-06 | HYPOTHESIS | The best checkpoint is not the last one | untested |
| [H004](year-1/H004-2026-09-06-baseline-labels-cap-hard-tier.md) | 2026-09-06 | HYPOTHESIS | Distilling the deterministic baseline will pull the hard tier down toward it | untested |

## What closes next

| entry | closed by |
| --- | --- |
| E004 (open) | the first checkpoint sweep, P004 |
| H003, H004 | the same sweep, read **per tier** |
| H001 | a `score_bits.py` pass (`d4901d4` on `bits-curriculum`) over `datasets/mlx/train.jsonl` under base and adapter |
| H002 | the three-arm experiment (selected / random control / full) in that entry |
| P004 (proposed → active) | its first actual run |

## Next free ids

`E006` · `O008` · `H005` · `P005`

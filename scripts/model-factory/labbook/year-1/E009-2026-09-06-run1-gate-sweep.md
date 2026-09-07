---
id: E009
date: 2026-09-06
occurred: 2026-09-05 20:15:29 — 2026-09-06 14:48
kind: EXPERIMENT
title: Run 1's gate sweep — four checkpoints, a re-recorded champion, and no promotion
status: closed
tags: [training, gate, promotion, run-1, mlx, lora]
sources:
  - 7fb54b5 — "Gate run 1: champion re-recorded at 49/51, no candidate promotes" (2026-09-06 14:49:35)
  - 2d5bb29:scripts/model-factory/gate_sweep.sh — blob `5c2c582f…`, 157 lines; :61-70 the prompt guard, :78-88 `probe()`, :124 the default iters, :143-144 the corrected model id
  - 2d5bb29:scripts/model-factory/evals-champions.json — blob `6dcc4a63…`, the re-recorded champion
  - 2d5bb29:scripts/model-factory/eval_gate.py:110-112 — the promotion rule this verdict is read against
  - "local-artifact: models/gate-sweep/results.tsv — the four score rows, quoted verbatim below"
  - "local-artifact: models/gate-sweep/champion.txt — 'core (gates): 25/26   hard (benchmark): 24/25' / 'tmux-routing evals: 49/51 passed (96%)'"
  - "local-artifact: models/gate-sweep/provenance.txt — '# router.md: c511bab2bf99495603e199fbfe82a6b9f5c9dab5' and '# evals_root: /Users/deepspacenine/forges/levi/fin-wt-gate'"
  - "local-artifact: models/gate-sweep/eval-{1000,2250,3500,final}.log — the per-scenario miss lists quoted below"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/train.log:1 — '=== TRAIN START 2026-09-05 20:15:29 pid 18405 base=mlx-community/gemma-4-E4B-it-qat-4bit ==='; :223 — 'Iter 4490: Val loss 0.003, Val took 174.683s'; 225 lines total"
related: [E004, E005, O001, O002, O003, O004, O011, O012, P001, P004, H002, H003, H004]
corrects: []
superseded-by: null
---

## Question

Does any checkpoint of run 1 — the first fine-tune the factory ever produced —
promote over the untuned base under P001's rule?

The run itself is E004, which was left **open** with this experiment named as
the event that closes it. E004 is the record of the training; this is the
record of the measurement, and E004 now carries `superseded-by: E009`.

## Method

### The training run being scored

Launched detached 2026-09-05 20:15:29 PDT, pid 18405
(`train.log:1`); finished 2026-09-06 14:28:36, **18 h 13 m 07 s** =
65,587 s wall clock, **14.607 s/iteration** across 4,490 iterations.

| flag | value |
| --- | --- |
| base | `mlx-community/gemma-4-E4B-it-qat-4bit` |
| `--fine-tune-type lora --num-layers 16` | LoRA on 16 layers, rank at the mlx-lm default |
| `--batch-size 1 --grad-accumulation-steps 2` | effective batch 2; **2,245 optimizer steps**, not 4,490 (E004 reads this off the installed trainer) |
| `--grad-checkpoint --max-seq-length 3072` | the memory contract from E003 / P003 |
| `--mask-prompt` | loss on answer tokens only |
| `--iters 4490` | exactly 2.00 epochs over 2,245 train rows |
| `--learning-rate 1e-4 --seed 17` | — |
| peak Metal | **14.978 GB**, flat from iteration 375 (E003) |

E004 projected a finish of **14:25:17-14:25:58** from checkpoint mtimes. The
actual finish was **14:28:36** — 2 m 38 s to 3 m 19 s late, an error of 0.3%
over 18.2 hours. The projection was arithmetic and it held; the earlier
hand-rounded "18.2 h" that E004 corrected itself for was not.

**Throughput: median 0.071 it/s over 155 clean reports.** A peer session's
leaked CPU load contaminated **11:56-12:16**, and wall-clock inside that window
is not usable for any pace claim. The existing entry on that contamination is
the one to read before quoting a rate from this run.

### The sweep

`scripts/model-factory/gate_sweep.sh` at `7fb54b5` (blob `5c2c582f…`, 157
lines), run from the worktree `/Users/deepspacenine/forges/levi/fin-wt-gate`:

```sh
scripts/model-factory/gate_sweep.sh 1000 2250 3500 final
```

Per checkpoint: stage → `mlx_lm fuse` → serve on `mlx_lm.server` → probe →
`run_evals.py --router router_llm.py` → record → delete the fused model. One
model in memory at a time (P003). This is **P004's first actual run**; P004 was
`proposed, never yet run` until 2026-09-06 14:38 and now carries
`superseded-by: E009`.

Three provenance facts the script wrote down itself, which is the point of it
existing (O005 is the entry about the factory not doing this):

- `# router.md: c511bab2bf99495603e199fbfe82a6b9f5c9dab5` — the prompt blob
  every score below was produced under, and the same blob the training corpus
  was built from (`gate_sweep.sh:61-70` refuses to run otherwise, `exit 78`).
- `# evals_root: /Users/deepspacenine/forges/levi/fin-wt-gate` — a `main`-based
  worktree, deliberately not the primary checkout, which sits at `78e6c36`
  (the `imac-site` tip, read at 2026-09-06 20:52:57 PDT) and carries a
  different `router.md`.
- `# base: mlx-community/gemma-4-E4B-it-qat-4bit`.

### The champion was re-recorded first

`evals-champions.json` held **36/51** — one commit ever (`a823271`), measured
under the **round-0** prompt. O002 is the standing entry on it. Re-run under the
prompt actually shipped (blob `c511bab2…`), the same untuned
`google/gemma-4-e4b` scores **49/51**, reproducing `RESULTS.md`'s round-3 result
including both named misses (`c01` core, `h08` hard):

```
core (gates): 25/26   hard (benchmark): 24/25
tmux-routing evals: 49/51 passed (96%)
```

Every candidate compared against the stored number would have been flattered by
**thirteen points**. The record was rewritten at `7fb54b5`, keeping the old
scores under a `supersedes` key rather than deleting them.

**Note what that re-record does to the gate: the champion does not itself pass
the core gate.** Promotion demands 26/26 core *and* strictly beating 49, so the
bar is now strictly harder than the incumbent. That is not a bug in the rule —
`>` and not `>=`, core as a gate and hard as a benchmark (P001) — but it is the
first time the two conditions have pointed in different directions, and it is
worth stating before it is discovered by accident.

## Result

`models/gate-sweep/results.tsv`, verbatim:

```
1000	  core (gates): 22/26   hard (benchmark): 21/25
2250	  core (gates): 26/26   hard (benchmark): 18/25
3500	  core (gates): 26/26   hard (benchmark): 16/25
final	  core (gates): 26/26   hard (benchmark): 19/25
```

| model | core | hard | total | core gate | beats 49? | promoted |
| --- | ---: | ---: | ---: | :---: | :---: | :---: |
| champion `google/gemma-4-e4b` untuned | 25/26 | **24/25** | **49/51** | ✗ | — | incumbent |
| ckpt 1000 | 22/26 | 21/25 | 43/51 | ✗ | ✗ | no |
| ckpt 2250 | **26/26** | 18/25 | 44/51 | ✓ | ✗ | no |
| ckpt 3500 | **26/26** | 16/25 | 42/51 | ✓ | ✗ | no |
| ckpt 4490 final | **26/26** | 19/25 | 45/51 | ✓ | ✗ | no |

### VERDICT: no promotion

`eval_gate.py:110-112` requires `core_gate and beats_champion`. Every checkpoint
from 2250 on satisfies the first and none satisfies the second: the best
candidate total is 45 against the champion's 49, four short.

### Which scenarios, not just how many

Every miss in the candidate column is in the **hard** tier from checkpoint 2250
onward. From the eval logs:

| checkpoint | core misses | hard misses |
| --- | --- | --- |
| 1000 | `r04` `r05` `r09` `f04` | `h03` `h08` `h09` `h11` |
| 2250 | — | `h01` `h03` `h07` `h08` `h09` `h10` `h11` |
| 3500 | — | `h01` `h02` `h03` `h07` `h08` `h09` `h10` `h11` `h14` |
| final | — | `h02` `h03` `h07` `h08` `h09` `h11` |

`h03`, `h08`, `h09` and `h11` miss at **every** checkpoint. Those are the
paraphrase-with-no-vocabulary-overlap and multi-clause-misdirection shapes that
E005 measured the deterministic baseline at 3/25 on — and the corpus's labels
are that baseline's output (O007). The champion, which was never trained on
them, gets all four right.

### The loss trajectory says nothing about any of this

Validation loss, every `Val loss` line in `train.log`:

| iter | 1 | 500 | 1000 | 1500 | 2000 | 2500 | 3000 | 3500 | 4000 | 4490 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| val loss (nats) | **2.463** | 0.074 | 0.013 | 0.028 | 0.005 | 0.013 | 0.009 | 0.012 | 0.024 | **0.003** |

Train loss reached **0.000** by roughly iteration 2900 and the final validation
is the lowest of the run. **The checkpoint with the best validation loss — the
last one, 0.003 — scores 45/51, and the checkpoint with the worst gate hard tier
(3500, 16/25) has a validation loss of 0.012, four thousandths of a nat away.**
Validation loss on this corpus orders the checkpoints in a way that has no
visible relationship to the number that decides promotion. O001 said the loss
curve cannot separate memorization from generalization on an in-distribution
split; this is the same claim with a gate score attached.

## What this settles, and what it does not

### H004 — supported, on both halves

H004 predicted that distilling a 3/25 labeler pulls the candidate's hard tier
down toward it, and partitioned the outcomes with **outcome A at ≤ 21/25**.
Every checkpoint lands in A: 21, 18, 16, 19 against the base's 24. The drop at
the final checkpoint is **5 hard scenarios**, well past the 3-scenario threshold
H004 set for itself before the fact.

The other half of H004 is confirmed too, and it is the more interesting half:
**core went the other way.** The base misses `c01`; the labeler is 26/26 on
core; every candidate from 2250 is 26/26. The fine-tune bought exactly what the
labels contained and lost exactly what they did not. H004 now carries
`superseded-by: E009`.

### H003 — neither supported nor refuted; its overall-score form is refuted

H003 predicted `argmax_i hard(i) < 4490`. Literally, that holds: the maximum
hard score is at checkpoint 1000 (21), not at 4490 (19). But H003 set its own
power threshold in advance — *"only a difference of ≥3 hard scenarios between
the best and the final checkpoint should count as support"* — and the difference
is **2**. By its own rule this is not support.

Its three overall-score sub-predictions are refuted outright:

| H003 predicted | measured | |
| --- | --- | --- |
| overall peaks at or before 2,250 | overall peaks at **4490** (45) | refuted |
| best-to-final spread ≥3 of 51 | the best **is** the final; spread **0** | refuted |
| core moves by at most one scenario | core moves by **four** (22 → 26) | refuted |

And its stated refutation clause — *"refuted if the final checkpoint takes the
maximum hard score, or if hard is flat within noise"* — is not met either: 19 is
not the maximum, and 16-21 is not flat. So the honest verdict is that **one
sweep of four checkpoints cannot settle it.** H003 keeps `status: untested` and
carries `superseded-by: E009` so the two are read together.

The failure mode this run created while it was being read — calling a
monotonic decline off three points, 21 → 18 → 16, and being contradicted by the
fourth — is O012.

### O002 — closed by the re-record

The stale champion is no longer stale. O002's warning was acted on before any
candidate was scored, which is the only reason this sweep produced a usable
verdict rather than a false promotion. O002 carries `superseded-by: E009`.

## What this does not show

- **One run, one corpus, one base, one prompt revision, one seed.** There is no
  second arm. Nothing here separates "the recipe is wrong" from "the corpus is
  wrong" from "this seed was unlucky", and the factory has never run the same
  configuration twice.
- **The hard-tier differences are inside sampling noise.** 25 scenarios, one
  scenario is 4 points, every score is a single un-repeated run and there is no
  variance estimate anywhere in this book. A ±3 swing is plausible noise
  (H003's own threshold, H004's own threshold, and now O012).
- **Nothing here isolates a cause.** The corpus is the *suspected* bottleneck
  and the evidence is circumstantial: the misses cluster exactly where the
  labeler is weak. That is consistent with distillation of a weak policy and
  also consistent with the base model's prompt-following being disturbed by any
  fine-tune at all. The experiment that separates them has not been run.
- **The serving surface differs between the two columns.** Candidates were fused
  to fp16 and served by `mlx_lm.server`; the champion was served by LM Studio
  from a 4-bit quantization. P001's last bullet names this and the gate cannot
  see it. A four-point gap is larger than that confound plausibly explains, but
  the confound is real and unmeasured.
- **Decoding parameters are UNSOURCED.** Neither `results.tsv` nor
  `provenance.txt` records temperature, top-p or seed for the scoring requests.
  *Settled by:* `run_evals.py` writing its sampling parameters into the eval log.
- **Four checkpoints of eighteen.** Seventeen numbered adapters survive on
  disk (`0000250`…`0004250`, 250-iteration granularity) plus the rolling
  `adapters.safetensors` that the sweep scores as `final`;
  1000/2250/3500/final is what was swept. The 250-750 window — where H002 says
  the corpus may already be saturated — was not looked at.
- **This says nothing about `goals-ledger`,** which is a third of the training
  corpus and is not in the gate at all (O006).

## The prompt has already moved out from under this result

`2d5bb29:scripts/model-factory/gate_sweep.sh:61-70` refuses to run unless the
checkout's own `router.md` blob equals the training prompt blob `c511bab2…`:

```sh
PROMPT_SHA=$(git -C "$EVALS_ROOT" rev-parse HEAD:evals/tmux-routing/prompts/router.md ...)
TRAINING_PROMPT_SHA=${FIN_TRAINING_PROMPT_SHA:-c511bab2bf99495603e199fbfe82a6b9f5c9dab5}
```

Resolved at **2026-09-06 20:52:57 PDT**:

| revision | `router.md` blob |
| --- | --- |
| `704ab09`, `99ed9d9`, `7fb54b5`, `3ea4a65` | `c511bab2bf99495603e199fbfe82a6b9f5c9dab5` — what this sweep scored |
| `78e6c36` (`imac-site`, read at 2026-09-06 20:52:57) | `936c93e8a6e6f9ad2a45cf92a7a2f12cccaedbe2` |
| `2d5bb29` (`main`, read at 2026-09-06 20:52:57) | `936c93e8a6e6f9ad2a45cf92a7a2f12cccaedbe2` |

`2d5bb29` is `Merge imac-site`, 20:27:23 — four hours after this sweep ran. **So
`gate_sweep.sh` run from the tip today would exit 78 and refuse**, correctly:
the candidate would be presented a prompt it never trained on. Any re-run of
this experiment must either check out `3ea4a65` or rebuild the corpus against
`936c93e8…` — and the second of those is a different experiment, not a re-run
of this one.

That is the guard doing its job on the first day it existed, and it is worth
noticing that it caught a change nobody in this line of work made.

## So what — this is data point one of a series

Levi, 2026-09-06: *"this was fine tune one of many more to come, the goal of the
model factory is cheaper and faster and better foreman models the more I use the
app and signals are gathered."*

A non-promoting run is a normal data point. The factory is judged on the slope,
not on run 1, and what run 1 bought is a calibration nothing else could have
given: **label quality propagates into behaviour almost completely.** Two epochs
on a 26/26-core, 3/25-hard labeler produced a model that is 26/26 on core and
16-21 on hard. That is the single most useful number available before corpus 2
is built, and it is the number H004 asked for.

The corpus is the suspected bottleneck: synthesized template data bought the
in-distribution core tier and lost the withheld adversarial tier. The next run
should change the corpus, not the recipe — and should change one thing, so the
next entry can say which.

## Open

- **No `verdict.json` was written.** The sweep records scores in `results.tsv`
  and the verdict was read by hand against `eval_gate.py`'s rule rather than by
  running `eval_gate.py`. The two agree, but the machine-readable artifact P001
  step 2 specifies does not exist for this run. *Settled by:* running the gate
  on the winning checkpoint, even when the answer is "no".
- **The eighteen adapter states are still on disk and the fused models are not.** Each
  fused model was deleted after scoring, so re-scoring any
  checkpoint means re-fusing it (`2d5bb29:scripts/model-factory/gate_sweep.sh:151`).
  Reproducible, not cheap.
- **`models/gate-sweep/` is gitignored** (`062f896`), so every number in the
  Result section above lives on one disk. They are quoted verbatim here for that
  reason.

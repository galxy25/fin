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
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/{adapters.safetensors,train.log} mtimes — 14:28:30 and 14:28:31, the only artifacts that carry the run's finish time (`stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S'`, read 2026-09-06 21:31 PDT)"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/0000250…0004250_adapters.safetensors mtimes — the eighteen timestamped pace windows tabulated below"
  - "measured 2026-09-06 21:29 PDT in this worktree: `python3 evals/tmux-routing/run_evals.py` → 29/51, core 26/26, hard 3/25, the labeler's hard passes being exactly h14, h22, h24"
  - "measured 2026-09-06 21:29 PDT: `python3 -c` over evals/tmux-routing/scenarios.json → 51 scenarios, 25 hard, 26 core"
related: [E004, E005, O001, O002, O003, O004, O011, O012, P001, P004, H002, H003, H004]
corrects: [E004]
superseded-by: null
---

## Corrected in place, 2026-09-06 21:31 PDT

This entry, O011, O012 and O013 were committed in `d2f40b0` and audited the same
evening. **Eleven findings came back** — seven against this entry, one each
against O011, O012, `INDEX.md` and the README, and one against
`check_citations.py`. Ten are corrected in place. The eleventh, that
`BRANCH-TIP` and `BRANCH-SUBJECT` are closed word lists a one-word substitution
walks through, got a partial fix (both lists widened, a fixture added) **and**
an honest statement of the residual limit in O013, because widening a closed
list does not close it.

The correction is **in place** rather than by a later entry, under the README's
draft-phase rule, because the round had never left this machine —
`git rev-parse --short origin/main` → `7fb54b5` and
`git rev-list --count origin/main..main` → `20`, read 2026-09-06 21:31:03 PDT.
The draft phase's price is that a correction is **never silent**: every sentence
replaced below is quoted where it stood, with the command that establishes the
number that replaced it. Two of the findings were against conclusions rather
than numbers, and both conclusions are weaker in this revision than in
`d2f40b0`; the sections that carry them say so explicitly.

Nothing here is a claim that the audit found everything. It is the fourth
consecutive round in which a review of this book found defects the previous
round's controls passed, and the first in which the defects included **a
conclusion refuted by the numbers in its own sentence.** A number that is wrong
gets corrected; a conclusion whose evidence is corrected has to be re-derived,
and two of them were.

## Question

Does any checkpoint of run 1 — the first fine-tune the factory ever produced —
promote over the untuned base under P001's rule?

The run itself is E004, which was left **open** with this experiment named as
the event that closes it. E004 is the record of the training; this is the
record of the measurement, and E004 now carries `superseded-by: E009`.

## Method

### The training run being scored

Launched detached 2026-09-05 20:15:29 PDT, pid 18405
(`train.log:1`); finished 2026-09-06 **14:28:30**, **18 h 13 m 01 s** =
65,581 s wall clock, **14.606 s/iteration** across 4,490 iterations.

*Corrected.* This entry as committed at `d2f40b0` said *"finished 2026-09-06
14:28:36, 18 h 13 m 07 s = 65,587 s wall clock, 14.607 s/iteration"*, and
`E004:33` still carries the same 14:28:36. **Nothing on disk records 14:28:36.**
`train.log` has no end marker — its last line is `Saved final weights to
models/candidates/fin-foreman-e4b-mlx/adapters.safetensors.` — so the finish is
whatever the artifacts say it is, and there are exactly two:

```sh
$ stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' adapters.safetensors train.log
2026-09-06 14:28:30 models/candidates/fin-foreman-e4b-mlx/adapters.safetensors
2026-09-06 14:28:31 models/candidates/fin-foreman-e4b-mlx/train.log
```

The weights land at 14:28:30 and the log's last write is one second later. The
figure above is the weights' mtime, which is the event "the run finished"; the
six seconds between it and the published 14:28:36 came from nowhere. Every
duration and rate in this entry is re-derived from 14:28:30. `E004:33` is
corrected by this paragraph and E009 now carries `corrects: [E004]`.

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
actual finish was **14:28:30** — 2 m 32 s to 3 m 13 s late, an error of
**0.23-0.29%** over 18.2 hours. The projection was arithmetic and it held; the
earlier hand-rounded "18.2 h" that E004 corrected itself for was not.

**Throughput: median 0.0705 it/s across all 180 `It/sec` reports in
`train.log`** (`grep -oE 'It/sec [0-9.]+' train.log` → 180 values, min 0.055,
max 0.118), and **0.0685 it/s** as the whole-run average, 4,490 iterations over
65,581 s.

*Corrected.* `d2f40b0` said *"Throughput: median 0.071 it/s over 155 clean
reports"* and pointed at "the existing entry on that contamination". Two things
were wrong with that sentence and both matter more than the number:

1. **There are 180 reports, not 155, and no subset of them can be called
   clean.** `train.log`'s iteration lines carry no timestamps — only
   `Iter N: Train loss …` — so nothing in the artifact can place a report
   inside or outside a wall-clock window. "155 clean reports" was not derivable
   from the file it cited, and the count of excluded reports (25) was never
   derived from anything either.
2. **The entry it pointed at does not exist.** A peer session's leaked CPU load
   was observed at **11:56-12:16** on 2026-09-06 and that observation lives in
   the session that made it, not in this book. It is cited here as what it is:
   **UNSOURCED — a session report with no artifact behind it.** *Settled by:*
   a load sample written to disk beside the run, or nothing.

What the artifacts *can* time is the eighteen checkpoint intervals, because
adapter files have mtimes. 250 iterations each, `it/s` = 250 ÷ Δmtime:

| window | interval | s/250 iters | it/s |
| --- | --- | ---: | ---: |
| 250 → 500 | 21:16:46 → 22:25:17 | 4,111 | **0.0608** — slowest of eighteen |
| 3750 → 4000 | 11:21:20 → 12:26:58 | 3,938 | **0.0635** — second slowest; contains 11:56-12:16 |
| 4250 → 4490 | 13:27:15 → 14:28:30 | 3,675 (240 iters) | 0.0653 |
| … the other fifteen | — | 3,323-3,769 | 0.0663-0.0752 |

The window containing the reported contamination is the second-slowest of the
eighteen. **It is not the slowest**, and the slowest — 250 → 500, the night
before — has no such explanation. So the checkpoint mtimes are consistent with
the contamination and do not isolate it, which is a weaker statement than the
one `d2f40b0` published and the strongest one this run's artifacts support.

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
are that baseline's output (O007). **The champion gets three of those four
right — `h03`, `h09`, `h11` — and misses `h08`, which is the one scenario every
model in the table above misses, tuned or not.**

*Corrected, and this one was load-bearing.* `d2f40b0` said *"The champion, which
was never trained on them, gets all four right."* It does not. **This entry
already said so, above**, under *The champion was re-recorded first*: the
re-record reproduces *"both named misses (`c01` core, `h08` hard)"*. The
contradiction was internal, in one file, and three artifacts agree with the
earlier half:

```sh
$ cat models/gate-sweep/champion.txt
core (gates): 25/26   hard (benchmark): 24/25
tmux-routing evals: 49/51 passed (96%)
$ grep -n 'kept' evals/tmux-routing/RESULTS.md
45:| 3 (route⊆registry, start-object test) — **kept** | **49/51** | **25/26** | **24/25** | c01 h08 |
```

and `evals-champions.json`'s note — *"Residual misses c01 (core) and h08 (hard)
reproduce exactly as RESULTS.md records"* — says it a third time. 49/51 is two
misses, and one of them is `h08`. The section's own table was never wrong; the
sentence under it contradicted the entry it sits in.

### Does the miss set actually point at the labeler?

That sentence was the whole evidential basis for "the misses cluster exactly
where the labeler is weak" (below, under *What this does not show*), so
correcting it means re-deriving what the clustering is worth. Measured, not
asserted — the labeler's hard tier re-run in this worktree at 2026-09-06 21:29
PDT:

```sh
$ python3 evals/tmux-routing/run_evals.py
tmux-routing evals: 29/51 passed (57%)  [offline]
  core (gates): 26/26   hard (benchmark): 3/25
```

The three hard scenarios the labeler gets right are **`h14`, `h22`, `h24`**
(the miss list is the other 22). Against that:

| | |
| --- | ---: |
| candidate hard-miss instances across the four checkpoints | 26 |
| …that fall in the labeler's 22-scenario weak set | **25 (96.2%)** |
| base rate if misses were drawn uniformly from the 25 hard scenarios | **88.0%** |

**A hit rate of 96% against a base rate of 88% is not a finding.** The labeler
is weak on 22 of 25 hard scenarios, so *any* model that misses hard scenarios
lands in the weak set almost by construction. Under a uniform-random null, the
probability that a checkpoint's misses land wholly inside the weak set is 0.58
at 1000 (4 misses), 0.36 at 2250 (7) and 0.42 at final (6) — and checkpoint 3500
does not even manage it: one of its nine misses is `h14`, a scenario the labeler
**passes**.

So the clustering is real and it is nearly uninformative. What survives is the
weaker, still-true statement: the four persistent misses are all in the
labeler's weak set, the champion — never trained on any of it — recovers three
of them, and one (`h08`) is beyond every model measured here.

### The loss trajectory says nothing about any of this

Validation loss, every `Val loss` line in `train.log`:

| iter | 1 | 500 | 1000 | 1500 | 2000 | 2500 | 3000 | 3500 | 4000 | 4490 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| val loss (nats) | **2.463** | 0.074 | 0.013 | 0.028 | 0.005 | 0.013 | 0.009 | 0.012 | 0.024 | **0.003** |

Train loss touches **0.000 in exactly three of its 180 reports** — iterations
2675, 2925 and 4325 — and never settles there: from 2900 on it ranges 0.000 to
**0.322** with a median of 0.014, and the last report of the run (iteration
4490) is **0.007**. The 3550-3800 stretch inside that range is O004's excursion.
The final validation loss is the lowest of the run.

**The checkpoint with the best validation loss — the
last one, 0.003 — scores 45/51, and the checkpoint with the worst gate hard tier
(3500, 16/25) has a validation loss of 0.012, four thousandths of a nat away.**
Validation loss on this corpus orders the checkpoints in a way that has no
visible relationship to the number that decides promotion. O001 said the loss
curve cannot separate memorization from generalization on an in-distribution
split; this is the same claim with a gate score attached.

*Corrected.* `d2f40b0` said *"Train loss reached **0.000** by roughly iteration
2900"*. The log does not show that — it shows three isolated 0.000 readings
among 180, with a post-2900 median of 0.014 and a maximum of 0.322:

```sh
$ grep -oE 'Iter [0-9]+: Train loss [0-9.]+' train.log | wc -l
     180
$ grep -oE 'Iter [0-9]+: Train loss 0\.000' train.log
Iter 2675: Train loss 0.000
Iter 2925: Train loss 0.000
Iter 4325: Train loss 0.000
```

"Reached 0.000 and stayed" is a floor; three readings out of 180 are a
distribution that includes zero. The correction does not change the section's
point, which is about *validation* loss and the gate.

## What this settles, and what it does not

### H004 — supported, on both halves

H004 predicted that distilling a 3/25 labeler pulls the candidate's hard tier
down toward it, and partitioned the outcomes with **outcome A at ≤ 21/25**.
Every checkpoint lands in A: 21, 18, 16, 19 against the base's 24. The drop at
the final checkpoint is **5 hard scenarios**, well past the 3-scenario threshold
H004 set for itself before the fact.

The other half of H004 is confirmed too, and it is the more interesting half:
**core went the other way.** The base misses `c01`; the labeler is 26/26 on
core; every candidate from 2250 is 26/26.

**The two halves did not move by the same amount, and the difference is the
result.** Core propagated completely — the labeler's 26/26 arrived intact. Hard
propagated *partially*, and the arithmetic is worth writing out, because it is
the number the next run is planned against:

| checkpoint | hard | scenarios moved from the base's 24 | share of the 21-scenario base→labeler gap |
| --- | ---: | ---: | ---: |
| 1000 | 21/25 | 3 | 14% |
| 2250 | 18/25 | 6 | 29% |
| 3500 | 16/25 | 8 | **38%** — the most any checkpoint moved |
| final | 19/25 | 5 | **24%** |

Two epochs of distillation from a 3/25 labeler left the hard tier at 16-21, not
at 3. **The candidate stayed far closer to the base it started from than to the
policy it was trained on.**

*Corrected.* `d2f40b0` continued: *"The fine-tune bought exactly what the labels
contained and lost exactly what they did not."* The first clause holds on core.
The second is false on hard by the table above — the labels contained 3/25 and
the fine-tune kept 16-21/25, so most of what the labels did not contain was not
lost. H004 now carries `superseded-by: E009`.

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
- **Nothing here isolates a cause, and the clustering argument is close to
  empty.** `d2f40b0` offered as circumstantial evidence that "the misses cluster
  exactly where the labeler is weak". They do — 25 of 26 miss instances land in
  the labeler's weak set — but that set is 22 of the 25 hard scenarios, so the
  base rate is 88% and the observation is 96%. A *randomly chosen* hard miss
  lands in the weak set 22 times in 25; a test that a coin passes seven times in
  eight discriminates nothing, and checkpoint 3500 misses `h14`, which the
  labeler passes. Distillation of a weak policy and "any
  fine-tune at all disturbs the base's prompt-following" both still predict
  everything measured here. The experiment that separates them has not been run,
  and this entry no longer claims the miss set leans toward the first one.
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

`2d5bb29` is `Merge imac-site`, 20:27:23 — **5 h 39 m** after this sweep
finished, and 5 h 49 m after it started.

*Corrected.* `d2f40b0` said *"four hours after this sweep ran"*, which is not
what its own timestamps say. The sweep's window is fixed by its artifacts'
mtimes — `provenance.txt` 14:38:17, written first, and
`sweep.log`/`results.tsv` 14:48:19, written last — so 20:27:23 − 14:48:19 =
**5:39:04** and 20:27:23 − 14:38:17 = 5:49:06. Both numbers were on disk in this
entry's own source list when "four hours" was written; neither was subtracted.

**So
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
given: **label quality propagates completely on the tier the labels are strong
on, and only partially on the tier they are weak on.** Two epochs on a
26/26-core, 3/25-hard labeler produced a model that is 26/26 on core — the
labeler's score exactly — and 16-21 on hard, which is **14-38% of the way** from
the base's 24 to the labeler's 3, and **24%** at the checkpoint that scored
best. That asymmetry is the number H004 asked for and the most useful thing
available before corpus 2 is built.

*Corrected, and this was the entry's headline.* `d2f40b0` said **"label quality
propagates into behaviour almost completely."** The very next sentence refutes
it: if propagation were almost complete the hard tier would be near 3/25, and it
is 16-21/25. At the final checkpoint **16 of the base's 21-scenario hard-tier
advantage over the labeler survived** two epochs of distillation — 76% — and
even at the worst checkpoint 13 of 21 survived. The claim was written from the
core half and applied to both.

That the correction cuts the effect from "almost all" to about a quarter is not
a small edit. **"Label quality is destiny" and "label quality is worth a quarter
of the gap in two epochs" imply different next runs**, and the second is what
was measured.

The corpus remains the *suspected* bottleneck — the corpus is the one input
whose weakness is directly measured (3/25, E005) and the tier it is weak on is
the tier that lost points. But the miss-location evidence that `d2f40b0` offered
for it does not survive its own base rate (above), so the suspicion now rests on
the tier-level asymmetry alone and is weaker than the entry first claimed. The
next run should still change the corpus and not the recipe, and should change
one thing so the next entry can say which — and it should carry a second arm,
because nothing measured here distinguishes "the corpus is weak" from "any
fine-tune disturbs the base".

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
- **Four things the round-5 audit left standing, on purpose.** They are here so
  a later reader finds them without re-deriving them:
  1. **The 11:56-12:16 CPU contamination is UNSOURCED** — a session report, no
     artifact. *Settled by:* a load sample written beside the run.
  2. **O012's "falling monotonically" is UNSOURCED** — the entry now flags it
     itself; the four scores it is about are not in doubt.
  3. **`E004:33` still reads 14:28:36.** Append-only forbids editing it; this
     entry's `corrects: [E004]` and the Method section are the correction.
  4. **`H004:7` still reads `untested` and `P004:7` still reads `proposed`**
     even though E009 settled the first and ran the second. Neither takes the
     open-EXPERIMENT carve-out E004 took, so `superseded-by: E009` is the only
     permitted edit and `INDEX.md` says so instead of striking them through.
- **Nothing in the sweep was re-run for this audit; only the reading was.** The
  scores in the Result section are the same four rows `results.tsv` has held
  since 14:48:19. Every number the audit changed was a number *about* those
  rows — a finish time, a throughput, a delta, a base rate — which is the class
  of number this book has now got wrong in four consecutive rounds. *Settled
  by:* nothing yet. The controls that exist catch citations, not arithmetic.

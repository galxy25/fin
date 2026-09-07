---
id: O007
date: 2026-09-06
occurred: 2026-09-05
kind: OBSERVATION
title: Every routing and ledger label in the corpus is deterministic-baseline output, and the filter that was meant to validate them rejected nothing
status: standing
tags: [data, labels, distillation, baseline]
sources:
  - scripts/model-factory/gen_training_data.py:276-285 (routing keep()), :540-552 (the ledger path)
  - 8aa690c — commit message claiming "an independent baseline re-derivation"
  - evals/tmux-routing/RESULTS.md:25-27 — baseline 3/25 hard vs model 24/25 hard
  - "measured today (E005): router_baseline 29/51 core 26/26 hard 3/25; policy_baseline 24/35 core 21/21 hard 3/14"
  - "generator instrumentation, 2026-09-06 from a clean checkout at 704ab09: routing 3,054 baseline calls / 3,054 passed the filter / 0 rejected; ledger 769 / 769 / 0 — counting wrapper, command below"
  - "re-derived here 2026-09-06: import gen_training_data, run gen_routing(), group by (target, decision), apply CAPS (gen_training_data.py:985-1001, sliced at :1053-1056) → 3,054 candidates, 890 kept"
  - scripts/model-factory/gen_training_data.py:27-35 (the "correct twice over" docstring claim)
  - "merged from docs/labbook/entries/O001-2026-09-06-baseline-filter-never-fires.md (the parallel book, 4705b67) — see the merge note below"
related: [E005, E007, H004, P002, O001, O003]
corrects: []
superseded-by: null
---

**Merged from two drafts.** Both books recorded that the label filter never
fires: this entry, `scripts/model-factory/labbook/year-1/O007-2026-09-06-labels-are-baseline-output.md`,
and `docs/labbook/entries/O001-2026-09-06-baseline-filter-never-fires.md`. The
consolidation (O009) kept this one — it carries the caps analysis, the
vocabulary-survival measurement, the three consequences and the labeler
competence table — and folded the other's reproducer, its "tripwire, not a
validator" framing and its filing rationale into the sections below. The counts
in the two drafts were identical, and both had already filed the same two
corrections to `8aa690c`'s commit message, in the same words.

**On why this is an OBSERVATION and not an EXPERIMENT.** The instrumentation
below monkeypatches the labeler, which looks like intervention. It is a
**counting wrapper**: it calls the original `router_baseline.decide` and returns
its value unchanged, so the generator's behaviour and output are bit-identical
to an uninstrumented run. That is read-only instrumentation, and the README's
"Instrumentation is not intervention" convention — added to this book by the
consolidation, from the other book's README — states the line. E007 imports and
runs the same generator and is filed as an EXPERIMENT, correctly: it poses a
question in advance and builds a method to answer it, rather than recording
something noticed in passing.

## What was observed

The routing and ledger halves of the training corpus — **1,659 of 2,363
examples (70%)** — are labeled by running the deterministic baselines and
recording their answers.

`gen_training_data.py:276-285`, the routing path:

```python
def keep(query, registry, live, intended_action, intended_session=None):
    decision = router_baseline.decide(query, registry, live)
    if decision.get("action") != intended_action:
        return
    if intended_session is not None and decision.get("session") != intended_session:
        return
    system = router_llm._system_prompt(registry, live)
    assistant = _stable(decision, ROUTE_KEY_ORDER)
    out.append(_record("routing", intended_action, query,
                        _example(system, query, assistant)))
```

The assistant message is `decision` — the baseline's output object, serialized.
The ledger path (`:540-552`) is the same shape against `policy_baseline.decide`.

The generator's docstring makes the claim in full (`:27-35`):

> We generate inputs inside the baseline's competence zone […] then KEEP an
> example only when the baseline's decision equals the class we generated it
> for. Label == baseline rule output AND == intended class: correct twice over.

The template knows the intended class, and the baseline is asked to agree before
the row is kept.

## The filter never fired

Instrumenting the generator (counting `decide` invocations against appends, run
2026-09-06 from a clean checkout at `704ab09`):

```sh
# from any checkout of main @ 704ab09 — e.g.
#   git worktree add ../fin-wt-filter 704ab09 && cd ../fin-wt-filter
python3 -c "
import importlib.util,sys
spec=importlib.util.spec_from_file_location('g','scripts/model-factory/gen_training_data.py')
m=importlib.util.module_from_spec(spec); sys.argv=['g']; spec.loader.exec_module(m)
n=[0]; orig=m.router_baseline.decide
m.router_baseline.decide=lambda *a,**k: (n.__setitem__(0,n[0]+1), orig(*a,**k))[1]
r=m.gen_routing(); print('consulted',n[0],'kept',len(r))
"
```


| track | baseline consulted | passed the filter | rejected |
| --- | --- | --- | --- |
| routing | 3,054 | 3,054 | **0** |
| ledger | 769 | 769 | **0** |

**"Passed the filter" is not "kept".** The 3,054 routing rows that survive
`keep()` are then cut down to **890** by the balancing caps, and nothing else in
this book had recorded that. Re-derived here by importing the generator and
grouping before the cap:

| (target, decision) | candidates | cap | kept | discarded |
| --- | ---: | ---: | ---: | ---: |
| routing / refuse | 1,280 | 200 | 200 | **84%** |
| routing / start | 992 | 230 | 230 | 77% |
| routing / route | 512 | 230 | 230 | 55% |
| routing / clarify | 270 | 230 | 230 | 15% |
| **routing total** | **3,054** | | **890** | **71%** |

And the cut is **not a sample**. `gen_training_data.py:1053-1056` keeps
`sorted(grp, key=lambda r: r["line"])[:cap]` — a deterministic *alphabetical*
slice of the serialized examples. That removes vocabulary wholesale: all 16
invented domains (`DOMAINS`, `gen_training_data.py:138-155` — `DOMAINS = [` at
138, the sixteen entries at 139-154 with `atlas` last, `]` at 155; an earlier
version cited `:138-153`, which cut off `atlas`, a domain the next sentence
names) appear in the
`route` and `start` candidate pools, but only **8 of 16** survive into the kept
`route` rows (atlas, beacon, brewlog, cadence, harbor, kettle, ledgerbook,
lumen) and only **4 of 16** into the kept `start` rows (atlas, beacon, brewlog,
cadence). `clarify` keeps all 16; `refuse` uses none of them.

Three consequences worth carrying:

- **P002's disjointness argument counts the candidate pool, not the corpus.**
  Its "16 invented domains" is true of what the generator can produce; the
  corpus that trained run 1 contains 4 of them in its `start` class. The
  leakage conclusion is unaffected (fewer domains cannot create overlap with the
  eval registry) but the vocabulary breadth claim is weaker than it reads.
- **H001 and H002 propose selecting a curriculum over a corpus that is already
  the output of an unrecorded, non-random selection.** Any bits-ranked subset is
  a selection on top of an alphabetical one.
- **H004 reasons about what inputs the model was "pushed" on.** It was pushed on
  a quarter of the `start` vocabulary the generator can write.

The baseline filter itself is a **tripwire, not a validator**. It eliminated
nothing the templates did not already guarantee — the second check rejected 0 of
3,823 candidates, which is the expected outcome when the templates are written
to produce exactly the inputs the baseline handles well, as the docstring in
fact says they are. Keeping it is still right: it would catch a future template
that drifts outside the baseline's competence. What it does not do is certify
anything about the corpus that exists, so "correct twice over" is technically
true and practically vacuous, and the claim carries no independent evidence.

The corollary is the sharper statement, and it is this entry's title: since no
candidate was ever rejected, the routing and ledger labels are, **without
exception**, `router_baseline.decide` and `policy_baseline.decide` evaluated on
generated inputs. Nothing in the pipeline currently checks a routing or ledger
label against anything other than the baseline that produced it.

Two corrections to `8aa690c`'s commit message, filed here:

1. It says the labels "reproduce an **independent** baseline re-derivation".
   Re-running a deterministic function on its own input is a determinism check,
   not independent verification.
2. It describes the tool-use classes as "request_input / notify / **proceed**".
   The code emits four classes and none is named `proceed`: `request_input`,
   `notify`, `send_input`, `read_terminal` (`gen_tooluse`,
   `gen_training_data.py:912-935`). `proceed` is a *construction label*, not an
   emitted class: it appears in the module docstring at `:22` ("app tool-use —
   request_input / notify / proceed (construction label)"), in the section
   comment at `:819-821`, and as the list name `TOOL_PROCEED` at `:888`. An
   earlier draft of this entry pointed at `:830-833`, which is inside the
   `TOOLUSE_SYSTEM` prompt literal describing `send_input` and `request_input`
   to the model and contains no occurrence of the word.

   In fairness to `8aa690c`: its phrasing is a verbatim echo of the generator's
   own docstring, tagged "(construction label)" in both places. The commit
   message repeats the source's own shorthand rather than inventing one. The
   correction is that the shorthand names no class a reader will find in the
   data.

## Why this is the corpus's defining property

The labeler's measured competence, on the corpus that decides promotion:

| policy | overall | core | **hard** |
| --- | --- | --- | --- |
| `router_baseline.py` — **the labeler** | 29/51 | 26/26 | **3/25** |
| `google/gemma-4-e4b`, round-3 prompt — the shipped policy | 49/51 | 25/26 | **24/25** |

So: **890 examples of a policy that scores 3/25 on the hard tier, presented
under the 24/25 policy's system prompt, trained to a loss of zero.**

Two things follow directly:

- **The corpus teaches format and the easy cases perfectly.** Every label is
  well-formed JSON in the exact contract, and the core-tier behaviours the
  baseline gets right (26/26) are densely covered.
- **The corpus contains no examples of the judgment the hard tier tests.** The
  mechanism is the generator's *input* selection, not an inability of the
  labeler. An earlier version of this bullet said "by construction: the
  baseline cannot produce those answers", which is too strong and is refuted by
  this book's own E005: `router_baseline.py` scores **3/25** on the hard tier,
  so it demonstrably produces three of the answers that tier tests — and on
  goals-ledger, `h12`-`h14` are annotated in the corpus itself as "model trap,
  baseline passes". The correct statement is the one the generator's docstring
  makes (`gen_training_data.py:31-34`): the hard tier's paraphrase, typo and
  misdirection *input shapes* are deliberately not reproduced, so the labeler is
  only ever asked questions inside its competence zone (P002). Nothing in the
  corpus exercises the judgment the hard tier tests, because nothing in the
  corpus asks for it. The conclusion is unchanged; the "by construction" step
  was wrong, and it is load-bearing for H004 and for H002's "ceiling this cannot
  break", so it is worth having right.

H004 states the falsifiable prediction that follows.

## Where labels could come from instead

Named here because the alternatives determine what a second corpus looks like:

1. **Model labels with human review** — the round-3-prompted model scores 49/51,
   so its outputs on fresh inputs are a better teacher than the baseline for
   the hard classes. Cost: it needs review, and it bakes in the model's own two
   residual errors (E001).
2. **Real telemetry** — `raw/trajectories/` decision records with `rating: 1`,
   and `rating: -1` pairs relabeled with `payload.correctedDecision`. The
   ingest path exists and is deployed; `build_dataset.py:98-133` implements the
   reader. **No evidence it has ever been used**: no synced `raw/` directory
   exists in the repo.
3. **Disagreements** — examples where a human overruled the baseline. These are
   the only category that adds information the generator does not already
   contain (H001).

## What this does not show

- **It does not show the labels are wrong.** On the classes they cover they are
  correct by construction and verified by the eval's own core tier.
- **It does not show the fine-tune will fail.** A model trained on
  format-perfect easy examples may still generalize from its base's own
  reasoning. That is H004's open question and only the gate answers it.

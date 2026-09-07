---
id: O011
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Three checkpoints scored an identical 10/51 — the model was never queried at all
status: standing
tags: [gate, measurement, harness, evals, run-1]
sources:
  - 7fb54b5 — "Gate run 1: champion re-recorded at 49/51, no candidate promotes"; the commit message carries the diagnosis
  - 2d5bb29:scripts/model-factory/gate_sweep.sh:73-88 — the comment block and `probe()` added in response
  - 2d5bb29:scripts/model-factory/gate_sweep.sh:143-144 — `probe` in the `serve &&` chain, and `"$FUSED"` as the model id where an invented label used to be
  - 7fb54b5 — `git show 7fb54b5 -- scripts/model-factory/gate_sweep.sh` is the whole 23-line diff, including `SERVE-FAILED` → `SERVE-OR-PROBE-FAILED`
  - "evals/tmux-routing/scenarios.json — 51 scenarios, 25 hard, expected actions route 24 / start 13 / clarify 10 / refuse 4; clarify is c01-c05 (core) and h13, h22-h25 (hard). Parsed once, re-parsed 2026-09-06 21:33:14 PDT after the audit, output pasted below"
  - "local-artifact: models/gate-sweep/eval-1000.log — the per-class breakdown a real run prints, quoted below"
related: [E009, O012, P004, P001, E005]
corrects: []
superseded-by: null
---

## What was observed

The first checkpoint sweep of run 1 returned **exactly 10/51 for three
checkpoints thousands of iterations apart.**

That is a catastrophic-looking number. A 4-billion-parameter model that scores
10 out of 51 on the corpus its labeler scores 29 on has been destroyed by
training. The obvious reading was that the fine-tune had collapsed.

**The identity was the tell.** Three checkpoints separated by thousands of
optimizer steps do not agree to the scenario. Two models that differ produce
different mistakes; two models that produce the same 41 mistakes are not two
models.

## What had actually happened

`gate_sweep.sh` served each fused checkpoint with `mlx_lm.server` and then told
`run_evals.py` to score a model id it had invented — a label of the form
`fin-foreman-<iters>`, chosen because it reads well in a results table.

**`mlx_lm.server` reports its model id as the PATH passed to `--model`.** It
does not accept a nickname. Every scoring request therefore named a model the
server did not have, every request 404'd, and `router_llm.py` degraded each
scenario to its clarify fallback.

The corpus has **exactly 10 scenarios whose expected action is `clarify`**
(`scenarios.json`, re-parsed 2026-09-06 **21:33:14** PDT: route 24 / start 13 /
clarify 10 / refuse 4). A router that answers `clarify` to everything scores
10/51 — every clarify scenario, nothing else, at every checkpoint, forever.

### Correcting the count in the commit that fixed it

`7fb54b5`'s commit message says *"exactly the five clarify scenarios passed"*
and `7fb54b5:scripts/model-factory/gate_sweep.sh:76` carried the same figure
beside the same 10/51 in one sentence. **Five and 10/51 cannot both be right,
and the number is ten.** Re-parsed at 2026-09-06 21:33:14 PDT — output pasted
rather than described, which is the rule this entry exists to enforce:

```sh
$ python3 -c "import json; …"      # evals/tmux-routing/scenarios.json
scenarios 51 | hard 25
expected actions: {'route': 24, 'start': 13, 'clarify': 10, 'refuse': 4}
clarify core: ['c01', 'c02', 'c03', 'c04', 'c05']
clarify hard: ['h13', 'h22', 'h23', 'h24', 'h25']
```

| tier | ids | count |
| --- | --- | ---: |
| core | `c01` `c02` `c03` `c04` `c05` | 5 |
| hard | `h13` `h22` `h23` `h24` `h25` | 5 |

So the empty-pipe signature decomposes as **core 5/26, hard 5/25, overall
10/51**. "Five" was a count of the core half, written while the total was a
count of both. The script's comment was corrected in the same commit as this
entry and re-verified against the corpus in the audit —
`grep -n clarify scripts/model-factory/gate_sweep.sh` at `:76-77` now reads *"the
10 clarify scenarios pass — 5 core (c01-c05) and 5 hard (h13, h22-h25)"*, which
is the parse above. The commit message stands as written, with this as its
correction, and the mistake is instructive in its own right — *the fix for a
miscounted measurement shipped a miscount*, which is O010's subject arriving in
a new place.

*Corrected.* At `d2f40b0` this entry dated the same single `scenarios.json`
parse two ways — **20:47 PDT** in the front matter and **20:56 PDT** twice in
the body. One read has one time. Neither is recoverable, so both are replaced
by the re-parse above, whose output is pasted in full. A read time that cannot
be reconstructed is not a smaller defect than a wrong number; it is the same
defect, since a tip and a corpus are both things that move.

So the number was not a measurement of a damaged model. It was a measurement of
**an empty pipe**, and it was stable across checkpoints for the same reason a
disconnected thermometer reads the same temperature in every room.

## Why it looked like a result and not like a bug

Four properties conspired, and they are worth naming because the next
harness will have all four:

1. **The failure was silent.** Nothing crashed. The server was up, the fuse
   succeeded, `run_evals.py` exited normally and printed a well-formed score
   table with a per-class breakdown.
2. **The number was plausible.** 10/51 is bad but not absurd. A 0/51 would have
   been investigated immediately; a 51/51 would have been disbelieved. A number
   in the plausible-disaster band gets *explained* instead of *checked*, and
   the explanation was ready to hand — H004 had predicted a hard-tier collapse
   the day before, and this looked like a bigger version of it.
3. **The degradation was toward a valid answer.** `clarify` is a legal action
   with real scenarios behind it, so the failure mode produced partial credit
   rather than a parse error. A fallback that returned nothing would have
   scored 0 and been obvious.
4. **The provenance the run recorded was all true.** `provenance.txt` correctly
   named the router prompt blob, the base model and the adapter directory.
   Every fact it wrote down was accurate; the one fact that mattered — *did the
   endpoint answer* — was not among them.

## The fix

A **liveness probe** that spends one trivial request on the endpoint before
spending 51 scenarios on it, and the model id corrected to the fused path
(`2d5bb29:scripts/model-factory/gate_sweep.sh:78-88, :143-144`):

```sh
probe() {  # probe <base-url> <model-id>
  local body
  body=$(curl -s -m 90 "$1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK\"}],\"max_tokens\":8,\"temperature\":0}")
  case "$body" in
    *'"choices"'*) return 0 ;;
    *) say "PROBE FAILED for model id '$2' — the endpoint did not answer a trivial request:"
       say "  ${body:-<empty response>}"
       return 1 ;;
  esac
}
```

wired in as `serve "$FUSED" "$IT" && probe "http://127.0.0.1:$PORT/v1" "$FUSED"`,
with the failure row renamed `SERVE-FAILED` → `SERVE-OR-PROBE-FAILED` so the
results file distinguishes the two. The probe sends the **same model id** the
51 scenarios will send, which is the only version of the check that would have
caught this: a probe that hardcoded the path would have passed while the sweep
kept sending the nickname.

## The rule this book now holds

> **A score is not a measurement until something proves the model was queried.**
> Prove it with a request that costs one round trip and uses the exact
> credentials, endpoint and model id the real run will use, and run it *before*
> the expensive part.

And its corollary, which is the part that generalizes past this harness:

> **A degraded fallback that returns a legal answer will always score the
> fraction of the corpus that answer is correct for.** When a harness has a
> fallback, know that fraction in advance, and treat a score at exactly that
> fraction as a liveness failure until proven otherwise. Here it was 10/51.

The second rule is the reusable one. `router_llm.py`'s fallback is `clarify`;
`clarify` is 10 of 51; **10/51 is the harness's signature for "nothing
answered"**, and it should be recognized as a signature rather than diagnosed
as a model.

## What a real run looks like, for contrast

The same harness, same script, with the endpoint actually answering
(`eval-1000.log`, checkpoint 1000):

```
tmux-routing evals: 43/51 passed (84%)  [offline]
  core (gates): 22/26   hard (benchmark): 21/25
  clarify  10/10
  refuse   3/4
  route    17/24
  start    13/13
```

Note that `clarify 10/10` appears in the healthy run too. **The per-class
breakdown does not distinguish the two cases**; only the other three rows do.
An eye scanning for "clarify is fine" learns nothing.

## What this does not show

- **It does not tell us what the checkpoints would have scored** under the
  broken sweep if the id had been right. The broken run's numbers are void, not
  low; there is nothing to compare.
- **It does not prove the probe is sufficient.** A probe answering one trivial
  request proves the endpoint resolves the model id. It does not prove the
  adapter was fused correctly, that the right checkpoint was staged, or that
  the server is serving the weights the filename claims. Those failures would
  all pass the probe and produce a *plausible, non-identical* set of scores —
  which is the harder version of this bug and is still unguarded.
- **No log of the broken sweep survives.** `models/gate-sweep/results.tsv` was
  truncated (`: >"$RESULTS"`) by the corrected run, so the three identical
  10/51 rows exist only in `7fb54b5`'s commit message and in this entry. That
  is a weaker artifact class than this book likes, and it is recorded as such.
- **It says nothing about how long the bug was live**, because the sweep had
  never run before (P004 was `proposed, never yet run`). The corrected sweep is
  timestamped 14:38-14:48 by its own log files; **the broken sweep's start and
  end times are UNSOURCED** — nothing on disk records them, because the run that
  replaced it truncated the results file. *Settled by:* the timestamped results
  file named in the open items below.

## Open

- **The sweep truncates its own results file at the start of every run.** A
  re-run overwrites the evidence of the previous one. *Settled by:* writing
  `results-<timestamp>.tsv`, or refusing to overwrite a non-empty file.
- **Nothing records the served model id in the eval log.** `provenance.txt`
  records the router prompt, base and adapters but not what the harness actually
  put in the `"model"` field of its requests — the exact field that was wrong.
  *Settled by:* one more line in `provenance.txt`.

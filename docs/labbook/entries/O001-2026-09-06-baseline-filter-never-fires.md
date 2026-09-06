# O001 — The "correct twice over" label filter rejected zero examples

- **Kind:** OBSERVATION
- **Date:** 2026-09-06
- **Corrections:** amends the reading of `8aa690c`'s commit message (see below)
- **Superseded-by:** —

## What was noticed

`gen_training_data.py`'s docstring makes a strong claim about label quality
for the two baseline-labeled targets (lines 27-35):

> We generate inputs inside the baseline's competence zone […] then KEEP an
> example only when the baseline's decision equals the class we generated it
> for. Label == baseline rule output AND == intended class: correct twice
> over.

The implementing code is the `keep()` closure at
`gen_training_data.py:277-286`: it calls `router_baseline.decide`, returns
early on any mismatch of action or session, and only then appends.

**The filter never rejected anything.** Counting invocations against
appends, on both baseline-labeled tracks:

| track | baseline consulted | kept | rejected |
| --- | ---: | ---: | ---: |
| routing (`gen_routing`) | 3,054 | 3,054 | **0** |
| ledger (`gen_ledger`) | 769 | 769 | **0** |

Method — monkeypatch the labeler and count, at main `704ab09`:

```sh
cd /Users/deepspacenine/forges/levi/fin-wt-labbook
python3 -c "
import importlib.util,sys
spec=importlib.util.spec_from_file_location('g','scripts/model-factory/gen_training_data.py')
m=importlib.util.module_from_spec(spec); sys.argv=['g']; spec.loader.exec_module(m)
n=[0]; orig=m.router_baseline.decide
m.router_baseline.decide=lambda *a,**k: (n.__setitem__(0,n[0]+1), orig(*a,**k))[1]
r=m.gen_routing(); print('consulted',n[0],'kept',len(r))
"
```

## Why it matters

"Correct twice over" is technically true and practically vacuous. The second
check eliminated 0 of 3,823 candidates, which means the templates were built
to sit exactly inside the baseline's rules — as the docstring in fact says
they were. The filter is a **tripwire**, not a validator: it would catch a
future template that drifts outside the baseline's competence, and that is
worth keeping, but it certifies nothing about the current corpus that the
templates did not already guarantee.

The corollary is sharper. Since no candidate was ever rejected, the labels
for routing and ledger are, without exception, `router_baseline.decide` and
`policy_baseline.decide` evaluated on generated inputs. The corpus teaches
the baselines' rules and nothing else — see
[H001](H001-2026-09-06-hard-tier-regression.md) for what that implies about
the adversarial tier.

## Correction to the record

Commit `8aa690c`'s message reads:

> 2363 balanced examples; run is byte-stable and all 890 routing / 769 ledger
> labels reproduce an independent baseline re-derivation from the serialized
> prompts.

"Independent re-derivation" overstates it. Re-running a deterministic function
on its own input reproduces its own output; that is a determinism check, not
independent verification. The claim as written is true and the check is worth
having — it would catch a non-deterministic baseline or a prompt-serialization
bug — but it should not be read as evidence that the labels are *right*, only
that they are *stable*. Nothing in the pipeline currently checks a routing or
ledger label against anything other than the baseline that produced it.

Also recorded for the file: `8aa690c`'s message describes the tool-use track as
"request_input / notify / proceed". The code emits four classes and no class
named `proceed`: `request_input` (128), `notify` (96), `send_input` (96),
`read_terminal` (64) — `gen_training_data.py:912-937` and the generator's own
stdout. "Proceed" is the name of the *construction rule* comment
(`gen_training_data.py:830-833`), not of an emitted label.

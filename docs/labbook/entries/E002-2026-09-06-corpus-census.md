# E002 — Corpus census: where 4,527 generated candidates become 2,363 training rows

- **Kind:** EXPERIMENT
- **Date:** 2026-09-06
- **Corrections:** —
- **Superseded-by:** —

## Question

`gen_training_data.py` prints what it *kept*. What did it *generate*, and
which classes are shaped by the generator's reach versus by the balancing
caps? A cap that never binds and a cap that discards 84% of its class are
very different facts about a corpus.

## Method

Import the generator as a module from a worktree at main (`704ab09`) and call
each `gen_*` function directly, counting per `(target, decision)` before the
cap in `CAPS` (`gen_training_data.py:985-1001`) is applied:

```sh
cd /Users/deepspacenine/forges/levi/fin-wt-labbook
python3 -c "
import importlib.util,sys
spec=importlib.util.spec_from_file_location('g','scripts/model-factory/gen_training_data.py')
m=importlib.util.module_from_spec(spec); sys.argv=['g']; spec.loader.exec_module(m)
for fn in (m.gen_routing, m.gen_ledger, m.gen_elicit, m.gen_tooluse): ...
"
```

Kept counts are the generator's own stdout from the E001 reproduction run.

## Result

| target / decision | generated | cap | kept | note |
| --- | ---: | ---: | ---: | --- |
| routing / route | 512 | 230 | 230 | capped, 55% discarded |
| routing / start | 992 | 230 | 230 | capped, 77% discarded |
| routing / clarify | 270 | 230 | 230 | capped |
| routing / refuse | **1,280** | 200 | 200 | capped, **84% discarded** |
| ledger / ingest | 176 | 210 | 176 | cap never binds |
| ledger / drive | 176 | 210 | 176 | cap never binds |
| ledger / report | 144 | 210 | 144 | cap never binds |
| ledger / clarify | 160 | 210 | 160 | cap never binds |
| ledger / idle | 113 | 210 | 113 | cap never binds |
| elicit / ask | 160 | 160 | 160 | exactly at cap |
| elicit / proceed | 160 | 160 | 160 | exactly at cap |
| tooluse / request_input | 128 | 130 | 128 | cap never binds |
| tooluse / notify | 96 | 100 | 96 | cap never binds |
| tooluse / send_input | 96 | 100 | 96 | cap never binds |
| tooluse / read_terminal | 64 | 70 | 64 | cap never binds |
| **total** | **4,527** | | **2,363** | |

By target, kept: routing 890, ledger 769, tooluse 384, elicit 320.
Deduplication by full serialized line removed nothing (`deduped: 4527`).
The leakage gate dropped nothing (`dropped for overlap: 0`) — see
[P002](P002-2026-09-06-leakage-gate.md).

## Reading

**Only the routing track is cap-shaped.** 3,054 routing candidates become 890
rows; 2,164 are thrown away. Everything else is *generator-limited*: the caps
for ledger (210 each) and tool-use (130/100/100/70) are aspirational numbers
the templates cannot reach. `elicit` lands exactly on its cap of 160 by
coincidence of arithmetic — 16 flavors × 10 templates — not by selection.

The refuse class is the extreme: 16 domains × 10 unregistered names × 8
templates = 1,280 candidates for 200 slots. Since the cap keeps
`sorted(grp, key=line)[:cap]` (`gen_training_data.py:1069-1074`), the 200
kept refuse rows are the *lexicographically first* 200 serialized examples,
not a sample across the space. Whether that biases the surviving refuse
vocabulary toward particular session names is unmeasured — the artifact that
would settle it is a per-`{unreg}` histogram of the kept 200.

The balance the caps produce is real at the decision level (route 230 / start
230 / clarify 230+160 / refuse 200 / …), but it is a balance struck over an
unbalanced generator, and three of the four targets contribute whatever they
happen to produce.

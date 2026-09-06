---
id: E007
date: 2026-09-06
occurred: 2026-09-06
kind: EXPERIMENT
title: "Corpus census: where 4,527 generated candidates become 2,363 training rows"
status: closed
tags: [corpus, data, caps, census]
sources:
  - scripts/model-factory/gen_training_data.py:985-1001 (CAPS), :1053-1056 (the lexicographic slice)
  - "measured 2026-09-06 by importing the generator from a worktree at main 704ab09 and calling each gen_* function directly — command below"
  - "generator stdout from the E006 reproduction run (kept counts, `deduped: 4527`, `dropped for overlap: 0`)"
related: [E006, O007, P002, H001]
corrects: []
superseded-by: null
---

**Migrated entry.** Written as `docs/labbook/entries/E002-2026-09-06-corpus-census.md`
in the parallel book opened at `4705b67`, and renumbered `E002 -> E007` when the
two books were consolidated into this one (O009). Body unchanged apart from the
header block and the cross-references, which now name this book's ids.

**Relationship to O007.** O007 states the routing quarter of the table below —
3,054 candidates cut to 890 by a lexicographic slice — as one of its supporting
facts, and draws the vocabulary-survival consequence from it (8 of 16 domains
reach the kept `route` rows, 4 of 16 the kept `start` rows). The two entries were
written independently in the two books from the same instrumentation run and
they agree row for row; this one is the full census of all four targets, O007 is
the argument about what the labels are. Neither was folded into the other,
because their subjects are different.

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
# from any checkout of main @ 704ab09 — e.g.
#   git worktree add ../fin-wt-census 704ab09 && cd ../fin-wt-census
python3 -c "
import importlib.util,sys
spec=importlib.util.spec_from_file_location('g','scripts/model-factory/gen_training_data.py')
m=importlib.util.module_from_spec(spec); sys.argv=['g']; spec.loader.exec_module(m)
for fn in (m.gen_routing, m.gen_ledger, m.gen_elicit, m.gen_tooluse): ...
"
```

Kept counts are the generator's own stdout from the E006 reproduction run.

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
P002.

## Reading

**Only the routing track is cap-shaped.** 3,054 routing candidates become 890
rows; 2,164 are thrown away. Everything else is *generator-limited*: the caps
for ledger (210 each) and tool-use (130/100/100/70) are aspirational numbers
the templates cannot reach. `elicit` lands exactly on its cap of 160 by
coincidence of arithmetic — 16 flavors × 10 templates — not by selection.

The refuse class is the extreme: 16 domains × 10 unregistered names × 8
templates = 1,280 candidates for 200 slots. Since the cap keeps
`sorted(grp, key=lambda r: r["line"])[:cap]` (`gen_training_data.py:1053-1056`
— 1069-1074 in an earlier draft of this entry is the leakage assertion and the
final shuffle, not the cap), the 200 kept refuse rows are the *lexicographically
first* 200 serialized examples, not a sample across the space.

The bias that slicing introduces **is** measurable elsewhere in the same table,
and it is large: all 16 invented domains appear in the `route` and `start`
candidate pools, but only 8 survive into the kept `route` rows and only 4 into
the kept `start` rows. For `refuse` specifically the equivalent check — a
per-`{unreg}` histogram of the kept 200 — is still unmeasured.

The balance the caps produce is real at the decision level (route 230 / start
230 / clarify 230+160 / refuse 200 / …), but it is a balance struck over an
unbalanced generator, and three of the four targets contribute whatever they
happen to produce.

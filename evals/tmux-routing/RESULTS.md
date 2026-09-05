# Router eval results — baseline vs model-backed

Corpus: `scenarios.json`, 51 scenarios (26 original + 25 adversarial `h01`–`h25`).
Scored offline with:

```sh
# deterministic baseline
python3 evals/tmux-routing/run_evals.py

# model-backed (requires an OpenAI-compatible endpoint; LM Studio default)
FIN_ROUTER_MODEL=google/gemma-4-e4b \
  python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py
```

Model run recorded below (2026-09-05): LM Studio at `http://localhost:1234/v1`,
model `google/gemma-4-e4b`, temperature 0, 30s/call timeout. The box's larger
local models were unusable under the 30s contract: `gemma-4-12b-qat` spends
~40s/call on reasoning tokens; `gemma-4-26b-a4b` refuses to load for lack of
memory. Set `FIN_ROUTER_MODEL` to rescore with anything else.

## Overall

| router | overall | route | start | clarify | refuse |
|---|---|---|---|---|---|
| baseline (`router_baseline.py`) | 29/51 (57%) | 12/24 | 6/13 | 7/10 | 4/4 |
| model (`router_llm.py`, gemma-4-e4b) | **36/51 (71%)** | 21/24 | 4/13 | 7/10 | 4/4 |

## Miss sets

| | ids |
|---|---|
| baseline missed (22) | h01 h02 h03 h04 h05 h06 h07 h08 h09 h10 h11 h12 h13 h15 h16 h17 h18 h19 h20 h21 h23 h25 |
| model missed (15) | s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |
| model fixed (12) | h01 h02 h04 h05 h06 h07 h08 h09 h12 h19 h21 h25 |
| model regressed (5) | s01 s03 s05 s06 c01 |
| both missed (10) | h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |

## Reading

**What the model buys:** the zero-vocab paraphrases (h01–h03 mostly),
typo/voice noise (h04–h06), multi-clause misdirection (h07–h09), the
"main"-as-adjective trap (h12), explicit-new + protected name (h19), one
indirect dead-session recreation (h21), and the two-genuine-targets clarify
(h25). Route accuracy jumps 12/24 → 21/24 — semantics beat keyword rules
exactly where the hard set was designed to show it.

**Where it regressed (all `start`-flavored):** gemma-4-e4b over-clarifies on
explicit new-session asks with thin task context (s01, s03, and the whole
h15–h18 family stays missed), and mishandles the dead-session registry state:
for s05/s06 it answers `refuse` for a *registered* session that merely isn't
live — inverting the guardrail's direction — and c01 it routes on a phantom
vocabulary hit. Net `start` accuracy actually drops (6/13 → 4/13); the win is
concentrated in `route`.

**Still open (both routers miss):** ordinary-word traps where a live
unregistered session name doubles as a plain English word (h10 "deploy",
h11 "demo"/"window"), the human-world "book a dj" (h13), phrasal-verb
new-session variants (h15–h18), indirect recreation (h20), and the analogy
mention (h23). These need either a stronger model or prompt work in
`prompts/router.md` (dead ≠ unregistered; "new agent" synonyms; mention ≠
target) — the corpus now measures exactly that.

Full per-miss transcripts: run the commands above; the harness prints every
miss with expected vs actual JSON and the scenario note.

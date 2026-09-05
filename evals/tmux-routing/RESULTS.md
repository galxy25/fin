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

Model runs recorded below (2026-09-05): LM Studio at `http://localhost:1234/v1`,
model `google/gemma-4-e4b`, temperature 0, 30s/call timeout. The box's larger
local models were unusable under the 30s contract: `gemma-4-12b-qat` spends
~40s/call on reasoning tokens; `gemma-4-26b-a4b` refuses to load for lack of
memory. Set `FIN_ROUTER_MODEL` to rescore with anything else.

## Overall

| router | overall | route | start | clarify | refuse | core | hard |
|---|---|---|---|---|---|---|---|
| baseline (`router_baseline.py`) | 29/51 (57%) | 12/24 | 6/13 | 7/10 | 4/4 | 26/26 | 3/25 |
| model, original prompt | 36/51 (71%) | 21/24 | 4/13 | 7/10 | 4/4 | 21/26 | 15/25 |
| model, reworked prompt | **49/51 (96%)** | 23/24 | 13/13 | 9/10 | 4/4 | **25/26** | **24/25** |

The rework targeted the three prompt-fixable failure classes the first model
run exposed: **dead ≠ unregistered** (a registered session absent from the
live list means recreate/`start`, never `refuse`), **explicit-new synonym
coverage** (recognize new-session requests by meaning, not a verb list), and
**mention ≠ target** (analogies/asides/physical-world words don't route or
refuse; no phantom vocabulary matches). All worked micro-examples in
`prompts/router.md` use a generic invented registry (payments/gamedev/docs) —
no corpus leakage.

## Prompt-iteration rounds

| round | overall | core | hard | misses |
|---|---|---|---|---|
| 0 (original prompt) | 36/51 | 21/26 | 15/25 | s01 s03 s05 s06 c01 h03 h10 h11 h13 h15 h16 h17 h18 h20 h23 |
| 1 (three-classes rewrite) | 46/51 | 25/26 | 21/25 | c01 h01 h07 h08 h21† |
| 2 (imperative-first, honest vocab, start=lifecycle) | 48/51 | 24/26 | 24/25 | r01† f01 h08 |
| 3 (route⊆registry, start-object test) — **kept** | **49/51** | **25/26** | **24/25** | c01 h08 |
| 4 (generic-phrase clamp, anti-contrast rule) — reverted | 48/51 | 25/26 | 23/25 | r06 h01 h12 |

† = 30s endpoint timeout, not a semantic miss (`decide()` degrades to
clarify). One flake each in rounds 1–2, none in rounds 3–4.

Round 1 fixed all fifteen round-0 misses in the three targeted classes but
introduced over-corrections (h01 over-clarify, h07 false "two targets", h08
"set that up"→start, c01 vocabulary hallucination). Rounds 2–3 clamped those:
route may only name a registry session (f01 had routed into unregistered
`main`), start requires a session/agent object rather than a feature/plan,
and multi-clause requests target the main imperative. Round 4 fixed the last
two (c01, h08) but its stronger generic-word clamp regressed three others —
r06's direct name mention got second-guessed as "generic tests", h01's domain
paraphrase got re-labeled generic, h12 refused on an adjectival "main" — so
the round-3 prompt is the keeper: the best point on this model's curve.

## Remaining misses (round-3 prompt)

| id | one-line analysis |
|---|---|
| c01 (core) | "run the tests" → routes `fin`, rationalizing bare "tests" as fin's "testing and app development" domain; for e4b the domain-paraphrase allowance (needed for h01–h03) and the no-generic-words rule sit on a knife edge — round 4's harder clamp fixed it but broke r06/h01/h12. |
| h08 (hard) | "unlike the newsletter rollout, the widget release needs a phased rollout — set that up" → routes `africanintellect`; the contrast-clause noun still outweighs the imperative's "widget" (which is literally in fin's vocabulary); the explicit anti-contrast rule that fixed it in round 4 cost three other scenarios. |

Core stands at 25/26 — c01 is the only gate blocker. Both residual misses
look like model-capacity limits at this prompt length rather than missing
rules: each has a rule in the prompt that the model applies inconsistently,
and strengthening either rule further tips its neighbors (rounds 2 and 4
both demonstrated the see-saw). A stronger local model under the 30s
contract, or a shorter compiled prompt, is the likelier path to 26/26 than
more prose.

Full per-miss transcripts: run the commands above; the harness prints every
miss with expected vs actual JSON and the scenario note.

# Fin model factory

An LLM factory in AWS (profile `levi`, us-west-2, account 011183829623) that
builds the small, fast, fine-tuned model that runs fin as the **foreman** of a
software factory of agents — local Apple Silicon boxes and the cloud workers
`scripts/cloud-agent/` launches. Base: a 4–12B open Gemma. Fine-tune targets,
in priority order:

1. **tmux session management** — routing/discrimination between sessions.
   `evals/tmux-routing/` is both the spec and the gate.
2. **Eliciting feedback from factory owners** — asking the right short question
   at the right moment, then acting on the answer.
3. **Monitoring long-running missions** — efficient long-horizon supervision
   with accurate context management (the goals-ledger work; its eval joins the
   gate when that branch merges — see [Eval gate](#eval-gate)).

The factory closes the loop through the fin app: opt-in user feedback and
decision trajectories flow in through the control plane, become datasets,
train candidates, and only a candidate that beats the champion on the evals
ships back to the app as the local model.

## Status

- [x] Architecture + frozen `POST /feedback` ingest contract (this doc)
- [x] Ingest deployed and verified live — bucket
      `fin-model-factory-011183829623` created (public access blocked,
      `raw/` 180-day lifecycle), Lambda write policy `raw/*` only, 201/400/401
      paths exercised end-to-end
- [x] Dataset builder — `build_dataset.py` (routing corpus + synced `raw/`
      trajectories → chat JSONL; byte-stable; goals-ledger track auto-joins
      when present). **Leakage caveat:** the seed build derives from the eval
      corpus itself; synthetic variants + telemetry must replace it before a
      real training run (see Leakage rule below)
- [x] QLoRA recipe + validator — `train/qlora_config.yaml`,
      `train/run_finetune.py` (`--dry-run` is pure-python: no torch, no
      downloads; real mode refuses without `FIN_FACTORY_GO=1`)
- [x] mlx-lm local-run alternative — `train/README-local.md`
- [x] Eval gate + champion record — `eval_gate.py`,
      `evals-champions.json` (seeded: untuned gemma-4-e4b 36/51)
- [ ] Synthetic expansion of the routing taxonomy (satisfies the leakage
      rule; unblocks the first real fine-tune)
- [ ] First fine-tune run (**human go required** — see Hard rule)
- [ ] Merge → GGUF export, `models/` registry upload, `champion.json` flip
- [ ] goals-ledger eval joins the gate (that branch has not merged)
- [ ] App-side opt-in feedback UI posting to `/feedback`

```
fin app (iOS/macOS)                        control plane (existing Lambda)
  opt-in, pre-redacted signals ──POST /feedback──▶ validate ──▶ S3 data lake
                                                                    │ raw/
                                             dataset builder ◀──────┤
                                                    │ datasets/     │
                                             QLoRA fine-tune        │
                                             (human "go" required)  │
                                                    │ adapter       │
                                             eval gate (run_evals)  │
                                                    │ promoted      │
                                             merge → GGUF ──▶ models/ registry
                                                    │
                                             LM Studio / local serving
```

## Data lake

One private S3 bucket, separate from the agent supervision channel on purpose
(training telemetry and live agent traffic never share a key space, a
lifecycle, or an IAM statement):

```
s3://fin-model-factory-011183829623/          (us-west-2, all public access blocked)
  raw/                                        # EXPIRES 180 days after write
    feedback/YYYY/MM/DD/<uuid>.json           # user_feedback documents
    trajectories/YYYY/MM/DD/<uuid>.json       # trajectory documents
  datasets/                                   # persists
    <dataset-id>/train.jsonl
    <dataset-id>/val.jsonl
    <dataset-id>/manifest.json                # sources, counts, sha256 of each split
  models/                                     # persists
    <model-id>/<model-id>.gguf                # merged + quantized, LM Studio-ready
    <model-id>/adapter/                       # the LoRA adapter (safetensors)
    <model-id>/manifest.json                  # base, data hash, scores — see Export
    champion.json                             # pointer to the current champion + its scores
  evals/                                      # persists
    <model-id>/<run-id>.json                  # raw run_evals output per candidate
```

The bucket, its public-access block, and the `raw/` 180-day lifecycle rule are
created idempotently by `scripts/cloud-agent/control-plane/deploy.sh` — the
same script that grants the Lambda its single write permission
(`s3:PutObject` on `raw/*` only; the control plane can ingest telemetry but
can never touch datasets, models, or eval records).

## Ingest contract — FROZEN

The app team builds against this; it does not change without a coordinated
version bump on both sides.

**`POST /feedback`** on the **existing** control-plane API
(`scripts/cloud-agent/control-plane/`), same bearer-token auth as every other
route (`authorization: Bearer <token>`, token in `~/.fin-control-plane-token`,
mode 600 — read from the file, never paste it anywhere).

Request body (JSON object):

| field | type | rule |
| --- | --- | --- |
| `kind` | `"user_feedback"` \| `"trajectory"` | required; anything else is 400 |
| `rating` | `1` \| `-1` \| `null` | thumbs up / thumbs down / no rating |
| `comment` | `str` \| `null` | free-text from the factory owner |
| `payload` | `object` \| `null` | structured, **pre-redacted** signal (decision JSON, tick summary, …) |
| `appVersion` | `str` | non-empty |
| `platform` | `str` | non-empty (`"ios"`, `"macos"`, …) |
| `createdAt` | `str` | ISO8601, client's own clock |

Responses:

- **201** `{"id": "<uuid>", "kind": "...", "receivedAt": "<iso8601>"}` — the
  Lambda wrapped the validated fields with a server `receivedAt` and an `id`
  and wrote one object to `raw/feedback/YYYY/MM/DD/<uuid>.json`
  (`user_feedback`) or `raw/trajectories/YYYY/MM/DD/<uuid>.json`
  (`trajectory`). The date partition is the **server** receive date; the
  client's `createdAt` lives inside the document.
- **400** — bad `kind` or any other field violating the table above.
- **401** — missing/wrong bearer token.
- **413** — document over 1 MiB after wrapping; chunk trajectories app-side.

Unknown extra fields are dropped, never stored.

**Privacy (non-negotiable):** every field the app sends is **opt-in** and
**pre-redacted on the device before upload**. The factory never receives raw
terminal output — no pane captures, no scrollback, no command lines. `payload`
carries structured, already-redacted signals only: routing decision JSONs,
abstract session descriptors, tick summaries, ratings. The Lambda never logs
or echoes `comment`/`payload` content, and the bucket blocks all public
access.

## Dataset builder

Corpora + telemetry → SFT JSONL in standard chat format (what `peft`+`trl`'s
`SFTTrainer` and `mlx_lm.lora` both consume directly). One line per example:

```json
{"messages": [
  {"role": "system", "content": "<prompts/router.md + registry JSON + live-session list + strict output contract — built exactly as evals/tmux-routing/router_llm.py builds it>"},
  {"role": "user", "content": "fix the fin widget build"},
  {"role": "assistant", "content": "{\"action\": \"route\", \"session\": \"fin\", \"reason\": \"widget/build vocabulary belongs to the fin session\"}"}
]}
```

- **System** = the eval prompt block (`evals/tmux-routing/prompts/router.md`
  for the router track; the goals-ledger prompt for the monitoring track when
  it merges) plus the per-example context (registry, live sessions), assembled
  by the same code path the eval adapter uses — training and inference must
  see byte-identical framing.
- **User** = the JSON tick / query input.
- **Assistant** = the expected decision JSON, exactly the object the strict
  output contract demands — no prose, no fences.

Sources, per track:

| track | sources |
| --- | --- |
| tmux routing | synthetic paraphrase/typo/misdirection expansions of the taxonomy; `raw/trajectories/` decision records with `rating: 1` (and `rating: -1` pairs relabeled with the corrected decision) |
| feedback elicitation | `raw/feedback/` comment threads (opt-in), templated ask-one-short-question exchanges |
| mission monitoring | goals-ledger tick corpora — **absent until that branch merges**; the builder skips the track gracefully when the corpus directory doesn't exist |

**Leakage rule:** `evals/tmux-routing/scenarios.json` (core + hard) is the
gate, so its literal scenarios are **held out** — they never appear in
`train.jsonl` or `val.jsonl`. Train on generated variants and telemetry;
score on the untouched corpus. A gate that measures memorization measures
nothing.

Every build writes `datasets/<dataset-id>/manifest.json`: source list, example
counts per track, per-split sha256, corpus git commit, build date. The data
hash in a model manifest points here.

## Training

**Recipe: QLoRA.** 4-bit NF4 base (bitsandbytes), LoRA adapters via HF
`peft` + `trl` `SFTTrainer` (r=16, alpha=32, lr 1e-4–2e-4, 2–3 epochs over a
10–50k-example set, seq len 2–4k — the router prompt+registry fits well under
4k). This workload is small: a few GPU-hours per run, not a pretraining bill.

**Base model default: `google/gemma-3-4b-it`** (the ~4B instruction-tuned
Gemma class — swap in the newest same-class checkpoint, e.g. the `gemma-4-e4b`
already scoring 36/51 untuned in `evals/tmux-routing/RESULTS.md`, once its
tokenizer/format is verified against the recipe). **12B (`gemma-3-12b-it`
class) is the documented scale-up** if the 4B plateaus below the gate — same
recipe, bigger runner (48 GB card or high-RAM Apple Silicon).

Runner options:

1. **Local Apple Silicon (mlx-lm) — THE DEFAULT RUNNER** (Levi, 2026-09-05:
   run it on the current iMac if it finishes in "days … a week or two";
   corpus-scale runs finish in hours). Verified hardware: **M4 iMac, 32 GB
   unified, 10 cores** — a 4-bit 4B base + LoRA trains comfortably in 32 GB.
   `mlx_lm.lora` with `--train` on the same chat JSONL. Marginal cost ≈ $0 and
   no launch approval needed since it's not a GPU job in AWS. **Preflight:
   check free disk** — the box had ~9 GB free at last check and a 4B
   base + checkpoints wants ~15 GB (clearing `~/Library/Developer/Xcode/
   DerivedData` usually frees tens of GB); the 12B is disk-blocked locally and
   goes to the cloud runners below. Note honestly: MLX LoRA is not
   bit-identical to the HF QLoRA recipe — whichever runner trains the
   candidate, the **eval gate is the arbiter**, so the difference is measured,
   not assumed.
2. **EC2 g6.xlarge spot** (L4 24 GB) — the default *cloud* runner. 4B QLoRA fits
   easily; 12B fits in 24 GB at 4-bit but is tight at 4k seq — use g6.2xlarge
   or g6e.xlarge (L40S 48 GB) for the 12B.
3. **SageMaker training job** (ml.g6.xlarge) — managed spot, automatic S3
   in/out, at a per-hour markup. Worth it only if runs become frequent enough
   that babysitting spot instances costs more than the markup.

### Cost table (honest estimates)

Assumes a typical run: 4B QLoRA, ~20k examples, 2 epochs ≈ 3–6 GPU-hours.
Rates are us-west-2 estimates in the spirit of the control plane's price note:
**for calibration, not billing truth** — verify current on-demand/spot pricing
before any launch, and spot prices swing.

| runner | rate (est.) | typical 4B run | 12B scale-up run | notes |
| --- | --- | --- | --- | --- |
| Apple Silicon (mlx-lm) | ~$0 marginal | $0, ~6–12 h wall | $0, ~overnight | electricity noise; box is busy meanwhile |
| EC2 g6.xlarge spot | ~$0.25–0.40/hr | **~$1–3** | n/a (24 GB tight) | interruption risk; checkpoint to S3 every N steps |
| EC2 g6.xlarge on-demand | ~$0.80/hr | ~$3–5 | n/a | the fallback when spot churns |
| EC2 g6e.xlarge spot | ~$0.60–0.90/hr | ~$2–5 | **~$4–9** (6–10 h) | L40S 48 GB; the 12B runner |
| SageMaker ml.g6.xlarge (managed spot) | ~$0.4–1.2/hr eff. | ~$2–7 | n/a | + a few min billed setup per job |

S3 storage is noise at this scale (a 4B GGUF ≈ 2.5 GB, a 12B ≈ 7 GB;
raw telemetry is KBs per document and expires at 180 days).

### Hard rule

**No GPU job is ever launched — EC2, SageMaker, or anything else that bills by
the GPU-hour — without an explicit human go from Levi for that specific run.**
Not by an agent, not by a schedule, not "while he's asleep because it's only
$3." Dataset builds, local mlx runs, and evals against an already-running
endpoint need no approval; anything that starts a GPU instance does. This is a
standing rule of this document, senior to the continuous-merge policy.

## Eval gate

A candidate is served on **any OpenAI-compatible endpoint** — LM Studio,
`mlx_lm.server`, vLLM on the training box before teardown — and scored by the
existing adapter, unchanged:

```sh
FIN_ROUTER_BASE_URL=http://<host>:<port>/v1 \
FIN_ROUTER_MODEL=<candidate-id> \
  python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py
```

When the goals-ledger work merges, its equivalent corpus + runner joins the
gate under the same contract (serve candidate, score offline corpus); until
then the gate is the routing corpus alone and this section is the placeholder
for the second bar.

**Promotion rule:** a candidate becomes champion only if it

1. **passes all core scenarios** (the exit-code gate — non-negotiable), and
2. **beats the current champion on core + hard combined** (per
   `evals/tmux-routing/RESULTS.md`, the untuned local champion stands at
   36/51; `models/champion.json` in the bucket is the authoritative record).

Ties don't promote. Every scored run — promoted or not — writes its raw
output to `evals/<model-id>/<run-id>.json` so regressions are diffable.

## Export

For a promoted candidate:

1. **Merge** the LoRA adapter into the base (`peft` `merge_and_unload`, or
   `mlx_lm.fuse` on the MLX path).
2. **Convert to GGUF** (llama.cpp `convert_hf_to_gguf.py`), quantize
   **Q4_K_M** for LM Studio local serving — the same runtime
   `router_llm.py` targets by default, so the shipped artifact is scored in
   the exact serving stack it will run in.
3. **Upload** to `models/<model-id>/` — the GGUF, the unmerged adapter, and
   `manifest.json`:

```json
{
  "modelId": "fin-foreman-4b-2026-09-05a",
  "base": "google/gemma-3-4b-it",
  "recipe": "qlora-r16-a32",
  "dataset": "datasets/<dataset-id>/",
  "dataHash": "sha256:<train.jsonl hash from the dataset manifest>",
  "corpusCommit": "<git sha of evals/ at scoring time>",
  "scores": {"core": "26/26", "hard": "19/25", "overall": "45/51"},
  "quant": "Q4_K_M",
  "createdAt": "2026-09-05T00:00:00Z",
  "promoted": true
}
```

4. **Flip `models/champion.json`** to point at it. The app and the daemon load
   the champion by that pointer, so rollback is rewriting one small JSON
   object to the previous model id.

## Serving roadmap

Two stages, in order (Levi, 2026-09-05):

1. **Now — local LM Studio.** The promoted GGUF serves from LM Studio on
   Levi's own boxes (the exact runtime the eval gate scores against). The fin
   app's existing custom-endpoint agent provider points at it; nothing new to
   build.
2. **Later — hosted endpoint for fin app users**: the promoted model served by
   **vLLM on SageMaker endpoints behind an API gateway**, so app users who
   don't run their own model get the foreman brain as a managed service.
   Auth rides the same bearer-token pattern as the control plane (per-user
   tokens when this goes multi-tenant); the endpoint serves the OpenAI dialect
   so `router_llm.py`, the app's `openAICompatible` provider, and the eval
   gate all work against it unchanged. Standing rule applies: a SageMaker
   endpoint bills per-hour like a GPU job — **no endpoint is created without
   an explicit human go**, and the deployment recipe lands here when stage 2
   starts.

## Fine-tune targets (the curriculum)

The foreman model is tuned for fin's own jobs, each with an eval corpus as
both gate and seed data:

1. **tmux session management** — `evals/tmux-routing/` (live today, the
   current gate).
2. **Mission monitoring / context management** — `evals/goals-ledger/` (the
   heartbeat tick corpus; joins the gate when its runner lands here).
3. **Owner-feedback elicitation** — knowing when and how to ask the factory
   owner for a decision, and when the ledger already answers it.
4. **App tool-use** (Levi, 2026-09-05) — trajectories in the app's OWN tool
   schema (FinAgentCore's tools), centered on **`request_input`**: hitting a
   login wall, a 2FA challenge, or missing credentials means *prompt the
   owner through the app* — never guess, never stall. Ties into the
   cloud-browser + secret-store work: the tool call is what triggers the 2FA
   relay. SFT examples for this track are tool-call transcripts, not
   decision JSON — the dataset builder grows a track per target as each
   corpus lands.

## Curriculum by information

> Levi, 2026-09-06: *"measure the bits of information per example, so that as we
> collect and train on different examples we find the best mix of high value
> examples to allow us to do the fewest training iterations."*

Cross-entropy **is** information. Summing `-log2 p(token)` over an example's
ANSWER tokens — under exactly the mask training uses — gives the number of bits
that example costs the model. That number is the currency of a curriculum.

### The four quantities

| quantity | how | what it means |
| --- | --- | --- |
| `bits_base` | score under the UNTUNED base | what the base does **not** already know. Low ⇒ the base already emits that answer ⇒ the example teaches nothing and only burns iterations. |
| `bits_tuned` | score under a trained adapter | what the candidate still does not know. |
| `learned_bits` | `bits_base - bits_tuned` | the information those iterations actually **bought**. |
| `residual_bits` | `bits_tuned` | genuinely hard **or mislabelled**. In a corpus this templated, noise is the likelier cause — and a mislabel is a bug in `gen_training_data.py`, not a hard example. |

`bits_per_token` normalises away the near-constant JSON scaffold, so a short
high-information answer is not buried under a long one — but note this is what
`--rank-normalize` *offers*, not what the experiment does: `run_bits_experiment.sh`
ranks per-example. On this corpus the within-partition answer-length spread runs
1.00×–1.55× (`tooluse/request_input` 1.55×, `ledger/report` 1.37×), so a 25% cut
under the default partly selects on length. Pass `--rank-normalize` if that
matters more to you than absolute information per example. It divides by the
token count **matching the column in force** — `decision_tokens` under
`--bits-column decision`, `answer_tokens` under `answer`. (It used to divide by
`answer_tokens` either way, so `decision --rank-normalize` ranked gate-field
bits per *whole-answer* token: two examples with identical decision bits then
sorted by the length of their `reason` prose — the exact length bias the flag
exists to remove, upside down.)

### The decision column — and what the gate actually covers

Most of every bits number is spent on prose no arbiter reads. So `score_bits.py`
emits a second column, **`decision_bits`**: the same cross-entropy summed only
over the tokens that spell the fields carrying the **label**.

Those fields are **per track**, because the four tracks do not share an answer
schema. `--decision-fields auto` (the default) resolves them through
`DECISION_FIELDS_BY_TARGET`:

| track | decision fields | rows | share of each answer, by characters |
|---|---|---|---|
| routing | `action`, `session` | 847 | min 11.7% · **median 16.0%** · max 42.6% |
| elicit | `action` | 305 | min 8.5% · **median 10.7%** · max 21.6% |
| ledger | `decision`, `goal_id`, `message_id` | 728 | min 23.7% · **median 41.1%** · max 51.2% |
| tooluse | `tool`, `arguments` | 365 | min 92.5% · **median 96.5%** · max 97.4% |
| **all** | | **2245** | min 8.5% · **median 36.6%** · max 97.4% |

Measured with the shipped `field_spans` over `datasets/mlx/train.jsonl`, merging
overlapping spans, denominator `len(answer)`. tooluse is ~97% because that
track's answer schema is `{tool, arguments}` with no prose field at all — there
the decision column is very nearly the answer column, and honestly so. By
*tokens* the share is smaller for the tracks that do have prose.

**A correction.** An earlier version of this document quoted "9.6%–46.8% of each
answer by characters (median 17.9%)" for a flat `action,session`. That trio does
not reproduce under any interpretation — the shipped code gives 8.5%/16.0%/42.6%
— and, worse, it was a *conditional* distribution presented as a marginal: it
described only the 1152 answers that contain one of those two keys. The other
**1093 (48.7%) — the entire ledger and tooluse tracks — contain neither**, so
their `decision_bits` was `null` and `select_curriculum.py` refused the column
outright at its 20%-missing guard. The flat default could not produce a
curriculum on the only corpus in the tree; the per-track table above covers
**100%** of it.

That failure is now cheap to catch. `--check-decision-coverage` is a pure-stdlib
preflight (no tokenizer, no weights, no GPU, runs while a fine-tune holds the
machine) and it is **stage 0** of the runner, before either scoring stage:

```sh
$V scripts/model-factory/score_bits.py --data datasets/mlx/train.jsonl \
    --out /dev/null --check-decision-coverage 0.95     # exit 3 if short
```

**What the arbiter covers is narrower than either column.**
`evals/tmux-routing` is 51 scenarios whose expected actions are all
`route`/`start`/`clarify`/`refuse`, and `run_evals.py:matches()` compares only
`action` and, when present, `session`. Nothing in it exercises ledger, elicit or
tooluse. By `score_bits.classify` the corpus is routing 847, elicit 305, ledger
728, tooluse 365 — so **1398 of 2245 rows (62.3%) of what the curriculum cuts is
invisible to the gate**, while the selector applies its budget to every partition
alike. A subset that destroys the tooluse track's argument formatting would score
identically on all 51 scenarios. The gate remains the arbiter; it is an arbiter
**of the routing track**, and a stage-5 verdict should be read that way. The
report prints the per-run count under `gate visibility`.

Neither column is automatically right — prose bits still shape the model. The
mapping from JSON field to token span is exact for spans and monotone-decode
tokenizers, and is **verified only against a character-level stub so far**: no
real tokenizer has run yet (see "Nothing above has been run yet").
`decision_bits` is `null`, never `0.0`, when the span cannot be located,
`score_bits` reports how many rows that hit, and `select_curriculum` refuses
`--bits-column decision` when more than 20% of rows lack it — otherwise the
ranking would be on "could this be computed", not on information.

### Running it

```sh
V=scripts/model-factory/.venv/bin/python

# 1. bits_base — the untuned base
$V scripts/model-factory/score_bits.py \
    --model mlx-community/gemma-4-E4B-it-qat-4bit \
    --data datasets/mlx/train.jsonl \
    --max-seq-length 3072 --chunk 512 \
    --out reports/bits-train-base.jsonl

# 2. bits_tuned — the same corpus under a candidate
$V scripts/model-factory/score_bits.py ... \
    --adapter models/candidates/fin-foreman-e4b-mlx \
    --out reports/bits-train-tuned.jsonl

# 3. the curriculum (no GPU, ~2s on 2363 examples)
$V scripts/model-factory/select_curriculum.py \
    --base reports/bits-train-base.jsonl \
    --tuned reports/bits-train-tuned.jsonl \
    --corpus datasets/mlx/train.jsonl \
    --target-fraction 0.25 \
    --out datasets/mlx-bits0.25/train.jsonl \
    --report reports/curriculum-0.25.txt
```

Step 2 prints the adapter it hashed (`--adapter … -> sha256:…`) before it loads
anything. Note that `models/candidates/fin-foreman-e4b-mlx` takes a new
`adapters.safetensors` every 250 iterations: **one `--out` per checkpoint**. A
re-run against that path after the weights changed is refused (exit 2) rather
than resumed — see the adapter digest below.

`scripts/model-factory/run_bits_experiment.sh` wires all of that together plus
the retrain and the gate. It derives its own location from `$0`, so it runs the
code it shipped with; `FIN_DATA_ROOT` (corpora/models) and `FIN_OUT_ROOT`
(reports/datasets it writes) both default to that same checkout, so running it
from a worktree stays in the worktree.

Its stages, default `0 1 2 3 4` (stage 5 needs an explicit go):

| stage | GPU | what it does |
| --- | --- | --- |
| 0 | no | **preflight** — can the chosen bits column be computed at all? Seconds. |
| 1 | yes | `bits_base`, plus **1b-anchor** (mask vs the trainer's own log) and **1c** (chunked-vs-full parity) |
| 2 | yes | `bits_tuned`, plus **2b** parity |
| 3 | no | select the curriculum + the random control arm |
| 4 | no | print the report |
| 5 | yes | retrain all four arms and gate them — the only proof that counts |

Stage 0 exists because its absence was expensive by construction: the runner
defaulted to `--bits-column decision` while the scorer defaulted to a flat
`action,session`, so both multi-hour scoring stages would have completed and
stage 3 would then have refused, producing nothing. `FIN_BITS_COLUMN=answer`
skips the column (and the preflight) entirely.

The two selector invocations in stage 3 are the experiment's honesty, and a test
(`TestExperimentConfiguration`) compares them **flag for flag**, requiring every
difference to be declared in an allow-list. Pinning one flag at a time — which
is what it used to do, for `--jaccard` alone — let any other flag regain a second
confound silently; `--target-fraction 0.5` in one arm and `0.25` in the other
passed the whole suite.

`scripts/model-factory/tests/test_bits_curriculum.py` (stdlib `unittest`, **205
tests, no model, no GPU, no network**, ~0.1s) covers the bits formula, the
masking indices, truncation and exact-fit flagging, the per-track decision mask
and its coverage preflight, the machine guard's actual refusals, both parity
modes (internal and the external anchor) and the relative tolerance with its
absolute floor, the run fingerprint within a file and across the base/tuned pair,
the adapter content digest and the pair's direction rule, the mislabel screen at
scales two orders of magnitude apart, every selector property, and the experiment
script's own configuration. The adapter tests build fixture adapter directories
by hand — plausible bytes in `adapters.safetensors` and a real-shaped
`adapter_config.json` — so the whole content-identity path is exercised with no
`safetensors` library and no weights.

It is mutation-checked. The earlier round broke 24 guards one at a time — wrong
pad id, guard that checks nothing, guard that fails open, pad step at the
exact-fit boundary, decision-span off-by-one, dropped `tools`, missing resume
check, chunked gather assertion removed, re-serializing emitter, `idx` not
advanced past an unscored line, picks keyed by hash, leakage checks removed,
residual floor removed, noise flag disabled, control arm un-clustered, stage-5
baseline removed, vacuous parity pass — and all 24 failed a test. This round
broke a further **21**, one per fix below (per-track fields reverted to the flat
default, `chunk` dropped from the fingerprint, the pair check removed from its
call site, the noise cut reverted to `max(8.0, 4× median)`, `norm_tokens`
reverted to `answer_tokens`, `fmt()` reverted to a raw `:.2f`, the redundancy
denominator reverted to `total`, the section cross-reference reverted to 6, the
dry-run guard removed, the truncation guard removed, the prefix-stability
assertion disabled, the quota switched to `len(members)`, the coverage preflight
made unconditional, the ranked-share and gate-visibility blocks removed, the
anchor's adapter and empty-log guards removed, the skipped-partition record
dropped, the decision column never preferred, the drop list re-sorted by
`bits_base`, the shell guard returned to failing open) — **all 21 fail a test**.
Three of them survived on the first attempt and the tests were rewritten until
they did not; a test that cannot fail is not evidence.

A third round broke **6** more, one per component of the two fixes above
(`run_fingerprint` reverted to path-only adapter identity, the
`check_pair_adapters` call site deleted, the two-digests-in-one-file refusal
deleted, the parity tolerance reverted to an absolute `1e-2`, the `NOT
CALIBRATED` banner deleted, the absolute floor removed) — **all 6 fail a test**,
and the path-only mutation fails it in exactly the shape the review described:
`resuming: 3 already scored / nothing to do`, exit 0, under weights that had
changed underneath.

### Fidelity to training — the part that is easy to get wrong

`score_bits.py` reproduces `mlx_lm`'s tokenization and masking exactly, because
a bits number that does not match the trainer's is not measuring the training:

* **Tokenize through mlx-lm's `TokenizerWrapper`, never the raw HF tokenizer.**
  The wrapper forces `return_dict=False` (transformers 5.x otherwise returns a
  `BatchEncoding` whose `len()` is **2** — the number of dict keys, the classic
  "my prompts are 2 tokens long" bug) and injects `enable_thinking=True`, which
  makes the gemma-4 template emit `<|think|>\n` in the first system turn. Each
  omission shifts every example by ~2 tokens.
* **The offset** is `len(apply_chat_template(messages[:-1], add_generation_prompt=
  messages[-1]["role"] == "assistant"))`, exactly `ChatDataset.process` under
  `--mask-prompt`. The scorer asserts the prefix property (`tokens[:offset] ==
  prompt_tokens`) and refuses to score if it fails.
* **The indices.** `default_loss` keeps target `j ∈ [offset-1, L-1]` of
  `batch[:, 1:]`, i.e. predicted positions `k ∈ [offset, L]` read from rows
  `k-1`. Position `L` is the trailing `<pad>` the batch padder always supplies,
  so the trainer's `ntoks` is **`L - offset + 1`** — one more than the real
  answer. We report the honest `answer_tokens = L - offset` as the primary
  number and `trainer_tokens` alongside it, so the port can be validated against
  a logged loss. A sequence that *fills* the window — truncated **or an exact
  fit at `L == max_seq_length`** — gets no pad column at all, because
  `iterate_batches` caps the batch width at `max_seq_length`; there `ntoks`
  collapses to `L' - offset`. (Nothing in today's corpus hits that boundary; it
  is the one the check exists for.)
* **The calibration check, and its status.** The log side is measured: the live
  run reports `Trained Tokens 127129` at `Iter 3675`, i.e. **34.593 tokens/iter**.
  The corpus side — mean `L - offset + 1` over `train.jsonl` — has **not been
  run**, because it needs the real tokenizer and the machine has been held by
  the fine-tune:

  ```sh
  $V scripts/model-factory/score_bits.py --model mlx-community/gemma-4-E4B-it-qat-4bit \
      --data datasets/mlx/train.jsonl --out /dev/null --dry-run   # mean_trainer_tokens
  ```

  The port is validated when that figure lands near 34.593. Until it does,
  treat the masking port as unconfirmed against the log.

  **`--dry-run` is not GPU-free, and no longer pretends to be.** It loads no
  weights, but reaching mlx-lm's `TokenizerWrapper` means `import mlx_lm`, and
  that import initialises the Metal device. An earlier version skipped the guard
  entirely on the grounds that it "allocates nothing" — making it the one path
  in this branch that touched the Metal runtime unguarded, under exactly the
  condition the standing machine rule was written for. It now takes the
  **process half** of the guard (no `mlx_lm lora`/`server`/`fuse`/`generate` may
  be live) and skips only the free-memory half, which it genuinely does not
  need. So this command **waits for the fine-tune to finish** like everything
  else; it is a one-minute tokenizer pass, not a GPU job.
* **Truncation is flagged, never silent.** An example whose ANSWER is cut by
  `--max-seq-length` gets `truncated: true` and its bits are a lower bound; one
  whose prompt alone fills the window is `skipped`, not scored as zero. Whether
  anything in today's corpus truncates at 3072 is **not known**: that is a token
  count and the corpus has never been tokenized (same reason as above). The
  longest example is 11012 *characters*, which at 3.5–4 chars/token **estimates**
  ~2750–3150 tokens — i.e. near enough to 3072 that it could go either way. The
  `--dry-run` above answers it; until then this is an estimate, not a measurement.
* **Comparing to logged loss:** the TRAIN loss line is an unweighted mean of
  per-batch per-token means; VALIDATION is token-weighted. The summary's
  `trainer_parity_loss_nats` is token-weighted, so compare it to validation.

The scorer **refuses to run** while `mlx_lm lora`/`server`/`fuse`/`generate` is
alive or free memory is under 10 GB, and it **fails closed**: if `pgrep` or
`vm_stat` cannot be read, the machine state is *unknown*, not *idle*, and the
run is refused unless `--allow-unverified-machine`. (The shell `guard()` in
`run_bits_experiment.sh` now fails closed the same way: `pgrep` exits 1 for "no
match" but 2 or 3 for a usage or fatal error, and the old `if pgrep …; then`
sent every non-zero code down the same branch, so an unreadable process table
read as "nothing is running".) It is resumable (skips hashes already in `--out`,
`fsync` per row) and deterministic.

**The run fingerprint, and the two places it is enforced.** Every row carries
`model`, `adapter`, `adapter_digest`, `max_seq_length`, `match_trainer`,
`full_forward` and `chunk`.

* *Within* one file, on resume: a resume **refuses** when the existing rows were
  scored under different settings, so one forgotten `--out` cannot splice two
  incommensurable runs into one file. `chunk` is part of that set — it is a
  forward-path parameter, not a performance knob, because different prefill
  boundaries mean different matmul shapes and, on a sliding-window architecture,
  different rotating-cache eviction points. (It is recorded as `null` under
  `--full-forward`, where the prompt is never split and the flag has no effect,
  so the fingerprint names the path actually taken.)
* *Across* the `--base`/`--tuned` pair — **which is where the subtraction
  happens, and where nothing was checking.** `learned_bits = bits_base −
  bits_tuned` is only "information the run acquired" if both sides saw the same
  model, window and forward path; score the base at `--max-seq-length 3072` and
  the tuned adapter at 2048 and every example truncated under one but not the
  other contributes a fabricated `learned_bits`, to the **default** ranking key,
  silently. `select_curriculum.py` compares the two files' fingerprints and
  refuses on a mismatch (`--allow-fingerprint-mismatch` to override). The two
  adapter fields are excluded from that comparison: they are the ones that must
  **differ**, and they get their own rule, below.

**The adapter is identified by its CONTENT (`adapter_digest`), not by its path.**
A path is not an identity. `models/candidates/fin-foreman-e4b-mlx/adapters.safetensors`
is rewritten every 250 iterations, and the checkpoint-staging recipe in
`run_bits_experiment.sh` deliberately copies checkpoints over one reused
directory. Identifying the adapter as `str(Path(args.adapter).resolve())` — which
is all it used to be — therefore says nothing about which weights produced a row:
score under checkpoint 3000, take a kill at row 1200, let checkpoint 3500 land on
the same path, re-run the same command, and every recorded key still matched. The
resume passed, the rest of the corpus was appended under different weights, and
one score file held two models under one name.

* **What it is.** A streaming SHA-256 over the two files `mlx_lm` actually loads
  out of an adapter directory — `adapters.safetensors` and `adapter_config.json`
  (rank, scale and which layers change the forward pass as surely as the weights
  do) — mixed with each file's name and size in a fixed order, and recorded as
  `sha256:…`. Deterministic and path-independent by construction: one checkpoint
  staged at two paths digests the same, two checkpoints staged at one path do
  not. **Cost: ~14 ms** on this repo's real 27,683,964-byte adapter, once per
  run, before the guard and before any weights load — so a malformed `--adapter`
  directory is refused there rather than three GPU-minutes later. (Full hashing,
  not a `size+mtime` shortcut: `touch` changes mtime without changing weights,
  `cp -p` changes weights without changing mtime, and consecutive LoRA
  checkpoints are byte-identical in size — size+mtime is precisely the
  discriminator this hazard defeats.)
* **Operator-visible consequences.** Re-running with the same command against a
  path whose weights have changed is now **refused** (exit 2) instead of resumed;
  point `--out` at a new file per checkpoint, which is what the staging recipe
  already tells you to do. A **tuned** score file written before this existed has
  no digest and cannot be resumed — re-score it. A **base** file has no adapter,
  so "recorded no digest" and "has no digest" are the same state and old base
  files still resume; the expensive half is not invalidated.
* **The pair's direction rule** (`check_pair_adapters`). "Allowed to differ" had
  quietly become "never looked at", and a pair that does *not* differ is exactly
  as broken as one that differs in the wrong field: two untuned runs make
  `learned_bits` identically zero and the default ranking a coin flip. So the
  **direction** is asserted, not just the difference — the `--base` file must
  carry no adapter and no digest, the `--tuned` file must carry both — and these
  are refused: both sides carrying the same digest (one checkpoint subtracted
  from itself, under two paths, which nothing keyed on the path could see), a
  base file that carries an adapter, a tuned file that carries none, a tuned file
  that names an adapter but records no digest, and a pair where neither file
  records the fields at all. `--allow-fingerprint-mismatch` waives it, loudly.
  `select_curriculum.py` also refuses a single file holding two different
  digests, however it came to (a hand-concatenation, a restored backup).

**The parity tolerance is RELATIVE, and its default is not yet a gate.** The
internal check (`parity_check.py CHUNKED.jsonl FULLFWD.jsonl`, stages 1c and 2b)
compares an un-cached single forward against a chunked prefill through a rotating
KV cache on a 4-bit-quantised model — two different sequences of floating-point
operations over the same mathematics, which `score_bits.py`'s own comments concede
disagree numerically. Some divergence is *expected*; the check's job is to
separate it from a chunked path assembling the wrong rows.

It used to enforce `TOLERANCE = 1e-2` as an **absolute** bound on a per-example
**sum** of bits, and hard-gate the pipeline on it. At this corpus's scale that is
~8e-5 relative:

    Iter 1: Val loss 2.463 nats/token   ×   127129/3675 = 34.6 unmasked tokens/step
      = 85.2 nats = ~123 bits per example        (from the live train.log)

A per-token disagreement of 1e-3 nats — unremarkable for this arithmetic — sums to
0.05 bits, **five times** the old bound. The check was likelier to fail on float
noise than on a bug, and a check that cries wolf on its first honest run gets
loosened by whoever is holding the pipeline at 2am. The rule now:

    error(h) = |chunked[h] − full[h]| / max(|full[h]|, --abs-floor)

Relative, because the quantity spans orders of magnitude (a base example is ~10²
bits; a memorized tuned example is ~10⁻²) and one absolute bound cannot be right
for both. Floored at 1 bit, because below that the model is essentially certain
and a ratio stops carrying information.

**Calibration status: AWAITING CALIBRATION — no GPU parity run has ever been made
against this code**, so nobody knows what these two paths actually agree to, and
no number here is a measured bound. Rather than invent one, `--tolerance` now
defaults to *unset*: the check enforces only a deliberately coarse `5e-2` relative
ceiling — an order-of-magnitude argument that resolves a chunked path wrong in
**kind** (rows off by one, the wrong cache, the prompt scored as the answer), not
one off by a little — reports the observed **max relative divergence**
prominently, and prints a `NOT CALIBRATED` banner *on a pass*, because an
uncalibrated pass is the one that gets mistaken for a validated one.

**What an operator must do:** run stage 1c or 2b once, read the reported "max
relative divergence", and add `--tolerance <a small multiple of it>` to **both**
`parity_check.py` invocations in `run_bits_experiment.sh`. Until that is done, a
pass from those stages means "not wrong in kind", not "validated to a stated
precision", and the script's comments say so at both call sites.

### Honest caveats

* **Bits are a property of the PAIR (example, model), not of the data alone.**
  A different base — or the same base after any training — reorders the list.
  Re-score when the base changes; never treat a stale bits file as ground truth.
* **A low-bits example is not worthless.** It may be the only thing holding a
  behaviour in place. Dropping the whole low-bits mass can cause forgetting that
  shows up only in the gate, which is exactly why the gate is the arbiter.
* **High bits can mean a BUG, not value.** This is the ranking's own failure
  mode and it points the opposite way from the caveat above. A mislabel from
  `gen_training_data.py` makes the base maximally surprised, so it *maximises*
  `bits_base` — and once training has driven `bits_tuned` to ~0 for everything,
  `learned_bits ≈ bits_base` too, so **both** information rankings put a mislabel
  first in its class and a small budget concentrates label noise rather than
  diluting it. `select_curriculum.py` flags examples whose bits exceed
  **`median + --noise-z × 1.4826 × MAD` of their own `(target, decision_class)`**,
  reports how many of them the subset kept and by what enrichment factor, and
  warns on stderr past 1.25×.

  That cut is **scale-free, and it had to become so.** The previous rule was
  `max(--noise-floor 8.0 bits, --noise-factor 4.0 × the class median)`,
  calibrated against a unit-test fixture whose clean class sits at ~6.5 bits. The
  real scale is two orders of magnitude larger — the log's `Iter 1: Val loss
  2.463` at 34.593 trained tokens per example puts a typical whole-answer example
  near ~123 bits under the base — so that rule cut at ~492 bits while a wrong
  decision token adds roughly 10. It could not fire on this corpus, and the
  absolute 8.0 floor was inert by three orders of magnitude: section 5 would have
  printed "none" on a corpus that does contain mislabels, and `--noise-policy
  cap`/`exclude` were levers no one would ever be told to pull. `--noise-floor`
  now defaults to **0.0 (off)**, because an absolute bits floor is only
  meaningful once a run has measured what a bit is worth in the column in force.

  Two further changes follow from the same arithmetic. The screen now runs on
  **`decision_bits` when every scored row has one**, because a mislabel is ~10
  bits against a whole-answer class spread of *tens* — mostly prose length — and
  in the decision column it is most of the signal. And section 5 now prints the
  **per-partition median, MAD, cut and which term bound it**, plus any partition
  too small to screen at all (`--noise-min-n`, default 8), so that "none flagged"
  reads as *"nothing reached these thresholds"* rather than as an all-clear.
  **Its power is still unmeasured**: whether it fires on the mislabels actually
  present needs a real bits distribution, i.e. stage 1, which has not run.

  Default policy is `flag` (report only); `--noise-policy cap` keeps them but
  stops them out-ranking clean examples; `exclude` leaves them out with a reason
  recorded. Under `exclude` the excluded rows never enter a cluster, so the
  redundancy headline divides by the **clustered** count, not by every scored row
  — otherwise each excluded row counted as its own redundancy and the headline
  contradicted the per-partition table in the same report. **No bits number can
  tell a hard example from a wrong one** — only reading the flagged examples can.
* **The redundancy estimate is SURFACE redundancy.** Word 3-gram Jaccard cannot
  see two examples that teach the same rule in disjoint vocabulary, and it could
  over-merge two examples that differ only in the token that flips the label —
  so clustering is confined to a single `(target, decision_class)` partition,
  making that second failure impossible *across* labels. Single-linkage also
  chains (A~B, B~C ⇒ one cluster), which under-counts clusters and therefore
  over-states redundancy: the conservative direction for a keep decision. And it
  is threshold-dependent, so the report prints a curve rather than one number.
* **The loose end of that curve is mostly label scaffold.** `--cluster-on both`
  (the default) concatenates the assistant answer, which inside one
  `(target, decision_class)` is near-constant JSON — the same artifact the code
  excludes the *system* prompt to avoid. Measured on the corpus the pipeline
  actually selects from, `datasets/mlx/train.jsonl` (2245 rows): the 0.80
  headline is robust (**1735** clusters with the answer, **1757** on user text
  alone), but the loose end is not: at 0.70, **1283 vs 1661**; at 0.50, **122 vs
  805**. Read a low threshold as shared scaffold, not as shared input.
  (`select_curriculum.py`'s own LIMITS block used to hardcode the 2363-row
  figures — 1817 / 1335 / 121 — into a report computed on the 2245-row file, so
  every report contradicted its own section 2. It now names the corpus those
  figures belong to.)
* **High residual does not mean "drop it".** It is reported and never
  auto-dropped: deleting genuinely hard cases is how a curriculum quietly
  removes the thing the gate measures. The report's residual section also has an
  absolute floor, so it stays silent rather than accusing eight innocent
  examples of being mislabels when every residual is ~0.001 bits — which is
  exactly the regime a memorised corpus produces.
* **The leakage rule outranks every number here.** Selection must never touch
  `evals/tmux-routing/` or `evals/goals-ledger/`; `select_curriculum.py` refuses
  a `--corpus` under `evals/` outright, **and** refuses one whose examples
  appear in a sibling `valid.jsonl`. That second check is not hypothetical:
  `datasets/sft-train-2026-09-05.jsonl` (2363) is exactly
  `datasets/mlx/train.jsonl` (2245) ∪ `datasets/mlx/valid.jsonl` (118), verified
  by content hash with zero train/valid overlap — so selecting from the file the
  directive names would train on the yardstick the experiment's arms share.
* **Bits never certify a model.** They choose a curriculum. `eval_gate.py` says
  whether the choice was right.

### The experiment that proves the value

Hypothesis (strong prior, not yet tested): the corpus carries far fewer bits
than it has examples, so a small subset reaches the same gate score in a fraction
of the iterations.

What the training log actually supports, parsed from
`models/candidates/fin-foreman-e4b-mlx/train.log` (152 reported train points):
**validation loss has sat at 0.005–0.013 since iteration 2000** (0.005 / 0.013 /
0.009 / 0.012 at iters 2000–3500; from iteration 1000 the honest range is
0.005–0.028, because iteration 1500 reads 0.028). An earlier draft of this
paragraph said "0.005–0.013 since iteration 1000" while listing the 0.028 that
contradicts it two clauses later — the enumeration was right and the summary was
not. The train
loss did **not** "hit 0.000 and stay there": it touched 0.000 exactly twice
(iters 2675 and 2925) and kept bouncing, averaging 0.041 over iterations ≥ 2900
with a maximum of 0.322. The direction of the claim survives — the corpus is easy
for the model late in training, which the independent redundancy measurement also
supports — but stating it as "train loss hit 0.000 by ~2900" overstates the
evidence, and it is the number a reader would cite when deciding whether this is
worth GPU hours.

1. Score the corpus under the base and under the final adapter.
2. Select a subset at `--target-fraction 0.25`, and a **random control arm** of
   the same size, the same class proportions and **the same clustering
   threshold** (`--rank-by random`, same `--jaccard`). Only the ranking may
   differ: an earlier version turned clustering off in the control alone, which
   moves 10–18% of the 563 picks (measured on the real corpus with stub scores —
   real bits do not exist yet — the exact figure depending on the score
   distribution). A gate win would then have been attributable to deduplication
   or to bits with no way to separate them, which is the one inference the
   control exists to support.
3. Retrain each arm for the SAME NUMBER OF EPOCHS (so `iters = 2 × |subset|`,
   vs the live run's 4490 = 2 epochs of 2245), all other flags identical.
4. Add the arm that can kill the claim: **the full corpus at the subset's
   iteration count**. Without it, "the subset ties 4490 iterations at 1126" is
   satisfiable by early stopping alone — val loss is already 0.005–0.013 from
   iteration 2000 — and every arm ties while selection did nothing. It is also
   the direct competitor: at identical compute it sees 1126 *distinct* examples
   once where the subset arms see 563 examples twice, and more diversity per
   iteration is precisely the hypothesis's rival.
5. Gate all four through `eval_gate.py` against the re-recorded champion.
   (`gate_sweep.sh` is the fuse+serve+score wrapper; it lands with the
   gate-sweep branch and is **not in this checkout**, so `eval_gate.py` against
   whatever is serving is the portable instruction.)

**The metric is gate score per iteration.** The claim is proved only if the bits
subset ties or beats the full corpus's gate score at strictly fewer iterations,
**and** beats the random control, **and** beats the full corpus trained for the
same reduced iterations. It is disproved if the subset gates worse; if random
matches it (the redundancy was real but bits added nothing over counting); or if
the truncated full-corpus run matches it (the saving was early stopping, not
curriculum). Write down whichever happens; a negative result honestly reported is
a good result.

**How big a difference counts.** The gate is 51 binary scenarios, so **one
scenario is 2.0 points**, and LoRA seed-to-seed variance on it has never been
measured. Four single runs compared against each other can therefore produce a
confident PROVED from noise: 46/51 vs 45/51 is one scenario. So each arm needs
**≥ 3 seeds** (17, 18, 19); arm A's spread across its seeds is the noise floor
*S*; and "B beats C" means `median(B) − median(C) > max(S, 2 scenarios)`, with
"ties" defined the same way rather than left to the reader. Report every
individual score. If the arms overlap, the honest finding is "no measurable
difference at this sample size" — which is a result.

**And the verdict is a verdict on routing.** `evals/tmux-routing` exercises the
routing track only; 1398 of 2245 training examples (62.3%) are in tracks it never
touches (see [the decision column](#the-decision-column--and-what-the-gate-actually-covers)).
A subset that wrecks tooluse formatting gates identically. Either hold out a
per-track check, or state plainly that three of the four tracks are unmeasured.

**No bits number above has been produced yet.** All of this was written
2026-09-06 while a fine-tune held ~15 GB of the machine, and every GPU stage
refuses to start until that is clear. What that leaves unvalidated, precisely:

* **The masking port is unconfirmed against the training log.** Two checks now
  exist for it and neither has run. `--dry-run` gives the token-count
  calibration (mean `trainer_tokens` vs the log's 34.593/iter) — and it is *not*
  runnable right now, because it imports mlx_lm and therefore takes the process
  guard; it waits for the fine-tune like everything else.
* **The external anchor has never run.** `parity_check.py --anchor
  reports/bits-valid-base.jsonl.meta.json --log …/train.log --iter 1` compares
  the scorer's token-weighted loss on `valid.jsonl` against the trainer's own
  `Iter 1: Val loss 2.463` — the untuned base's loss under the trainer's mask,
  recorded before the first step. This replaces a check that was **vacuous**:
  the old stage 2c compared the *tuned* run's residual on the memorized train
  split against the *tail* of the log, two numbers that are both ~0.01 whether
  the mask is right or wrong. At 2.463 nats/token there is dynamic range. Its
  resolution is limited — the log's figure is a `--val-batches 25` sample of the
  118-example split, so it catches a mask wrong in **kind** (prompt scored as
  answer), not one off by a single token, and it says so in its own output.
* **The chunked-vs-full-forward parity check has never run** (stages 1c / 2b),
  **and its tolerance is therefore uncalibrated.** It is now a *relative* bound
  with an absolute floor rather than the old absolute `1e-2` bits (which was
  ~8e-5 relative at this corpus's scale, tighter than the arithmetic can
  support), but no number in it is measured. Until a real run reports its "max
  relative divergence" and an operator sets `--tolerance` from it, these stages
  resolve a forward path wrong in **kind**, not one off by a little — the check
  prints `NOT CALIBRATED` on its own passes so this cannot be forgotten.
* **The decision-field mask has been verified only against a character-level
  stub tokenizer**, never a real one.
* **The mislabel screen's power is unknown.** The cut is now scale-free, so
  unlike the threshold it replaced it *can* fire; whether it fires on the
  mislabels actually present needs the real distribution.

Those are real limitations, not oversights — they are unfixable without the GPU,
and nothing downstream should be trusted until stages 1–2 have run and 1b-anchor,
1c and 2b all pass.

What HAS been measured is the redundancy estimate, which needs only text. On
**`datasets/mlx/train.jsonl` (2245 — the corpus the experiment actually selects
from)** at Jaccard 0.80 it collapses to **1735 clusters, 22.7% surface
redundancy**, very unevenly:

| partition | n | clusters | redundancy |
| --- | --- | --- | --- |
| `ledger/ingest` | 169 | 31 | 81.7% |
| `ledger/clarify` | 154 | 47 | 69.5% |
| `routing/refuse` | 187 | 80 | 57.2% |
| `ledger/report` | 134 | 59 | 56.0% |
| `ledger/drive` | 166 | 122 | 26.5% |
| `routing/start` | 223 | 188 | 15.7% |
| `ledger/idle` | 105 | 101 | 3.8% |
| `routing/route`, `routing/clarify`, all `elicit`, all `tooluse` | 1107 | 1107 | **0.0%** |

Loosening the threshold collapses it fast (0.70 → 1283 clusters, 0.60 → 518,
0.50 → 122) — but see the caveat above: below 0.80 that is mostly shared label
scaffold, since `--cluster-on both` includes the near-constant answer. On user
text alone the same corpus gives 1757 clusters at 0.80 and only 1661 at 0.70.

(The 2363-example `sft-train-2026-09-05.jsonl` gives 1817 clusters / 23.1% at
0.80 — the figure quoted in earlier drafts. Same conclusion, different corpus:
that file is train **plus** valid, and the pipeline selects from the train split
alone.)

Note what this already says **against** the hypothesis: **one representative per
cluster at 0.80 still needs 77.3% of the corpus**, so a 25% budget is decided by
the *ranking*, not by deduplication — which is precisely what the bits numbers
are for, precisely why the random control must cluster identically, and
precisely why only the gate can settle it.

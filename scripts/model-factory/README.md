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

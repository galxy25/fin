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
matters more to you than absolute information per example.

### What the gate actually reads — and why there are two bits columns

`evals/tmux-routing/run_evals.py:matches()` compares `expected["action"]` and,
when present, `expected["session"]`. It never reads `reason`, `question`, or any
other prose. Summed over the whole assistant turn, most of every bits number is
therefore spent on text the arbiter ignores: measured on `datasets/mlx/train.jsonl`,
the gate-scored fields are **9.6%–46.8% of each answer by characters (median
17.9%)** — and less by tokens, because the decisive value is usually one token
while the prose is many.

So `score_bits.py` emits a second column, **`decision_bits`**: the same
cross-entropy summed only over the tokens spelling `--decision-fields`
(`action,session` by default). `select_curriculum.py --bits-column decision`
ranks on it, and `run_bits_experiment.sh` uses it by default
(`FIN_BITS_COLUMN=answer` switches back).

Neither column is automatically right — prose bits still shape the model — but a
curriculum built to move the gate has the better claim on the second. The mapping
from JSON field to token span is exact for spans and monotone-decode tokenizers,
and is **verified only against a character-level stub so far**: no real
tokenizer has run yet (see "Nothing above has been run yet"). `decision_bits` is
`null`, never `0.0`, when the span cannot be located, `score_bits` reports how
many rows that hit, and `select_curriculum` refuses `--bits-column decision`
when more than 20% of rows lack it — otherwise the ranking would be on "could
this be computed", not on information.

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

`scripts/model-factory/run_bits_experiment.sh` wires all of that together plus
the retrain and the gate. It derives its own location from `$0`, so it runs the
code it shipped with; `FIN_DATA_ROOT` (corpora/models) and `FIN_OUT_ROOT`
(reports/datasets it writes) both default to that same checkout, so running it
from a worktree stays in the worktree.

`scripts/model-factory/tests/test_bits_curriculum.py` (stdlib `unittest`, **110
tests, no model, no GPU, no network**, ~0.1s) covers the bits formula, the
masking indices, truncation and exact-fit flagging, the decision-field mask, the
machine guard's actual refusals, the parity gate, every selector property, and
the experiment script's own configuration. It is mutation-checked: 24 deliberate
breaks — wrong pad id, guard that checks nothing, guard that fails open, pad
step at the exact-fit boundary, decision-span off-by-one, dropped `tools`,
missing resume check, chunked gather assertion removed, re-serializing emitter,
`idx` not advanced past an unscored line, picks keyed by hash, leakage checks
removed, residual floor removed, noise flag disabled, control arm un-clustered,
stage-5 baseline removed, vacuous parity pass — and all 24 fail a test.

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
  the fine-tune. `--dry-run` now prints it and deliberately skips the GPU guard
  (it loads no weights), so the check is a command rather than a claim:

  ```sh
  $V scripts/model-factory/score_bits.py --model mlx-community/gemma-4-E4B-it-qat-4bit \
      --data datasets/mlx/train.jsonl --out /dev/null --dry-run   # mean_trainer_tokens
  ```

  The port is validated when that figure lands near 34.593. Until it does,
  treat the masking port as unconfirmed against the log.
* **Truncation is flagged, never silent.** An example whose ANSWER is cut by
  `--max-seq-length` gets `truncated: true` and its bits are a lower bound; one
  whose prompt alone fills the window is `skipped`, not scored as zero. (For the
  2026-09-05 corpus max length is 2826, so nothing truncates at 3072 — the check
  exists for the next corpus.)
* **Comparing to logged loss:** the TRAIN loss line is an unweighted mean of
  per-batch per-token means; VALIDATION is token-weighted. The summary's
  `trainer_parity_loss_nats` is token-weighted, so compare it to validation.

The scorer **refuses to run** while `mlx_lm lora`/`server`/`fuse`/`generate` is
alive or free memory is under 10 GB, and it **fails closed**: if `pgrep` or
`vm_stat` cannot be read, the machine state is *unknown*, not *idle*, and the
run is refused unless `--allow-unverified-machine`. It is resumable (skips
hashes already in `--out`, `fsync` per row) and deterministic — and a resume
**refuses** when the existing rows were scored under a different model, adapter,
`--max-seq-length` or forward path, so one forgotten `--out` cannot splice two
incommensurable runs into one file.

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
  `max(--noise-floor, --noise-factor × their class median)`, reports how many of
  them the subset kept and by what enrichment factor, and warns on stderr past
  1.25×. Default policy is `flag` (report only); `--noise-policy cap` keeps them
  but stops them out-ranking clean examples; `exclude` leaves them out with a
  reason recorded. **No bits number can tell a hard example from a wrong one** —
  only reading the flagged examples can.
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
  excludes the *system* prompt to avoid. The 0.80 headline is robust (1817
  clusters with the answer, 1840 on user text alone), but the loose end is not:
  at 0.70, 1335 vs 1733; at 0.50, 121 vs 834. Read a low threshold as shared
  scaffold, not as shared input.
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
**validation loss has sat at 0.005–0.013 since iteration 1000** (0.013 / 0.028 /
0.005 / 0.013 / 0.009 / 0.012 at iters 1000–3500) — that half is solid. The train
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

**No bits number above has been produced yet.** All of this was written
2026-09-06 while a fine-tune held ~15 GB of the machine, and every GPU stage
refuses to start until that is clear. Consequently: the masking port is
unvalidated against the training log (see the `--dry-run` check above), the
chunked-vs-full-forward parity check has never run, and the decision-field mask
has been verified only against a character-level stub tokenizer. Those are real
limitations, not oversights — they are unfixable without the GPU, and nothing
downstream should be trusted until stages 1–2 have run and stage 2b passes.

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

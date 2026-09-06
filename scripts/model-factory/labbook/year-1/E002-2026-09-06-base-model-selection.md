---
id: E002
date: 2026-09-06
occurred: 2026-09-05
kind: EXPERIMENT
title: Base-model selection — gemma-3-4b chosen, smoke-trained, and dropped for gemma-4-E4B
status: closed
tags: [base-model, negative-result, mlx]
sources:
  - "transcript 96d4ea32-4134-4277-824b-975f32754df7.jsonl @ 2026-09-06T03:06:27.301Z = 2026-09-05 20:06:27 PDT — Levi, verbatim"
  - "~/.cache/huggingface/hub/.locks/models--mlx-community--gemma-3-4b-it-4bit/ — 14 zero-byte locks, all mtime 2026-09-05 19:28 (the blobs are gone)"
  - "~/.cache/huggingface/hub/.locks/models--mlx-community--gemma-4-E4B-it-qat-4bit/ — mtime 2026-09-05 20:06"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/launch-train.sh (header states the reason)"
  - scripts/model-factory/train/qlora_config.yaml:7 — still names google/gemma-3-4b-it
  - "memory note foreman-finetune-state"
related: [E003, E004, O005]
corrects: []
superseded-by: null
---

## Question

Which base model does the foreman candidate fine-tune from?

## What happened

The first answer was **`mlx-community/gemma-3-4b-it-4bit`** — a ~4B, 4-bit,
34-layer MLX build, 3.2 GB on disk. It was downloaded at **2026-09-05 19:28**
and used for the smoke trains in E003.

It was chosen by an agent, not by a measurement. The record in the memory note
`foreman-finetune-state` is explicit that the gemma-3-4b pick was "the previous
smoke agent's substitution (it never probed gemma-4 builds)". The committed
recipe `scripts/model-factory/train/qlora_config.yaml:7` still names
`google/gemma-3-4b-it` today, along with an `output_dir` of
`models/candidates/fin-foreman-4b` that was never created.

It was undone by one question from Levi: *"why gemma 3 and not gemma 4?"*
followed at **2026-09-05 20:06:27 PDT** by:

> *"good and cleanup the gemma3 model, that was so last year"*

## The reason the replacement is right

Recorded in the header of `launch-train.sh`, written nine minutes later:

> *"the gemma-4 E4B QAT 4-bit MLX base — same family as the served champion
> (`google/gemma-4-e4b`) and the cloud brain (`gemma-4-12b-qat`): train on the
> architecture we serve (Levi, 2026-09-05)."*

That is the principle worth carrying forward: **the base model should be the
family that is actually served**, because the champion number the candidate has
to beat (P001) is that family's own score, and because the serving stack — LM
Studio, the same quantization lineage — is already proven on it. A base picked
for convenience creates a candidate whose promotion is measured against a
stranger.

## Cost of the reversal

| item | value | source |
| --- | --- | --- |
| gemma-3-4b download wasted | 3.2 GB | `du -sh` recorded in the session transcript |
| smoke runs performed on the wrong base | 2 (E003) | memory note `foreman-finetune-state` |
| elapsed from Levi's question to the new run starting | ~9 min (20:06 → 20:15:29) | lock-dir mtime; `train.log:1` |
| stale references left in the repo | `train/qlora_config.yaml`, `train/README-local.md`, `README.md` "Base model default" section | grep |

The replacement base: **`mlx-community/gemma-4-E4B-it-qat-4bit`**, snapshot
`0f35c6f6d386f7f74e628bd7c6526ce531212300`, **6.4 GB**, 2 safetensors shards,
text config 42 layers / hidden 2560 / vocab 262144, QAT 4-bit with 8-bit MLPs.
`mlx-lm 0.31.3` has `gemma4.py`, so it trains without a patch. Its chat
template has a real system turn (`<|turn>system`), which matters for anything
that tokenizes the corpus outside the trainer (H001).

## The forensic detail worth keeping

The gemma-3 blobs are deleted but
`~/.cache/huggingface/hub/.locks/models--mlx-community--gemma-3-4b-it-4bit/`
still holds **14 zero-byte lock files, all stamped 2026-09-05 19:28**. The
hub cache itself now contains only the E4B model and
`models--Systran--faster-whisper-small`. The lock directory is the only
surviving proof the download happened. If someone cleans it, this entry is the
record.

## What this does not show

- **No measurement compared the two bases.** gemma-3-4b was never scored on
  `evals/tmux-routing` and never trained to completion. The switch is justified
  by the serving-family argument, not by a head-to-head. It is entirely
  possible that a gemma-3-4b LoRA would gate better; nobody knows.
- **The decision is unrecorded in the repo.** It lives in a chat transcript, a
  script header comment and a memory note. `qlora_config.yaml` still contradicts
  it in committed code (O005 covers the wider docs drift).

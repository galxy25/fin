# Local fine-tune on Apple Silicon (mlx-lm)

The zero-dollar alternative to the GPU runners in the README cost table: MLX
LoRA on an M-series box (64 GB+ handles the 4B comfortably, the 12B
tolerably). No cloud instance starts, so the standing no-GPU-without-human-go
rule does not gate it — but it still trains a candidate, so the eval gate
(`../eval_gate.py`) remains the only path to promotion.

**Honesty note (from the README):** MLX LoRA is not bit-identical to the HF
QLoRA recipe (`qlora_config.yaml`). Whichever runner trains the candidate,
the eval gate is the arbiter — the difference is measured, not assumed.

## Setup

```sh
pip install mlx-lm
```

## Train

`mlx_lm.lora` consumes the same chat-format JSONL `build_dataset.py` emits,
but expects a data *directory* containing `train.jsonl` / `valid.jsonl`:

```sh
mkdir -p /tmp/fin-sft-data
# ~95/5 split; datasets are small enough that head/tail is fine for now
DATASET=datasets/sft-$(date +%F).jsonl
N=$(wc -l < "$DATASET"); V=$(( N / 20 + 1 ))
head -n $(( N - V )) "$DATASET" > /tmp/fin-sft-data/train.jsonl
tail -n $V           "$DATASET" > /tmp/fin-sft-data/valid.jsonl

python3 -m mlx_lm.lora \
  --model mlx-community/gemma-3-4b-it-4bit \
  --train \
  --data /tmp/fin-sft-data \
  --batch-size 2 \
  --num-layers 16 \
  --iters 600 \
  --learning-rate 1e-4 \
  --adapter-path models/candidates/fin-foreman-4b-mlx
```

Mirror `qlora_config.yaml` where the knobs line up (lr, effective batch);
`--iters` replaces epochs (iters ~= examples * epochs / batch-size).

## Serve the candidate for the eval gate

```sh
python3 -m mlx_lm.server \
  --model mlx-community/gemma-3-4b-it-4bit \
  --adapter-path models/candidates/fin-foreman-4b-mlx \
  --port 8080
```

Then score it:

```sh
python3 scripts/model-factory/eval_gate.py \
  --base-url http://localhost:8080/v1 \
  --model fin-foreman-4b-mlx
```

(LM Studio can also serve the fused model directly once exported to GGUF.)

## Fuse + export (promoted candidates only)

```sh
python3 -m mlx_lm.fuse \
  --model mlx-community/gemma-3-4b-it-4bit \
  --adapter-path models/candidates/fin-foreman-4b-mlx \
  --save-path models/candidates/fin-foreman-4b-fused
```

Then GGUF-convert + Q4_K_M quantize per the README "Export" section
(llama.cpp `convert_hf_to_gguf.py`), upload to `models/<model-id>/`, and flip
`models/champion.json` only after the gate promotes.

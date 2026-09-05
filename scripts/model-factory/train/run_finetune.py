#!/usr/bin/env python3
"""QLoRA fine-tune runner for the fin foreman model (HF peft + trl).

Two modes:

--dry-run (default-safe, PURE PYTHON):
    Validates the config and the dataset schema and prints an estimated
    token-length histogram — WITHOUT importing torch/transformers and
    without downloading a single weight or tokenizer file. Token counts are
    the chars/4 heuristic (documented, deliberately tokenizer-free); treat
    them as +/-30%. Exits 0 iff everything validates.

real mode (no --dry-run):
    Prints the run plan + honest cost estimate, then REFUSES to proceed
    unless the environment carries FIN_FACTORY_GO=1. That is the standing
    hard rule from scripts/model-factory/README.md: no GPU spend without an
    explicit human go for that specific run. This script never launches
    cloud instances itself — running it on a GPU box (or an Apple Silicon
    box via the mlx path, see README-local.md) is the human's action.

Usage:
  python3 scripts/model-factory/train/run_finetune.py \
      --config scripts/model-factory/train/qlora_config.yaml \
      --dataset datasets/sft-<date>.jsonl [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# chars-per-token heuristic for English + JSON-ish text; tokenizer-free on
# purpose so --dry-run downloads nothing.
CHARS_PER_TOKEN = 4.0
# Effective QLoRA throughput assumption for a 4B on an L4 (g6.xlarge),
# forward+backward with checkpointing. Calibration-grade, not billing truth.
L4_TOKENS_PER_SEC = 2000.0
G6_SPOT_RATE = (0.25, 0.40)  # $/hr, us-west-2 estimate (README cost table)

REQUIRED_KEYS = {
    "base_model": str, "output_dir": str, "seed": int,
    "max_seq_len": int, "num_epochs": int, "learning_rate": float,
    "lr_scheduler_type": str, "warmup_ratio": float,
    "per_device_train_batch_size": int, "gradient_accumulation_steps": int,
    "lora_r": int, "lora_alpha": int, "lora_dropout": float,
    "lora_target_modules": str,
    "bnb_4bit": bool, "bnb_4bit_quant_type": str,
    "bnb_4bit_compute_dtype": str, "bnb_4bit_use_double_quant": bool,
    "bf16": bool, "gradient_checkpointing": bool,
    "logging_steps": int, "save_steps": int, "val_split": float,
}


# ---------------------------------------------------------------------------
# Config loading — PyYAML if available, else a mini-parser for the flat
# scalar-only subset qlora_config.yaml commits to.
# ---------------------------------------------------------------------------
def _parse_scalar(raw: str):
    raw = raw.strip()
    if raw.lower() in ("true", "false"):
        return raw.lower() == "true"
    for cast in (int, float):
        try:
            return cast(raw)
        except ValueError:
            pass
    return raw.strip("'\"")


def load_config(path: Path) -> dict:
    try:
        import yaml  # type: ignore
        return yaml.safe_load(path.read_text())
    except ImportError:
        config = {}
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].rstrip()
            if not line or ":" not in line:
                continue
            key, _, value = line.partition(":")
            if key != key.strip() or not value.strip():
                raise ValueError(
                    f"flat-config fallback can't parse {line!r}; install "
                    f"PyYAML or keep {path.name} flat")
            config[key.strip()] = _parse_scalar(value)
        return config


def validate_config(config: dict) -> list:
    problems = []
    for key, kind in REQUIRED_KEYS.items():
        if key not in config:
            problems.append(f"config: missing key {key!r}")
            continue
        value = config[key]
        if kind is float and isinstance(value, int) and not isinstance(value, bool):
            value = float(value)
        if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
            problems.append(f"config: {key} should be {kind.__name__}, "
                            f"got {type(config[key]).__name__} ({config[key]!r})")
    def bad(cond, msg):
        if cond:
            problems.append(f"config: {msg}")
    if not problems:
        bad(not (0 < config["learning_rate"] <= 1e-2),
            "learning_rate outside (0, 1e-2]")
        bad(not (1 <= config["num_epochs"] <= 10), "num_epochs outside 1..10")
        bad(not (512 <= config["max_seq_len"] <= 8192),
            "max_seq_len outside 512..8192")
        bad(config["lora_r"] <= 0 or config["lora_alpha"] <= 0,
            "lora_r/lora_alpha must be positive")
        bad(not (0 <= config["lora_dropout"] < 1), "lora_dropout outside [0,1)")
        bad(config["bnb_4bit_quant_type"] not in ("nf4", "fp4"),
            "bnb_4bit_quant_type must be nf4 or fp4")
        bad(not (0 <= config["val_split"] < 0.5), "val_split outside [0, 0.5)")
    return problems


# ---------------------------------------------------------------------------
# Dataset validation (chat-format JSONL) + token-length histogram
# ---------------------------------------------------------------------------
def validate_dataset(path: Path, max_seq_len: int):
    problems, est_tokens = [], []
    with path.open(encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                problems.append(f"line {lineno}: blank line")
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                problems.append(f"line {lineno}: invalid JSON ({exc})")
                continue
            messages = obj.get("messages")
            if not isinstance(messages, list) or len(messages) < 2:
                problems.append(f"line {lineno}: 'messages' missing or too short")
                continue
            chars = 0
            for i, message in enumerate(messages):
                role = message.get("role")
                content = message.get("content")
                if role not in ("system", "user", "assistant"):
                    problems.append(f"line {lineno}: message {i} bad role {role!r}")
                if not isinstance(content, str) or not content:
                    problems.append(f"line {lineno}: message {i} empty content")
                    content = ""
                chars += len(content)
            if messages[-1].get("role") != "assistant":
                problems.append(f"line {lineno}: last message must be assistant")
            est_tokens.append(int(math.ceil(chars / CHARS_PER_TOKEN)))
    if not est_tokens:
        problems.append("dataset: zero examples")
    over = sum(1 for t in est_tokens if t > max_seq_len)
    if over:
        problems.append(f"dataset: {over} examples exceed max_seq_len="
                        f"{max_seq_len} at the chars/4 estimate (would truncate)")
    return problems, est_tokens


def histogram(est_tokens: list) -> str:
    buckets = [(0, 512), (512, 1024), (1024, 2048), (2048, 3072),
               (3072, 4096), (4096, 1 << 30)]
    lines = ["token-length histogram (chars/4 estimate, +/-30%):"]
    for lo, hi in buckets:
        n = sum(1 for t in est_tokens if lo <= t < hi)
        label = f"{lo}-{hi}" if hi < (1 << 30) else f">={lo}"
        lines.append(f"  {label:>11s}  {n:4d}  {'#' * min(n, 60)}")
    ordered = sorted(est_tokens)
    p50 = ordered[len(ordered) // 2]
    p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
    lines.append(f"  n={len(ordered)}  p50={p50}  p95={p95}  max={ordered[-1]}"
                 f"  total={sum(ordered)}")
    return "\n".join(lines)


def cost_estimate(est_tokens: list, epochs: int) -> str:
    total = sum(est_tokens) * epochs
    hours = total / L4_TOKENS_PER_SEC / 3600
    lo = hours * G6_SPOT_RATE[0]
    hi = hours * G6_SPOT_RATE[1]
    note = ""
    if hours < 0.25:
        note = ("\n  note: this dataset is scaffold-sized — the run is a "
                "smoke test, not a training run;\n  the README cost table's "
                "typical 20k-example run is ~$1-3 on g6.xlarge spot.")
    return (f"cost estimate (g6.xlarge spot, L4 24GB, "
            f"~{L4_TOKENS_PER_SEC:.0f} tok/s effective):\n"
            f"  {total:,} training tokens ({epochs} epochs) "
            f"~= {hours:.2f} GPU-h ~= ${lo:.2f}-${hi:.2f} spot "
            f"(${hours * 0.80:.2f} on-demand)\n"
            f"  Apple Silicon mlx-lm alternative: ~$0 marginal, slower wall "
            f"clock — see README-local.md.{note}")


# ---------------------------------------------------------------------------
# Real training (GPU box only; imports stay inside so --dry-run never
# touches torch). Exercised only on a runner with the HF stack installed.
# ---------------------------------------------------------------------------
def train(config: dict, dataset_path: Path) -> int:
    import torch  # noqa: F401  (deliberate lazy import)
    from datasets import load_dataset
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    from trl import SFTConfig, SFTTrainer

    bnb = BitsAndBytesConfig(
        load_in_4bit=config["bnb_4bit"],
        bnb_4bit_quant_type=config["bnb_4bit_quant_type"],
        bnb_4bit_compute_dtype=getattr(torch, config["bnb_4bit_compute_dtype"]),
        bnb_4bit_use_double_quant=config["bnb_4bit_use_double_quant"],
    )
    tokenizer = AutoTokenizer.from_pretrained(config["base_model"])
    model = AutoModelForCausalLM.from_pretrained(
        config["base_model"], quantization_config=bnb, device_map="auto",
        attn_implementation="eager",  # Gemma guidance
    )
    dataset = load_dataset("json", data_files=str(dataset_path), split="train")
    split = dataset.train_test_split(
        test_size=config["val_split"], seed=config["seed"]) \
        if config["val_split"] > 0 else {"train": dataset, "test": None}
    peft_config = LoraConfig(
        r=config["lora_r"], lora_alpha=config["lora_alpha"],
        lora_dropout=config["lora_dropout"], bias="none",
        task_type="CAUSAL_LM",
        target_modules=config["lora_target_modules"].split(","),
    )
    sft_config = SFTConfig(
        output_dir=config["output_dir"],
        num_train_epochs=config["num_epochs"],
        learning_rate=config["learning_rate"],
        lr_scheduler_type=config["lr_scheduler_type"],
        warmup_ratio=config["warmup_ratio"],
        per_device_train_batch_size=config["per_device_train_batch_size"],
        gradient_accumulation_steps=config["gradient_accumulation_steps"],
        max_seq_length=config["max_seq_len"],
        bf16=config["bf16"],
        gradient_checkpointing=config["gradient_checkpointing"],
        logging_steps=config["logging_steps"],
        save_steps=config["save_steps"],
        seed=config["seed"],
    )
    trainer = SFTTrainer(
        model=model,
        args=sft_config,
        train_dataset=split["train"],
        eval_dataset=split["test"],
        peft_config=peft_config,
        processing_class=tokenizer,  # trl>=0.12; use tokenizer= on older
    )
    trainer.train()
    trainer.save_model(config["output_dir"])
    print(f"adapter saved -> {config['output_dir']}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", type=Path,
                        default=HERE / "qlora_config.yaml")
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true",
                        help="validate config+dataset, print histogram and "
                             "cost estimate; no torch, no downloads")
    args = parser.parse_args()

    if not args.dataset.is_file():
        print(f"error: dataset {args.dataset} not found", file=sys.stderr)
        return 1
    config = load_config(args.config)
    problems = validate_config(config)
    if problems:
        for problem in problems:
            print(f"FAIL {problem}", file=sys.stderr)
        return 1
    print(f"config OK: {args.config} ({len(config)} keys, "
          f"base={config['base_model']}, r={config['lora_r']} "
          f"alpha={config['lora_alpha']} lr={config['learning_rate']} "
          f"epochs={config['num_epochs']} seq={config['max_seq_len']})")

    problems, est_tokens = validate_dataset(args.dataset, config["max_seq_len"])
    if problems:
        for problem in problems[:20]:
            print(f"FAIL {problem}", file=sys.stderr)
        if len(problems) > 20:
            print(f"... and {len(problems) - 20} more", file=sys.stderr)
        return 1
    print(f"dataset OK: {args.dataset} ({len(est_tokens)} chat examples)")
    print(histogram(est_tokens))
    print(cost_estimate(est_tokens, config["num_epochs"]))

    if args.dry_run:
        forbidden = [m for m in ("torch", "transformers", "trl", "peft")
                     if m in sys.modules]
        assert not forbidden, f"dry-run imported {forbidden} — contract broken"
        print("dry-run: all validations passed (torch never imported)")
        return 0

    if os.environ.get("FIN_FACTORY_GO") != "1":
        print("\nREFUSING to train: FIN_FACTORY_GO=1 is not set.\n"
              "Standing hard rule (scripts/model-factory/README.md): no GPU "
              "spend without an\nexplicit human go for this specific run. "
              "Review the cost estimate above, then:\n"
              f"  FIN_FACTORY_GO=1 python3 {sys.argv[0]} "
              f"--config {args.config} --dataset {args.dataset}",
              file=sys.stderr)
        return 3
    return train(config, args.dataset)


if __name__ == "__main__":
    sys.exit(main())

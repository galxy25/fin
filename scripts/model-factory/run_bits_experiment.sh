#!/bin/bash
# The bits-curriculum experiment, end to end. NOTHING IN HERE HAS BEEN RUN YET.
#
# Written 2026-09-06 while a fine-tune (pid 18405, ~15 GB) held the machine.
# Every stage that touches the GPU refuses to start while that is true, so this
# script is safe to launch the moment the run finishes -- it will simply stop
# with exit 75 if it is still going.
#
#   scripts/model-factory/run_bits_experiment.sh [stage...]
#
# Stages (default: all of 1-4; stage 5 is the retrain and needs an explicit go):
#   1  score the corpus under the UNTUNED base       -> bits_base
#   2  score it under the FINAL adapter              -> bits_tuned
#   3  select a subset from the two score files      -> the curriculum
#   4  report                                        -> the numbers to argue about
#   5  retrain on the subset + gate both             -> the only proof that counts
#
# THE CLAIM UNDER TEST (Levi, 2026-09-06): the 2363-example corpus carries far
# fewer bits than it has examples, so a fraction of it reaches the same EVAL GATE
# SCORE in a fraction of the iterations. The payoff is gate-score-per-iteration.
# A negative result -- the subset gates worse -- is a real result; report it.
#
# THE ARBITER IS ALWAYS THE GATE. Bits pick the curriculum. eval_gate.py says
# whether the pick was right. Never promote on a bits number.

set -uo pipefail

REPO=${FIN_REPO:-/Users/deepspacenine/forges/levi/fin}
PY="$REPO/scripts/model-factory/.venv/bin/python"
BASE=mlx-community/gemma-4-E4B-it-qat-4bit
ADAPTERS="$REPO/models/candidates/fin-foreman-e4b-mlx"
TRAIN="$REPO/datasets/mlx/train.jsonl"
VALID="$REPO/datasets/mlx/valid.jsonl"
REPORTS="$REPO/reports"
FRACTION=${FIN_BITS_FRACTION:-0.25}
SEED=${FIN_BITS_SEED:-17}

say() { echo "[bits-experiment] $*"; }

# ---- guard: identical precondition to gate_sweep.sh step 0 -----------------
# score_bits.py enforces this itself too; duplicated here so a stage that only
# shells out still refuses early.
guard() {
  if pgrep -f "mlx_lm lo""ra" >/dev/null 2>&1; then
    say "a fine-tune is training -- refusing (it needs the GPU)"; exit 75
  fi
  if pgrep -f "mlx_lm server" >/dev/null 2>&1; then
    say "mlx_lm server is up -- refusing (it is holding a model)"; exit 75
  fi
  FREE=$(vm_stat | awk '/page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
    /Pages free/ { gsub(/\./, "", $3); f = $3 } /Pages inactive/ { gsub(/\./, "", $3); i = $3 }
    END { printf "%d", (f + i) * ps / 1073741824 }')
  if [ "$FREE" -lt 10 ]; then say "only ${FREE}GB free; need >=10GB"; exit 75; fi
  say "machine is clear: ${FREE}GB free"
}

cd "$REPO" || exit 1
mkdir -p "$REPORTS"
STAGES=${*:-"1 2 3 4"}

# ---------------------------------------------------------------------------
# 1. bits_base -- what the untuned base does NOT already know.
#    Low bits here means the base already produces that answer, so the example
#    teaches nothing and only burns iterations.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 1 "* ]]; then
  guard
  say "stage 1: scoring $TRAIN under the untuned base"
  "$PY" scripts/model-factory/score_bits.py \
    --model "$BASE" --data "$TRAIN" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-train-base.jsonl" || exit $?
  say "stage 1b: same for the validation split (a sanity check, not a curriculum)"
  "$PY" scripts/model-factory/score_bits.py \
    --model "$BASE" --data "$VALID" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-valid-base.jsonl" || exit $?
fi

# ---------------------------------------------------------------------------
# 2. bits_tuned -- residual surprise after the run that already happened.
#    learned_bits = base - tuned is what those 4490 iterations actually bought.
#
#    To score an intermediate checkpoint instead of the final adapter, stage it:
#      mkdir -p "$REPO/models/bits-stage-3000"
#      cp "$ADAPTERS/adapter_config.json" "$REPO/models/bits-stage-3000/"
#      cp "$ADAPTERS/0003000_adapters.safetensors" \
#         "$REPO/models/bits-stage-3000/adapters.safetensors"
#      ... --adapter "$REPO/models/bits-stage-3000" --out reports/bits-train-3000.jsonl
#    Doing that for 250/1000/2250/3500/final gives a bits-vs-iteration curve:
#    the iteration where learned_bits stops growing is the iteration where the
#    corpus stopped teaching, which is the honest --iters ceiling.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 2 "* ]]; then
  guard
  say "stage 2: scoring $TRAIN under the final adapter"
  "$PY" scripts/model-factory/score_bits.py \
    --model "$BASE" --data "$TRAIN" --adapter "$ADAPTERS" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-train-tuned.jsonl" || exit $?

  # Port validation, ~2 minutes: --full-forward reproduces the trainer's own
  # un-cached single forward. The two paths must agree to ~1e-3 bits. If they do
  # not, the chunked KV-cache path is wrong and every number above is suspect.
  say "stage 2b: parity spot-check (chunked vs full forward, 20 examples)"
  "$PY" scripts/model-factory/score_bits.py \
    --model "$BASE" --data "$TRAIN" --adapter "$ADAPTERS" --limit 20 \
    --full-forward --out "$REPORTS/bits-train-tuned-fullfwd.jsonl" || exit $?
  "$PY" - <<'PARITY'
import json, pathlib
r = pathlib.Path("reports")
a = {x["hash"]: x for x in map(json.loads, (r / "bits-train-tuned.jsonl").read_text().splitlines()) if x.get("bits") is not None}
b = [json.loads(l) for l in (r / "bits-train-tuned-fullfwd.jsonl").read_text().splitlines()]
worst = max((abs(a[x["hash"]]["bits"] - x["bits"]) for x in b if x["hash"] in a), default=0.0)
print(f"[bits-experiment] max |chunked - full| = {worst:.6f} bits over {len(b)} examples")
raise SystemExit(0 if worst < 1e-2 else 1)
PARITY
  [ $? -eq 0 ] || { say "PARITY FAILED -- do not trust the bits numbers"; exit 1; }

  # And against the live run's own log: the token-weighted trainer-parity loss
  # over train.jsonl should sit near the last recorded VALIDATION loss (the train
  # loss line is an unweighted mean of per-batch means -- not comparable).
  say "stage 2c: compare summary.trainer_parity_loss_nats in \
$REPORTS/bits-train-tuned.jsonl.meta.json against the tail of \
$ADAPTERS/train.log"
fi

# ---------------------------------------------------------------------------
# 3. the curriculum. No GPU: pure stdlib, seconds.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 3 "* ]]; then
  say "stage 3: selecting a ${FRACTION} subset"
  "$PY" scripts/model-factory/select_curriculum.py \
    --base "$REPORTS/bits-train-base.jsonl" \
    --tuned "$REPORTS/bits-train-tuned.jsonl" \
    --corpus "$TRAIN" \
    --target-fraction "$FRACTION" --seed "$SEED" \
    --out "$REPO/datasets/mlx-bits${FRACTION}/train.jsonl" \
    --report "$REPORTS/curriculum-${FRACTION}.txt" || exit $?
  # The valid split is NOT subset -- comparing two runs needs one fixed yardstick.
  mkdir -p "$REPO/datasets/mlx-bits${FRACTION}"
  cp "$VALID" "$REPO/datasets/mlx-bits${FRACTION}/valid.jsonl"

  # A control arm, and the reason the experiment is honest: a RANDOM subset of
  # the same size, same class proportions. If bits-selection does not beat
  # random at the gate, bits bought nothing and the result is negative.
  "$PY" scripts/model-factory/select_curriculum.py \
    --base "$REPORTS/bits-train-base.jsonl" \
    --corpus "$TRAIN" --target-fraction "$FRACTION" --seed 999 \
    --rank-by random --jaccard 1.01 \
    --out "$REPO/datasets/mlx-rand${FRACTION}/train.jsonl" \
    --report "$REPORTS/curriculum-random-${FRACTION}.txt" >/dev/null || exit $?
  mkdir -p "$REPO/datasets/mlx-rand${FRACTION}"
  cp "$VALID" "$REPO/datasets/mlx-rand${FRACTION}/valid.jsonl"
  say "control arm: --rank-by random draws the same budget with the same class"
  say "proportions but blind to bits; --jaccard 1.01 also switches clustering off"
  say "so the only difference between the arms is the information criterion."
fi

# ---------------------------------------------------------------------------
# 4. report
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 4 "* ]]; then
  say "stage 4: the numbers"
  cat "$REPORTS/curriculum-${FRACTION}.txt"
fi

# ---------------------------------------------------------------------------
# 5. THE ONLY PROOF THAT COUNTS. Needs an explicit go: this is a multi-hour GPU
#    job and it is the thing the standing machine rules are about.
#
#    Iteration budget: one epoch of the subset is FRACTION * 2245 iterations.
#    The live run used 4490 (2 epochs). Match EPOCHS, not iterations, so the
#    comparison is "same passes over less data" -- that is where the saving is:
#
#      SUBSET_N=$(wc -l < datasets/mlx-bits0.25/train.jsonl)
#      ITERS=$(( SUBSET_N * 2 ))          # 2 epochs, same as the live run
#
#      "$PY" -m mlx_lm lora \
#        --model mlx-community/gemma-4-E4B-it-qat-4bit --train \
#        --data datasets/mlx-bits0.25 \
#        --fine-tune-type lora --num-layers 16 --batch-size 1 \
#        --grad-accumulation-steps 2 --grad-checkpoint --mask-prompt \
#        --max-seq-length 3072 --iters "$ITERS" --learning-rate 1e-4 \
#        --seed 17 --save-every 250 \
#        --adapter-path models/candidates/fin-foreman-e4b-bits25
#
#    Then gate BOTH arms through the existing machinery -- fuse, serve, score:
#
#      scripts/model-factory/gate_sweep.sh final          # re-uses the champion
#      # or, per candidate, once it is serving somewhere:
#      "$PY" scripts/model-factory/eval_gate.py \
#        --base-url http://127.0.0.1:8080/v1 --model fin-foreman-bits25 \
#        --out reports/gate-bits25.json
#
#    THE METRIC: gate score per iteration.
#
#      full corpus : <core>/<total> at 4490 iters
#      bits subset : <core>/<total> at  ITERS
#      random ctrl : <core>/<total> at  ITERS
#
#    The claim is proved if the bits subset ties or beats the full corpus's gate
#    score at strictly fewer iterations AND beats the random control. It is
#    disproved if the subset gates worse, or if random matches it -- in which
#    case the redundancy was real but bits added nothing over counting, and that
#    is worth writing down too.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 5 "* ]]; then
  say "stage 5 is documented, not automated: it is a multi-hour GPU job."
  say "read the comment block above, then run it deliberately."
  exit 0
fi

say "done"

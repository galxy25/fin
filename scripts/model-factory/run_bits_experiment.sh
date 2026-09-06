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
# Stages (default: all of 0-4; stage 5 is the retrain and needs an explicit go):
#   0  preflight, no GPU: can the chosen bits column be computed at all?
#   1  score the corpus under the UNTUNED base       -> bits_base
#      (1b also anchors the masking port against the trainer's own logged loss)
#   2  score it under the FINAL adapter              -> bits_tuned
#   3  select a subset from the two score files      -> the curriculum
#   4  report                                        -> the numbers to argue about
#   5  retrain on the subset + gate both             -> the only proof that counts
#
# THE CLAIM UNDER TEST (Levi, 2026-09-06): the corpus carries far fewer bits than
# it has examples, so a fraction of it reaches the same EVAL GATE SCORE in a
# fraction of the iterations. The payoff is gate-score-per-iteration. A negative
# result -- the subset gates worse, or the random control matches it, or the full
# corpus at the same reduced iteration count matches it -- is a real result;
# report it. (The corpus under test is datasets/mlx/train.jsonl, 2245 examples.
# datasets/sft-train-2026-09-05.jsonl is that file PLUS the 118 validation
# examples, and selecting from it would train on the yardstick.)
#
# THE ARBITER IS ALWAYS THE GATE. Bits pick the curriculum. eval_gate.py says
# whether the pick was right. Never promote on a bits number.

set -uo pipefail

# SCRIPTS is where THIS file lives -- so the script runs the code it shipped
# with, whether that is the main checkout or a worktree. DATA is where the
# corpora, models and reports live, and it defaults to the same repo: running
# from a worktree must not write into another checkout's datasets/ tree.
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPTS/../.." && pwd)
DATA=${FIN_DATA_ROOT:-$REPO}
PY=${FIN_PY:-$DATA/scripts/model-factory/.venv/bin/python}
BASE=mlx-community/gemma-4-E4B-it-qat-4bit
ADAPTERS=${FIN_ADAPTERS:-$DATA/models/candidates/fin-foreman-e4b-mlx}
TRAIN="$DATA/datasets/mlx/train.jsonl"
VALID="$DATA/datasets/mlx/valid.jsonl"
# Outputs go under the SCRIPTS repo by default, so a worktree run stays in the
# worktree. Point FIN_OUT_ROOT elsewhere to change that.
OUT_ROOT=${FIN_OUT_ROOT:-$REPO}
REPORTS="$OUT_ROOT/reports"
FRACTION=${FIN_BITS_FRACTION:-0.25}
SEED=${FIN_BITS_SEED:-17}
JACCARD=${FIN_BITS_JACCARD:-0.8}
BITS_COLUMN=${FIN_BITS_COLUMN:-decision}

say() { echo "[bits-experiment] $*"; }

# ---- preflight -------------------------------------------------------------
for f in "$PY" "$TRAIN" "$VALID"; do
  [ -e "$f" ] || { say "missing: $f -- set FIN_DATA_ROOT/FIN_PY to the checkout that has it"; exit 1; }
done

# ---- guard: the same precondition score_bits.py enforces -------------------
# score_bits.py re-checks on every invocation; duplicated here so a stage that
# only shells out still refuses early. Keep the pattern list in sync with
# score_bits._BUSY_PATTERNS -- a subset here is a guard with a hole in it.
guard() {
  for pat in "mlx_lm lo""ra" "mlx_lm server" "mlx_lm fuse" "mlx_lm generate"; do
    pgrep -f "$pat" >/dev/null 2>&1
    rc=$?
    # FAIL CLOSED, like score_bits._pgrep: 0 = matched, 1 = no match, and
    # ANYTHING ELSE (2 usage, 3 fatal) means the process table could not be
    # read. Treating "I could not check" as "nothing is running" fails in
    # exactly the direction that wedges the machine.
    case "$rc" in
      0) say "'$pat' is live -- refusing (it is holding the GPU)"; exit 75;;
      1) ;;
      *) say "pgrep -f '$pat' exited $rc -- cannot verify the machine is idle; refusing"; exit 75;;
    esac
  done
  FREE=$(vm_stat | awk '/page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
    /Pages free/ { gsub(/\./, "", $3); f = $3 } /Pages inactive/ { gsub(/\./, "", $3); i = $3 }
    END { printf "%d", (f + i) * ps / 1073741824 }')
  # Fail CLOSED: an unreadable vm_stat is "unknown", not "idle".
  case "$FREE" in ''|*[!0-9]*) say "cannot read free memory -- refusing"; exit 75;; esac
  if [ "$FREE" -lt 10 ]; then say "only ${FREE}GB free; need >=10GB"; exit 75; fi
  say "machine is clear: ${FREE}GB free"
}

cd "$DATA" || exit 1
mkdir -p "$REPORTS"
STAGES=${*:-"0 1 2 3 4"}

# ---------------------------------------------------------------------------
# 0. PREFLIGHT, no GPU, seconds. Everything that can invalidate the run is
#    checked here rather than discovered at stage 3 with the GPU hours spent.
#
#    This stage exists because that is exactly what happened: the runner
#    defaulted to --bits-column decision while score_bits defaulted to a flat
#    `action,session`, which is empty for the whole ledger and tooluse tracks
#    (1093 of 2245 rows, 48.7%). select_curriculum refuses past 20% missing --
#    correctly -- so stages 1 and 2 would both have run to completion and stage
#    3 would then have aborted, producing no curriculum. A cheap check that
#    cannot pass when the expensive stages would be wasted.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 0 "* ]]; then
  if [ "$BITS_COLUMN" = "decision" ]; then
    say "stage 0: can the decision column even be computed on this corpus?"
    "$PY" "$SCRIPTS/score_bits.py" --data "$TRAIN" --out /dev/null \
      --check-decision-coverage 0.95 || {
        say "PREFLIGHT FAILED -- fix --decision-fields before spending the GPU"; exit 1; }
  else
    say "stage 0: bits column is '$BITS_COLUMN'; no decision-coverage preflight needed"
  fi
fi

# ---------------------------------------------------------------------------
# 1. bits_base -- what the untuned base does NOT already know.
#    Low bits here means the base already produces that answer, so the example
#    teaches nothing and only burns iterations.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 1 "* ]]; then
  guard
  say "stage 1: scoring $TRAIN under the untuned base"
  "$PY" "$SCRIPTS/score_bits.py" \
    --model "$BASE" --data "$TRAIN" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-train-base.jsonl" || exit $?
  say "stage 1b: same for the validation split -- THE EXTERNAL ANCHOR, not a curriculum"
  "$PY" "$SCRIPTS/score_bits.py" \
    --model "$BASE" --data "$VALID" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-valid-base.jsonl" || exit $?

  # THE ONE CHECK THIS REPO DID NOT PRODUCE THE ANSWER TO. Internal parity
  # (1c/2b) proves the chunked path agrees with the full forward; it cannot
  # prove the MASK is the trainer's, because both paths would be wrong the same
  # way. trainer.py runs evaluate() BEFORE the first step, so the log's
  #   Iter 1: Val loss 2.463
  # is the UNTUNED base's token-weighted loss over valid.jsonl under the
  # trainer's own mask -- the same quantity stage 1b just wrote to
  # summary.trainer_parity_loss_nats. At 2.463 nats/token there is dynamic
  # range: a prompt-masking error moves it by a large multiple. (Comparing the
  # TAIL of the log instead, as an earlier version of this script did, compares
  # two numbers that are both ~0.01 whether the mask is right or wrong.)
  say "stage 1b-anchor: does the masking port reproduce the trainer's own Iter 1 val loss?"
  "$PY" "$SCRIPTS/parity_check.py" \
    --anchor "$REPORTS/bits-valid-base.jsonl.meta.json" \
    --log "$ADAPTERS/train.log" --iter 1 || {
      say "ANCHOR FAILED -- the mask is not the trainer's; every bits number is wrong"; exit 1; }

  # The base ranking IS the whole curriculum in base-only mode, so the chunked
  # KV-cache path has to be validated here too, not only in stage 2. Same
  # uncalibrated-bound caveat as stage 2b: this prints the per-token divergence
  # it observed and enforces only a coarse ceiling until someone sets
  # --per-token-bits from a real run. (--tolerance is retired and REFUSED: it
  # was a relative half ORed on top, and at the base scale its 6.15 bits of
  # room passed a mis-assembled row.)
  say "stage 1c: parity spot-check on the BASE scores (chunked vs full forward)"
  "$PY" "$SCRIPTS/score_bits.py" \
    --model "$BASE" --data "$TRAIN" --limit 20 \
    --full-forward --out "$REPORTS/bits-train-base-fullfwd.jsonl" || exit $?
  "$PY" "$SCRIPTS/parity_check.py" \
    "$REPORTS/bits-train-base.jsonl" "$REPORTS/bits-train-base-fullfwd.jsonl" || {
      say "PARITY FAILED on the base scores -- do not trust the ranking"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. bits_tuned -- residual surprise after the run that already happened.
#    learned_bits = base - tuned is what those 4490 iterations actually bought.
#
#    To score an intermediate checkpoint instead of the final adapter, stage it:
#      mkdir -p "$DATA/models/bits-stage-3000"
#      cp "$ADAPTERS/adapter_config.json" "$DATA/models/bits-stage-3000/"
#      cp "$ADAPTERS/0003000_adapters.safetensors" \
#         "$DATA/models/bits-stage-3000/adapters.safetensors"
#      ... --adapter "$DATA/models/bits-stage-3000" --out reports/bits-train-3000.jsonl
#    Give each checkpoint its OWN staging directory and its own --out, as above.
#    score_bits.py hashes the adapter's contents into every row (adapter_digest),
#    so re-using one staging directory for a second checkpoint no longer risks a
#    silently spliced file -- a resume against changed weights is refused rather
#    than appended. It is still refused, not merged: point --out somewhere new.
#    Doing that for 250/1000/2250/3500/final gives a bits-vs-iteration curve:
#    the iteration where learned_bits stops growing is the iteration where the
#    corpus stopped teaching, which is the honest --iters ceiling.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 2 "* ]]; then
  guard
  say "stage 2: scoring $TRAIN under the final adapter"
  "$PY" "$SCRIPTS/score_bits.py" \
    --model "$BASE" --data "$TRAIN" --adapter "$ADAPTERS" \
    --max-seq-length 3072 --chunk 512 \
    --out "$REPORTS/bits-train-tuned.jsonl" || exit $?

  # Port validation, ~2 minutes: --full-forward reproduces the trainer's own
  # un-cached single forward. parity_check.py FAILS on an empty or partial
  # overlap -- a comparison over zero examples agrees perfectly and would
  # validate nothing.
  #
  # BOUND: NOT CALIBRATED YET. No parity run has been made on a GPU, so no bound
  # is passed here and the check enforces only its coarse wrong-in-KIND ceiling.
  # It will PRINT "max per-token divergence <y> bits/token". Write that down and
  # add
  #   --per-token-bits <a small multiple of y>
  # to BOTH parity_check invocations in this file (stage 1c and here). That is
  # the whole calibration: the bound is per TOKEN alone, at every length. The
  # relative half is retired -- max() was an OR of two permissions, and at the
  # base scale it granted 6.15 bits, more than a mis-assembled row costs -- so
  # --tolerance is REFUSED (exit 2), not ignored. Until the bound is set, a pass
  # from this stage means "not wrong in kind", not "validated". The two score
  # files must also come from runs that differ ONLY in the forward path, and
  # both must RECORD it -- parity_check refuses the pair (exit 2) otherwise,
  # which is why the --full-forward run below repeats the same --model/--adapter
  # and leaves --max-seq-length at its default 3072.
  say "stage 2b: parity spot-check (chunked vs full forward, 20 examples)"
  "$PY" "$SCRIPTS/score_bits.py" \
    --model "$BASE" --data "$TRAIN" --adapter "$ADAPTERS" --limit 20 \
    --full-forward --out "$REPORTS/bits-train-tuned-fullfwd.jsonl" || exit $?
  "$PY" "$SCRIPTS/parity_check.py" \
    "$REPORTS/bits-train-tuned.jsonl" "$REPORTS/bits-train-tuned-fullfwd.jsonl" || {
      say "PARITY FAILED -- do not trust the bits numbers"; exit 1; }

  # NOT a comparison against the tail of train.log. That check used to live here
  # and it was vacuous: the log's late val losses are 0.005-0.028 and this
  # adapter has memorized train.jsonl, so both sides are ~0.01 under a correct
  # port AND under a broken one. An off-by-one in the gather index would add or
  # drop one template-deterministic token the tuned model also predicts at ~0
  # nats, and the comparison would not move. The discriminating check is the
  # base model's Iter 1 anchor in stage 1b, where the quantity is 2.463 rather
  # than ~0.01. What is worth PRINTING here is the residual itself, as the
  # measurement it is:
  say "stage 2c: residual after training (a measurement, not a check) --"
  say "  summary.trainer_parity_loss_nats in $REPORTS/bits-train-tuned.jsonl.meta.json"
  say "  is this adapter's loss on the TRAIN split it memorized; expect ~0.01-0.04."
  say "  It validates nothing about the mask: see stage 1b-anchor for that."
fi

# ---------------------------------------------------------------------------
# 3. the curriculum. No GPU: pure stdlib, seconds.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 3 "* ]]; then
  say "stage 3: selecting a ${FRACTION} subset (bits column: ${BITS_COLUMN})"
  BITS_DIR="$OUT_ROOT/datasets/mlx-bits${FRACTION}"
  RAND_DIR="$OUT_ROOT/datasets/mlx-rand${FRACTION}"
  "$PY" "$SCRIPTS/select_curriculum.py" \
    --base "$REPORTS/bits-train-base.jsonl" \
    --tuned "$REPORTS/bits-train-tuned.jsonl" \
    --corpus "$TRAIN" --bits-column "$BITS_COLUMN" \
    --target-fraction "$FRACTION" --seed "$SEED" --jaccard "$JACCARD" \
    --out "$BITS_DIR/train.jsonl" \
    --report "$REPORTS/curriculum-${FRACTION}.txt" || exit $?
  # The valid split is NOT subset -- comparing two runs needs one fixed yardstick.
  mkdir -p "$BITS_DIR"
  cp "$VALID" "$BITS_DIR/valid.jsonl"

  # THE CONTROL ARM, and the reason the experiment is honest: a RANDOM subset of
  # the same size and the same class proportions. If bits-selection does not beat
  # random at the gate, bits bought nothing and the result is negative.
  #
  # It must differ from the bits arm in ONE thing: the ranking. It therefore runs
  # at the SAME --jaccard as the bits arm. An earlier version passed 1.01 here
  # (clustering off) and 0.80 there, which changed the DEDUPLICATION as well.
  # Measured on the real corpus with stub scores (real bits do not exist yet),
  # toggling only that threshold moves 10-18% of the 563 picks depending on the
  # score distribution -- so a gate win would have been attributable to dedup or
  # to bits with no way to tell them apart, which is the one inference the
  # control exists to support. Both arms cluster; only the criterion differs.
  # --bits-column is passed here too, identically. A random ranking ignores the
  # column, so this changes no pick -- but leaving it off made the two arms
  # differ in a second flag, and "it happens not to matter" is exactly the
  # reasoning that let --jaccard 1.01 sit here unnoticed. The arms are
  # configured identically; only --rank-by differs.
  "$PY" "$SCRIPTS/select_curriculum.py" \
    --base "$REPORTS/bits-train-base.jsonl" \
    --corpus "$TRAIN" --bits-column "$BITS_COLUMN" \
    --target-fraction "$FRACTION" --seed 999 \
    --rank-by random --jaccard "$JACCARD" \
    --out "$RAND_DIR/train.jsonl" \
    --report "$REPORTS/curriculum-random-${FRACTION}.txt" >/dev/null || exit $?
  mkdir -p "$RAND_DIR"
  cp "$VALID" "$RAND_DIR/valid.jsonl"
  say "control arm: same budget, same class proportions, same clustering"
  say "(--jaccard $JACCARD), blind to bits. The ONLY difference between the arms"
  say "is the information criterion."
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
#        --seed 17 --save-every 250 \          # and again at --seed 18, 19
#        --adapter-path models/candidates/fin-foreman-e4b-bits25
#
#    FOUR ARMS, NOT THREE. The fourth is the one that can kill the claim:
#
#      D. the FULL corpus, trained for the SAME ITERS as the subset arms
#         --data datasets/mlx --iters "$ITERS"
#         --adapter-path models/candidates/fin-foreman-e4b-full-short
#
#    Without D, "the bits subset ties 4490 iterations at 1126" is satisfiable by
#    early stopping alone: the live run's val loss is already 0.005-0.013 from
#    iteration 2000, so the full corpus truncated to 1126 iterations may well tie
#    4490 by itself -- and then every arm ties and the criterion reports a
#    success that selection had no part in. D is also the DIRECT competitor for
#    "fewest iterations at equal gate score": at identical compute it sees 1126
#    DISTINCT examples once, where the subset arms see 563 examples twice. More
#    diversity per iteration is exactly the hypothesis's rival.
#
#    Then gate ALL arms through the existing machinery -- fuse, serve, score.
#    (`gate_sweep.sh` is the wrapper that does fuse+serve+score in one; it lands
#    with the gate-sweep branch and is NOT in this checkout, so the portable
#    instruction is eval_gate.py against whatever is serving:)
#
#      "$PY" scripts/model-factory/eval_gate.py \
#        --base-url http://127.0.0.1:8080/v1 --model fin-foreman-bits25 \
#        --out reports/gate-bits25.json
#
#    THE METRIC: gate score per iteration.
#
#      A. full corpus, full run : <core>/<total> at 4490 iters
#      B. bits subset           : <core>/<total> at  ITERS
#      C. random control        : <core>/<total> at  ITERS
#      D. full corpus, ITERS    : <core>/<total> at  ITERS   <-- the honest floor
#
#    HOW BIG A DIFFERENCE COUNTS. The gate is 51 binary scenarios, so ONE
#    scenario is 2.0 percentage points, and nothing in this branch has ever
#    measured LoRA seed-to-seed variance on it. A one-scenario gap between two
#    single runs is not a result; declaring "bits beat random" on 46/51 vs 45/51
#    would be reading noise. So:
#
#      * Run each arm at >= 3 SEEDS (--seed 17, 18, 19). Four arms x three seeds
#        is the price of a claim; one seed per arm buys an anecdote.
#      * First establish the NOISE FLOOR: the spread of arm A across its three
#        seeds. Call it S (in scenarios).
#      * "B beats C" requires median(B) - median(C) > max(S, 2 scenarios).
#        "B ties A" requires |median(B) - median(A)| <= max(S, 2 scenarios).
#      * Report every individual score, not just the medians. If the arms
#        overlap, the honest finding is "no measurable difference at this
#        sample size", and that is a result worth writing down.
#
#    WHAT THE VERDICT COVERS. evals/tmux-routing is 51 scenarios and all of them
#    are routing (route/start/clarify/refuse); run_evals.py:matches() compares
#    'action' and 'session'. The ledger, elicit and tooluse tracks -- 1398 of
#    2245 training examples, 62.3% of what the curriculum cuts -- are NOT
#    exercised by it. A subset that destroys tooluse's argument formatting
#    scores identically on all 51 scenarios. So a stage-5 verdict is a verdict
#    ON ROUTING. Before promoting anything on it, either hold out a per-track
#    check of your own, or say plainly that the other three tracks are unmeasured.
#
#    The claim is proved only if B ties or beats A at strictly fewer iterations
#    AND beats C AND beats D, all at the margin above. It is disproved if B
#    gates worse than A; if C matches B (the redundancy was real but bits added
#    nothing over counting); or if D matches B (the saving was early stopping,
#    not curriculum). Write down whichever happens -- a negative result honestly
#    reported is a good result.
# ---------------------------------------------------------------------------
if [[ " $STAGES " == *" 5 "* ]]; then
  say "stage 5 is documented, not automated: it is a multi-hour GPU job."
  say "read the comment block above, then run it deliberately."
  exit 0
fi

say "done"

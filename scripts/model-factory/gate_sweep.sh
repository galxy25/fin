#!/bin/bash
# Score several LoRA checkpoints against the tmux-routing corpus and report which
# one to promote — because the LAST checkpoint is not automatically the best one.
#
#   scripts/model-factory/gate_sweep.sh [iters...]        # default: 1000 2250 3500 final
#
# Why a sweep: the 2026-09-06 run reached train loss 0.000 by iteration ~2900 on
# programmatically synthesized data, so later checkpoints memorize templates while
# the eval corpus's adversarial "hard" tier is what actually discriminates. Loss
# cannot tell those apart; the gate can.
#
# Order of operations (all serialized — one model in memory at a time):
#   0. refuse to run while a fine-tune is training or LM Studio holds the GPU
#   1. RE-RECORD THE CHAMPION. evals-champions.json still holds 36/51, which was
#      measured with the round-0 router prompt; the kept round-3 prompt scores
#      49/51 on the same untuned model. Scoring a candidate against the stale
#      number would flatter it into a false promotion.
#   2. per checkpoint: stage -> fuse -> serve (mlx_lm.server) -> run_evals -> record
#      -> delete the fused model (each is ~4-6 GB; 12 of them would fill the disk)
#   3. print a table and name the winner. Promotion still needs eval_gate.py's
#      verdict against the re-recorded champion, and the winner should be
#      re-scored in LM Studio (the real serving surface) before it goes live.
set -uo pipefail

# THE PROMPT MUST MATCH THE ONE THE TRAINING DATA WAS BUILT FROM.
# evals/tmux-routing/prompts/router.md is the source of truth for BOTH the eval
# adapter's system prompt AND (via router_llm._system_prompt, in
# gen_training_data.py) the system prompt baked into every training example.
# Branch imac-site edits that file to describe the tmux send-guard, so scoring a
# candidate from THAT tree would present a prompt the candidate never trained on
# and dock it points for a reason unrelated to training. EVALS_ROOT is therefore
# the checkout THIS SCRIPT lives in — put it on a main-based worktree — while the
# venv and the adapters stay in the primary checkout where training wrote them.
EVALS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO=/Users/deepspacenine/forges/levi/fin
VENV="$REPO/scripts/model-factory/.venv/bin/python"
BASE=mlx-community/gemma-4-E4B-it-qat-4bit
ADAPTERS="$REPO/models/candidates/fin-foreman-e4b-mlx"
WORK="$REPO/models/gate-sweep"
PORT=${FIN_GATE_PORT:-8080}
CHAMPION_MODEL=${FIN_CHAMPION_MODEL:-google/gemma-4-e4b}

cd "$EVALS_ROOT" || exit 1
mkdir -p "$WORK"
RESULTS="$WORK/results.tsv"

say() { echo "[gate-sweep] $*"; }

# ---- 0. refuse to compete for memory -------------------------------------
if pgrep -f "mlx_lm lo""ra" >/dev/null 2>&1; then
  say "a fine-tune is still training — refusing to start (it needs the GPU)"; exit 75
fi
FREE=$(vm_stat | awk '/page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
  /Pages free/ { gsub(/\./, "", $3); f = $3 } /Pages inactive/ { gsub(/\./, "", $3); i = $3 }
  END { printf "%d", (f + i) * ps / 1073741824 }')
if [ "$FREE" -lt 10 ]; then say "only ${FREE}GB free; need >=10GB"; exit 75; fi
say "starting with ${FREE}GB free"

# Provenance: which prompt is being scored, recorded beside the scores. A sweep
# whose prompt sha is not written down cannot be compared with any other sweep.
PROMPT_SHA=$(git -C "$EVALS_ROOT" rev-parse HEAD:evals/tmux-routing/prompts/router.md 2>/dev/null || echo unknown)
TRAINING_PROMPT_SHA=${FIN_TRAINING_PROMPT_SHA:-c511bab2bf99495603e199fbfe82a6b9f5c9dab5}
say "router.md = $PROMPT_SHA (evals root $EVALS_ROOT)"
{ echo "# gate sweep"; echo "# evals_root: $EVALS_ROOT";
  echo "# router.md: $PROMPT_SHA"; echo "# base: $BASE"; echo "# adapters: $ADAPTERS"; } > "$WORK/provenance.txt"
if [ "$PROMPT_SHA" != "$TRAINING_PROMPT_SHA" ]; then
  say "REFUSING: router.md is $PROMPT_SHA but the training corpus was built from $TRAINING_PROMPT_SHA."
  say "Scoring against a prompt the candidate never trained on measures the wrong thing."
  say "Run from a checkout at the training prompt, or set FIN_TRAINING_PROMPT_SHA deliberately."
  exit 78
fi

# Prove the served endpoint actually answers for the id we will send, BEFORE
# spending 51 scenarios on it. mlx_lm.server reports its model id as the PATH
# passed to --model; sending anything else 404s per request, run_evals degrades
# every scenario to `clarify`, and the 5 clarify scenarios pass — 10/51 that
# looks like a catastrophic fine-tune and is really an empty measurement.
probe() {  # probe <base-url> <model-id>
  local body
  body=$(curl -s -m 90 "$1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK\"}],\"max_tokens\":8,\"temperature\":0}")
  case "$body" in
    *'"choices"'*) return 0 ;;
    *) say "PROBE FAILED for model id '$2' — the endpoint did not answer a trivial request:"
       say "  ${body:-<empty response>}"
       return 1 ;;
  esac
}

serve() {  # serve <model-path> <label>; sets SERVE_PID
  "$VENV" -m mlx_lm server --model "$1" --port "$PORT" >"$WORK/server-$2.log" 2>&1 &
  SERVE_PID=$!
  for _ in $(seq 1 90); do
    sleep 2
    curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && return 0
    kill -0 "$SERVE_PID" 2>/dev/null || { say "server died — see $WORK/server-$2.log"; return 1; }
  done
  say "server did not come up in 180s"; return 1
}
unserve() { [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null; SERVE_PID=; }
trap 'unserve' EXIT INT TERM

score() {  # score <base-url> <model-id> <label> -> "core/total hard/total overall/total"
  FIN_ROUTER_BASE_URL="$1" FIN_ROUTER_MODEL="$2" \
    python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py \
    >"$WORK/eval-$3.log" 2>&1
  grep -E "core \(gates\)|hard \(benchmark\)|^ *[0-9]+/[0-9]+" "$WORK/eval-$3.log" | tail -3
}

# ---- 1. champion, re-measured with the prompt we actually ship -------------
if [ ! -f "$WORK/champion.txt" ]; then
  if curl -s -m 3 http://127.0.0.1:1234/v1/models >/dev/null 2>&1; then
    say "re-recording the champion ($CHAMPION_MODEL) through LM Studio"
    score "http://127.0.0.1:1234/v1" "$CHAMPION_MODEL" "champion" | tee "$WORK/champion.txt"
  else
    say "LM Studio is not serving on :1234 — start it and load $CHAMPION_MODEL, then re-run"
    say "(skipping the champion re-record; candidate scores below are still valid on their own)"
  fi
else
  say "champion already recorded: $(cat "$WORK/champion.txt" | tr '\n' ' ')"
fi

# ---- 2. per-checkpoint sweep ----------------------------------------------
ITERS=${*:-"1000 2250 3500 final"}
: >"$RESULTS"
for IT in $ITERS; do
  if [ "$IT" = "final" ]; then FILE="$ADAPTERS/adapters.safetensors"; else
    FILE="$ADAPTERS/$(printf '%07d' "$IT")_adapters.safetensors"; fi
  [ -f "$FILE" ] || { say "no checkpoint for $IT ($FILE) — skipping"; continue; }

  STAGE="$WORK/stage-$IT"; FUSED="$WORK/fused-$IT"
  rm -rf "$STAGE" "$FUSED"; mkdir -p "$STAGE"
  cp "$ADAPTERS/adapter_config.json" "$STAGE/"
  cp "$FILE" "$STAGE/adapters.safetensors"

  say "fusing checkpoint $IT"
  if ! "$VENV" -m mlx_lm fuse --model "$BASE" --adapter-path "$STAGE" --save-path "$FUSED" \
        >"$WORK/fuse-$IT.log" 2>&1; then
    say "fuse failed for $IT — see $WORK/fuse-$IT.log"; rm -rf "$STAGE"; continue
  fi

  say "serving + scoring checkpoint $IT"
  if serve "$FUSED" "$IT" && probe "http://127.0.0.1:$PORT/v1" "$FUSED"; then
    OUT=$(score "http://127.0.0.1:$PORT/v1" "$FUSED" "$IT")
    printf '%s\t%s\n' "$IT" "$(echo "$OUT" | tr '\n' ' ')" >>"$RESULTS"
    say "checkpoint $IT: $(echo "$OUT" | tr '\n' ' ')"
  else
    printf '%s\tSERVE-OR-PROBE-FAILED\n' "$IT" >>"$RESULTS"
  fi
  unserve
  rm -rf "$STAGE" "$FUSED"   # each fused model is ~4-6 GB
done

say "--- results ---"; cat "$RESULTS"
say "router.md scored: $PROMPT_SHA"
  say "champion: $(cat "$WORK/champion.txt" 2>/dev/null | tr '\n' ' ' || echo 'NOT RE-RECORDED — do not promote on the stale 36/51')"
say "next: pick the winner, re-score it in LM Studio, then run eval_gate.py for the promotion verdict"

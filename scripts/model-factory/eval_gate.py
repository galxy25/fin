#!/usr/bin/env python3
"""Score a candidate model on the eval gate and emit a promotion verdict.

Serves nothing itself: point it at any OpenAI-compatible endpoint already
running the candidate (LM Studio, mlx_lm.server, vLLM) and it runs the
existing tmux-routing eval unchanged — `run_evals.py --router router_llm.py`
as a subprocess with FIN_ROUTER_BASE_URL / FIN_ROUTER_MODEL set — then
compares the parsed scores against the recorded champion
(evals-champions.json, seeded with the untuned gemma-4-e4b 36/51 from
evals/tmux-routing/RESULTS.md).

Promotion rule (README "Eval gate"):
  1. ALL core scenarios pass (non-negotiable), AND
  2. core+hard combined strictly beats the champion (ties don't promote).
     If corpus sizes differ between runs, pass fractions are compared.

Output: the verdict JSON on stdout (progress on stderr), optionally also to
--out. The raw run_evals stdout is embedded in the verdict ("runOutput") so
every scored run stays diffable.

Exit code: 0 promoted, 1 not promoted, 2 the eval run itself failed to score.

Usage:
  python3 scripts/model-factory/eval_gate.py \
      --base-url http://localhost:1234/v1 --model <candidate-id> \
      [--champions scripts/model-factory/evals-champions.json] [--out FILE]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
EVAL_DIR = REPO / "evals" / "tmux-routing"

OVERALL_RE = re.compile(r"tmux-routing evals: (\d+)/(\d+) passed")
TIERS_RE = re.compile(r"core \(gates\): (\d+)/(\d+)\s+hard \(benchmark\): (\d+)/(\d+)")


def run_eval(base_url: str, model: str, corpus: Path, timeout: int):
    env = dict(os.environ,
               FIN_ROUTER_BASE_URL=base_url,
               FIN_ROUTER_MODEL=model)
    cmd = [sys.executable, str(EVAL_DIR / "run_evals.py"),
           "--router", str(EVAL_DIR / "router_llm.py"),
           "--corpus", str(corpus)]
    print(f"running: {' '.join(cmd)}", file=sys.stderr)
    print(f"  FIN_ROUTER_BASE_URL={base_url} FIN_ROUTER_MODEL={model}",
          file=sys.stderr)
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True,
                          timeout=timeout)
    return proc


def parse_scores(stdout: str):
    overall = OVERALL_RE.search(stdout)
    tiers = TIERS_RE.search(stdout)
    if not overall or not tiers:
        return None
    return {
        "overall": {"passed": int(overall.group(1)), "total": int(overall.group(2))},
        "core": {"passed": int(tiers.group(1)), "total": int(tiers.group(2))},
        "hard": {"passed": int(tiers.group(3)), "total": int(tiers.group(4))},
    }


def beats(candidate: dict, champion: dict) -> bool:
    """Strictly better on core+hard combined; fractions when totals differ."""
    if candidate["total"] == champion["total"]:
        return candidate["passed"] > champion["passed"]
    return (candidate["passed"] / candidate["total"]
            > champion["passed"] / champion["total"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", required=True,
                        help="OpenAI-compatible endpoint serving the candidate")
    parser.add_argument("--model", required=True, help="candidate model id")
    parser.add_argument("--champions", type=Path,
                        default=HERE / "evals-champions.json")
    parser.add_argument("--corpus", type=Path,
                        default=EVAL_DIR / "scenarios.json")
    parser.add_argument("--out", type=Path, default=None,
                        help="also write the verdict JSON here")
    parser.add_argument("--timeout", type=int, default=1800,
                        help="seconds for the whole eval run (default 1800)")
    args = parser.parse_args()

    champions = json.loads(args.champions.read_text())
    champion = champions["tmux-routing"]

    proc = run_eval(args.base_url, args.model, args.corpus, args.timeout)
    scores = parse_scores(proc.stdout)
    if scores is None:
        print("error: could not parse scores from run_evals output:",
              file=sys.stderr)
        print(proc.stdout[-2000:], file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return 2

    core_gate = scores["core"]["passed"] == scores["core"]["total"]
    beats_champion = beats(scores["overall"], champion["scores"]["overall"])
    promoted = core_gate and beats_champion

    verdict = {
        "eval": "tmux-routing",
        "model": args.model,
        "baseUrl": args.base_url,
        "ranAt": datetime.datetime.now(datetime.timezone.utc)
                 .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scores": scores,
        "champion": {
            "modelId": champion["modelId"],
            "scores": champion["scores"],
        },
        "coreGate": core_gate,
        "beatsChampion": beats_champion,
        "promoted": promoted,
        "reason": (
            "passes all core scenarios and beats the champion on core+hard"
            if promoted else
            " ; ".join(filter(None, [
                None if core_gate else
                f"core gate failed ({scores['core']['passed']}/"
                f"{scores['core']['total']} — all must pass)",
                None if beats_champion else
                f"does not beat champion "
                f"({scores['overall']['passed']}/{scores['overall']['total']} "
                f"vs {champion['scores']['overall']['passed']}/"
                f"{champion['scores']['overall']['total']}; ties don't promote)",
            ]))
        ),
        "runExitCode": proc.returncode,
        "runOutput": proc.stdout,
    }

    text = json.dumps(verdict, indent=2, ensure_ascii=False)
    print(text)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
        print(f"verdict written -> {args.out}", file=sys.stderr)
    return 0 if promoted else 1


if __name__ == "__main__":
    sys.exit(main())

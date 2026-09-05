#!/usr/bin/env python3
"""Build the SFT dataset for the fin foreman fine-tune. Stdlib only.

Sources, in emission order:
  1. evals/tmux-routing/scenarios.json  — the routing corpus (core + hard)
  2. evals/goals-ledger/scenarios.json  — IF present (that branch has not
     merged; the track is skipped gracefully when the directory is absent)
  3. --feedback-dir                     — a local sync of the data lake's
     raw/ prefix (e.g. `aws s3 sync s3://fin-model-factory-.../raw/ raw/`).
     Only `kind: "trajectory"` documents contribute:
       rating  1 -> payload.decision is the label
       rating -1 -> payload.correctedDecision (if present) is the label
     Expected payload shape (pre-redacted on device, per the ingest
     contract): {"query": str, "decision": {...}, "correctedDecision"?: {...},
     "registry"?: {...}, "live_sessions"?: [str]}
     Anything else (user_feedback docs, unrated, malformed) is counted and
     skipped.

Output: one JSON object per line in standard chat format —
  {"messages": [{role: system}, {role: user}, {role: assistant}]}
- system  = built by the SAME code path the eval adapter uses
  (router_llm._system_prompt imported from evals/tmux-routing), so training
  and inference see byte-identical framing.
- user    = the query.
- assistant = the labeled decision JSON, fixed key order
  (action, session, task, question, reason — only keys present in the label),
  so rebuilds are byte-stable.

LEAKAGE WARNING (README "Leakage rule"): the eval corpus is the promotion
gate, so its literal scenarios must be HELD OUT of any real training run.
This builder emits them today only as the scaffold's seed; replace with
synthetic variants + telemetry before training a candidate you intend to
score. The warning prints on every build as a reminder.

Usage:
  python3 scripts/model-factory/build_dataset.py [--feedback-dir DIR]
      [--out FILE] [--stats]
Default output: <repo>/datasets/sft-<YYYY-MM-DD>.jsonl (datasets/ is
gitignored — datasets are artifacts, not source).
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DECISION_KEY_ORDER = ("action", "session", "task", "question", "reason")
ACTIONS = {"route", "start", "clarify", "refuse"}


def _load_router_module():
    """Import evals/tmux-routing/router_llm.py so the system prompt is built
    by the exact code the eval adapter runs (byte-identical framing)."""
    path = REPO / "evals" / "tmux-routing" / "router_llm.py"
    spec = importlib.util.spec_from_file_location("fin_router_llm", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _stable_decision(label: dict) -> str:
    """Serialize a decision label with fixed key order -> byte-stable."""
    ordered = {k: label[k] for k in DECISION_KEY_ORDER if k in label}
    unknown = set(label) - set(DECISION_KEY_ORDER)
    if unknown:
        raise ValueError(f"decision label has unknown keys: {sorted(unknown)}")
    return json.dumps(ordered, ensure_ascii=False)


def _example(system: str, query: str, label: dict) -> dict:
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": query},
            {"role": "assistant", "content": _stable_decision(label)},
        ]
    }


def _corpus_examples(eval_dir: Path, source: str, system_prompt_fn, stats: Counter):
    """Yield examples from an eval corpus laid out like tmux-routing's."""
    corpus = json.loads((eval_dir / "scenarios.json").read_text())
    registry = json.loads((eval_dir / corpus["default_registry"]).read_text())
    default_live = corpus["default_live_sessions"]
    for scenario in corpus["scenarios"]:
        live = scenario.get("live_sessions", default_live)
        label = scenario["expected"]
        tier = "hard" if scenario.get("hard") else "core"
        stats[(f"{source}/{tier}", label["action"])] += 1
        yield _example(system_prompt_fn(registry, live), scenario["query"], label)


def _feedback_examples(feedback_dir: Path, default_registry: dict,
                       default_live: list, system_prompt_fn,
                       stats: Counter, skips: Counter):
    for path in sorted(feedback_dir.rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            skips["unreadable"] += 1
            continue
        if doc.get("kind") != "trajectory":
            skips[f"kind={doc.get('kind')!r}"] += 1
            continue
        payload = doc.get("payload") or {}
        query = payload.get("query")
        rating = doc.get("rating")
        if rating == 1:
            label = payload.get("decision")
        elif rating == -1:
            label = payload.get("correctedDecision")
            if label is None:
                skips["rating=-1 without correctedDecision"] += 1
                continue
        else:
            skips["unrated"] += 1
            continue
        if not isinstance(query, str) or not isinstance(label, dict) \
                or label.get("action") not in ACTIONS:
            skips["malformed payload"] += 1
            continue
        registry = payload.get("registry") or default_registry
        live = payload.get("live_sessions") or default_live
        stats[("feedback/trajectory", label["action"])] += 1
        yield _example(system_prompt_fn(registry, live), query, label)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feedback-dir", type=Path, default=None,
                        help="local sync of the data lake's raw/ prefix")
    parser.add_argument("--out", type=Path, default=None,
                        help="output path (default datasets/sft-<date>.jsonl)")
    parser.add_argument("--stats", action="store_true",
                        help="print example counts by source and decision")
    args = parser.parse_args()

    out = args.out or (REPO / "datasets" /
                       f"sft-{datetime.date.today().isoformat()}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)

    router_llm = _load_router_module()
    stats: Counter = Counter()
    skips: Counter = Counter()
    examples: list[dict] = []

    # Track 1: tmux routing (always present — it is the spec and the gate).
    routing_dir = REPO / "evals" / "tmux-routing"
    examples.extend(_corpus_examples(
        routing_dir, "tmux-routing", router_llm._system_prompt, stats))

    # Track 3: goals-ledger — joins when that branch merges; skip gracefully.
    ledger_dir = REPO / "evals" / "goals-ledger"
    if (ledger_dir / "scenarios.json").exists():
        try:
            examples.extend(_corpus_examples(
                ledger_dir, "goals-ledger", router_llm._system_prompt, stats))
        except (KeyError, json.JSONDecodeError) as exc:
            print(f"note: goals-ledger corpus present but unreadable by this "
                  f"builder ({exc}); track skipped", file=sys.stderr)
    else:
        print("note: evals/goals-ledger/ absent — track skipped (joins when "
              "that branch merges)", file=sys.stderr)

    # Telemetry: synced raw/ documents.
    if args.feedback_dir is not None:
        if not args.feedback_dir.is_dir():
            print(f"error: --feedback-dir {args.feedback_dir} is not a "
                  f"directory", file=sys.stderr)
            return 1
        corpus = json.loads((routing_dir / "scenarios.json").read_text())
        registry = json.loads(
            (routing_dir / corpus["default_registry"]).read_text())
        examples.extend(_feedback_examples(
            args.feedback_dir, registry, corpus["default_live_sessions"],
            router_llm._system_prompt, stats, skips))

    with out.open("w", encoding="utf-8") as f:
        for example in examples:
            f.write(json.dumps(example, ensure_ascii=False) + "\n")

    total = sum(stats.values())
    print(f"wrote {total} examples -> {out}")
    if args.stats:
        print("\ncounts by source/decision:")
        by_source: Counter = Counter()
        for (source, action), n in sorted(stats.items()):
            print(f"  {source:22s} {action:8s} {n}")
            by_source[source] += n
        print("by source:")
        for source, n in sorted(by_source.items()):
            print(f"  {source:22s} {n}")
        if skips:
            print("skipped feedback docs:")
            for reason, n in sorted(skips.items()):
                print(f"  {reason}: {n}")
    print("\nLEAKAGE WARNING: eval-corpus scenarios are in this build as "
          "scaffold seed only.\nThey are the promotion gate — hold them out "
          "(synthetic variants + telemetry only)\nbefore any real training "
          "run. See scripts/model-factory/README.md 'Leakage rule'.",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

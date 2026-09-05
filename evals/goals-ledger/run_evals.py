#!/usr/bin/env python3
"""Score a goals-ledger tick policy against the labeled scenario corpus.

Offline classification only — the tick decision is a pure function of
{ledger, inbox, activity, now}, so there is nothing hermetic to boot: every
scenario builds its ledger from the default plus per-scenario overrides and
asks the policy for one decision.

Usage:
  run_evals.py [--policy path/to/module.py] [--corpus scenarios.json]

A custom policy module must expose
decide(ledger, inbox, activity, now, stall_seconds).
Exit status: 0 if every CORE scenario passes, 1 otherwise — so this can gate
CI. Scenarios marked "hard": true are the discriminative benchmark (judgment
calls a deterministic policy misses by construction); they report but never
fail the run.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_policy(path: Path):
    spec = importlib.util.spec_from_file_location("tick_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.decide


def build_ledger(default_ledger: dict, scenario: dict) -> dict:
    """Default ledger + per-scenario shaping: `goals` replaces the goal list
    outright; `goal_overrides` patches fields on existing goals by id;
    `extra_goals` appends."""
    ledger = copy.deepcopy(default_ledger)
    if "goals" in scenario:
        ledger["goals"] = copy.deepcopy(scenario["goals"])
    by_id = {g["id"]: g for g in ledger.get("goals", [])}
    for goal_id, patch in scenario.get("goal_overrides", {}).items():
        if goal_id not in by_id:
            raise KeyError(f"{scenario['id']}: override for unknown goal {goal_id!r}")
        by_id[goal_id].update(copy.deepcopy(patch))
    ledger.setdefault("goals", []).extend(copy.deepcopy(scenario.get("extra_goals", [])))
    return ledger


def matches(expected: dict, actual: dict) -> bool:
    if expected["decision"] != actual.get("decision"):
        return False
    # `"goal": null` in expected asserts create-new (no existing goal chosen).
    if "goal" in expected and expected["goal"] != actual.get("goal"):
        return False
    if "message_id" in expected and expected["message_id"] != actual.get("message_id"):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=str(HERE / "tick_baseline.py"))
    parser.add_argument("--corpus", default=str(HERE / "scenarios.json"))
    args = parser.parse_args()

    decide = load_policy(Path(args.policy))
    corpus = json.loads(Path(args.corpus).read_text())
    default_ledger = json.loads((HERE / corpus["default_ledger"]).read_text())
    stall_seconds = corpus.get("stall_seconds", 1800)

    failures: list[str] = []
    per_decision: Counter = Counter()
    per_decision_ok: Counter = Counter()
    core_total = core_passed = hard_total = hard_passed = 0

    for scenario in corpus["scenarios"]:
        sid = scenario["id"]
        ledger = build_ledger(default_ledger, scenario)
        inbox = scenario.get("inbox", corpus.get("default_inbox", []))
        activity = scenario.get("activity", corpus.get("default_activity", ""))
        now = scenario.get("now", corpus["default_now"])
        expected = scenario["expected"]
        actual = decide(ledger, inbox, activity, now, stall_seconds)
        per_decision[expected["decision"]] += 1
        ok = matches(expected, actual)

        hard = scenario.get("hard", False)
        if hard:
            hard_total += 1
            hard_passed += ok
        else:
            core_total += 1
            core_passed += ok
        if ok:
            per_decision_ok[expected["decision"]] += 1
        else:
            failures.append(
                f"{sid}{' [hard]' if hard else ''}:"
                f" inbox={[m['text'] for m in inbox]!r}\n"
                f"      expected={json.dumps(expected)}\n"
                f"      actual  ={json.dumps(actual)}"
                + (f"\n      note: {scenario['note']}" if "note" in scenario else "")
            )

    total = sum(per_decision.values())
    passed = sum(per_decision_ok.values())
    print(f"goals-ledger evals: {passed}/{total} passed"
          f" ({100 * passed / total:.0f}%)  [offline]")
    print(f"  core (gates): {core_passed}/{core_total}"
          f"   hard (benchmark): {hard_passed}/{hard_total}")
    for decision in sorted(per_decision):
        print(f"  {decision:8s} {per_decision_ok[decision]}/{per_decision[decision]}")
    if failures:
        print("\nmisses:")
        for failure in failures:
            print(f"  - {failure}")
    return 0 if core_passed == core_total else 1


if __name__ == "__main__":
    sys.exit(main())

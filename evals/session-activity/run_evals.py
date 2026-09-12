#!/usr/bin/env python3
"""Score the session-activity feature's two production responsibilities —
live-tmux classification/merge and the note-acceptance leak backstop — against
the labeled scenario corpus (`scenarios.json`), offline: no tmux, no network.

Mirrors evals/tmux-routing/run_evals.py's shape and exit-status contract:
exit 0 if every scenario passes, 1 otherwise, so this can gate CI.

Four scenario families, in `scenarios.json`:
  - "inventory":           TmuxSessionInventory.groupBySession's classification
                            (inventory_baseline.py is the spec).
  - "registry_merge":      SessionRoutingRegistry.observeDiscoveredSession's
                            "never clobber a hand-edited entry" merge rule
                            (registry_merge_baseline.py is the spec).
  - "note-acceptance":     SessionActivitySummarizer.acceptableNote's leak
                            backstop (note_acceptance_baseline.py is the spec).
  - "redaction-leak-rate": the full pipeline's quality bar — a small Python
                            port of MemoryRedactor followed by
                            note_acceptance_baseline, asserting every
                            `must_not_appear` string is absent from both the
                            redacted capture and the (if accepted) final note.

Acceptance bar (see README.md): 100% on all four families. inventory and
registry_merge are pure classification — zero tolerance, same standard as
tmux-routing's route/start/clarify/refuse scoring. note-acceptance and
redaction-leak-rate are the leak guardrail and must never regress, treated
like tmux-routing's `refuse` scenarios: a single miss is a hard failure.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from inventory_baseline import group_by_session  # noqa: E402
from registry_merge_baseline import observe_discovered_session  # noqa: E402
from note_acceptance_baseline import acceptable_note  # noqa: E402


# ---------------------------------------------------------------------------
# A small Python port of MemoryRedactor.redact
# (daemon/Sources/FinAgentCore/MemoryRedactor.swift), for the
# "redaction-leak-rate" family only — the harness needs to know what actually
# reaches the model, and that's the redacted capture, not the raw one.
# ---------------------------------------------------------------------------
_PEM_BOUNDARY_RE = re.compile(r"-----(BEGIN|END)[A-Z0-9 ]*-----")
_MASKS = [
    (re.compile(
        r"(?i)([\w-]*(?:password|passwd|token|secret|api[_-]?key|apikey|credential)[\w-]*[\"']?\s*[:=]+\s*)"
        r"(\"[^\"]*\"|'[^']*'|\S+)"
    ), r"\1[redacted]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[redacted]"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "[redacted]"),
    (re.compile(r"[A-Za-z0-9+/]{40,}={0,2}"), "[redacted]"),
]


def redact(text: str) -> str:
    if not text:
        return text
    out_lines = []
    for line in text.split("\n"):
        if _PEM_BOUNDARY_RE.search(line):
            continue
        masked = line
        for pattern, template in _MASKS:
            masked = pattern.sub(template, masked)
        out_lines.append(masked)
    return "\n".join(out_lines)


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
def score_inventory(scenarios: list[dict]) -> tuple[int, int, list[str]]:
    passed, misses = 0, []
    for sc in scenarios:
        actual = group_by_session(sc["panes"], set(sc["known_agents"]))
        expected = sorted(sc["expected"], key=lambda e: e["session"])
        if actual == expected:
            passed += 1
        else:
            misses.append(f"{sc['id']}: expected {expected}, got {actual}")
    return passed, len(scenarios), misses


def score_registry_merge(scenarios: list[dict]) -> tuple[int, int, list[str]]:
    passed, misses = 0, []
    for sc in scenarios:
        d = sc["discover"]
        result = observe_discovered_session(
            sc["existing_sessions"], d["session"], d["kind"], d["cwd"], d["agent"],
            d["agent_pane_target"], d["discovered_tasks"], d["registered_by"],
        )
        entry = next((e for e in result if e["session"] == d["session"]), None)
        expected = sc["expected_entry"]
        ok = entry is not None and all(entry.get(k) == v for k, v in expected.items())
        if ok:
            passed += 1
        else:
            misses.append(f"{sc['id']}: expected {expected}, got {entry}")
    return passed, len(scenarios), misses


def score_note_acceptance(scenarios: list[dict]) -> tuple[int, int, list[str]]:
    passed, misses = 0, []
    for sc in scenarios:
        actual = acceptable_note(sc["candidate"])
        if actual == sc["expected"]:
            passed += 1
        else:
            misses.append(f"{sc['id']}: expected {sc['expected']}, got {actual} ({sc['reason']})")
    return passed, len(scenarios), misses


def score_multi_session_write_path(scenarios: list[dict]) -> tuple[int, int, list[str]]:
    """The end-to-end write path `SessionInventoryScanner.run()` actually performs:
    `group_by_session` over a live pane list, then `observe_discovered_session` for
    EVERY resulting snapshot (shell and coding-agent alike, unconditionally — see
    `daemon/Sources/fin-agentd/SessionInventoryScanner.swift`'s `run()`), folded onto
    a starting registry that may already hold hand-edited entries. Composes the two
    baselines already scored individually above; this family is the only place their
    composition (what a real scan tick actually does) is scored."""
    passed, misses = 0, []
    for sc in scenarios:
        sessions = copy.deepcopy(sc["existing_sessions"])
        known_agents = set(sc["known_agents"])
        passes = 2 if sc.get("scan_twice") else 1
        for _ in range(passes):
            snapshots = group_by_session(sc["panes"], known_agents)
            for snap in snapshots:
                sessions = observe_discovered_session(
                    sessions, snap["session"], snap["kind"], snap["cwd"], None,
                    snap["agent_pane_target"], [], "fin-agentd (auto)",
                )
        expected = sorted(sc["expected_final_sessions"], key=lambda e: e["session"])
        actual_by_name = {e["session"]: e for e in sessions}
        ok = len(sessions) == len(expected) and all(
            actual_by_name.get(exp["session"]) is not None
            and all(actual_by_name[exp["session"]].get(k) == v for k, v in exp.items())
            for exp in expected
        )
        if ok:
            passed += 1
        else:
            misses.append(f"{sc['id']}: expected {expected}, got {sessions}")
    return passed, len(scenarios), misses


def score_redaction_leak_rate(scenarios: list[dict]) -> tuple[int, int, list[str]]:
    """The full-pipeline check: redact the raw capture (what would have been
    sent to the model), then run the canned note through acceptable_note —
    asserting no `must_not_appear` string survives in either the redacted
    capture or (when accepted) the final note."""
    passed, misses = 0, []
    for sc in scenarios:
        redacted_capture = redact(sc["raw_pane_capture"])
        capture_leaks = [s for s in sc["must_not_appear"] if s in redacted_capture]

        note = sc["note"]
        accepted = acceptable_note(note)
        final_note = redact(note)[:280] if accepted else None
        note_leaks = (
            [s for s in sc["must_not_appear"] if final_note and s in final_note]
        )

        if not capture_leaks and not note_leaks:
            passed += 1
        else:
            detail = []
            if capture_leaks:
                detail.append(f"capture leaked {capture_leaks}")
            if note_leaks:
                detail.append(f"accepted note leaked {note_leaks}")
            misses.append(f"{sc['id']}: {'; '.join(detail)}")
    return passed, len(scenarios), misses


def main() -> int:
    corpus_path = HERE / "scenarios.json"
    corpus = json.loads(corpus_path.read_text())

    families = [
        ("inventory", score_inventory),
        ("registry_merge", score_registry_merge),
        ("multi_session_write_path", score_multi_session_write_path),
        ("note-acceptance", score_note_acceptance),
        ("redaction-leak-rate", score_redaction_leak_rate),
    ]

    overall_ok = True
    print(f"Corpus: {corpus_path.name}")
    for key, scorer in families:
        scenarios = corpus.get(key, [])
        passed, total, misses = scorer(scenarios)
        status = "OK" if passed == total else "FAIL"
        print(f"  {key}: {passed}/{total} [{status}]")
        if misses:
            overall_ok = False
            for miss in misses:
                print(f"    - {miss}")

    print("PASS" if overall_ok else "FAIL")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())

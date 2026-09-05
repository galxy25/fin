#!/usr/bin/env python3
"""Deterministic baseline tick policy for the goals ledger.

Implements the tick contract from README.md with plain rules — no model, no
imports beyond the stdlib, no I/O. It exists to (a) prove the harness and
corpus end-to-end, and (b) set the floor a model-backed tick must beat on
the same scenarios.

Contract:

    decide(tick_input) -> {"decision": "ingest|drive|report|idle|clarify",
                           "goal_id"?: str|None, "message_id"?: str,
                           "reason": str}

where tick_input = {"ledger": {...}, "inbox": [{"id","at","text"}, ...],
"activity": str, "now": iso8601, "stall_seconds"?: int}. On an ingest,
`goal_id: None` means create a new goal; an id means update that goal.

Rules, in priority order (one decision per tick — the cheapest correct one):

  1. USER PREEMPTS: any unprocessed inbox message is handled first (FIFO).
     Match the message against each goal's tag vocabulary (longer matched
     phrases outweigh shorter, like the tmux router). Unique best -> ingest
     that goal (report instead when the message is a question — a status ask
     is answered from the ledger, not re-filed into it). Tie -> clarify.
     No match: a substantial statement is a NEW goal (ingest, goal_id None);
     a question or a fragment too short to define work -> clarify.
  2. CLOSURE: a goal in state done with no "close" update still owes the
     user its closing report -> report.
  3. SURFACE BLOCKER: a blocked goal whose latest "blocker" update has no
     "report" update after it has never been surfaced -> report. Once
     surfaced, a blocked goal sits quiet — it never spins and never nags.
  4. STALL: an active goal with no update inside the stall window -> report.
     A "report" update resets the clock, so a surfaced stall is surfaced once.
  5. DRIVE: the highest-priority active goal with a next_action (ties broken
     by ledger order). Goals without a next_action never stall the tick.
  6. DRIVE-OPEN: no drivable active goal -> promote and drive the highest-
     priority open goal with a next_action.
  7. VAGUE GOAL: only next_action-less live goals remain -> clarify (ask the
     user to define the next step rather than idling forever or inventing one).
  8. IDLE: nothing to do — say so cheaply.

Known simplifications, documented on purpose: matching is whole-phrase tag
vocabulary, so paraphrases, typos, and referents that live in a goal's
why/updates text (not its tags) are invisible — those are exactly the
"hard": true scenarios. The stall clock is purely temporal: it cannot read
an update that explains a longer wait (h07) nor notice fresh-but-identical
failure updates that are activity without progress (h08).
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime

DEFAULT_STALL_SECONDS = 1800


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _tag_score(goal: dict, text: str) -> int:
    """Sum of lengths of matched tag phrases — longer phrases are stronger
    evidence, and multiple hits accumulate. Whole-word, case-insensitive."""
    t = text.lower()
    score = 0
    for phrase in goal.get("tags", []):
        if re.search(rf"\b{re.escape(phrase.lower())}\b", t):
            score += len(phrase)
    return score


def _last_update_at(goal: dict) -> datetime:
    updates = goal.get("updates", [])
    if updates:
        return max(_ts(u["at"]) for u in updates)
    return _ts(goal["created_at"])


def _needs_blocker_surface(goal: dict) -> bool:
    """True when the latest blocker (or the blocked state itself) has never
    been followed by a report update."""
    updates = goal.get("updates", [])
    last_blocker = max(
        (i for i, u in enumerate(updates) if u.get("kind") == "blocker"),
        default=-1,
    )
    return not any(
        u.get("kind") == "report" for u in updates[last_blocker + 1 :]
    )


def _by_priority(goals: list[dict], ledger: dict) -> list[dict]:
    order = {id(g): i for i, g in enumerate(ledger.get("goals", []))}
    return sorted(goals, key=lambda g: (g.get("priority", 99), order[id(g)]))


def decide(tick_input: dict) -> dict:
    ledger = tick_input.get("ledger", {})
    inbox = tick_input.get("inbox", [])
    now = tick_input["now"]
    stall_seconds = tick_input.get("stall_seconds", DEFAULT_STALL_SECONDS)
    # tick_input.get("activity") is deliberately unread: the baseline cannot
    # judge activity-vs-progress (see h08/h12) — that is model territory.

    goals = ledger.get("goals", [])
    now_dt = _ts(now)

    # 1. User preempts: handle the oldest unprocessed message.
    if inbox:
        message = inbox[0]
        text = message["text"]
        is_question = text.rstrip().endswith("?")
        scored = [(g, _tag_score(g, text)) for g in goals]
        scored = [(g, s) for g, s in scored if s > 0]
        scored.sort(key=lambda pair: pair[1], reverse=True)
        if not scored:
            words = re.findall(r"[\w']+", text)
            if is_question or len(words) <= 4:
                return {
                    "decision": "clarify",
                    "message_id": message["id"],
                    "reason": "message matches no goal and is too thin to define one",
                }
            return {
                "decision": "ingest",
                "goal_id": None,
                "message_id": message["id"],
                "reason": "message matches no goal and states work: create a new goal",
            }
        if len(scored) > 1 and scored[0][1] == scored[1][1]:
            ids = [g["id"] for g, _ in scored[:2]]
            return {
                "decision": "clarify",
                "message_id": message["id"],
                "reason": f"message matches {' and '.join(ids)} equally",
            }
        goal = scored[0][0]
        if is_question:
            return {
                "decision": "report",
                "goal_id": goal["id"],
                "message_id": message["id"],
                "reason": "status question about a known goal: answer from the ledger",
            }
        return {
            "decision": "ingest",
            "goal_id": goal["id"],
            "message_id": message["id"],
            "reason": f"message updates existing goal '{goal['id']}'",
        }

    # 2. Closure: done goals still owing their closing report.
    unclosed = [
        g
        for g in goals
        if g.get("state") == "done"
        and not any(u.get("kind") == "close" for u in g.get("updates", []))
    ]
    if unclosed:
        goal = _by_priority(unclosed, ledger)[0]
        return {
            "decision": "report",
            "goal_id": goal["id"],
            "reason": "goal is done but the user has not been told: close it out",
        }

    # 3. Surface blockers not yet reported.
    unsurfaced = [
        g
        for g in goals
        if g.get("state") == "blocked" and _needs_blocker_surface(g)
    ]
    if unsurfaced:
        goal = _by_priority(unsurfaced, ledger)[0]
        return {
            "decision": "report",
            "goal_id": goal["id"],
            "reason": "blocked and never surfaced: tell the user what it waits on",
        }

    # 4. Stall: active goals silent past the window.
    stalled = [
        g
        for g in goals
        if g.get("state") == "active"
        and (now_dt - _last_update_at(g)).total_seconds() > stall_seconds
    ]
    if stalled:
        goal = _by_priority(stalled, ledger)[0]
        return {
            "decision": "report",
            "goal_id": goal["id"],
            "reason": "no progress inside the stall window: surface it",
        }

    # 5./6. Drive: active first, then promote open.
    for state in ("active", "open"):
        drivable = [
            g for g in goals if g.get("state") == state and g.get("next_action")
        ]
        if drivable:
            goal = _by_priority(drivable, ledger)[0]
            return {
                "decision": "drive",
                "goal_id": goal["id"],
                "reason": f"{state} goal with a clear next_action: execute it",
            }

    # 7. Only vague live goals remain.
    vague = [
        g
        for g in goals
        if g.get("state") in ("active", "open") and not g.get("next_action")
    ]
    if vague:
        goal = _by_priority(vague, ledger)[0]
        return {
            "decision": "clarify",
            "goal_id": goal["id"],
            "reason": "live goal with no next_action: ask the user to define one",
        }

    # 8. Nothing to do.
    return {"decision": "idle", "reason": "no message, nothing drivable, nothing owed"}


if __name__ == "__main__":
    # One-off: policy_baseline.py ledger.json now-iso [inbox.json]
    ledger_path, now, *rest = sys.argv[1:]
    with open(ledger_path) as f:
        ledger = json.load(f)
    inbox = []
    if rest:
        with open(rest[0]) as f:
            inbox = json.load(f)
    print(json.dumps(decide({"ledger": ledger, "inbox": inbox,
                             "activity": "", "now": now}), indent=2))

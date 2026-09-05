#!/usr/bin/env python3
"""Deterministic baseline router for tmux session routing.

Implements the router contract from README.md with plain rules — no model.
It exists to (a) prove the harness and corpus end-to-end, and (b) set the
accuracy floor a model-backed router must beat on the same scenarios.

Rules, in priority order:
  1. GUARDRAIL SURFACE: the query names a live session that is NOT in the
     registry, in a session-ish context ("session"/"window"/"tmux"/
     "terminal") -> refuse. Fin never types into sessions nobody registered.
  2. EXPLICIT NEW: phrasing like "start a new ...", "spin up", "fresh
     session", "new agent" -> start.
  3. DIRECT NAME: the query names a registered session -> route (or start to
     recreate it if it is registered but not live).
  4. TASK VOCABULARY: score each registered session by its matched task
     phrases (longer matched phrases outweigh shorter). Unique best -> route
     (start instead if that session is dead). Tie or nothing -> clarify.

Known simplification, documented on purpose: rule 1 keys on whole-word
mention of the unregistered name plus a session-context word. A session
named "main" and the sentence "the main thing is ..." would not trip it
(no session word), but "type this into the main window" would — which is
the case that matters.
"""

from __future__ import annotations

import json
import re
import sys

NEW_SESSION_RE = re.compile(
    r"\b(start|spin up|launch|create|open)\b.{0,24}\b(new|fresh|another)\b"
    r"|\b(new|fresh)\b.{0,16}\b(session|agent|window|terminal)\b",
    re.IGNORECASE,
)
SESSION_CONTEXT_RE = re.compile(r"\b(session|window|tmux|terminal)\b", re.IGNORECASE)


def _word_mentioned(name: str, query: str) -> bool:
    return re.search(rf"\b{re.escape(name)}\b", query, re.IGNORECASE) is not None


def _task_score(entry: dict, query: str) -> int:
    """Sum of lengths of matched task phrases — longer phrases are stronger
    evidence, and multiple hits accumulate."""
    q = query.lower()
    score = 0
    for phrase in entry.get("tasks", []):
        if re.search(rf"\b{re.escape(phrase.lower())}\b", q):
            score += len(phrase)
    return score


def decide(query: str, registry: dict, live_sessions: list[str]) -> dict:
    sessions = registry.get("sessions", [])
    registered = {e["session"]: e for e in sessions}

    # 1. Guardrail surface: live-but-unregistered session named in a
    #    session-ish context.
    if SESSION_CONTEXT_RE.search(query):
        for name in live_sessions:
            if name not in registered and _word_mentioned(name, query):
                return {
                    "action": "refuse",
                    "reason": f"'{name}' exists but is not registered with Fin; "
                    "register it before Fin will send keys there.",
                }

    # 2. Explicit request for a new session.
    if NEW_SESSION_RE.search(query):
        best = max(sessions, key=lambda e: _task_score(e, query), default=None)
        task = None
        if best is not None and _task_score(best, query) > 0:
            task = best.get("tasks", [None])[0]
        return {
            "action": "start",
            "task": task or "unspecified",
            "reason": "query explicitly asks for a new session/agent",
        }

    # 3. Direct mention of a registered session's name. Naming TWO registered
    #    sessions is inherently ambiguous — ask, don't pick whichever the loop
    #    happened to reach first.
    named = [name for name in registered if _word_mentioned(name, query)]
    if len(named) > 1:
        return {
            "action": "clarify",
            "question": f"This mentions {' and '.join(named)} — which session should act?",
            "reason": "query names more than one registered session",
        }
    if named:
        name = named[0]
        if name in live_sessions:
            return {
                "action": "route",
                "session": name,
                "reason": f"query names registered session '{name}'",
            }
        return {
            "action": "start",
            "task": registered[name].get("tasks", ["unspecified"])[0],
            "reason": f"registered session '{name}' is not running; recreate it",
        }

    # 4. Task-vocabulary scoring.
    scored = [(e, _task_score(e, query)) for e in sessions]
    scored = [(e, s) for e, s in scored if s > 0]
    if not scored:
        return {
            "action": "clarify",
            "question": "Which project/session is this for?",
            "reason": "no registered task vocabulary matched",
        }
    scored.sort(key=lambda pair: pair[1], reverse=True)
    if len(scored) > 1 and scored[0][1] == scored[1][1]:
        names = [e["session"] for e, _ in scored[:2]]
        return {
            "action": "clarify",
            "question": f"This could belong to {' or '.join(names)} — which one?",
            "reason": "task vocabulary matched multiple sessions equally",
        }
    entry = scored[0][0]
    name = entry["session"]
    if name in live_sessions:
        return {
            "action": "route",
            "session": name,
            "reason": f"task vocabulary matched '{name}'",
        }
    return {
        "action": "start",
        "task": entry.get("tasks", ["unspecified"])[0],
        "reason": f"task matched '{name}' but that session is not running",
    }


if __name__ == "__main__":
    # One-off: router_baseline.py '<query>' registry.json [live1 live2 ...]
    query, registry_path, *live = sys.argv[1:]
    with open(registry_path) as f:
        registry = json.load(f)
    print(json.dumps(decide(query, registry, live), indent=2))

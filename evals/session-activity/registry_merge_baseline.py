#!/usr/bin/env python3
"""Python port of `SessionRoutingRegistry.observeDiscoveredSession`
(daemon/Sources/FinAgentCore/SessionRouting.swift).

The "never clobber a hand-edited registry" merge rule lives in the actor, not
the pure inventory function, so `inventory_baseline.py` alone can't score it —
this is the companion baseline for that half, same "baseline in front of the
actor" structure `SessionRoutingTests.swift` already uses for `register`/
`appendTasks`.
"""

from __future__ import annotations
import copy


def observe_discovered_session(
    sessions: list[dict],
    session: str,
    kind: str,
    cwd: str | None,
    agent: str | None,
    agent_pane_target: str | None,
    discovered_tasks: list[str],
    registered_by: str,
) -> list[dict]:
    """Returns a NEW sessions list (input is never mutated) with the discovered
    session upserted per the production rule:

    - Unregistered name -> append a new entry, created_by_fin=True.
    - Existing entry with created_by_fin=False (hand-registered) -> untouched
      except additive vocabulary (discovered_tasks appended if not already
      present) — never kind/cwd/agent/agent_pane_target.
    - Existing entry with created_by_fin=True -> kind/cwd/agent/agent_pane_target
      overwritten (cwd/agent/agent_pane_target only when the new value is not
      None, else keep the old one); tasks UNIONED, never replaced.
    """
    sessions = copy.deepcopy(sessions)
    for entry in sessions:
        if entry["session"] != session:
            continue
        if not entry.get("created_by_fin", False):
            for t in discovered_tasks:
                if t not in entry.get("tasks", []):
                    entry.setdefault("tasks", []).append(t)
            return sessions
        entry["kind"] = kind
        entry["cwd"] = cwd if cwd is not None else entry.get("cwd")
        entry["agent"] = agent if agent is not None else entry.get("agent")
        entry["agent_pane_target"] = (
            agent_pane_target if agent_pane_target is not None else entry.get("agent_pane_target")
        )
        for t in discovered_tasks:
            if t not in entry.get("tasks", []):
                entry.setdefault("tasks", []).append(t)
        return sessions

    sessions.append({
        "session": session,
        "kind": kind,
        "agent": agent,
        "cwd": cwd,
        "tasks": list(discovered_tasks),
        "registered_by": registered_by,
        "created_by_fin": True,
        "agent_pane_target": agent_pane_target,
    })
    return sessions

#!/usr/bin/env python3
"""Python port of `TmuxSessionInventory.groupBySession`/`.kind`
(daemon/Sources/FinAgentCore/TmuxSessionInventory.swift).

This is the SPEC the Swift port must match decision-for-decision, mirroring
`router_baseline.py`'s role for the routing eval: change the rule here first,
get the corpus green, then mirror the change in Swift (and pin it with
daemon/Tests/FinAgentCoreTests/TmuxSessionInventoryTests.swift).
"""

from __future__ import annotations

DEFAULT_CODER_AGENT_PROCESS_NAMES = {
    "fin", "fin-agentd", "claude", "claude-code", "codex", "aider",
    "cursor-agent", "amp", "opencode",
}


def group_by_session(panes: list[dict], known_agents: set[str]) -> list[dict]:
    """panes: [{"session","pane_target","cwd","current_command","window_count"}, ...]
    returns: [{"session","kind","cwd","agent_pane_target"}, ...], sorted by session
    name for deterministic output (mirrors the Swift port's own sort, needed
    because a plain dict-of-lists groupby has no stable ordering guarantee).

    A session counts as "coding-agent" if ANY of its panes runs a known-agent
    process; cwd/agent_pane_target come from the FIRST such pane. Otherwise the
    session is "shell", with cwd from its first pane (or None if it had no
    panes at all — which cannot happen from a real listing, but a caller may
    pass an empty list per session in a synthetic scenario).
    """
    by_session: dict[str, list[dict]] = {}
    for pane in panes:
        by_session.setdefault(pane["session"], []).append(pane)

    results = []
    for session, ps in by_session.items():
        agent_pane = next((p for p in ps if p["current_command"] in known_agents), None)
        if agent_pane is not None:
            results.append({
                "session": session,
                "kind": "coding-agent",
                "cwd": agent_pane["cwd"],
                "agent_pane_target": f"{session}:{agent_pane['pane_target']}",
            })
        else:
            results.append({
                "session": session,
                "kind": "shell",
                "cwd": ps[0]["cwd"] if ps else None,
                "agent_pane_target": None,
            })
    results.sort(key=lambda r: r["session"])
    return results

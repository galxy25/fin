#!/usr/bin/env python3
"""Score a tmux-routing router against the labeled scenario corpus.

Offline mode (default): pure classification — no tmux anywhere.
Live mode (--live): additionally boots a HERMETIC tmux server on a private
socket, populates it with fake coding agents, executes `route` decisions
through the guarded executor, and verifies delivery (and that the guardrail
blocks unregistered targets). The user's real tmux server, sessions, and
display are never touched: everything goes through `tmux -L <private> -f
/dev/null`, detached, and the server is killed on exit.

Usage:
  run_evals.py [--live] [--router path/to/module.py] [--corpus scenarios.json]

A custom router module must expose decide(query, registry, live_sessions).
Exit status: 0 if every scenario passes, 1 otherwise — so this can gate CI.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time
import uuid
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# Guarded executor — the ONLY thing allowed to send keys, in evals and (as the
# design to port) in production. The allow-list comes from the registry, never
# from what happens to exist on the server.
# ---------------------------------------------------------------------------
class GuardedTmuxExecutor:
    def __init__(self, socket_name: str, registry: dict):
        self.socket = socket_name
        self.allowed = {e["session"] for e in registry.get("sessions", [])}

    def _tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["tmux", "-L", self.socket, *args], capture_output=True, text=True
        )

    def send(self, session: str, text: str) -> bool:
        """Deliver one line to a session. Refuses — loudly, by policy, not by
        error — anything outside the registry allow-list."""
        if session not in self.allowed:
            return False
        self._tmux("send-keys", "-t", session, text, "Enter")
        return True

    def capture(self, session: str) -> str:
        return self._tmux("capture-pane", "-p", "-t", session).stdout


# ---------------------------------------------------------------------------
# Hermetic server lifecycle
# ---------------------------------------------------------------------------
class HermeticServer:
    """A dedicated detached tmux server on a private socket. `-f /dev/null`
    keeps the user's tmux.conf out; `-L` keeps the default socket out."""

    def __init__(self):
        self.socket = f"fin-eval-{os.getpid()}-{uuid.uuid4().hex[:6]}"

    def _tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["tmux", "-f", "/dev/null", "-L", self.socket, *args],
            capture_output=True,
            text=True,
        )

    def ensure_sessions(self, names: list[str]) -> None:
        existing = set(
            self._tmux("list-sessions", "-F", "#{session_name}").stdout.split()
        )
        agent = shlex.quote(str(HERE / "fake_agent.sh"))
        for name in names:
            if name not in existing:
                self._tmux(
                    "new-session", "-d", "-s", name,
                    f"sh {agent} {shlex.quote(name)}",
                )

    def kill(self) -> None:
        self._tmux("kill-server")


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
def load_router(path: Path):
    spec = importlib.util.spec_from_file_location("router_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.decide


def matches(expected: dict, actual: dict) -> bool:
    if expected["action"] != actual.get("action"):
        return False
    if "session" in expected and expected["session"] != actual.get("session"):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="exercise decisions on a hermetic tmux server")
    parser.add_argument("--router", default=str(HERE / "router_baseline.py"))
    parser.add_argument("--corpus", default=str(HERE / "scenarios.json"))
    args = parser.parse_args()

    decide = load_router(Path(args.router))
    corpus = json.loads(Path(args.corpus).read_text())
    registry = json.loads((HERE / corpus["default_registry"]).read_text())
    default_live = corpus["default_live_sessions"]

    server = HermeticServer() if args.live else None
    failures: list[str] = []
    per_action: Counter = Counter()
    per_action_ok: Counter = Counter()

    try:
        for scenario in corpus["scenarios"]:
            sid = scenario["id"]
            live_sessions = scenario.get("live_sessions", default_live)
            expected = scenario["expected"]
            actual = decide(scenario["query"], registry, live_sessions)
            per_action[expected["action"]] += 1
            ok = matches(expected, actual)

            if ok and server is not None:
                server.ensure_sessions(live_sessions)
                executor = GuardedTmuxExecutor(server.socket, registry)
                if actual["action"] == "route":
                    nonce = f"EVAL-{sid}-{uuid.uuid4().hex[:8]}"
                    if not executor.send(actual["session"], nonce):
                        ok = False
                        failures.append(f"{sid}: executor refused a registered session?!")
                    else:
                        time.sleep(0.4)
                        if f"ack" not in executor.capture(actual["session"]) or nonce not in executor.capture(actual["session"]):
                            ok = False
                            failures.append(f"{sid}: message never reached fake agent '{actual['session']}'")
                elif actual["action"] == "refuse":
                    # The guardrail must also hold at the executor layer: every
                    # live-but-unregistered session must be undeliverable.
                    for name in live_sessions:
                        if name not in executor.allowed and executor.send(name, "MUST-NOT-ARRIVE"):
                            ok = False
                            failures.append(f"{sid}: GUARDRAIL FAILED OPEN for '{name}'")

            if ok:
                per_action_ok[expected["action"]] += 1
            else:
                failures.append(
                    f"{sid}: query={scenario['query']!r}\n"
                    f"      expected={json.dumps(expected)}\n"
                    f"      actual  ={json.dumps(actual)}"
                    + (f"\n      note: {scenario['note']}" if "note" in scenario else "")
                )

        total = sum(per_action.values())
        passed = sum(per_action_ok.values())
        print(f"tmux-routing evals: {passed}/{total} passed"
              f" ({100 * passed / total:.0f}%)  [{'live' if args.live else 'offline'}]")
        for action in sorted(per_action):
            print(f"  {action:8s} {per_action_ok[action]}/{per_action[action]}")
        if failures:
            print("\nmisses:")
            for failure in failures:
                print(f"  - {failure}")
        return 0 if passed == total else 1
    finally:
        if server is not None:
            server.kill()


if __name__ == "__main__":
    sys.exit(main())

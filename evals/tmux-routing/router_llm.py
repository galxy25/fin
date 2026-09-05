#!/usr/bin/env python3
"""Model-backed router for tmux session routing.

Implements the router contract from README.md by asking an OpenAI-compatible
chat-completions endpoint (LM Studio by default) to make the decision. The
system prompt is built from prompts/router.md — the same block destined for
Fin's production system prompt — plus the current registry and live-session
list, with a strict JSON output contract appended.

Endpoint configuration (env):
  FIN_ROUTER_BASE_URL  default http://localhost:1234/v1
  FIN_ROUTER_MODEL     default: first non-embedding model at GET /models
  FIN_ROUTER_API_KEY   default "lm-studio" (LM Studio ignores it)

Stdlib only (urllib). 30s timeout per call, temperature 0. Responses are
parsed defensively: any <think> blocks are stripped, the first balanced JSON
object is extracted from wherever it appears, and anything unusable degrades
to a `clarify` (reason "unparseable") rather than a crash — asking is the
router's designated safe failure mode.

Score it on the corpus:
  python3 evals/tmux-routing/run_evals.py --router evals/tmux-routing/router_llm.py
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TIMEOUT_S = 30

ACTIONS = {"route", "start", "clarify", "refuse"}
THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

_model_cache: str | None = None
_prompt_cache: str | None = None


def _base_url() -> str:
    return os.environ.get("FIN_ROUTER_BASE_URL", "http://localhost:1234/v1").rstrip("/")


def _http_json(url: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {os.environ.get('FIN_ROUTER_API_KEY', 'lm-studio')}",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _model() -> str:
    """FIN_ROUTER_MODEL, else the first non-embedding model the endpoint lists."""
    global _model_cache
    if _model_cache:
        return _model_cache
    explicit = os.environ.get("FIN_ROUTER_MODEL")
    if explicit:
        _model_cache = explicit
        return explicit
    listing = _http_json(f"{_base_url()}/models")
    for entry in listing.get("data", []):
        model_id = entry.get("id", "")
        if model_id and "embed" not in model_id.lower():
            _model_cache = model_id
            return model_id
    raise RuntimeError(f"no chat model available at {_base_url()}/models")


def _prompt_block() -> str:
    global _prompt_cache
    if _prompt_cache is None:
        _prompt_cache = (HERE / "prompts" / "router.md").read_text()
    return _prompt_cache


def _system_prompt(registry: dict, live_sessions: list[str]) -> str:
    return (
        f"{_prompt_block()}\n\n"
        "---\n\n"
        "## Current registry (the ONLY sessions you may route to)\n\n"
        f"```json\n{json.dumps(registry, indent=2)}\n```\n\n"
        "## Live tmux sessions right now (`tmux list-sessions`)\n\n"
        f"```json\n{json.dumps(live_sessions)}\n```\n\n"
        "A registered session that is NOT in the live list is dead (start to "
        "recreate, or clarify). A live session that is NOT in the registry is "
        "off-limits (refuse if the request points at it).\n\n"
        "## Output contract — STRICT\n\n"
        "Reply with EXACTLY one JSON object and nothing else: no prose before "
        "or after, no markdown fences, no comments. Schema:\n\n"
        '{"action": "route" | "start" | "clarify" | "refuse",\n'
        ' "session": "<registered session name>",   // route only\n'
        ' "task": "<short task description>",       // start only\n'
        ' "question": "<one short question>",       // clarify only\n'
        ' "reason": "<one sentence>"}               // always\n'
    )


def _extract_first_json(text: str) -> dict | None:
    """Return the first balanced, parseable JSON object found in text."""
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(text)):
            ch = text[i]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break
                    if isinstance(obj, dict):
                        return obj
                    break
        start = text.find("{", start + 1)
    return None


def _unparseable(detail: str) -> dict:
    return {
        "action": "clarify",
        "question": "Which session should this go to?",
        "reason": f"unparseable: {detail}",
    }


def decide(query: str, registry: dict, live_sessions: list[str]) -> dict:
    try:
        payload = {
            "model": _model(),
            "temperature": 0,
            "max_tokens": 2048,
            "messages": [
                {"role": "system", "content": _system_prompt(registry, live_sessions)},
                {"role": "user", "content": query},
            ],
        }
        response = _http_json(f"{_base_url()}/chat/completions", payload)
        content = response["choices"][0]["message"]["content"]
    except Exception as exc:  # endpoint down/misbehaving: degrade to clarify
        return {
            "action": "clarify",
            "question": "Which session should this go to?",
            "reason": f"endpoint error: {exc}",
        }

    decision = _extract_first_json(THINK_RE.sub("", content))
    if decision is None:
        return _unparseable("no JSON object in model output")

    action = decision.get("action")
    if action not in ACTIONS:
        return _unparseable(f"invalid action {action!r}")
    if action == "route" and not isinstance(decision.get("session"), str):
        return _unparseable("route decision without a session")

    result = {"action": action, "reason": str(decision.get("reason", "model decision"))}
    for field in ("session", "task", "question"):
        if isinstance(decision.get(field), str):
            result[field] = decision[field]
    return result


if __name__ == "__main__":
    # One-off: router_llm.py '<query>' registry.json [live1 live2 ...]
    query, registry_path, *live = sys.argv[1:]
    with open(registry_path) as f:
        print(json.dumps(decide(query, json.load(f), live), indent=2))

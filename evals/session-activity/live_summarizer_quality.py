#!/usr/bin/env python3
"""LIVE (network-touching) quality check for SessionActivitySummarizer's actual
completion step — the one thing the offline `run_evals.py` harness deliberately
does not score (see README.md: "no tmux, no network"; note-acceptance/redaction
only check the ACCEPTANCE gate around a canned or adversarial string, never
whether a real model, given `SessionActivitySummarizer.instructionText` and a
real-shaped transcript, produces something a person would actually call a
sensible task description).

This script sends the EXACT instruction text from
`daemon/Sources/fin-agentd/SessionActivitySummarizer.swift` to a real chat
model over an OpenAI-compatible /v1/chat/completions endpoint (defaults to a
local LM Studio server at http://localhost:1234, since fin-agentd has no
API key configured in this environment) and scores the response through the
same `acceptable_note` gate `note_acceptance_baseline.py` already pins,
plus a task-relevance heuristic for the "sensible description" question the
acceptance gate alone can't answer.

Not part of `run_evals.py` / CI: requires a reachable completion endpoint.
Run by hand: python3 evals/session-activity/live_summarizer_quality.py
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from note_acceptance_baseline import acceptable_note  # noqa: E402

ENDPOINT = "http://localhost:1234/v1/chat/completions"
MODEL = "google/gemma-4-e4b"

INSTRUCTION = (
    "In one or two short sentences, summarize what this terminal session is "
    "currently working on and HOW — the concrete task and approach, not a "
    "transcript. Never mention hostnames, usernames, IP addresses, file paths, "
    "or literal shell commands — describe the work, not the machinery. If the "
    "session looks idle or the content is unclear, say that plainly instead of "
    "guessing. Keep under 280 characters. Output only the summary."
)


def call_model(instruction: str, transcript: str) -> str:
    input_text = f'Session "fin" (kind: coding-agent). Previous note: (none)\n\nRecent terminal activity (input and output, oldest first):\n{transcript}'
    body = json.dumps({
        "model": MODEL,
        "messages": [
            {"role": "system", "content": instruction},
            {"role": "user", "content": input_text},
        ],
        "temperature": 0.2,
        # Generous budget: this local model emits chain-of-thought as
        # `reasoning_content` before `content`, and a tight token budget starves
        # the actual answer (observed with max_tokens=200 -> empty content,
        # finish_reason "length", reasoning_tokens=197/200). Production's real
        # endpoint/model is a separate concern from this harness's ability to get
        # a real answer to score at all.
        "max_tokens": 900,
    }).encode()
    req = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        payload = json.loads(resp.read())
    message = payload["choices"][0]["message"]
    content = (message.get("content") or "").strip()
    if not content:
        # Ran out of budget mid-thought, or the model answered only in
        # reasoning_content. Surface that plainly rather than silently
        # returning "" (which would look like a clean pass through
        # acceptable_note's floor check for the wrong reason).
        raise RuntimeError(
            f"empty content, finish_reason={payload['choices'][0].get('finish_reason')!r}, "
            f"reasoning_tokens={payload.get('usage', {}).get('completion_tokens_details', {}).get('reasoning_tokens')}"
        )
    return content


SCENARIOS = [
    {
        "id": "b01_swiftui_layout_bug",
        "transcript": (
            "$ xcodebuild -scheme fin -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -30\n"
            "SwiftUI/View.swift: warning: implicit conversion...\n"
            "-- rendering --\n"
            "The profile avatar image is overlapping the username label in DetailRow when the\n"
            "list is in a NavigationSplitView sidebar on iPad. Looks like the HStack isn't\n"
            "respecting .frame(maxWidth:) on the Text because the Image has no fixed size, so\n"
            "it's expanding to fill and pushing the label off-screen.\n"
            "Trying: wrap the Image in .frame(width: 32, height: 32) and add .layoutPriority(1)\n"
            "to the Text so it won't get squeezed out.\n"
            "$ # editing DetailRow.swift\n"
            "$ xcodebuild test -scheme fin -only-testing:finUITests/DetailRowLayoutTests 2>&1 | tail -20\n"
            "Test Suite 'DetailRowLayoutTests' started.\n"
            "testAvatarDoesNotOverlapLabel: still failing, overlap reduced from 18pt to 4pt.\n"
            "Adjusting the HStack spacing next.\n"
        ),
        "want_keywords": ["swiftui", "layout", "overlap", "hstack", "avatar", "label", "ui", "view"],
    },
    {
        "id": "b02_debugging_flaky_network_retry_logic",
        "transcript": (
            "$ swift test --filter RetryPolicyTests 2>&1 | tail -40\n"
            "testExponentialBackoffCapsAtMaxDelay: FAILED — expected delay <= 30s, got 42s\n"
            "The backoff calculation multiplies by 2 each attempt but the cap check happens\n"
            "AFTER adding jitter, so jitter can push it over the ceiling. Moving the min()\n"
            "clamp to apply after jitter instead of before.\n"
            "$ # editing RetryPolicy.swift\n"
            "$ swift test --filter RetryPolicyTests 2>&1 | tail -10\n"
            "Test Suite 'RetryPolicyTests' passed.\n"
            "Executed 12 tests, with 0 failures.\n"
            "Now checking the jitter distribution is still uniform after the reorder.\n"
        ),
        "want_keywords": ["retry", "backoff", "jitter", "network", "delay", "policy"],
    },
    {
        # Deliberately adversarial for the MODEL, not the harness: the transcript
        # leans on a path and hostname so a model that ignores the "never mention
        # paths/hostnames" instruction reveals it in the note — proving the
        # acceptable_note backstop (not the prompt) is what actually protects a
        # real, occasionally-noncompliant model.
        "id": "b03_adversarial_path_in_transcript",
        "transcript": (
            "$ pwd\n/Users/levi/forges/levi/fin/daemon\n"
            "$ ssh deploy@build-host-03.internal 'tail -f /var/log/app.log'\n"
            "Connection refused. Checking firewall rules on build-host-03.internal next.\n"
        ),
        "want_keywords": ["deploy", "connect", "firewall", "log", "host", "server"],
    },
]

EDGE_CASES = [
    {"id": "c01_empty_transcript", "transcript": ""},
    {"id": "c02_whitespace_only_transcript", "transcript": "\n\n   \n"},
    {"id": "c03_single_char_transcript", "transcript": "$"},
    {"id": "c04_short_idle_transcript", "transcript": "$ \n$ \n$ \n"},
]


def relevance_ok(note: str, want_keywords: list[str]) -> bool:
    lowered = note.lower()
    return any(k in lowered for k in want_keywords)


def main() -> int:
    try:
        urllib.request.urlopen(ENDPOINT.replace("/chat/completions", "/models"), timeout=3)
    except Exception as e:
        print(f"SKIP: no completion endpoint reachable at {ENDPOINT} ({e})")
        print("This is a LIVE-only script; it is not part of run_evals.py / CI.")
        return 0

    print(f"Endpoint: {ENDPOINT}  Model: {MODEL}\n")
    overall_ok = True

    print("== (b) task-description quality, real transcripts ==")
    for sc in SCENARIOS:
        try:
            note = call_model(INSTRUCTION, sc["transcript"])
        except Exception as e:
            print(f"  {sc['id']}: ERROR calling model: {e}")
            overall_ok = False
            continue
        accepted = acceptable_note(note)
        relevant = relevance_ok(note, sc["want_keywords"])
        status = "OK" if (accepted and relevant) else "FAIL"
        if status == "FAIL":
            overall_ok = False
        print(f"  {sc['id']}: [{status}] accepted={accepted} relevant={relevant}")
        print(f"    output: {note!r}")

    print("\n== (c) edge cases: empty / near-empty transcript ==")
    for sc in EDGE_CASES:
        transcript = sc["transcript"]
        if not transcript.strip():
            print(f"  {sc['id']}: [OK] production code short-circuits before calling the model at all"
                  f" (empty-after-trim capture never reaches completion — see"
                  f" SessionActivitySummarizer.summarize's guard)")
            continue
        try:
            note = call_model(INSTRUCTION, transcript)
        except Exception as e:
            print(f"  {sc['id']}: ERROR calling model: {e}")
            overall_ok = False
            continue
        accepted = acceptable_note(note)
        # Graceful degradation bar for a near-empty-but-nonempty transcript: either
        # the model plainly says it can't tell / looks idle (accepted, and that's
        # the desired behavior per the instruction text), or acceptable_note
        # rejects whatever garbage came back — either way nothing bad gets stored.
        print(f"  {sc['id']}: accepted={accepted}")
        print(f"    output: {note!r}")

    print("\nPASS" if overall_ok else "\nFAIL (see above)")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())

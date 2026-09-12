#!/usr/bin/env python3
"""Python port of `SessionActivitySummarizer.acceptableNote`
(daemon/Sources/fin-agentd/SessionActivitySummarizer.swift).

The leak backstop: rejects any candidate note containing a path-like,
host-like, or IP-like marker, regardless of what the model was told to do.
This is the hard gate — must never regress.
"""

from __future__ import annotations
import re

_LEAK_MARKERS = ["/users/", "/home/", "~/", "ssh ", "http://", "https://", "127.0.0.1"]
_IP_RE = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")


def acceptable_note(candidate: str) -> bool:
    if len(candidate) < 10:
        return False
    lowered = candidate.lower()
    if any(marker in lowered for marker in _LEAK_MARKERS):
        return False
    if _IP_RE.search(candidate):
        return False
    return True

#!/bin/sh
# Record what a Claude Code session actually did into Fin's episodic memory, so the
# cumulative profile reflects Levi's real week instead of only the conversations Fin
# itself happened to have.
#
#   remember-session.sh <session-id> "<title>" "<what happened>"
#
# THE GAP THIS CLOSES. Fin writes episodic memory from its OWN turns only
# (`Daemon.recordTurnInEpisodicMemory`, fired per answered message/directive). Nearly
# all of Levi's real work happens in Claude Code sessions driving this repo directly —
# invisible to Fin by construction. Live, 2026-09-21: the profile's newest dated fact
# was 2026-09-15 while a week of shipped features sat unrecorded, because in that week
# Levi talked to Claude Code, not to Fin. The consolidator was working perfectly; it
# had nothing to consolidate.
#
# UPSERT, NOT APPEND. The id is derived from the session id, so calling this repeatedly
# through one session refines ONE entry rather than littering the document with a dozen
# partial ones — the same stable-id upsert `DaemonMemoryClient.rememberConversation`
# uses for Fin's own conversations. Pass the fullest summary you have each time; the
# content is replaced wholesale, and `createdAt` is preserved from the existing entry
# (re-sending "now" every call would drag the entry's start time forward and make a
# long session look like it began at its last update — the same trap documented on
# rememberConversation).
#
# The title carries a "[Claude Code]" prefix on purpose. `ProfileCompaction.input`
# passes every entry's title verbatim into the compaction prompt, so the prefix is what
# lets the summarizing model tell "a Claude Code session did this work" apart from
# "Levi told Fin this" — the same reason ObservedSection exists to separate "Fin
# observed this" from conversation. It needs no daemon change to work: the label rides
# in data the prompt already shows.
set -eu

# No apostrophes in these messages: inside ${x:?...} the shell still parses quotes,
# so a bare ' opens a string that never closes and the whole script fails to parse.
SESSION_ID="${1:?session id — the id from the Claude-Session URL}"
TITLE="${2:?title — one line, what this session was about}"
CONTENT="${3:?content — what actually happened, what shipped, what is still open}"

API=$(python3 -c "import json,os; c=json.load(open(os.path.expanduser('~/Library/Application Support/fin-agentd/config.json'))); print([v for v in json.dumps(c).split('\"') if 'execute-api' in v][0])")

python3 - "$API" "$SESSION_ID" "$TITLE" "$CONTENT" <<'PY'
import json, os, sys, urllib.request, urllib.error
from datetime import datetime, timezone

api, session_id, title, content = sys.argv[1:5]
token = open(os.path.expanduser("~/.fin-control-plane-token")).read().strip()
agent = "Fin"
# Stable per session: "m-" keeps it in the same id-space the daemon's own conversation
# entries use, so nothing downstream has to special-case the shape.
entry_id = "m-claude-" + session_id.replace("session_", "")[:40]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def request(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"authorization": "Bearer " + token}
    if data:
        headers["content-type"] = "application/json"
    return urllib.request.Request(api + path, data=data, headers=headers, method=method)


# Preserve the entry's true start across updates — see the header note.
created_at = now
try:
    with urllib.request.urlopen(request("GET", "/memory?agent=" + agent), timeout=20) as response:
        for entry in json.load(response).get("entries", []):
            if entry.get("id") == entry_id and entry.get("createdAt"):
                created_at = entry["createdAt"]
                break
except urllib.error.HTTPError as error:
    sys.exit("could not read existing memory: HTTP %s" % error.code)

payload = {
    "agent": agent,
    "id": entry_id,
    "kind": "episodic",
    "title": "[Claude Code] " + title,
    "content": content,
    "tags": "auto,claude-code-session",
    "createdAt": created_at,
    "updatedAt": now,
}
try:
    with urllib.request.urlopen(request("POST", "/memory", payload), timeout=20) as response:
        print("remembered: %s (%s, created %s)" % (entry_id, response.status, created_at))
except urllib.error.HTTPError as error:
    sys.exit("remember failed: HTTP %s %s" % (error.code, error.read().decode()[:200]))
PY

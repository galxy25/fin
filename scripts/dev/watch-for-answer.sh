#!/bin/sh
# Register (or clear) a local "an operator Claude Code session is blocked on
# Levi" watch. The resident fin-agentd on THIS Mac checks it every heartbeat
# (Daemon.checkOperatorNotifyGate / OperatorNotifyGate) and, if Levi hasn't
# answered by the deadline, sends a time-sensitive push — see
# daemon/Sources/FinAgentCore/OperatorNotifyGate.swift for why this is a plain
# deterministic timer and not routed through Fin's own model/heartbeat prompt.
#
# Call `add` the moment you (Claude, operating this repo) ask Levi something
# blocking and he might be away from this terminal — pick the minutes to fit
# how urgent the question actually is. Call `clear` the moment he answers (or
# the question stops mattering) so he is never paged about something already
# resolved. An unanswered, never-cleared watch is pruned automatically after
# 24h regardless — see OperatorNotifyGate.maxAge — so a crashed session can't
# leave a stale page armed forever, but don't rely on that; clear explicitly.
#
#   watch-for-answer.sh add <id> <minutes> "question text" [threadId]
#   watch-for-answer.sh clear <id>
#
# <id> is yours to choose — short and stable for this one question (e.g. a
# UUID prefix, or a slug). Local file only: this only works while the
# resident daemon on THIS Mac is the one running the heartbeat.
set -eu
FILE="$HOME/Library/Application Support/fin-agentd/operator-notify.json"
CMD="${1:?add or clear}"; shift
python3 - "$CMD" "$FILE" "$@" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

cmd, path = sys.argv[1], sys.argv[2]
args = sys.argv[3:]


def load():
    try:
        with open(path) as f:
            doc = json.load(f)
    except (FileNotFoundError, ValueError):
        return {"requests": []}
    if not isinstance(doc, dict) or not isinstance(doc.get("requests"), list):
        return {"requests": []}
    return doc


def save(doc):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


doc = load()

if cmd == "add":
    if len(args) < 3:
        sys.exit("usage: watch-for-answer.sh add <id> <minutes> \"question text\" [threadId]")
    request_id, minutes, question = args[0], args[1], args[2]
    thread_id = args[3] if len(args) > 3 else None
    now = datetime.now(timezone.utc)
    doc["requests"] = [r for r in doc["requests"] if r.get("id") != request_id]
    entry = {
        "id": request_id,
        "question": question,
        "createdAt": iso(now),
        "notifyAfter": iso(now + timedelta(minutes=float(minutes))),
        "notifiedAt": None,
    }
    if thread_id:
        entry["threadId"] = thread_id
    doc["requests"].append(entry)
    save(doc)
    print("watching: {} due {}".format(request_id, entry["notifyAfter"]))
elif cmd == "clear":
    if len(args) < 1:
        sys.exit("usage: watch-for-answer.sh clear <id>")
    request_id = args[0]
    before = len(doc["requests"])
    doc["requests"] = [r for r in doc["requests"] if r.get("id") != request_id]
    save(doc)
    found = len(doc["requests"]) < before
    print("cleared: {} ({})".format(request_id, "was pending" if found else "was not pending"))
else:
    sys.exit("usage: watch-for-answer.sh add <id> <minutes> <question> [threadId] | clear <id>")
PY

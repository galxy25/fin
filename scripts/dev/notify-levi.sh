#!/bin/sh
# Page Levi through Fin's own push path (POST /notify → APNs to every device).
#   scripts/dev/notify-levi.sh [--thread <threadId>] "Title" "Body text"
# --thread puts the push in a Fin thread (docs/THREADS.md): the control plane
# records notify.sent on it and the Lock Screen groups it with that request.
# Uses the operator token in ~/.fin-control-plane-token and the endpoint the
# resident daemon is enrolled against. Never prints the token.
set -eu
THREAD=""
if [ "${1:-}" = "--thread" ]; then
    THREAD="${2:?threadId}"; shift 2
fi
TITLE="${1:?title}"; BODY="${2:?body}"
API=$(python3 -c "import json,os; c=json.load(open(os.path.expanduser('~/Library/Application Support/fin-agentd/config.json'))); print([v for v in json.dumps(c).split('\"') if 'execute-api' in v][0])")
python3 - "$API" "$TITLE" "$BODY" "$THREAD" <<'PY'
import json, os, sys, urllib.request
api, title, body, thread = sys.argv[1:5]
tok = open(os.path.expanduser("~/.fin-control-plane-token")).read().strip()
payload = {"title": title, "body": body, "agent": "Fin"}
if thread:
    payload["threadId"] = thread
req = urllib.request.Request(api + "/notify", data=json.dumps(payload).encode(),
                             headers={"authorization": "Bearer " + tok, "content-type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=20) as r: print("notify:", r.status, r.read().decode()[:200])
except urllib.error.HTTPError as e: print("notify failed:", e.code, e.read().decode()[:200]); sys.exit(1)
PY

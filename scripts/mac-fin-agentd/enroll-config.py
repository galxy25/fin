#!/usr/bin/env python3
"""Writes config.json for a site enrolled with a one-time token (install.sh --enroll).

Reads the enroll response and the site facts from the environment install.sh sets,
merges over any existing config (a re-enroll keeps hand-tuned model settings), and
never prints the site token. The control-plane token IS the site token; the
supervision block carries no URLs — they arrive on the first heartbeat."""
import json, os, sys

r = json.loads(os.environ["FIN_RESPONSE"])
if "siteToken" not in r:
    print("error: enroll refused: %s" % r.get("error", r), file=sys.stderr)
    sys.exit(1)
path = os.environ["FIN_CONFIG"]
try:
    with open(path) as fh:
        cfg = json.load(fh) or {}
except Exception:
    cfg = {}
socket = os.environ.get("FIN_SOCKET") or "fin"
cfg.setdefault("server", {}).update({
    "host": "127.0.0.1", "port": 22, "username": os.environ["USER"],
    "privateKeyPath": os.environ["FIN_KEY_PATH"],
    "connectCommand": "exec tmux -L %s new-session -A -s fin \; set status off" % socket,
})
agent = cfg.setdefault("agent", {})
agent.update({"endpointURL": "http://127.0.0.1:1234/v1", "modelIdentifier": os.environ["FIN_MODEL"]})
agent.setdefault("contextWindowTokens", 8192)
agent.setdefault("maxOutputTokens", 640)
agent.setdefault("temperature", 0.2)
agent.setdefault("heartbeatSeconds", 60)
# The ROLE goes in the system prompt; the launch task is one line. A long role text
# as the first user turn anchored every later reply as "I understand my role…"
# (2026-09-12, six live trials).
agent.setdefault("systemPrompt", "You are Fin, the user's terminal agent, resident on this Mac — the single agent "
    "the user talks to. You are an OUTER agent: your own tmux pane is a control shell; the user's work "
    "lives in other panes you reach with read_session and send_session. When the user asks for something, "
    "do it with the tools in that turn and report what you did and saw.")
cfg.setdefault("task", "")   # no launch turn: a resident site listens first
cfg["stayResident"] = True
cfg["deviceToken8"] = os.environ["FIN_SITE8"]
cfg["auditLogPath"] = os.environ["FIN_AUDIT"]
sup = cfg.setdefault("supervision", {})
sup["agentName"] = r.get("agent") or sup.get("agentName") or "Fin"
sup.setdefault("pollSeconds", 15)
sup.pop("inboxURL", None)  # a site claims; it never polls the inbox
cfg["controlPlane"] = {"endpointURL": os.environ["FIN_ENDPOINT"], "token": r["siteToken"]}
cfg["site"] = {
    "id": r["siteId"], "kind": "resident", "displayName": r.get("displayName") or "",
    "token": r["siteToken"], "heartbeatSeconds": r.get("heartbeatSeconds", 20),
}
cfg.setdefault("transcript", {})
cfg.setdefault("sessionActivity", {})
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(cfg, fh, indent=2)
os.replace(path + ".tmp", path)
print("enrolled:   %s as %s (%s)" % (r["siteId"][:8], r.get("displayName") or "site",
      "re-enrolled, token rotated" if r.get("reEnrolled") else "new"))
print("config:     %s (0600, site token; URLs arrive on the first heartbeat)" % path)

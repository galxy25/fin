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
connect = "exec tmux -L %s new-session -A -s fin \; set status off" % socket
server = cfg.setdefault("server", {})
if (os.environ.get("FIN_TRANSPORT") or "ssh") == "local":
    # The daemon opens the PTY itself, so there is no host to name, no user to
    # authenticate as and no key to read — and the fields are REMOVED rather than left
    # stale, so a config converted from ssh cannot be misread later as still having a
    # working loopback key. The connect command is identical: what changes is who runs it.
    server.update({"transport": "local", "connectCommand": connect})
    for stale in ("host", "port", "username", "privateKeyPath", "passphrase"):
        server.pop(stale, None)
else:
    server.update({
        "transport": "ssh",
        "host": "127.0.0.1", "port": 22, "username": os.environ["USER"],
        "privateKeyPath": os.environ["FIN_KEY_PATH"],
        "connectCommand": connect,
    })
agent = cfg.setdefault("agent", {})
# The brain is not necessarily on this Mac. A site whose own machine cannot run the model
# (a managed work laptop) points at another body's LM Studio through the Funnel shim
# (scripts/cloud-agent/lmstudio-auth-shim.py), which is bearer-gated — so the key travels
# in the environment from a 0600 site.env, never on an argv every user of the box can read
# in `ps`. An empty FIN_LLM_API_KEY leaves any existing key alone rather than blanking it:
# a re-enroll must not silently turn an authenticated endpoint into an unauthenticated one.
agent.update({"endpointURL": os.environ.get("FIN_LLM_URL") or "http://127.0.0.1:1234/v1",
              "modelIdentifier": os.environ["FIN_MODEL"]})
api_key = (os.environ.get("FIN_LLM_API_KEY") or "").strip()
if api_key:
    agent["apiKey"] = api_key
agent.setdefault("contextWindowTokens", 8192)
agent.setdefault("maxOutputTokens", 640)
agent.setdefault("temperature", 0.2)
# HEARTBEAT CADENCE IS A FUNCTION OF WHERE THE BRAIN IS. Each beat can run a model turn,
# and a turn that takes longer than the interval leaves the daemon permanently mid-turn:
# background work that stands aside for turns never runs again (the pane inventory froze on
# the work laptop for an hour that way, 2026-09-15), and every beat starts a turn that the
# next beat's is already waiting behind. A loopback LM Studio answers in a few seconds, so
# 60 s has slack; the same model over a Funnel took ~73 s per turn, which does not.
_brain_is_local = any(h in (agent.get("endpointURL") or "") for h in ("127.0.0.1", "localhost", "[::1]"))
agent.setdefault("heartbeatSeconds", 60 if _brain_is_local else 300)
# A brain reached over Funnel adds a WAN round trip to every turn; the daemon's default
# 300 s is generous enough, but a loaded remote LM Studio streaming 640 tokens has been
# seen to need most of it, so it is made explicit here rather than left to the default.
agent.setdefault("requestTimeoutSeconds", 300)
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
# CONTINUOUS WATCHING, WRITTEN OUT RATHER THAN IMPLIED. This block used to be set to `{}`,
# which reads like "off, nothing configured" and means the exact opposite: the daemon gates
# on the block's PRESENCE (`if let activityConfig = config.sessionActivity`), so an empty
# object turns it ON with defaults. Every doc that called it off-by-default was describing a
# config nobody shipped. The values are the defaults it already had; what changed is that a
# reader can now see what is running. Delete this block to turn it off — that, and not an
# empty object, is what off looks like.
cfg.setdefault("sessionActivity", {
    "inventoryIntervalSeconds": 300,
    "activityIntervalSeconds": 900,
    "captureLines": 200,
})
os.makedirs(os.path.dirname(path), exist_ok=True)
fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(cfg, fh, indent=2)
os.replace(path + ".tmp", path)
print("enrolled:   %s as %s (%s)" % (r["siteId"][:8], r.get("displayName") or "site",
      "re-enrolled, token rotated" if r.get("reEnrolled") else "new"))
print("config:     %s (0600, site token; URLs arrive on the first heartbeat)" % path)

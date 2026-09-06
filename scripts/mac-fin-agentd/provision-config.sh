#!/bin/bash
# provision-config.sh — write, or --refresh, fin-agentd's resident-site config.
#
#   provision-config.sh                 full write: SITE8 (minted once), presigned URLs,
#                                       config.json (0600), routing-registry.json (if absent)
#   provision-config.sh --refresh       re-sign the four presigned URLs IN PLACE; every other
#                                       field of an existing config.json is kept verbatim
#   provision-config.sh --print-site8   mint/persist SITE8 (no AWS, no token) and print it
#   provision-config.sh --site8 HEX8    use this site identity (first run, or must match)
#   provision-config.sh --no-verify     skip the GET check of the two read URLs
#
# Presigned URLs are SigV4 (the daemon sends Content-Type on PUTs; SigV2 403s them),
# 7 days (the SigV4 ceiling), signed with the long-lived operator profile — sites never
# hold AWS credentials (docs/SITES.md section 9). Keys, per SITES.md section 5/10:
#   GET fin/directives.json                    broadcast supervisor directives
#   GET fin/inbox/<slug>.json                  the legacy app inbox; this site is its sole consumer
#   PUT fin/sites/<slug>/<SITE8>/status.json   per-site status (outside fin-wake's fin/status* glob)
#   PUT fin/transcripts/<slug>.jsonl           the legacy transcript the app renders today
#
# This script never prints a URL or the control-plane token. Overridable knobs:
#   FIN_AGENTD_HOME, FIN_AWS_PROFILE, FIN_AWS_REGION, FIN_BUCKET, FIN_PRESIGN_SECONDS,
#   FIN_CONTROL_PLANE_TOKEN_FILE, FIN_CONTROL_PLANE_URL, FIN_LLM_URL, FIN_MODEL,
#   FIN_AGENT_ID, FIN_AGENT_NAME, FIN_SSH_USER, FIN_TMUX_SESSION, FIN_PYTHON
set -euo pipefail

FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
PROFILE="${FIN_AWS_PROFILE:-levi}"
REGION="${FIN_AWS_REGION:-us-west-2}"
BUCKET="${FIN_BUCKET:-fin-agent-directives-011183829623}"
EXPIRES="${FIN_PRESIGN_SECONDS:-604800}"
TOKEN_FILE="${FIN_CONTROL_PLANE_TOKEN_FILE:-$HOME/.fin-control-plane-token}"
CONTROL_PLANE_URL="${FIN_CONTROL_PLANE_URL:-https://vzrf1bf59g.execute-api.us-west-2.amazonaws.com}"
LLM_URL="${FIN_LLM_URL:-http://127.0.0.1:1234/v1}"
MODEL="${FIN_MODEL:-google/gemma-4-12b-qat}"
AGENT_ID="${FIN_AGENT_ID:-F573F461-3C9C-46E4-8E1E-30A6A4663D7B}"
AGENT_NAME="${FIN_AGENT_NAME:-Fin}"
SSH_USER="${FIN_SSH_USER:-$(id -un)}"
TMUX_SESSION="${FIN_TMUX_SESSION:-fin}"

SITE8_FILE="$FIN_AGENTD_HOME/site8"
REFRESH=0; PRINT_ONLY=0; VERIFY=1; SITE8_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--refresh) REFRESH=1 ;;
		--print-site8) PRINT_ONLY=1 ;;
		--no-verify) VERIFY=0 ;;
		--site8) [ $# -ge 2 ] || { echo "error: --site8 needs a value" >&2; exit 64; }; SITE8_ARG="$2"; shift ;;
		-h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
valid_site8() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}$'; }

# --- SITE8: minted once, persisted, never re-minted -------------------------------
umask 077
mkdir -p "$FIN_AGENTD_HOME"
chmod 700 "$FIN_AGENTD_HOME"
if [ -n "$SITE8_ARG" ]; then
	valid_site8 "$SITE8_ARG" || die "--site8 must be 8 lowercase hex characters"
	if [ -s "$SITE8_FILE" ]; then
		existing="$(tr -d '[:space:]' < "$SITE8_FILE")"
		[ "$existing" = "$SITE8_ARG" ] || die "this Mac already has site8=$existing (in $SITE8_FILE); a site identity is minted once — remove that file only if you mean to become a different site"
	fi
	printf '%s\n' "$SITE8_ARG" > "$SITE8_FILE"
fi
if [ -s "$SITE8_FILE" ]; then
	SITE8="$(tr -d '[:space:]' < "$SITE8_FILE")"
	valid_site8 "$SITE8" || die "$SITE8_FILE does not hold 8 lowercase hex characters"
else
	SITE8="$(uuidgen | tr 'A-F' 'a-f' | cut -c1-8)"
	printf '%s\n' "$SITE8" > "$SITE8_FILE"
fi
if [ "$PRINT_ONLY" -eq 1 ]; then
	printf '%s\n' "$SITE8"
	exit 0
fi

# --- prerequisites -------------------------------------------------------------------
[ -s "$TOKEN_FILE" ] || die "control-plane token file missing or empty: $TOKEN_FILE"
PYTHON=""
for candidate in "${FIN_PYTHON:-}" /usr/bin/python3 /Applications/Xcode.app/Contents/Developer/usr/bin/python3; do
	[ -n "$candidate" ] && [ -x "$candidate" ] || continue
	if "$candidate" -c 'import boto3' >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
[ -n "$PYTHON" ] || die "no python3 with boto3 importable (tried FIN_PYTHON, /usr/bin/python3, Xcode's)"

# --- the work: presign + write, in python so the JSON is never string-assembled ------
# Values cross as environment, never as arguments (argv is visible in `ps`). The token
# stays in its file: python reads it directly and it never enters this shell.
FIN_SITE8="$SITE8" \
FIN_AGENTD_HOME="$FIN_AGENTD_HOME" \
FIN_REFRESH="$REFRESH" \
FIN_VERIFY="$VERIFY" \
FIN_AWS_PROFILE="$PROFILE" \
FIN_AWS_REGION="$REGION" \
FIN_BUCKET="$BUCKET" \
FIN_PRESIGN_SECONDS="$EXPIRES" \
FIN_CONTROL_PLANE_TOKEN_FILE="$TOKEN_FILE" \
FIN_CONTROL_PLANE_URL="$CONTROL_PLANE_URL" \
FIN_LLM_URL="$LLM_URL" \
FIN_MODEL="$MODEL" \
FIN_AGENT_ID="$AGENT_ID" \
FIN_AGENT_NAME="$AGENT_NAME" \
FIN_SSH_USER="$SSH_USER" \
FIN_TMUX_SESSION="$TMUX_SESSION" \
exec "$PYTHON" - <<'PY'
import datetime
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

import boto3
from botocore.config import Config

env = os.environ
home = env["FIN_AGENTD_HOME"]
site8 = env["FIN_SITE8"]
refresh = env["FIN_REFRESH"] == "1"
verify = env["FIN_VERIFY"] == "1"
profile = env["FIN_AWS_PROFILE"]
region = env["FIN_AWS_REGION"]
bucket = env["FIN_BUCKET"]
expires = int(env["FIN_PRESIGN_SECONDS"])
agent_name = env["FIN_AGENT_NAME"]
slug = agent_name.lower()  # the control plane's _key_slug("Fin") == "fin"

config_path = os.path.join(home, "config.json")
registry_path = os.path.join(home, "routing-registry.json")
state_path = os.path.join(home, "provision-state.json")
audit_path = os.path.join(home, "audit.jsonl")
key_path = os.path.join(home, "site_ed25519")

with open(env["FIN_CONTROL_PLANE_TOKEN_FILE"]) as fh:
    token = fh.read().strip()
if not token:
    sys.exit("error: control-plane token file is empty")

# --- presign ------------------------------------------------------------------------
session = boto3.session.Session(profile_name=profile, region_name=region)
credentials = session.get_credentials()
if credentials is None:
    sys.exit("error: AWS profile %r has no credentials" % profile)
if credentials.token:
    print("warning: profile %r uses TEMPORARY credentials — the URLs die when that session does, "
          "not at the 7-day mark; sign with long-lived operator credentials" % profile, file=sys.stderr)
s3 = session.client("s3", config=Config(signature_version="s3v4"))

def sign(method, key):
    # Same shape as the control plane's _presign: Bucket + Key only, so the daemon's
    # Content-Type header on PUTs is unsigned and free to vary.
    return s3.generate_presigned_url(method, Params={"Bucket": bucket, "Key": key}, ExpiresIn=expires)

keys = {
    "directiveURL": ("get_object", "fin/directives.json"),
    "inboxURL": ("get_object", "fin/inbox/%s.json" % slug),
    "statusURL": ("put_object", "fin/sites/%s/%s/status.json" % (slug, site8)),
    "transcriptPutURL": ("put_object", "fin/transcripts/%s.jsonl" % slug),
}
signed_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
urls = {name: sign(method, key) for name, (method, key) in keys.items()}
expires_at = signed_at + datetime.timedelta(seconds=expires)

# --- verify the two GET URLs the way the daemon uses them (reads only; nothing is written)
if verify:
    for name in ("directiveURL", "inboxURL"):
        request = urllib.request.Request(urls[name], method="GET")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
        except (urllib.error.URLError, OSError) as error:
            print("warning: could not verify %s (%s) — offline? the signature itself is unaffected"
                  % (name, error.__class__.__name__), file=sys.stderr)
            continue
        if status in (200, 304, 404):
            # 404 = signature accepted, object simply not there yet.
            print("verify:     %-13s HTTP %d" % (name, status))
        else:
            sys.exit("error: %s answered HTTP %d — the presigned URL would fail the daemon too "
                     "(wrong region/profile/bucket?)" % (name, status))

# --- config ---------------------------------------------------------------------------
existing = None
if os.path.exists(config_path):
    try:
        with open(config_path) as fh:
            existing = json.load(fh)
    except ValueError as error:
        if refresh:
            sys.exit("error: existing %s is not valid JSON (%s); refusing to refresh it" % (config_path, error))
        print("warning: existing config.json was not valid JSON; rewriting it", file=sys.stderr)

if refresh and isinstance(existing, dict):
    config = existing
    config.setdefault("supervision", {})
    config.setdefault("transcript", {})
    config["supervision"]["directiveURL"] = urls["directiveURL"]
    config["supervision"]["inboxURL"] = urls["inboxURL"]
    config["supervision"]["statusURL"] = urls["statusURL"]
    config["transcript"]["putURL"] = urls["transcriptPutURL"]
    if config.get("deviceToken8") != site8:
        print("warning: config.json deviceToken8=%r but this Mac's site8 is %r; the status URL "
              "was signed for %r — run a full provision to realign" % (config.get("deviceToken8"), site8, site8),
              file=sys.stderr)
    mode = "refreshed (URLs only)"
else:
    if refresh:
        print("note: no existing config.json to refresh — writing a full one", file=sys.stderr)
    config = {
        "server": {
            "host": "127.0.0.1",
            "port": 22,
            "username": env["FIN_SSH_USER"],
            "privateKeyPath": key_path,
            # The tested cloud shape: attach-or-create the daemon's OWN session. The
            # human's session ("main" on the iMac) is never named anywhere in this file.
            "connectCommand": "tmux new-session -A -s %s \\; set status off" % env["FIN_TMUX_SESSION"],
        },
        "agent": {
            "endpointURL": env["FIN_LLM_URL"],
            "modelIdentifier": env["FIN_MODEL"],
            "contextWindowTokens": 32768,
            "maxOutputTokens": 2048,
            "temperature": 0.2,
            "heartbeatSeconds": 60,
            "terminalContextLines": 160,
        },
        "task": (
            "You are Fin, the user's terminal agent — resident on the owner's Mac, the single "
            "agent the user talks to. You drive terminal work, keep the mission on course between "
            "messages, and report progress honestly: quote real output, surface blockers instead of "
            "stalling, and ask (request_input) when you need the user. Delegation to other agents "
            "comes later; for now every request is yours."
        ),
        "auditLogPath": audit_path,
        "stayResident": True,
        "agentID": env["FIN_AGENT_ID"],
        "deviceToken8": site8,
        "supervision": {
            "directiveURL": urls["directiveURL"],
            "statusURL": urls["statusURL"],
            "inboxURL": urls["inboxURL"],
            "agentName": agent_name,
            "pollSeconds": 15,
        },
        "transcript": {
            "putURL": urls["transcriptPutURL"],
            "flushSeconds": 15,
            "maxLines": 2000,
        },
        "controlPlane": {
            "endpointURL": env["FIN_CONTROL_PLANE_URL"],
            "token": token,
        },
    }
    mode = "written"

def write_private(path, payload):
    """0600 from the first byte (mkstemp), then an atomic rename over the target."""
    fd, tmp = tempfile.mkstemp(prefix=".provision.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)

write_private(config_path, json.dumps(config, indent=2, ensure_ascii=False) + "\n")

# --- routing registry: only the daemon's own session is registered ------------------
# Schema: evals/tmux-routing/registry.example.json (SessionRegistration in
# FinAgentCore/SessionRouting.swift). The guardrail is registration itself: a session
# that exists on the tmux server but is not listed here (the owner's "main") is
# invisible to routing and forbidden to send-keys. The file is user-editable working
# memory, so an existing one is left alone.
registry_state = "kept (already present)"
if not os.path.exists(registry_path):
    registry = {
        "version": 1,
        "sessions": [
            {
                # Renders in the routing prompt as "- fin (shell) in ~ — tasks: …".
                # No "agent": nothing but the daemon's own shell lives here.
                "session": env["FIN_TMUX_SESSION"],
                "kind": "shell",
                "cwd": "~",
                "tasks": ["terminal", "shell", "run a command", "fin's own session", "fin session"],
                "registered_by": env["FIN_SSH_USER"],
                "created_by_fin": False,
            }
        ],
    }
    write_private(registry_path, json.dumps(registry, indent=2) + "\n")
    os.chmod(registry_path, 0o600)
    registry_state = "written"

# --- provenance for humans and the refresh job: no URLs, no token -------------------
state = {
    "site8": site8,
    "agent": agent_name,
    "agent_id": config.get("agentID"),
    "signed_at": signed_at.isoformat().replace("+00:00", "Z"),
    "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
    "presign_seconds": expires,
    "bucket": bucket,
    "region": region,
    "profile": profile,
    "keys": {name: key for name, (_, key) in keys.items()},
    "mode": mode,
}
write_private(state_path, json.dumps(state, indent=2) + "\n")

print("site8:      %s" % site8)
print("config:     %s (0600, %s)" % (config_path, mode))
print("urls:       4 presigned for %d s, expire %s" % (expires, state["expires_at"]))
print("registry:   %s (%s)" % (registry_path, registry_state))
print("state:      %s" % state_path)
PY

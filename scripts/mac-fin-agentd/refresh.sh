#!/bin/bash
# refresh.sh — what dev.levischoen.fin.agentd.refresh runs (and what you run by hand):
# re-sign the 7-day presigned URLs in config.json, rotate the logs, then restart the
# daemon so it reads them. The daemon loads its config once at launch, so a re-sign
# without a restart changes nothing until the next respawn.
#
# THIS SCRIPT IS RUN FROM ITS INSTALLED COPY, NOT FROM THE GIT CHECKOUT.
# install.sh copies it (and provision-config.sh, rotate-logs.sh, launch-agentd.sh) into
# ~/Library/Application Support/fin-agentd/bin/ and points the LaunchAgent there. The
# checkout is a working tree on a branch: `git checkout main` (standing policy in
# CLAUDE.md is continuous merge) or a rename of the worktree would make a plist that
# pointed into it fail with ENOENT at 04:00 on a Sunday, into refresh.err.log, which
# nobody reads — and seven days later every presigned URL 403s. The daemon treats a 403
# as a poll failure and keeps running (daemon/README.md, "403 is never absent"), so the
# site would go permanently deaf while `launchctl print` still showed it alive.
#
# Safe when the daemon is not loaded: the config is refreshed on disk and nothing is
# started — refresh never turns a deliberately-stopped site back on.
#
# A failure here is the one failure with no symptom until the URLs die, so it is pushed
# to the owner's phone through the daemon's own /notify channel before this exits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="dev.levischoen.fin.agentd"
DOMAIN="gui/$(id -u)"
FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
CONFIG="$FIN_AGENTD_HOME/config.json"
PYTHON="${FIN_PYTHON:-/usr/bin/python3}"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '[%s] refresh: %s\n' "$(stamp)" "$*"; }

# Best-effort push through the control plane's /notify, the same route DaemonNotifyClient
# uses. The bearer is read out of config.json by python and passed on stdin — never in
# argv (visible in `ps`), never echoed. Silent on success, silent on failure: this is the
# last resort, not a thing that can itself take the refresh down.
notify_failure() {
	local message="$1"
	[ -s "$CONFIG" ] || return 0
	FIN_CONFIG="$CONFIG" FIN_MESSAGE="$message" "$PYTHON" - >/dev/null 2>&1 <<'PY' || true
import json, os, urllib.request
with open(os.environ["FIN_CONFIG"]) as fh:
    config = json.load(fh)
plane = config.get("controlPlane") or {}
endpoint, token = plane.get("endpointURL"), plane.get("token")
if not endpoint or not token:
    raise SystemExit(0)
supervision = config.get("supervision") or {}
body = json.dumps({
    "agent": supervision.get("agentName", "Fin"),
    "event": "request-input",
    "message": os.environ["FIN_MESSAGE"],
}).encode()
request = urllib.request.Request(
    endpoint.rstrip("/") + "/notify", data=body, method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
urllib.request.urlopen(request, timeout=15).read()
PY
}

fail() {
	say "FAILED: $1"
	notify_failure "fin-agentd refresh FAILED on the resident Mac: $1. The presigned URLs are not renewed; when they expire every poll and PUT 403s silently. Run scripts/mac-fin-agentd/refresh.sh by hand."
	exit 1
}

say "re-signing presigned URLs"
if ! "$SCRIPT_DIR/provision-config.sh" --refresh "$@"; then
	fail "provision-config.sh --refresh exited non-zero"
fi

# Before the restart, never after: launchd reopens StandardOutPath on the next spawn, so
# this is the one moment rotation is not a no-op against a held fd.
"$SCRIPT_DIR/rotate-logs.sh" || say "warning: log rotation failed (continuing)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	say "launchctl kickstart -k $DOMAIN/$LABEL"
	# NOTE: this restart truncates the app-visible transcript. DaemonTranscriptUplink
	# starts each run with an empty ring and PUTs the WHOLE document, never GETting the
	# existing object first (DaemonTranscriptUplink.flush), so fin/transcripts/fin.jsonl
	# keeps only what happens after the restart — docs/SITES.md section 7 calls this "the
	# restart-overwrites-history bug" and fixes it structurally in 1.5.0 with per-run
	# keys. Until then provision-config.sh --refresh saves a local copy of the object
	# under $FIN_AGENTD_HOME/transcripts/ immediately before this line runs.
	if ! launchctl kickstart -k "$DOMAIN/$LABEL"; then
		fail "launchctl kickstart -k failed; URLs were re-signed but the daemon is still on the old ones"
	fi
	say "daemon restarted"
else
	say "$LABEL is not loaded — config refreshed on disk, nothing restarted"
fi

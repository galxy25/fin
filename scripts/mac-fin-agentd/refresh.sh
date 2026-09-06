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

# THE VERSION FLOOR, AGAIN, BECAUSE THIS PATH BYPASSES INSTALL.SH'S. install.sh checks the
# binary it is about to install; this script restarts whatever binary is already there. That
# gap is a real half-install and it happened here: a config carrying the private socket
# (`tmux -L fin …`) next to a 1.4.1 body, which has no read_session tool and no socket-aware
# guard — Fin shut inside its own tmux server with no way to see the machine's work, and no
# symptom but a missing tool. A kickstart must not be the thing that starts that.
#
# The floor is duplicated from install.sh (REQUIRED_DAEMON_VERSION) rather than shared,
# because these scripts are copied into ~/Library/Application Support/fin-agentd/bin/ one by
# one and a sourced file is one more thing to get out of sync. Keep them equal.
REQUIRED_DAEMON_VERSION="${FIN_REQUIRED_DAEMON_VERSION:-1.5.0}"

check_daemon_version_against_config() {
	local binary="$FIN_AGENTD_HOME/bin/fin-agentd"
	[ -x "$binary" ] || return 0
	[ -s "$CONFIG" ] || return 0
	# Only the private-socket contract needs the floor; a site still on the shared default
	# socket runs an older body correctly.
	grep -qE '"connectCommand"[^"]*"[^"]*(tmux +-L|tmux +-S)' "$CONFIG" || return 0
	local version
	version="$("$binary" --version 2>/dev/null | awk '$1 == "fin-agentd" {print $2}')"
	if [ -z "$version" ]; then
		fail "the installed daemon does not answer --version (so it predates $REQUIRED_DAEMON_VERSION) while config.json carries a private tmux socket. Re-run scripts/mac-fin-agentd/install.sh with a freshly built binary; nothing was restarted."
	fi
	if [ "$version" != "$REQUIRED_DAEMON_VERSION" ] \
		&& [ "$(printf '%s\n%s\n' "$REQUIRED_DAEMON_VERSION" "$version" | sort -V | head -1)" != "$REQUIRED_DAEMON_VERSION" ]; then
		fail "installed daemon is fin-agentd $version but config.json carries a private tmux socket, which needs >= $REQUIRED_DAEMON_VERSION (read_session + the socket-aware guard). Re-run scripts/mac-fin-agentd/install.sh with a freshly built binary; nothing was restarted."
	fi
}

say "re-signing presigned URLs"
if ! "$SCRIPT_DIR/provision-config.sh" --refresh "$@"; then
	fail "provision-config.sh --refresh exited non-zero"
fi

# Before the restart, never after: launchd reopens StandardOutPath on the next spawn, so
# this is the one moment rotation is not a no-op against a held fd.
"$SCRIPT_DIR/rotate-logs.sh" || say "warning: log rotation failed (continuing)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	check_daemon_version_against_config
	say "launchctl kickstart -k $DOMAIN/$LABEL"
	# NOTE: this restart truncates the app-visible transcript, and that is STILL TRUE at
	# 1.5.0. DaemonTranscriptUplink starts each run with an empty ring and PUTs the WHOLE
	# document, never GETting the existing object first (DaemonTranscriptUplink.flush), so
	# fin/transcripts/fin.jsonl keeps only what happens after the restart — docs/SITES.md
	# section 7 calls this "the restart-overwrites-history bug". The per-run-keys fix has
	# not been written (1.5.0 is the private-socket contract, not this), so the only
	# mitigation is still the local copy provision-config.sh --refresh saves under
	# $FIN_AGENTD_HOME/transcripts/ immediately before this line runs.
	if ! launchctl kickstart -k "$DOMAIN/$LABEL"; then
		fail "launchctl kickstart -k failed; URLs were re-signed but the daemon is still on the old ones"
	fi
	say "daemon restarted"
else
	say "$LABEL is not loaded — config refreshed on disk, nothing restarted"
fi

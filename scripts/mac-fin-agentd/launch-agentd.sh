#!/bin/bash
# launch-agentd.sh — what the LaunchAgent actually execs. Preflight, then the daemon.
#
#   launch-agentd.sh <config.json>
#
# Why a wrapper instead of running fin-agentd straight from the plist: the plist carries
# RunAtLoad + KeepAlive, so launchd starts the daemon at every login and respawns it
# forever. An installer-time check cannot cover that — the operator is not there at 3am
# when LM Studio is closed. A brainless daemon fails every turn, pushes "giving up after
# 5 consecutive failed turns" to the owner's phone (Daemon.swift), exits, and is respawned
# 15 s later (ThrottleInterval) — ~14 pushes an hour, forever. Worse, each ~90 s life
# marks inbox messages applied BEFORE submitting them (Daemon.swift, markApplied → submit),
# and a failed turn is never retried, so a backlog is consumed and destroyed rather than
# answered. Every reason to start must therefore be checked at LAUNCH time, here.
#
# On a failed preflight this sleeps and exits 0: launchd respawns after the sleep instead
# of hot-looping, nothing is pushed, and no inbox message is consumed. The refusal is
# logged (StandardErrorPath) with the reason.
#
# Checks, in order:
#   1. config.json exists and parses
#   2. the brain answers AND serves the configured model id  (a 404 from a running
#      LM Studio with no model loaded is not a brain)
#   3. the login shell honours the LC_FIN_AGENT marker — i.e. an INTERACTIVE SSH session
#      with the marker set lands in a PLAIN shell, not in the owner's `main` tmux session.
#      This lives in ~/.config/fish/config.fish, a file this package does not own and Fin
#      itself can write; if it is ever lost, the daemon's readiness probes and every
#      keystroke of every turn land in the owner's live session (the 2026-09-05 iMac
#      incident). Checked at every launch, not once at install. INTERACTIVE is the word
#      that matters — see the long note at the check itself for why the previous version
#      of it could not fail.
#   4. presigned-URL expiry — warn only. Expired URLs 403; the daemon treats a 403 as a
#      poll failure and keeps running (daemon/README.md, "403 is never absent"), so this
#      is loud in the log rather than fatal.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$BIN_DIR/fin-agentd"
CONFIG="${1:-}"
STATE_DIR="$(cd "$BIN_DIR/.." && pwd)"
BACKOFF="${FIN_LAUNCH_BACKOFF_SECONDS:-300}"
PYTHON="${FIN_PYTHON:-/usr/bin/python3}"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
note() { printf '[%s] launch: %s\n' "$(stamp)" "$*" >&2; }

# Refuse WITHOUT failing: launchd counts a non-zero exit as a crash and respawns at
# ThrottleInterval (15 s). Sleeping first turns that into a calm retry cadence.
refuse() {
	note "REFUSING TO START: $*"
	note "retrying in ${BACKOFF}s; nothing was started, no message was consumed, nothing was pushed"
	sleep "$BACKOFF"
	exit 0
}

[ -n "$CONFIG" ] || refuse "no config path given (usage: launch-agentd.sh <config.json>)"
[ -x "$BIN" ] || refuse "daemon binary missing or not executable: $BIN"
[ -s "$CONFIG" ] || refuse "config missing or empty: $CONFIG"

# --- 1 + 2. config and brain -----------------------------------------------------------
# One python read: the config is 0600 and holds the control-plane token, so it is parsed,
# never grepped, and only these four non-secret fields are echoed.
FIELDS="$(FIN_CONFIG="$CONFIG" "$PYTHON" - <<'PY' 2>&1
import json, os, sys
try:
    with open(os.environ["FIN_CONFIG"]) as fh:
        c = json.load(fh)
except Exception as error:                     # noqa: BLE001 — the reason matters, the content never prints
    sys.exit("unreadable/invalid JSON: %s" % error.__class__.__name__)
agent = c.get("agent") or {}
server = c.get("server") or {}
print("%s\t%s\t%s\t%s" % (
    agent.get("endpointURL", ""), agent.get("modelIdentifier", ""),
    server.get("username", ""), server.get("privateKeyPath", "")))
PY
)" || refuse "config.json did not parse ($FIELDS): $CONFIG"
IFS=$'\t' read -r ENDPOINT MODEL SSH_USER KEY_PATH <<<"$FIELDS"
[ -n "$ENDPOINT" ] || refuse "config has no agent.endpointURL"
[ -n "$SSH_USER" ] && [ -n "$KEY_PATH" ] || refuse "config has no server.username / server.privateKeyPath"

if [ "${FIN_SKIP_BRAIN_CHECK:-0}" != "1" ]; then
	# -f: without it curl exits 0 on a 404/500, so an LM Studio that is listening with no
	# model loaded would pass. The model id must actually appear in the /models payload.
	models="$(curl -fsS -m 10 "$ENDPOINT/models" 2>/dev/null)" \
		|| refuse "no brain at $ENDPOINT/models (start LM Studio)"
	if [ -n "$MODEL" ] && ! printf '%s' "$models" | grep -qF -- "$MODEL"; then
		refuse "$ENDPOINT is serving, but not the configured model ($MODEL) — load it in LM Studio"
	fi
fi

# --- 3. the login-shell guard ------------------------------------------------------------
# THE OLD VERSION OF THIS CHECK WAS VACUOUS. It ran `ssh host <command>`, which sshd runs
# as `$SHELL -c …` — a NON-INTERACTIVE shell — while the auto-attach it is testing is gated
# on `status is-interactive` (~/.config/fish/config.fish). The block under test never ran,
# so the probe printed `TMUX=[]` and passed whether the guard was there or not. A check
# that always passes is worse than no check: it retires the operator's suspicion.
#
# The real path, and the two deliberate differences from it:
#   * `$SHELL -i -c` forces an INTERACTIVE shell, so the auto-attach block is evaluated.
#   * `SSH_TTY=/dev/null` is exported because the block's remote test accepts
#     SSH_CONNECTION *or* SSH_TTY, and only a PTY session sets the latter.
#   * NO PTY is requested. With one, the FAILING branch would attach the owner's live
#     `main` and resize their windows for as long as the probe ran. Without one, that
#     branch runs `tmux new-session -A -s main`, tmux exits "open terminal failed: not a
#     terminal" (verified, tmux 3.6a), nothing attaches, and the GUARD line never prints —
#     so the probe fails closed. A guard's test must not be able to do the damage the
#     guard prevents.
#   * The payload is single-quoted twice: the OUTER remote shell must not expand $TMUX,
#     which is unset there and would print `TMUX=[]` whatever the interactive shell did.
# What it still cannot prove: that the auto-attach works at all — a config that never
# attaches passes too. Checking that direction means attaching the owner's session on
# purpose, which this launcher will not do. See scripts/mac-fin-agentd/README.md.
if [ "${FIN_SKIP_TMUX_GUARD_CHECK:-0}" != "1" ]; then
	[ -r "$KEY_PATH" ] || refuse "site key unreadable: $KEY_PATH"
	# NEVER run this without LC_FIN_AGENT=1: without the marker an interactive login shell
	# is SUPPOSED to attach, which is the thing being tested for.
	probe_cmd='env SSH_TTY=/dev/null $SHELL -i -c '\''printf "GUARD LC=%s TMUX=[%s]\n" "$LC_FIN_AGENT" "$TMUX"'\'''
	probe="$(LC_FIN_AGENT=1 perl -e 'alarm shift; exec @ARGV' 30 \
		ssh -i "$KEY_PATH" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
		-o SendEnv=LC_FIN_AGENT -o StrictHostKeyChecking=accept-new \
		"$SSH_USER@127.0.0.1" "$probe_cmd" </dev/null 2>&1)" \
		|| refuse "loopback SSH with the site key failed: ${probe:-no output} (Remote Login off? key not authorized?)"
	case "$probe" in
		*"GUARD LC=1 TMUX=[]"*) : ;;
		*"GUARD LC=1 TMUX=["*)
			refuse "the login shell put an INTERACTIVE session inside tmux even with LC_FIN_AGENT set (${probe##*GUARD }).
Starting now would type the daemon's readiness probe and every keystroke of every turn into
the owner's live session. Restore the LC_FIN_AGENT exclusion in ~/.config/fish/config.fish." ;;
		*"GUARD LC="*)
			refuse "the LC_FIN_AGENT marker did not cross the SSH boundary (${probe##*GUARD }) — check sshd's AcceptEnv" ;;
		*)
			refuse "the interactive login shell never answered the probe: ${probe:-no output}
That is what an auto-attach looks like from here — the shell exec'd tmux instead of running the
probe (with no PTY, tmux then failed with 'not a terminal', so nothing was attached).
Restore the LC_FIN_AGENT exclusion in ~/.config/fish/config.fish." ;;
	esac
fi

# --- 4. presigned-URL expiry (warn only) ---------------------------------------------------
STATE="$STATE_DIR/provision-state.json"
if [ -s "$STATE" ]; then
	FIN_STATE="$STATE" "$PYTHON" - <<'PY' >&2 2>/dev/null || true
import datetime, json, os
with open(os.environ["FIN_STATE"]) as fh:
    state = json.load(fh)
raw = state.get("expires_at") or ""
if raw:
    at = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    left = (at - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
    if left <= 0:
        print("launch: WARNING presigned URLs EXPIRED %s — every poll and PUT will 403 and the "
              "daemon will keep running silently; run refresh.sh" % raw)
    elif left < 48 * 3600:
        print("launch: presigned URLs expire in %.1f h (%s)" % (left / 3600.0, raw))
PY
fi

note "preflight ok — exec $BIN"
exec "$BIN" "$CONFIG"

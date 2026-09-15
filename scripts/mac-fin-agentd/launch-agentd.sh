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
#   2. the brain can actually SERVE the configured model — polled for up to 5 minutes
#      (FIN_BRAIN_WAIT_SECONDS), and proved with a one-token completion rather than a
#      /models listing, which LM Studio answers from its DOWNLOADED models whether or not
#      any is in memory. That probe doubles as the on-demand load: an unloaded model costs
#      the probe a few seconds instead of costing the site a refusal to start.
#   3. the login shell honours the LC_FIN_AGENT marker — i.e. an INTERACTIVE SSH session
#      with the marker set lands in a PLAIN shell, not in the owner's `main` tmux session.
#      This lives in ~/.config/fish/config.fish, a file this package does not own and Fin
#      itself can write; if it is ever lost, the daemon's readiness probes and every
#      keystroke of every turn land in the owner's live session (the 2026-09-05 iMac
#      incident). Checked at every launch, not once at install. INTERACTIVE is the word
#      that matters — see the long note at the check itself for why the previous version
#      of it could not fail.
#      (The brain may be on ANOTHER machine, reached over Funnel and bearer-gated — see
#      check 2. Check 3 below is still loopback SSH on THIS machine, which every resident
#      site needs whatever it thinks with.)
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

# --- waiting for a brain, and loading the model ON DEMAND --------------------------------
# Two things this replaced, both wrong in ways that only showed on a real machine:
#
#   1. IT REFUSED INSTEAD OF WAITING. A single failed GET meant "no brain", which is right
#      only if the brain is a process on this same box. Reached over a Funnel it is also
#      what a sleeping Mac, a roaming laptop, a DERP hiccup or an LM Studio that is still
#      starting looks like — none of which is a reason to give up for a whole backoff.
#   2. `/models` WAS NOT EVIDENCE. LM Studio lists every DOWNLOADED model there whether or
#      not any of them is in memory, so the old "is the id in the payload?" test passed
#      with nothing loaded at all — and then every real turn failed. (Verified: with
#      `lms unload --all`, /v1/models still answers 200 and still lists the model.)
#
# So: poll until the endpoint answers, then prove it can SERVE with a one-token completion.
# That probe is also the FIX for an unloaded model rather than a complaint about it — LM
# Studio JIT-loads on a chat request (measured: ~3 s for a 7 GB gemma), so asking for one
# token is what brings the model back. A model with a TTL is expected to unload; that must
# cost the next turn three seconds, never a refusal to start.
#
# The one failure that does NOT wait is a model the server does not have at all: no amount
# of patience downloads it, so that returns 2 and the caller fails fast.
BRAIN_WAIT_SECONDS="${FIN_BRAIN_WAIT_SECONDS:-300}"
brain_probe_reason=""

# $1 endpoint (…/v1), $2 model id, $3 curl -K auth file or "", $4 python
brain_completion() {
	local endpoint="$1" model="$2" keyconf="$3" python="$4" payload
	payload="$(FIN_MODEL_ID="$model" "$python" -c 'import json, os; print(json.dumps({
    "model": os.environ["FIN_MODEL_ID"],
    "messages": [{"role": "user", "content": "ping"}],
    "max_tokens": 1, "temperature": 0}))')" || return 1
	# -m 180: a COLD model has to be read off disk inside this request. The outer deadline
	# is what actually bounds the wait; this only stops one attempt hanging forever.
	if [ -n "$keyconf" ]; then
		curl -fsS -m 180 -K "$keyconf" -H 'content-type: application/json' \
			-d "$payload" "$endpoint/chat/completions" >/dev/null 2>&1
	else
		curl -fsS -m 180 -H 'content-type: application/json' \
			-d "$payload" "$endpoint/chat/completions" >/dev/null 2>&1
	fi
}

# 0 = serving, 1 = still not serving when the budget ran out, 2 = it will never serve this
# model. Sets brain_probe_reason on 1 and 2. $5 is a progress logger (a shell function name).
brain_wait() {
	local endpoint="$1" model="$2" keyconf="$3" python="$4" progress="$5"
	local started elapsed body rc announced=0
	started="$(date +%s)"
	while :; do
		if [ -n "$keyconf" ]; then
			body="$(curl -fsS -m 15 -K "$keyconf" "$endpoint/models" 2>/dev/null)"; rc=$?
		else
			body="$(curl -fsS -m 15 "$endpoint/models" 2>/dev/null)"; rc=$?
		fi
		if [ "$rc" -eq 0 ]; then
			if [ -n "$model" ] && ! printf '%s' "$body" | grep -qF -- "$model"; then
				brain_probe_reason="$endpoint answers, but has no model called $model — check the id, or download it on the machine serving it"
				return 2
			fi
			if brain_completion "$endpoint" "$model" "$keyconf" "$python"; then
				return 0
			fi
		fi
		elapsed=$(( $(date +%s) - started ))
		if [ "$elapsed" -ge "$BRAIN_WAIT_SECONDS" ]; then
			brain_probe_reason="$endpoint could not serve ${model:-a model} within ${elapsed}s"
			return 1
		fi
		if [ "$announced" -eq 0 ]; then
			"$progress" "waiting for the brain at $endpoint (up to ${BRAIN_WAIT_SECONDS}s; an unloaded model is loaded on demand by this probe)"
			announced=1
		fi
		sleep 5
	done
}


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
# SHELL ASSIGNMENTS, NOT DELIMITED FIELDS. This used to print tab-separated values and
# split them with `IFS=$'\t' read`, which is wrong in a way that hid until a config left a
# field EMPTY: tab is IFS *whitespace*, so bash collapses runs of it into one delimiter and
# every field after an empty one shifts left. Under the local transport `username` and
# `privateKeyPath` are both absent by design, so `HAS_API_KEY` received the transport name,
# `TRANSPORT` received nothing, and the checks below silently examined the wrong values —
# the ssh branch "passed" on two fields that were not a user and not a key. Python quotes
# each value with shlex instead, so an empty value stays empty and a value with a space
# stays one value.
FIELDS="$(FIN_CONFIG="$CONFIG" "$PYTHON" - <<'PY' 2>&1
import json, os, shlex, sys
try:
    with open(os.environ["FIN_CONFIG"]) as fh:
        c = json.load(fh)
except Exception as error:                     # noqa: BLE001 — the reason matters, the content never prints
    sys.exit("unreadable/invalid JSON: %s" % error.__class__.__name__)
agent = c.get("agent") or {}
server = c.get("server") or {}
for name, value in (
    ("ENDPOINT", agent.get("endpointURL", "")),
    ("MODEL", agent.get("modelIdentifier", "")),
    ("SSH_USER", server.get("username", "")),
    ("KEY_PATH", server.get("privateKeyPath", "")),
    # The key itself is never printed — only whether there is one.
    ("HAS_API_KEY", "yes" if (agent.get("apiKey") or "").strip() else "no"),
    ("TRANSPORT", server.get("transport") or "ssh"),
):
    print("%s=%s" % (name, shlex.quote(str(value))))
PY
)" || refuse "config.json did not parse ($FIELDS): $CONFIG"
case "$FIELDS" in
    *"ENDPOINT="*"TRANSPORT="*) : ;;
    *) refuse "could not read the config's fields: $FIELDS" ;;
esac
eval "$FIELDS"
[ -n "$ENDPOINT" ] || refuse "config has no agent.endpointURL"
if [ "$TRANSPORT" = "local" ]; then
	# tmux IS the session under the local transport — the connect command is the child
	# process, so a tmux that is not on PATH is not an error the daemon can report from
	# inside a shell, it is a child that exits instantly, forever, at the backoff ceiling.
	# launchd's PATH is the plist's, not a login shell's, which is exactly the environment
	# where a Homebrew tmux goes missing.
	command -v tmux >/dev/null || refuse "tmux is not on PATH ($PATH) — the local transport runs it directly"
else
	[ -n "$SSH_USER" ] && [ -n "$KEY_PATH" ] || refuse "config has no server.username / server.privateKeyPath"
fi

if [ "${FIN_SKIP_BRAIN_CHECK:-0}" != "1" ]; then
	# -f: without it curl exits 0 on a 404/500, so an LM Studio that is listening with no
	# model loaded would pass. The model id must actually appear in the /models payload.
	#
	# A REMOTE brain is bearer-gated, and to `-f` alone its 401 is indistinguishable from
	# "no brain at all" — so when the config carries an apiKey it is sent, through a 0600
	# `-K` file rather than a `-H` argument: curl's argv is world-readable in `ps`, and on
	# a managed laptop that is not a theoretical audience. The key is read out of the
	# config by python (the config is 0600 and also holds the site token), never echoed.
	KEYCONF=""
	if [ "$HAS_API_KEY" = "yes" ]; then
		KEYCONF="$(mktemp -t fin-brain-auth)" || refuse "could not create a temp file for the brain auth header"
		chmod 600 "$KEYCONF"
		trap 'rm -f "$KEYCONF"' EXIT
		FIN_CONFIG="$CONFIG" "$PYTHON" - > "$KEYCONF" <<'PY' || refuse "could not read agent.apiKey from the config"
import json, os
key = ((json.load(open(os.environ["FIN_CONFIG"])).get("agent") or {}).get("apiKey") or "").strip()
print('header = "Authorization: Bearer %s"' % key)
PY
	fi
	set +e
	brain_wait "$ENDPOINT" "$MODEL" "$KEYCONF" "$PYTHON" note
	brain_rc=$?
	set -e
	if [ -n "$KEYCONF" ]; then rm -f "$KEYCONF"; trap - EXIT; fi
	case "$brain_rc" in
		0) : ;;
		2) refuse "$brain_probe_reason" ;;
		*) refuse "$brain_probe_reason — the machine serving it may be asleep, off the network, or not running LM Studio" ;;
	esac
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
# UNDER THE LOCAL TRANSPORT THIS CHECK HAS NOTHING TO CHECK. It exists because sshd hands
# the daemon an INTERACTIVE LOGIN SHELL, which can auto-attach the owner's tmux before the
# daemon types anything (2026-09-05). A local PTY execs the connect command itself,
# non-interactively: no login shell, no rc files, no auto-attach to exclude. The daemon
# still asserts at every launch that `$TMUX` names its own socket afterwards, which is the
# stronger statement and covers both transports.
if [ "$TRANSPORT" = "local" ]; then
	:
elif [ "${FIN_SKIP_TMUX_GUARD_CHECK:-0}" != "1" ]; then
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

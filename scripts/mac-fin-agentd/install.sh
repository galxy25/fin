#!/bin/bash
# install.sh — install (or reinstall) fin-agentd as a resident site on this Mac.
#
#   install.sh                 install without loading; prints the exact start command
#   install.sh --start         …and bootstrap both LaunchAgents into gui/$UID
#   install.sh --binary PATH   copy this fin-agentd instead of daemon/.build/release/fin-agentd
#   install.sh --site8 HEX8    site identity to use (first install, or must match the persisted one)
#   install.sh --reprovision   rewrite config.json from defaults instead of re-signing in place
#   install.sh --no-verify     skip provision-config.sh's GET check of the two read URLs
#
# What it does, in order — every step is idempotent, so re-run it freely:
#   1. checks the binary's own `--version` against the floor below, then copies it to
#      ~/Library/Application Support/fin-agentd/bin/ (never builds; build with
#      scripts/dev/one-at-a-time.sh first)
#   2. preflights the credentials a provision needs BEFORE generating any secret
#   3. mints SITE8 once (persisted in …/fin-agentd/site8) and generates the dedicated
#      site key …/fin-agentd/site_ed25519 if missing
#   4. appends the restricted authorized_keys line EXACTLY once — grep before append,
#      other lines are never touched; a same-key line with the WRONG options is fatal
#   5. runs provision-config.sh: presigned URLs, config.json (0600), routing-registry.json.
#      An existing, matching config is REFRESHED in place (hand edits survive);
#      --reprovision forces the full default rewrite
#   6. installs the runtime scripts next to the binary — the LaunchAgents must never
#      point into this git checkout — and renders both plists into ~/Library/LaunchAgents
#   7. with --start: enable, bootout-if-loaded, bootstrap. Without it the labels are
#      launchctl-DISABLED, so a plist on disk cannot start the daemon at the next login.
#
# ZERO sudo. The one root step the design calls for (`sudo pmset -a sleep 0`, so the
# resident site never sleeps) is printed at the end, never run. See README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL="dev.levischoen.fin.agentd"
REFRESH_LABEL="dev.levischoen.fin.agentd.refresh"
FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
LOG_DIR="${FIN_AGENTD_LOG_DIR:-$HOME/Library/Logs/fin-agentd}"
AGENTS_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$FIN_AGENTD_HOME/bin"
BIN_DEST="$BIN_DIR/fin-agentd"
CONFIG="$FIN_AGENTD_HOME/config.json"
KEY="$FIN_AGENTD_HOME/site_ed25519"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
DOMAIN="gui/$(id -u)"
LLM_URL="${FIN_LLM_URL:-http://127.0.0.1:1234/v1}"

BIN_SRC="${FIN_AGENTD_BIN_SRC:-$REPO_ROOT/daemon/.build/release/fin-agentd}"
# The floor, not a preference, and it tracks the daemon<->config CONTRACT.
#
# 1.5.0 is the private-socket contract: provision-config.sh writes (and on every refresh
# rewrites) a connectCommand that puts the daemon's shell on its OWN tmux socket
# (`exec tmux -L fin …`). A 1.4.x binary paired with that config is confined with no way
# to look out of it — it has no read_session tool and no tmux guard, so Fin can neither
# see nor drive the machine's real sessions, and nothing in the install output would say
# so. This check is the only thing standing between an old binary in
# daemon/.build/release and that silent half-install.
#
# 1.4.1 is still the floor for the older reason, kept because a floor only ever moves up:
# below it the first supervised run seeds only the directive document, so every message
# sitting in fin/inbox/<slug>.json — up to 200 accumulated app messages, some weeks old —
# is injected as one model turn each on the resident first run.
REQUIRED_DAEMON_VERSION="${FIN_REQUIRED_DAEMON_VERSION:-1.5.0}"
# Copied next to the binary at install time; the LaunchAgents reference these, never the
# checkout (see step 6).
RUNTIME_SCRIPTS=(refresh.sh provision-config.sh rotate-logs.sh launch-agentd.sh)
START=0; SITE8_ARG=""; REPROVISION=0; PROVISION_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--start) START=1 ;;
		--binary) [ $# -ge 2 ] || { echo "error: --binary needs a path" >&2; exit 64; }; BIN_SRC="$2"; shift ;;
		--site8) [ $# -ge 2 ] || { echo "error: --site8 needs a value" >&2; exit 64; }; SITE8_ARG="$2"; shift ;;
		--reprovision) REPROVISION=1 ;;
		--no-verify) PROVISION_ARGS+=(--no-verify) ;;
		-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

for f in "${RUNTIME_SCRIPTS[@]}" "$LABEL.plist" "$REFRESH_LABEL.plist"; do
	[ -f "$SCRIPT_DIR/$f" ] || die "$SCRIPT_DIR/$f not found"
done
case "$HOME$SCRIPT_DIR" in
	*'#'*|*'&'*|*'<'*|*'>'*) die "home or checkout path contains #, &, < or > — the plist renderer can't escape that" ;;
esac

# --- 1. binary --------------------------------------------------------------------------
step "Binary"
[ -f "$BIN_SRC" ] || die "daemon binary not found: $BIN_SRC
Build it first (through the machine guard, never bare):
    $REPO_ROOT/scripts/dev/one-at-a-time.sh swift build -c release --package-path $REPO_ROOT/daemon
or point at one with --binary PATH."
[ -x "$BIN_SRC" ] || die "$BIN_SRC is not executable"

# Ask the binary what it is. `strings` cannot answer this: `daemonVersion` is a five-byte
# Swift string, stored as a small-string immediate in the instruction stream, so grepping
# the Mach-O for "1.5.0" finds nothing even in a 1.5.0 body.
DAEMON_VERSION="$("$BIN_SRC" --version 2>/dev/null | awk '$1 == "fin-agentd" {print $2}')"
[ -n "$DAEMON_VERSION" ] || die "$BIN_SRC does not answer --version — it predates the version flag,
so it is older than $REQUIRED_DAEMON_VERSION. Rebuild through the machine guard:
    $REPO_ROOT/scripts/dev/one-at-a-time.sh swift build -c release --package-path $REPO_ROOT/daemon"
if [ "$DAEMON_VERSION" != "$REQUIRED_DAEMON_VERSION" ] \
	&& [ "$(printf '%s\n%s\n' "$REQUIRED_DAEMON_VERSION" "$DAEMON_VERSION" | sort -V | head -1)" != "$REQUIRED_DAEMON_VERSION" ]; then
	die "$BIN_SRC is fin-agentd $DAEMON_VERSION; this site needs >= $REQUIRED_DAEMON_VERSION.
Below $REQUIRED_DAEMON_VERSION the daemon does not know about the private tmux socket this
installer provisions: no read_session tool and no tmux guard, so Fin would be shut inside its
own tmux server with no way to see the machine's real work (and below 1.4.1 the resident first
run also replays the whole inbox backlog, one model turn per message). Rebuild through the
machine guard:
    $REPO_ROOT/scripts/dev/one-at-a-time.sh swift build -c release --package-path $REPO_ROOT/daemon"
fi
echo "version: fin-agentd $DAEMON_VERSION (floor $REQUIRED_DAEMON_VERSION)"

umask 077
mkdir -p "$FIN_AGENTD_HOME" "$BIN_DIR" "$LOG_DIR"
chmod 700 "$FIN_AGENTD_HOME"
if [ -f "$BIN_DEST" ] && cmp -s "$BIN_SRC" "$BIN_DEST"; then
	echo "unchanged: $BIN_DEST"
else
	# Copy to a sibling temp file and rename over the target: a running daemon keeps its
	# old inode mapped, whereas overwriting a mapped Mach-O in place kills the process.
	tmp="$BIN_DIR/.fin-agentd.$$"
	cp "$BIN_SRC" "$tmp"
	chmod 755 "$tmp"
	mv -f "$tmp" "$BIN_DEST"
	echo "installed: $BIN_DEST ($(stat -f %z "$BIN_DEST") bytes)"
fi

# --- 2. credential preflight, BEFORE any secret exists ---------------------------------
# This used to live inside step 5 (provision-config.sh), which meant a Mac missing
# ~/.fin-control-plane-token — or a python without boto3, or an AWS profile with no
# credentials — aborted the install AFTER generating the site key and appending its
# authorized_keys line. That leaves a live authorized key on disk beside its private half,
# and a plain `uninstall.sh` deliberately KEEPS both. Nothing said so.
step "Preflight"
"$SCRIPT_DIR/provision-config.sh" --preflight

# --- 3. site identity + dedicated key -------------------------------------------------
step "Site identity"
if [ -n "$SITE8_ARG" ]; then
	SITE8="$("$SCRIPT_DIR/provision-config.sh" --print-site8 --site8 "$SITE8_ARG")"
else
	SITE8="$("$SCRIPT_DIR/provision-config.sh" --print-site8)"
fi
echo "site8: $SITE8 (persisted in $FIN_AGENTD_HOME/site8)"

step "Site key"
if [ -f "$KEY" ]; then
	echo "exists: $KEY"
else
	# Dedicated, restricted key — NOT Fin's Key (docs/SITES.md section 9).
	ssh-keygen -q -t ed25519 -N "" -C "fin-site-$SITE8" -f "$KEY"
	echo "generated: $KEY"
fi
chmod 600 "$KEY"
[ -f "$KEY.pub" ] || ssh-keygen -y -f "$KEY" > "$KEY.pub"

# --- 4. authorized_keys: one restricted line, appended at most once ---------------------
step "authorized_keys"
KEY_TYPE="$(awk '{print $1}' "$KEY.pub")"
KEY_BLOB="$(awk '{print $2}' "$KEY.pub")"
[ "$KEY_TYPE" = "ssh-ed25519" ] && [ -n "$KEY_BLOB" ] || die "$KEY.pub does not look like an ed25519 public key"
# restrict: no forwarding/X11/agent/pty; pty: re-enable the terminal the harness needs;
# from=: loopback only — this key can only ever be used from this Mac to this Mac.
AUTH_LINE="restrict,pty,from=\"127.0.0.1,::1\" $KEY_TYPE $KEY_BLOB fin-site-$SITE8"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
[ -f "$AUTHORIZED_KEYS" ] || : > "$AUTHORIZED_KEYS"
if grep -qF -- "$AUTH_LINE" "$AUTHORIZED_KEYS"; then
	echo "present: fin-site-$SITE8 line already in $AUTHORIZED_KEYS"
elif grep -qF -- "$KEY_BLOB" "$AUTHORIZED_KEYS"; then
	# Fatal, not a warning. The whole security model of a resident site is that this key
	# is useless off the box: `restrict` kills forwarding, `from=` pins it to loopback.
	# A hand-authorized line (`cat site_ed25519.pub >> ~/.ssh/authorized_keys`, or an
	# older options set) has none of that, and sshd here listens on *:22 — so the key
	# would be usable from any host that can reach this Mac, which is exactly the
	# property README.md's security model promises it does not have. Warning and then
	# completing normally (through --start, even) made the absence silent.
	die "this key is already in $AUTHORIZED_KEYS with DIFFERENT options.
Nothing was changed. The line must be exactly:
    restrict,pty,from=\"127.0.0.1,::1\" $KEY_TYPE <key> fin-site-$SITE8
Without those options the site key is not pinned to loopback and is usable from any host
that can reach this Mac. Remove the existing line (it is the one whose key blob matches
$KEY.pub) and re-run, or authorize it exactly as above."
else
	# Make sure we append on a fresh line even if the file lacks a trailing newline.
	if [ -s "$AUTHORIZED_KEYS" ] && [ "$(tail -c 1 "$AUTHORIZED_KEYS" | od -An -c | tr -d ' ')" != '\n' ]; then
		printf '\n' >> "$AUTHORIZED_KEYS"
	fi
	printf '%s\n' "$AUTH_LINE" >> "$AUTHORIZED_KEYS"
	echo "appended: fin-site-$SITE8 line to $AUTHORIZED_KEYS ($(grep -c . "$AUTHORIZED_KEYS") lines now)"
fi
chmod 600 "$AUTHORIZED_KEYS"

# --- 5. config + presigned URLs + routing registry -------------------------------------
# A re-install used to run a FULL provision every time, rebuilding every field from this
# script's env defaults: point the site at a freshly fine-tuned model by editing
# config.json, re-run install.sh to pick up a new binary, and the model silently reverted
# to the default with no diff and no warning. When a valid config for THIS site is already
# there, re-sign in place instead (--refresh keeps every other field verbatim).
step "Config"
CONFIG_MODE="full write"
if [ "$REPROVISION" -eq 0 ] && [ -s "$CONFIG" ] \
	&& CONFIG_SITE8="$(FIN_CONFIG="$CONFIG" /usr/bin/python3 -c '
import json, os, sys
try:
    with open(os.environ["FIN_CONFIG"]) as fh:
        print((json.load(fh) or {}).get("deviceToken8") or "")
except Exception:
    sys.exit(1)' 2>/dev/null)" \
	&& [ "$CONFIG_SITE8" = "$SITE8" ]; then
	CONFIG_MODE="refresh in place (hand edits kept; --reprovision to overwrite)"
	PROVISION_ARGS+=(--refresh)
fi
echo "mode: $CONFIG_MODE"
FIN_DAEMON_VERSION="$DAEMON_VERSION" \
	"$SCRIPT_DIR/provision-config.sh" "${PROVISION_ARGS[@]+"${PROVISION_ARGS[@]}"}"
[ -s "$CONFIG" ] || die "provision-config.sh did not produce $CONFIG"

# --- 6. runtime scripts next to the binary, then the LaunchAgents ----------------------
# The plists must NEVER point into this git checkout. scripts/mac-fin-agentd exists only
# on an unmerged branch, and CLAUDE.md's standing policy is continuous merge in this same
# worktree: one `git checkout main` (or a rename of the checkout) and the refresh job
# fails with ENOENT at 04:00 on a Sunday, into refresh.err.log, which nobody reads. Seven
# days later every presigned URL expires; the daemon treats each 403 as a poll failure and
# keeps running (daemon/README.md, "403 is never absent"), so the site goes permanently
# deaf — no directives, no inbox, no status, no transcript, no alert — while
# `launchctl print` still shows it alive. The binary was always copied out; these are the
# files that were not.
step "Runtime scripts"
for f in "${RUNTIME_SCRIPTS[@]}"; do
	tmp="$BIN_DIR/.$f.$$"
	cp "$SCRIPT_DIR/$f" "$tmp"
	chmod 755 "$tmp"
	mv -f "$tmp" "$BIN_DIR/$f"
	echo "installed: $BIN_DIR/$f"
done

step "LaunchAgents"
mkdir -p "$AGENTS_DIR"
render() {
	# '#' delimiter: the paths contain slashes and spaces, never '#'.
	sed -e "s#__FIN_AGENTD_BIN__#$BIN_DEST#g" \
	    -e "s#__FIN_AGENTD_CONFIG__#$CONFIG#g" \
	    -e "s#__FIN_AGENTD_HOME__#$FIN_AGENTD_HOME#g" \
	    -e "s#__FIN_AGENTD_LOG_DIR__#$LOG_DIR#g" \
	    -e "s#__FIN_LAUNCHER__#$BIN_DIR/launch-agentd.sh#g" \
	    -e "s#__FIN_REFRESH_SCRIPT__#$BIN_DIR/refresh.sh#g" \
	    "$1" > "$2"
	if grep -q '__FIN_' "$2"; then die "unrendered placeholder in $2"; fi
	if grep -qF -- "$SCRIPT_DIR" "$2"; then die "$2 still points into the git checkout ($SCRIPT_DIR)"; fi
	plutil -lint -s "$2" || die "$2 is not a valid plist"
	chmod 644 "$2"
	echo "rendered: $2"
}
render "$SCRIPT_DIR/$LABEL.plist" "$AGENTS_DIR/$LABEL.plist"
render "$SCRIPT_DIR/$REFRESH_LABEL.plist" "$AGENTS_DIR/$REFRESH_LABEL.plist"

# --- 7. load, or make sure nothing can load itself -----------------------------------------
LOADED=0
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && LOADED=1
if [ "$START" -eq 1 ]; then
	step "Brain check"
	# -f, because without it curl exits 0 on a 404 or 500: an LM Studio that is listening
	# with no model loaded would sail through, and the daemon would then 404 on every
	# /v1/chat/completions — the exact fail-loop this check exists to prevent. The model
	# id must be in the payload too. (This is a convenience: launch-agentd.sh re-runs the
	# same check at EVERY launch, which is the one that actually protects the owner.)
	if [ "${FIN_SKIP_BRAIN_CHECK:-0}" != "1" ]; then
		MODELS="$(curl -fsS -m 10 "$LLM_URL/models" 2>/dev/null)" || die \
			"nothing usable answers at $LLM_URL/models — start LM Studio (or set FIN_LLM_URL) before --start.
Installed and rendered; not loaded. FIN_SKIP_BRAIN_CHECK=1 overrides this check."
		WANT_MODEL="${FIN_MODEL:-$(FIN_CONFIG="$CONFIG" /usr/bin/python3 -c '
import json, os
with open(os.environ["FIN_CONFIG"]) as fh:
    print(((json.load(fh) or {}).get("agent") or {}).get("modelIdentifier") or "")' 2>/dev/null)}"
		if [ -n "$WANT_MODEL" ] && ! printf '%s' "$MODELS" | grep -qF -- "$WANT_MODEL"; then
			die "$LLM_URL is serving, but not $WANT_MODEL — load that model in LM Studio.
Installed and rendered; not loaded."
		fi
		echo "brain: $LLM_URL serving ${WANT_MODEL:-<unchecked>}"
	fi

	step "Login-shell guard check"
	# The LC_FIN_AGENT marker only helps if the login shell honours it, and that lives in
	# ~/.config/fish/config.fish — a file this package neither owns nor installs, and one
	# Fin itself can write. Lose that line to a dotfile restore and the daemon's
	# FIN_READY_* probe and every keystroke of every turn land in the owner's live `main`
	# session (the 2026-09-05 incident the marker exists to prevent).
	#
	# THE PREVIOUS VERSION OF THIS CHECK WAS VACUOUS, and a check that always passes is
	# worse than none. It ran `ssh host <command>`, which sshd runs as `$SHELL -c …` — a
	# NON-INTERACTIVE shell — while the auto-attach it was testing is gated on
	# `status is-interactive`. The block under test never ran, so the probe printed
	# `TMUX=[]` and passed whether the guard was there or not.
	#
	# What it does now, and why in this exact shape:
	#   * `$SHELL -i -c` forces an INTERACTIVE shell, so `status is-interactive` is true
	#     and the auto-attach block is actually evaluated. That is the gate that was
	#     being skipped.
	#   * `SSH_TTY=/dev/null` is set because the block's "am I remote?" test accepts
	#     SSH_CONNECTION *or* SSH_TTY, and only a PTY session sets the latter — so a
	#     future config keyed on SSH_TTY would otherwise slip past a PTY-less probe.
	#   * NO PTY IS REQUESTED, deliberately, and this is the one place the check differs
	#     from the session it models. With a PTY, the FAILING branch would really attach
	#     the owner's live `main` (resizing their windows) for as long as the probe took.
	#     Without one, that same branch runs `tmux new-session -A -s main` and tmux exits
	#     with "open terminal failed: not a terminal" (verified, tmux 3.6a) — no client,
	#     no resize, no keystrokes — and the GUARD line never prints, so the probe fails
	#     closed. Testing a guard must not be able to cause the damage the guard prevents.
	#   * The payload is single-quoted twice on purpose: the OUTER remote shell must not
	#     expand $TMUX (it is unset there, so it would print `TMUX=[]` no matter what the
	#     interactive shell did — the same vacuity in a new disguise).
	# What it still cannot prove: that the auto-attach works AT ALL. A config that never
	# attaches anything passes this too. The only check for that direction is to attach
	# the owner's session on purpose, which this installer will not do.
	if [ "${FIN_SKIP_TMUX_GUARD_CHECK:-0}" != "1" ]; then
		PROBE_CMD='env SSH_TTY=/dev/null $SHELL -i -c '\''printf "GUARD LC=%s TMUX=[%s]\n" "$LC_FIN_AGENT" "$TMUX"'\'''
		PROBE="$(LC_FIN_AGENT=1 perl -e 'alarm shift; exec @ARGV' 30 \
			ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
			-o ConnectTimeout=5 -o SendEnv=LC_FIN_AGENT -o StrictHostKeyChecking=accept-new \
			"$(id -un)@127.0.0.1" "$PROBE_CMD" </dev/null 2>&1)" \
			|| die "loopback SSH with the site key failed: ${PROBE:-no output}
Remote Login on? key authorized? Installed and rendered; not loaded."
		case "$PROBE" in
			*"GUARD LC=1 TMUX=[]"*) echo "guard: ${PROBE#*GUARD }" ;;
			*"GUARD LC=1 TMUX=["*) die "the login shell put an INTERACTIVE session inside tmux even
with LC_FIN_AGENT set (${PROBE#*GUARD }).
Starting now would type the daemon's readiness probe and every keystroke of every turn into
the owner's live tmux session. Restore the LC_FIN_AGENT exclusion in ~/.config/fish/config.fish.
Installed and rendered; not loaded." ;;
			*"GUARD LC="*) die "the LC_FIN_AGENT marker did not cross the SSH boundary
(${PROBE#*GUARD }) — check sshd's AcceptEnv. Installed and rendered; not loaded." ;;
			*) die "the interactive login shell never answered the probe: ${PROBE:-no output}
That is what an auto-attach looks like from here — the shell exec'd tmux instead of running the
probe (with no PTY, tmux then failed with 'not a terminal', so nothing was attached).
Restore the LC_FIN_AGENT exclusion in ~/.config/fish/config.fish.
Installed and rendered; not loaded." ;;
		esac
	fi

	step "Bootstrapping into $DOMAIN"
	"$BIN_DIR/rotate-logs.sh" || echo "warning: log rotation failed (continuing)" >&2
	for label in "$LABEL" "$REFRESH_LABEL"; do
		if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
			echo "booting out the loaded $label"
			launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
		fi
		# enable BEFORE bootstrap: the no-start path leaves these labels disabled, and
		# bootstrapping a disabled label is a no-op that reads like success.
		launchctl enable "$DOMAIN/$label" 2>/dev/null || true
		launchctl bootstrap "$DOMAIN" "$AGENTS_DIR/$label.plist"
		echo "loaded: $label"
	done
	echo
	launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state = |program = |pid = " || true
	echo
	echo "Logs: $LOG_DIR/agentd.{out,err}.log ; audit: $FIN_AGENTD_HOME/audit.jsonl"
	echo "    tail -f \"$LOG_DIR/agentd.err.log\""
else
	# "Installed, NOT loaded" was true only until the next login. Both plists sit in
	# ~/Library/LaunchAgents with RunAtLoad=true and no override, so launchd loads and
	# starts them at the next login or reboot — with no brain check, because that check
	# only ever ran on the --start path. With LM Studio deliberately closed that means
	# every turn failing, a "giving up after 5 consecutive failed turns" push to the
	# owner's phone every ~90 s under KeepAlive+ThrottleInterval 15 (neither
	# DaemonNotifyClient nor the control plane's /notify dedupes), and — because inbox
	# messages are marked applied BEFORE the turn is submitted and a failed turn is never
	# retried — the whole inbox backlog silently consumed within about an hour.
	# `launchctl disable` writes a persistent per-user override that survives reboots;
	# --start re-enables. The launcher wrapper is the second half of the fix.
	step "Disabling both labels (nothing may start itself)"
	DISABLED_NOTE="both labels launchctl-DISABLED — a login or reboot will not start them"
	if [ "$LOADED" -eq 1 ]; then
		DISABLED_NOTE="LOADED and running — autostart left enabled on purpose"
		echo "skipped: $LABEL is loaded — someone started it deliberately; not disabling autostart"
	else
		for label in "$LABEL" "$REFRESH_LABEL"; do
			if launchctl disable "$DOMAIN/$label" 2>/dev/null; then
				echo "disabled: $label"
			else
				echo "warning: could not launchctl disable $DOMAIN/$label — check it by hand" >&2
			fi
		done
	fi

	step "Installed, NOT loaded"
	cat <<EOF
site8:    $SITE8
version:  fin-agentd $DAEMON_VERSION
binary:   $BIN_DEST
launcher: $BIN_DIR/launch-agentd.sh (preflights brain + tmux guard at every launch)
config:   $CONFIG (0600, $CONFIG_MODE)
key:      $KEY
plists:   $AGENTS_DIR/$LABEL.plist
          $AGENTS_DIR/$REFRESH_LABEL.plist   (runs $BIN_DIR/refresh.sh)
logs:     $LOG_DIR/
state:    $DISABLED_NOTE
EOF
	if [ "$LOADED" -eq 1 ]; then
		cat <<EOF

WARNING: $LABEL is ALREADY LOADED and still running the OLD binary and the OLD config.
The binary was replaced by rename, so the running process keeps its old inode and its old
code; it will never read the freshly signed URLs either. Restart it to pick both up:
    launchctl kickstart -k $DOMAIN/$LABEL
EOF
	fi
	cat <<EOF

Before starting: LM Studio must be serving on $LLM_URL, and — until Phase 1 —
nobody taps Start Worker for Fin (README.md, "Do not Start Worker for Fin").

To start (enables, loads the daemon AND the twice-weekly URL refresh):
    "$SCRIPT_DIR/install.sh" --start

Equivalent by hand:
    launchctl enable $DOMAIN/$LABEL && launchctl bootstrap $DOMAIN "$AGENTS_DIR/$LABEL.plist"
    launchctl enable $DOMAIN/$REFRESH_LABEL && launchctl bootstrap $DOMAIN "$AGENTS_DIR/$REFRESH_LABEL.plist"
EOF
fi

cat <<'EOF'

------------------------------------------------------------------------------
OPTIONAL (root, not run for you): a resident site is only as always-on as its
Mac, and a sleeping Mac cannot poll. docs/SITES.md step 12:

    sudo pmset -a sleep 0

Undo with:  sudo pmset -a sleep 1   (or your previous value)
------------------------------------------------------------------------------
EOF

#!/bin/bash
# install.sh — install (or reinstall) fin-agentd as a resident site on this Mac.
#
#   install.sh                 install without loading; prints the exact start command
#   install.sh --start         …and bootstrap both LaunchAgents into gui/$UID
#   install.sh --binary PATH   copy this fin-agentd instead of daemon/.build/release/fin-agentd
#   install.sh --site8 HEX8    site identity to use (first install, or must match the persisted one)
#   install.sh --no-verify     skip provision-config.sh's GET check of the two read URLs
#
# What it does, in order — every step is idempotent, so re-run it freely:
#   1. copies the daemon binary to ~/Library/Application Support/fin-agentd/bin/
#      (never builds; build with scripts/dev/one-at-a-time.sh first)
#   2. mints SITE8 once (persisted in …/fin-agentd/site8) and generates the dedicated
#      site key …/fin-agentd/site_ed25519 if missing
#   3. appends the restricted authorized_keys line EXACTLY once — grep before append,
#      other lines are never touched
#   4. runs provision-config.sh: presigned URLs, config.json (0600), routing-registry.json
#   5. renders both plists into ~/Library/LaunchAgents (placeholders → absolute paths)
#   6. with --start only: bootout-if-loaded, then bootstrap. Default: nothing is loaded.
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
START=0; SITE8_ARG=""; PROVISION_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--start) START=1 ;;
		--binary) [ $# -ge 2 ] || { echo "error: --binary needs a path" >&2; exit 64; }; BIN_SRC="$2"; shift ;;
		--site8) [ $# -ge 2 ] || { echo "error: --site8 needs a value" >&2; exit 64; }; SITE8_ARG="$2"; shift ;;
		--no-verify) PROVISION_ARGS+=(--no-verify) ;;
		-h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

for f in provision-config.sh refresh.sh "$LABEL.plist" "$REFRESH_LABEL.plist"; do
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

# --- 2. site identity + dedicated key -------------------------------------------------
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

# --- 3. authorized_keys: one restricted line, appended at most once ---------------------
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
	echo "warning: this key is in $AUTHORIZED_KEYS with DIFFERENT options — left as-is; expected:" >&2
	echo "    restrict,pty,from=\"127.0.0.1,::1\" $KEY_TYPE <key> fin-site-$SITE8" >&2
else
	# Make sure we append on a fresh line even if the file lacks a trailing newline.
	if [ -s "$AUTHORIZED_KEYS" ] && [ "$(tail -c 1 "$AUTHORIZED_KEYS" | od -An -c | tr -d ' ')" != '\n' ]; then
		printf '\n' >> "$AUTHORIZED_KEYS"
	fi
	printf '%s\n' "$AUTH_LINE" >> "$AUTHORIZED_KEYS"
	echo "appended: fin-site-$SITE8 line to $AUTHORIZED_KEYS ($(grep -c . "$AUTHORIZED_KEYS") lines now)"
fi
chmod 600 "$AUTHORIZED_KEYS"

# --- 4. config + presigned URLs + routing registry -------------------------------------
step "Config"
"$SCRIPT_DIR/provision-config.sh" "${PROVISION_ARGS[@]+"${PROVISION_ARGS[@]}"}"
[ -s "$CONFIG" ] || die "provision-config.sh did not produce $CONFIG"

# --- 5. LaunchAgents --------------------------------------------------------------------
step "LaunchAgents"
mkdir -p "$AGENTS_DIR"
render() {
	# '#' delimiter: the paths contain slashes and spaces, never '#'.
	sed -e "s#__FIN_AGENTD_BIN__#$BIN_DEST#g" \
	    -e "s#__FIN_AGENTD_CONFIG__#$CONFIG#g" \
	    -e "s#__FIN_AGENTD_HOME__#$FIN_AGENTD_HOME#g" \
	    -e "s#__FIN_AGENTD_LOG_DIR__#$LOG_DIR#g" \
	    -e "s#__FIN_REFRESH_SCRIPT__#$SCRIPT_DIR/refresh.sh#g" \
	    "$1" > "$2"
	if grep -q '__FIN_' "$2"; then die "unrendered placeholder in $2"; fi
	plutil -lint -s "$2" || die "$2 is not a valid plist"
	chmod 644 "$2"
	echo "rendered: $2"
}
render "$SCRIPT_DIR/$LABEL.plist" "$AGENTS_DIR/$LABEL.plist"
render "$SCRIPT_DIR/$REFRESH_LABEL.plist" "$AGENTS_DIR/$REFRESH_LABEL.plist"

# --- 6. load, or say how ------------------------------------------------------------------
if [ "$START" -eq 1 ]; then
	step "Brain check"
	# A daemon with no model endpoint fail-loops (KeepAlive + ThrottleInterval 15) and
	# every failed turn pushes a notification to the owner's phone — refuse to start blind.
	if [ "${FIN_SKIP_BRAIN_CHECK:-0}" != "1" ] && ! curl -sS -m 5 -o /dev/null "$LLM_URL/models"; then
		die "nothing answers at $LLM_URL/models — start LM Studio (or set FIN_LLM_URL) before --start.
Installed and rendered; not loaded. FIN_SKIP_BRAIN_CHECK=1 overrides this check."
	fi
	step "Bootstrapping into $DOMAIN"
	for label in "$LABEL" "$REFRESH_LABEL"; do
		if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
			echo "booting out the loaded $label"
			launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
		fi
		launchctl bootstrap "$DOMAIN" "$AGENTS_DIR/$label.plist"
		launchctl enable "$DOMAIN/$label" 2>/dev/null || true
		echo "loaded: $label"
	done
	echo
	launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state = |program = |pid = " || true
	echo
	echo "Logs: $LOG_DIR/agentd.{out,err}.log ; audit: $FIN_AGENTD_HOME/audit.jsonl"
	echo "    tail -f \"$LOG_DIR/agentd.err.log\""
else
	step "Installed, NOT loaded"
	cat <<EOF
site8:    $SITE8
binary:   $BIN_DEST
config:   $CONFIG (0600)
key:      $KEY
plists:   $AGENTS_DIR/$LABEL.plist
          $AGENTS_DIR/$REFRESH_LABEL.plist
logs:     $LOG_DIR/

Before starting: LM Studio must be serving on $LLM_URL, and — until Phase 1 —
nobody taps Start Worker for Fin (README.md, "Do not Start Worker for Fin").

To start (loads the daemon AND the weekly URL refresh):
    "$SCRIPT_DIR/install.sh" --start

Equivalent by hand:
    launchctl bootstrap $DOMAIN "$AGENTS_DIR/$LABEL.plist"
    launchctl bootstrap $DOMAIN "$AGENTS_DIR/$REFRESH_LABEL.plist"
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

#!/bin/bash
# Install (or reinstall) the fin-wake LaunchAgent for the current user.
#
# It renders the plist's script path to this checkout, copies it to
# ~/Library/LaunchAgents, and (re)bootstraps it into the per-user GUI domain.
# Idempotent: safe to run repeatedly — an already-loaded agent is booted out
# first, so a re-run picks up an edited script or a moved checkout.
#
# ZERO sudo. The only root step is OPTIONAL and printed at the end, never run:
# a daily `pmset repeat wake` that closes the cold-sleep gap (a request that
# arrives while the Mac is already asleep). See README.md for the tradeoff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAKE_SCRIPT="$SCRIPT_DIR/wake-for-fin.py"
SRC_PLIST="$SCRIPT_DIR/dev.levischoen.fin.wake.plist"
LABEL="dev.levischoen.fin.wake"
AGENTS_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$AGENTS_DIR/$LABEL.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"

if [ ! -f "$WAKE_SCRIPT" ]; then
	echo "error: $WAKE_SCRIPT not found" >&2
	exit 1
fi
if [ ! -f "$SRC_PLIST" ]; then
	echo "error: $SRC_PLIST not found" >&2
	exit 1
fi

echo "Rendering $LABEL -> $DEST_PLIST (script: $WAKE_SCRIPT)"
mkdir -p "$AGENTS_DIR"
# Render the __FIN_WAKE_SCRIPT__ placeholder to this checkout's absolute path.
# '#' delimiter avoids clashing with the slashes in the path.
sed "s#__FIN_WAKE_SCRIPT__#$WAKE_SCRIPT#" "$SRC_PLIST" > "$DEST_PLIST"

# Idempotent bootstrap: bootout an already-loaded instance so a re-run reloads
# the current plist/script. A "not loaded yet" bootout is expected to fail — hence
# the guard rather than set -e killing the script here.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	echo "Booting out the currently-loaded $LABEL"
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi

echo "Bootstrapping $LABEL into $DOMAIN"
launchctl bootstrap "$DOMAIN" "$DEST_PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed. Status:"
launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state = |program = " || true
echo
echo "Logs: transitions -> ~/Library/Logs/fin-wake.log ; launchd stdio -> /tmp/fin-wake.{out,err}"
echo
echo "To stop and uninstall:"
echo "    launchctl bootout $DOMAIN/$LABEL"
echo "    rm -f $DEST_PLIST"
echo
cat <<'EOF'
------------------------------------------------------------------------------
OPTIONAL (root, not run for you): close the cold-sleep gap.

While fin-wake runs, the Mac stays awake as long as Fin is active and sleeps when
it is idle. But once it is ASLEEP, nothing polls S3 — a request that arrives during
sleep is invisible until the Mac next wakes on its own. A scheduled wake bounds that
latency. `pmset repeat` supports ONE time per weekday set (NOT a cron-style every-N-
minutes), so this buys at best a DAILY wake window — worst-case latency ~24h for a
message that lands just after the wake. Run it yourself if you want it (edit the time):

    sudo pmset repeat wake MTWRFSU 08:00:00

Undo with:  sudo pmset repeat cancel
------------------------------------------------------------------------------
EOF

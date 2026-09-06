#!/bin/bash
# uninstall.sh — stop the resident fin-agentd site and remove its LaunchAgents.
#
#   uninstall.sh            bootout both agents, remove both plists. KEEPS the site key,
#                           config, audit log, ledger, registry and logs — a re-run of
#                           install.sh brings the same site (same SITE8) back.
#   uninstall.sh --purge    …and also remove ~/Library/Application Support/fin-agentd
#                           (key, config, site8, audit, ledger, registry), the log dir,
#                           and this site's ONE line from ~/.ssh/authorized_keys.
#                           The site identity is gone for good: a later install mints
#                           a new SITE8.
#
# Zero sudo. Never touches any authorized_keys line other than the fin-site-<SITE8>
# one; never touches Fin's Key ("fins-key"), fin-wake, or the LLM shim.
set -euo pipefail

LABEL="dev.levischoen.fin.agentd"
REFRESH_LABEL="dev.levischoen.fin.agentd.refresh"
FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
LOG_DIR="${FIN_AGENTD_LOG_DIR:-$HOME/Library/Logs/fin-agentd}"
AGENTS_DIR="$HOME/Library/LaunchAgents"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
DOMAIN="gui/$(id -u)"

PURGE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--purge) PURGE=1 ;;
		-h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

step() { printf '\n==> %s\n' "$*"; }

step "LaunchAgents"
for label in "$LABEL" "$REFRESH_LABEL"; do
	if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
		launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
		echo "booted out: $label"
	else
		echo "not loaded: $label"
	fi
	if [ -f "$AGENTS_DIR/$label.plist" ]; then
		rm -f "$AGENTS_DIR/$label.plist"
		echo "removed: $AGENTS_DIR/$label.plist"
	fi
done

if [ "$PURGE" -eq 0 ]; then
	echo
	echo "Kept: $FIN_AGENTD_HOME (key, config, site8, audit, ledger, registry) and $LOG_DIR."
	echo "Kept: the fin-site-* line in $AUTHORIZED_KEYS."
	echo "Run with --purge to remove them too."
	exit 0
fi

step "Purge"
SITE8=""
if [ -s "$FIN_AGENTD_HOME/site8" ]; then
	SITE8="$(tr -d '[:space:]' < "$FIN_AGENTD_HOME/site8")"
fi
if [ -f "$AUTHORIZED_KEYS" ]; then
	# Remove only lines whose trailing comment is this site's. With no persisted site8
	# (half-installed state) fall back to any fin-site-<8 hex> comment: those are only
	# ever written by install.sh on this Mac. Other lines pass through byte-for-byte.
	if [ -n "$SITE8" ]; then
		pattern=" fin-site-$SITE8\$"
	else
		pattern=" fin-site-[0-9a-f]{8}\$"
	fi
	before="$(grep -c . "$AUTHORIZED_KEYS" || true)"
	tmp="$AUTHORIZED_KEYS.fin-uninstall.$$"
	umask 077
	grep -Ev -- "$pattern" "$AUTHORIZED_KEYS" > "$tmp" || true
	chmod 600 "$tmp"
	mv -f "$tmp" "$AUTHORIZED_KEYS"
	after="$(grep -c . "$AUTHORIZED_KEYS" || true)"
	echo "authorized_keys: $((before - after)) fin-site line(s) removed, $after line(s) kept"
fi
if [ -d "$FIN_AGENTD_HOME" ]; then
	rm -rf "$FIN_AGENTD_HOME"
	echo "removed: $FIN_AGENTD_HOME"
fi
if [ -d "$LOG_DIR" ]; then
	rm -rf "$LOG_DIR"
	echo "removed: $LOG_DIR"
fi
echo
echo "Purged. The site identity${SITE8:+ ($SITE8)} no longer exists on this Mac."
echo "Its status object fin/sites/fin/${SITE8:-<site8>}/status.json in S3 is left for the operator."

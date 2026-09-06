#!/bin/bash
# refresh.sh — what dev.levischoen.fin.agentd.refresh runs (and what you run by hand):
# re-sign the 7-day presigned URLs in config.json, then restart the daemon so it reads
# them. The daemon loads its config once at launch, so a re-sign without a restart
# changes nothing until the next respawn.
#
# Safe when the daemon is not loaded: the config is refreshed on disk and nothing is
# started — refresh never turns a deliberately-stopped site back on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="dev.levischoen.fin.agentd"
DOMAIN="gui/$(id -u)"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "[$(stamp)] refresh: re-signing presigned URLs"
"$SCRIPT_DIR/provision-config.sh" --refresh "$@"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	echo "[$(stamp)] refresh: launchctl kickstart -k $DOMAIN/$LABEL"
	launchctl kickstart -k "$DOMAIN/$LABEL"
	echo "[$(stamp)] refresh: daemon restarted"
else
	echo "[$(stamp)] refresh: $LABEL is not loaded — config refreshed on disk, nothing restarted"
fi

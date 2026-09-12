#!/usr/bin/env bash
# Start the Mac GUI runner. RUN THIS FROM Terminal.app ON THE MAC — not over SSH.
#
# Ported from PocketDJ's apple/scripts/mac-gui-runner-start.sh. Path arithmetic is
# different here: Fin has no `apple/` subdirectory split, so this script lives at
# the repo's top-level `scripts/` directly (one level down from the repo root, not
# two).
#
# Claude connects over SSH, which lands in a launchd "Background" session with no
# window-server access, so it cannot drive macOS UI at all (screencapture fails,
# every app reports 0 windows, XCUITest times out enabling automation mode). This
# server, started from your desktop session, does that driving on Claude's behalf.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${SSH_CONNECTION:-}" ]; then
  echo "⚠️  You appear to be over SSH (SSH_CONNECTION is set)."
  echo "    macOS UI automation will NOT work from here. Start this from Terminal.app on the Mac."
  echo
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Distinct from PocketDJ's mac-gui-runner port (8791) so both can run at once.
PORT="${FIN_GUI_RUNNER_PORT:-8792}"

# Reclaim the port from a stale copy of THIS server automatically — that's the common
# case (a leftover smoke test, or a previous window). Anything else we leave alone and
# report, rather than killing a process we don't recognise.
if HOLDER_PID="$(lsof -ti:"$PORT" 2>/dev/null | head -1)" && [ -n "$HOLDER_PID" ]; then
  HOLDER_CMD="$(ps -o command= -p "$HOLDER_PID" 2>/dev/null || true)"
  if printf '%s' "$HOLDER_CMD" | grep -q "mac-gui-runner.mjs"; then
    echo "↻ Port $PORT held by a stale mac-gui-runner (pid $HOLDER_PID) — replacing it."
    kill -9 "$HOLDER_PID" 2>/dev/null || true
    sleep 1
  else
    echo "❌ Port $PORT is held by something that is NOT this server:"
    echo "   pid $HOLDER_PID: ${HOLDER_CMD:-unknown}"
    echo "   Either stop it, or pick another port:"
    echo "     FIN_GUI_RUNNER_PORT=8793 bash scripts/mac-gui-runner-start.sh"
    echo "   (if you change it, tell Claude — .mcp.json points at $PORT)"
    exit 1
  fi
fi

exec node scripts/mac-gui-runner.mjs

#!/bin/bash
# prepare-mac.sh — the one-time setup a macOS screenshot capture needs.
#
# The capture (finUITests/ScreenshotCaptureUITests/testCaptureMacStory, driven
# through scripts/mac-gui-runner.mjs) opens a LIVE loopback SSH session to this
# Mac so the terminal screenshot shows a real shell. That needs a key the app can
# use: a throwaway ed25519 pair, its public half authorized for loopback only,
# and the private half where ScreenshotFixtures looks for it — both the plain
# Application Support path (an ad-hoc-signed test build is not sandboxed) and
# the app's sandbox container (a store-signed build is).
#
# Re-runnable; nothing here touches the real key vault or the real store.
set -euo pipefail

DIR="$HOME/Library/Application Support/fin-screenshots"
CONTAINER="$HOME/Library/Containers/dev.levischoen.fin/Data/Library/Application Support/fin-screenshots"
KEY="$DIR/id_ed25519"

mkdir -p "$DIR" "$CONTAINER"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "fin-screenshots" -f "$KEY"
PUB="$(cat "$KEY.pub")"
touch "$HOME/.ssh/authorized_keys"
grep -qF "$PUB" "$HOME/.ssh/authorized_keys" \
  || printf 'restrict,pty,from="127.0.0.1,::1" %s\n' "$PUB" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
cp "$KEY" "$CONTAINER/id_ed25519"
chmod 600 "$CONTAINER/id_ed25519"

if ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes 127.0.0.1 'echo ok' >/dev/null 2>&1; then
  echo "loopback SSH with the capture key: ok"
else
  echo "loopback SSH failed — is Remote Login on for this user?" >&2
  exit 1
fi
echo "key: $KEY (mirrored into the app container)"

#!/bin/sh
# AgentBehaviorTests (finTests) drives a real SSH+tmux session inside the signed,
# sandboxed macOS test host (App Sandbox is on for fin-macOS.entitlements, with no
# home-relative file-read entitlement — same reason KeychainStoreTests skips on macOS).
# The sandboxed process can't read ~/.ssh directly, so this copies the dev machine's own
# key into the app's own sandbox container, which it can read freely. Local dev/test
# convenience only — never shipped, never touches production entitlements.
set -eu

BUNDLE_ID="dev.levischoen.fin"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/fin-agent-tests"
SOURCE_KEY="$HOME/.ssh/levi_id_ed25519"

if [ ! -f "$SOURCE_KEY" ]; then
    echo "No $SOURCE_KEY found — AgentBehaviorTests will skip itself out." >&2
    exit 0
fi

mkdir -p "$CONTAINER"
cp "$SOURCE_KEY" "$CONTAINER/id_ed25519"
chmod 600 "$CONTAINER/id_ed25519"
echo "Provisioned $CONTAINER/id_ed25519"

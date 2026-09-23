#!/bin/bash
# Publishes the release fin-agentd (arm64 macOS) to S3 for the daemon's `update`
# command (docs/SITES.md §3.5): the binary plus a sha256 sidecar the daemon
# verifies before the atomic rename. Build first, through the machine guard:
#
#     scripts/dev/one-at-a-time.sh swift build -c release --package-path daemon
#     scripts/mac-fin-agentd/publish-binary.sh
#
# Operator credentials (AWS profile), never the control plane: the Lambda only
# ever hands out presigned GETs for these two keys.
set -euo pipefail
PROFILE=${FIN_AWS_PROFILE:-levi}
BUCKET=fin-agent-directives-011183829623
KEY=fin/agentd/fin-agentd-macos-arm64
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$REPO_ROOT/daemon/.build/release/fin-agentd}"
[ -x "$BIN" ] || { echo "no release binary at $BIN — build it first" >&2; exit 1; }
VERSION="$("$BIN" --version | awk '$1 == "fin-agentd" {print $2}')"
[ -n "$VERSION" ] || { echo "$BIN does not answer --version" >&2; exit 1; }
# Signed with a STABLE identity, not ad hoc (what `swift build` leaves). macOS keys
# privacy grants (Accessibility, Screen Recording — docs/VNC.md) to a binary's
# designated requirement; for an ad-hoc binary that is its exact hash, so every
# update silently revoked them. With a real certificate the requirement is
# "this identifier, signed by this team", which survives every rebuild.
# The identity lives in the headless CI keychain the testflight scripts unlock
# (the login keychain refuses a non-GUI codesign with errSecInternalComponent).
SIGN_IDENTITY=${FIN_AGENTD_SIGN_IDENTITY:-"Apple Development: Created via API (C2G2V625FZ)"}
SIGN_KEYCHAIN=pocketdj-ci.keychain-db
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" "$SIGN_KEYCHAIN" 2>/dev/null || true
fi
codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --identifier dev.levischoen.fin.agentd "$BIN"
codesign --verify --strict "$BIN"
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf '%s  fin-agentd-macos-arm64\n' "$SHA" > "$WORK/sha256"
aws --profile "$PROFILE" s3 cp "$BIN" "s3://$BUCKET/$KEY" --no-progress --metadata "version=$VERSION,sha256=$SHA" >/dev/null
aws --profile "$PROFILE" s3 cp "$WORK/sha256" "s3://$BUCKET/$KEY.sha256" --no-progress --content-type text/plain >/dev/null
echo "published fin-agentd $VERSION -> s3://$BUCKET/$KEY (sha256 $SHA)"

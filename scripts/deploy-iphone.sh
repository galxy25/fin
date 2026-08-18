#!/bin/bash
# Build (signed), install, and launch Fin on Levi's iPhone.
# Run this from a shell in the GUI (Aqua) login session — e.g. via Claude Code's `!` prefix
# or your own Terminal — because code-signing needs Aqua-session keychain access that a
# detached/Background-session process can't reach (errSecInternalComponent).
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."   # repo root
DEV=59C072A6-6201-5A10-AA86-4EE176FDC8A8

which xcodegen >/dev/null || { echo "✗ xcodegen not found — brew install xcodegen"; exit 1; }
xcodegen generate

APP="build-device/Build/Products/Debug-iphoneos/fin.app"
# A failed build must never fall through to installing a STALE product from a
# previous run. Remove the product first and gate on the build's own exit code,
# not the product's existence.
rm -rf "$APP"

echo "▸ Building (signed) for the device…"
set +o pipefail  # grep exiting 1 on a quiet log must not mask xcodebuild's status
xcodebuild -project fin.xcodeproj -scheme fin \
  -destination "platform=iOS,id=$DEV" -derivedDataPath build-device \
  -configuration Debug -allowProvisioningUpdates build \
  | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED|CodeSign failed"
BUILD_RC=${PIPESTATUS[0]}
set -o pipefail
[ "$BUILD_RC" -eq 0 ] || { echo "✗ xcodebuild exited $BUILD_RC — not installing"; exit "$BUILD_RC"; }
[ -d "$APP" ] || { echo "✗ no app product — build failed"; exit 1; }

echo "▸ Installing onto the iPhone…"
xcrun devicectl device install app --device "$DEV" "$APP"

echo "▸ Launching…"
xcrun devicectl device process launch --device "$DEV" dev.levischoen.fin

echo "✓ DONE — Fin deployed to the iPhone"

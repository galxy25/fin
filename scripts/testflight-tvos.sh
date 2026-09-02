#!/usr/bin/env bash
#
# testflight-tvos.sh — archive Fin (tvOS) and upload the build to TestFlight.
#
# Sibling of testflight.sh (iOS), testflight-macos.sh, and testflight-visionos.sh.
# Same local-archive + ASC-API-key flow, but builds the fin-tv target (Apple TV).
#
# fin-tv is a SEPARATE target from the multiplatform `fin` target (the tvOS view/
# renderer layer differs enough — SwiftTerm's UIKit view excludes tvOS, so fin-tv
# uses a vendored headless engine + CoreText canvas), so SCHEME is "fin-tv", not "fin".
# It shares the dev.levischoen.fin bundle id for universal purchase; the app's tvOS
# platform in App Store Connect is created automatically on the first successful tvOS
# upload — the iOS app record already exists, no separate "New App" step (same as
# macOS and visionOS were).
#
# CONFIG (same as testflight.sh):
#   ASC_KEY_ID     — App Store Connect API Key ID (Admin role)
#   ASC_ISSUER_ID  — Issuer ID
#   ASC_KEY_PATH   — path to AuthKey_${ASC_KEY_ID}.p8
#                    (default: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8)
#
# USAGE:
#   scripts/testflight-tvos.sh            # build number = current unix timestamp
#   BUILD_NUMBER=42 scripts/testflight-tvos.sh
#
set -euo pipefail

# Load ASC credentials from the durable config unless already exported.
if [ -z "${ASC_KEY_ID:-}" ] && [ -f "$HOME/.config/pocketdj/asc.env" ]; then
  . "$HOME/.config/pocketdj/asc.env"
fi

# Unlock the dedicated CI signing keychain (headless codesign) — shared across
# Levi's projects, not Fin-specific (see .claude/skills/apple-publish/SKILL.md).
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" pocketdj-ci.keychain-db 2>/dev/null || true
fi

# --- resolve paths -----------------------------------------------------------
# project.yml / fin.xcodeproj live at the repo root, so just cd there.
cd "$(dirname "$0")/.."

TEAM_ID="EC27UF79GL"
SCHEME="fin-tv"
ARCHIVE="build-release/fin-tvOS.xcarchive"
EXPORT_DIR="build-release/export-tvos"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"   # monotonic; App Store Connect rejects dupes
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-UNSET}.p8}"

# --- preflight ---------------------------------------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not pointing at Xcode. Run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API Key ID)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect Issuer ID)}"
[ -f "$ASC_KEY_PATH" ] || { echo "ERROR: API key not found at $ASC_KEY_PATH" >&2; exit 1; }

echo "==> Regenerating project from project.yml"
xcodegen generate

# tvOS-specific signing note: unlike iOS (which has a registered iPhone) or macOS,
# this Apple Developer account has NO registered Apple TV device, so AUTOMATIC signing
# fails at archive — it tries to mint a tvOS *Development* profile, which requires a
# registered device ("Your team has no devices from which to generate a provisioning
# profile"). App Store *distribution* profiles need no device list, so this archive is
# signed manually with a TVOS_APP_STORE profile ("$SIGN_PROFILE") minted via the ASC
# API against the Apple Distribution cert. To recreate the profile if it's ever revoked,
# POST a TVOS_APP_STORE profile for bundle dev.levischoen.fin to the App Store Connect
# API and install it under ~/Library/MobileDevice/Provisioning Profiles/.
# Manual App Store signing lives in project.yml on the fin-tv target (SDK-scoped to
# appletvos), NOT as command-line overrides — those would apply to every target,
# including SPM packages (swift-crypto/swift-nio) that reject provisioning profiles.
SIGN_PROFILE="Fin tvOS App Store (fin-tv)"
SIGN_IDENTITY="Apple Distribution"

echo "==> Archiving $SCHEME for tvOS (build $BUILD_NUMBER), manual App Store signing"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild \
  -project fin.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=tvOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  clean archive

echo "==> Writing ExportOptions.plist (app-store-connect, upload)"
EXPORT_PLIST="$(mktemp -t FinTVExportOptions).plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>dev.levischoen.fin</key><string>$SIGN_PROFILE</string>
  </dict>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting + uploading to TestFlight (tvOS)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates

echo "==> Done. tvOS build $BUILD_NUMBER uploaded; it'll appear under the app's tvOS"
echo "    platform in TestFlight after Apple finishes processing (~5-15 min)."

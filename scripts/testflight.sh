#!/usr/bin/env bash
#
# testflight.sh — archive Fin (iOS) and upload the build to TestFlight.
#
# This is the LOCAL-ARCHIVE path (no Xcode Cloud): build on this Mac, then push the
# .ipa straight to App Store Connect via the App Store Connect API key. Avoids the
# "Grant Access to Your Source Code" dialog entirely — nothing here clones the remote
# repo over the network beyond the normal SPM package resolve.
#
# ONE-TIME SETUP (browser, see docs):
#   1. App Store Connect → Apps → New App, bundle id dev.levischoen.fin.
#      (App ID dev.levischoen.fin is already registered on the Apple Developer side —
#      this step is only the App Store Connect *app record*, which is separate.)
#   2. App Store Connect → Users and Access → Integrations → App Store Connect API:
#      create a key (Admin role — App Manager fails cloud signing below), download
#      AuthKey_XXXXX.p8 ONCE, note Key ID + Issuer ID.
#
# This project reuses PocketDJ's team-level ASC key and CI keychain (same Apple
# Developer team, EC27UF79GL) rather than minting Fin-specific ones — see CONFIG below.
#
# CONFIG — set these once (e.g. in ~/.config/fish/config.fish or export before running):
#   ASC_KEY_ID     — the App Store Connect API Key ID
#   ASC_ISSUER_ID  — the Issuer ID (same page as the key)
#   ASC_KEY_PATH   — path to the downloaded AuthKey_XXXXX.p8
#                    (default: ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8)
#
# USAGE:
#   scripts/testflight.sh            # build number = current unix timestamp
#   BUILD_NUMBER=42 scripts/testflight.sh
#
set -euo pipefail

# Load ASC credentials from the durable config unless already exported.
# ~/.config/pocketdj/asc.env holds ASC_KEY_ID (Admin role) + ASC_ISSUER_ID. This is a
# team-level key (not app-scoped), so PocketDJ's config is reused as-is here — no
# fin-specific asc.env.
if [ -z "${ASC_KEY_ID:-}" ] && [ -f "$HOME/.config/pocketdj/asc.env" ]; then
  . "$HOME/.config/pocketdj/asc.env"
fi

# Unlock the dedicated CI signing keychain (headless codesign). The login
# keychain's keys are ACL'd to require GUI prompts, which fails with
# errSecInternalComponent in headless sessions; pocketdj-ci holds an
# "Apple Development: Created via API" identity for team EC27UF79GL with a
# non-interactive ACL. The cert is team-scoped, not app-scoped, so this same
# PocketDJ-named keychain works for Fin's archive step too — intentionally shared
# across Levi's projects, not Fin-specific (hence the name).
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" pocketdj-ci.keychain-db 2>/dev/null || true
fi

# --- resolve paths -----------------------------------------------------------
# project.yml / fin.xcodeproj live at the repo root (unlike PocketDJ's apple/
# subdirectory), so just cd to the repo root — matching deploy-iphone.sh.
cd "$(dirname "$0")/.."

TEAM_ID="EC27UF79GL"
SCHEME="fin"
ARCHIVE="build-release/fin.xcarchive"
EXPORT_DIR="build-release/export"
BUILD_NUMBER="${BUILD_NUMBER:-}"              # empty ⇒ auto-incremented below
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

# --- auto-increment build number --------------------------------------------
# Ask App Store Connect for the highest build number on the app record (across all
# platforms) and use max+1, so re-uploads are always monotonic without hand-bumping.
# Falls back to a unix timestamp if the API is unreachable. Pass BUILD_NUMBER=N to
# override. CFBundleVersion resolves this via $(CURRENT_PROJECT_VERSION) — see project.yml.
if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER="$(python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" <<'PY'
import sys, time, json, urllib.request
try:
    import jwt
    kid, iss, keypath = sys.argv[1], sys.argv[2], sys.argv[3]
    tok = jwt.encode(
        {"iss": iss, "iat": int(time.time()), "exp": int(time.time()) + 300,
         "aud": "appstoreconnect-v1"},
        open(keypath).read(), algorithm="ES256", headers={"kid": kid})
    def get(p):
        r = urllib.request.Request("https://api.appstoreconnect.apple.com" + p,
                                   headers={"Authorization": "Bearer " + tok})
        return json.load(urllib.request.urlopen(r))
    apps = get("/v1/apps?filter[bundleId]=dev.levischoen.fin&fields[apps]=bundleId")
    app_id = apps["data"][0]["id"]
    builds = get(f"/v1/builds?filter[app]={app_id}&limit=200&fields[builds]=version")
    nums = [int(b["attributes"]["version"]) for b in builds["data"]
            if b["attributes"]["version"].isdigit()]
    print(max(nums) + 1 if nums else int(time.time()))
except Exception:
    print(int(time.time()))
PY
)"
fi
echo "==> Build number: $BUILD_NUMBER"

echo "==> Regenerating project from project.yml"
xcodegen generate

echo "==> Archiving $SCHEME for iOS (build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# Pass the App Store Connect API key to the ARCHIVE step too (not just export): with it,
# `-allowProvisioningUpdates` does CLOUD signing — minting the Apple Distribution cert + App
# Store profile via the key — so no Apple ID needs to be signed into Xcode (headless/CI). The
# key MUST be Admin role (App Manager fails: "No profiles for dev.levischoen.fin"). Without
# this, archive looks for an Xcode account and dies with "missing Xcode-Username".
xcodebuild \
  -project fin.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates \
  clean archive

echo "==> Writing ExportOptions.plist (app-store-connect, upload)"
EXPORT_PLIST="$(mktemp -t FinExportOptions).plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting + uploading to TestFlight"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -allowProvisioningUpdates

echo "==> Done. Build $BUILD_NUMBER uploaded; it'll appear in TestFlight after Apple finishes processing (~5-15 min)."

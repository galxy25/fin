#!/bin/bash
# Run the Fin test suite on macOS.
#
# Ported from PocketDJ's apple/scripts/test-macos.sh (same mechanism, proven there).
#
# macOS Gatekeeper blocks unsigned apps + XCUITest runners ("damaged"), and a plain
# `xcodebuild test -destination platform=macOS` with this project's Automatic signing
# fails headlessly on this Mac: the iMac's hardware UDID was never registered in the
# Developer Portal for dev.levischoen.fin, so there's no Mac Development profile
# ("Device isn't registered in your developer account" / "No profiles for
# 'dev.levischoen.fin' were found"). Separately, Fin's macOS entitlements carry the
# Push capability (com.apple.developer.aps-environment in fin-macOS.entitlements) —
# even a freshly-minted Mac Development profile wouldn't grant that. So we split
# build from run and ad-hoc sign the products in between:
#   build-for-testing  →  codesign --sign -  →  test-without-building
#
# Ad-hoc signing (--sign -) is the RIGHT path here, not a stopgap: it needs no
# provisioning profile and no device registration.
#
# First-run note: if a UI run dies with "Timed out while enabling automation
# mode", that's most likely a one-time macOS Automation/Accessibility (TCC)
# permission for the test runner — grant it once and re-run; it is NOT a signing
# problem. See .claude/skills/apple-test/SKILL.md for the full list of causes.
#
# Usage:
#   bash scripts/test-macos.sh                       # full suite, default derived dir
#   bash scripts/test-macos.sh build-mactest         # full suite, explicit derived dir
#   bash scripts/test-macos.sh -only-testing:…       # scoped run, default derived dir
#   bash scripts/test-macos.sh build-mactest -only-testing:finUITests/AgentHubWindowUITests
#
# The first arg is taken as the derivedDataPath ONLY when it doesn't start with
# "-"; any remaining args (e.g. -only-testing:…, -resultBundlePath …) pass
# straight through to `test-without-building`, so scoped macOS UI runs work
# without hand-running the build-for-testing / codesign / test dance.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DERIVED="build-mactest"
if [[ $# -gt 0 && "$1" != -* ]]; then
  DERIVED="$1"; shift
fi
PASSTHROUGH=("$@")   # forwarded verbatim to test-without-building (e.g. -only-testing:…)

echo "▶ build-for-testing (macOS, unsigned)…"
# Override the project's automatic signing → build unsigned, then ad-hoc sign
# below. (See the header: `-allowProvisioningUpdates` can't replace this on a Mac
# whose UDID isn't registered + has no dev.levischoen.fin Mac Development profile.)
# -skipPackagePluginValidation: SwiftTerm ships a build-tool plugin that headless
# xcodebuild refuses to run until it has been trusted in Xcode's GUI — per package
# checkout path, so every fresh worktree / derived dir fails at "Validate plug-in
# SwiftTermBuildInfoPlugin" without it.
xcodebuild build-for-testing -project fin.xcodeproj -scheme fin \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO >/dev/null

PRODUCTS="$DERIVED/Build/Products/Debug"

# STABLE-identity signing when the CI keychain is available (TCC permanence): an
# ad-hoc signature changes on every rebuild, so macOS treats each build as a NEW
# app and re-prompts privacy grants (e.g. a permission Allow loop). The shared
# pocketdj-ci keychain's Apple Development cert (see .claude/skills/apple-publish/
# SKILL.md — this keychain is intentionally reused team-wide, not PocketDJ-only)
# gives every build the SAME identity, so one Allow sticks forever. Falls back to
# ad-hoc when the keychain/cert is absent.
IDENTITY="-"
if [ -f "$HOME/.config/pocketdj/ci-keychain-pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/pocketdj/ci-keychain-pass")" pocketdj-ci.keychain-db 2>/dev/null || true
  FOUND=$(security find-identity -v -p codesigning pocketdj-ci.keychain-db 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')
  if [ -n "$FOUND" ]; then IDENTITY="$FOUND"; fi
fi
echo "▶ signing test products in $PRODUCTS (identity: $IDENTITY)…"
find "$PRODUCTS" -maxdepth 1 \( -name "*.app" -o -name "*.xctest" \) -print0 \
  | while IFS= read -r -d '' bundle; do
      xattr -dr com.apple.quarantine "$bundle" 2>/dev/null || true
      codesign --force --deep --sign "$IDENTITY" "$bundle" >/dev/null 2>&1 \
        || codesign --force --deep --sign - "$bundle" >/dev/null 2>&1
      echo "  signed $(basename "$bundle")"
    done

# Kill any stray running fin instance — a second instance of the same bundle id
# steals focus from the XCUITest-launched app, so keyboard commands + taps never
# reach the window under test. (Also: keep hands off the keyboard during the run.)
echo "▶ closing any running macOS fin…"
osascript -e 'tell application "fin" to quit' 2>/dev/null || true
# Kill ONLY the macOS app. A bare `killall fin` would also match anything else on
# this Mac named "fin" (and, by the same class of hazard PocketDJ documented for
# its iOS Simulator, could hit an unrelated process sharing that short name), so
# match on the full macOS bundle path instead — simulator-hosted or other builds
# live under a different path and never match.
# Anchored on argv[0] (leading `^/`), NOT on the end of the argv string: a trailing
# `$` would also match any command whose LAST ARGUMENT is that path (e.g.
# `codesign …/MacOS/fin`, `tail -f …/MacOS/fin`) — the same class of collateral
# kill, just rarer.
pkill -f '^/.*/fin\.app/Contents/MacOS/fin' 2>/dev/null || true
sleep 1

echo "▶ test-without-building (macOS)…"
# `${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}` expands to nothing when the array is
# empty — safe under `set -u` on bash 3.2 (macOS), where a bare "${arr[@]}"
# would otherwise trip "unbound variable".
xcodebuild test-without-building -project fin.xcodeproj -scheme fin \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

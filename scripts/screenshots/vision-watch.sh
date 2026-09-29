#!/bin/bash
# vision-watch.sh <sim-udid> <out-dir> — the host half of the visionOS capture.
#
# XCTest screenshots are 1x1 on visionOS, so ScreenshotCaptureUITests.shoot() drops
# <name>.ready in ~/Library/Application Support/fin-screenshots/vision-ready and waits for
# <name>.done. This loop takes the picture with `simctl io` and writes .done. Run it before
# the tests; Ctrl-C (or kill) when they finish.
set -eu
SIM=$1; OUT=$2
DIR="$HOME/Library/Application Support/fin-screenshots/vision-ready"
mkdir -p "$OUT" "$DIR"
while true; do
  for ready in "$DIR"/*.ready; do
    [ -e "$ready" ] || continue
    name="$(basename "$ready" .ready)"
    sleep 2   # let the frame settle after the marker
    xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1
    rm -f "$ready"
    touch "$DIR/$name.done"
    echo "shot $name"
  done
  sleep 1
done

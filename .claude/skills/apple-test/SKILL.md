---
name: apple-test
description: Run the native Fin app's unit + UI tests on iPhone, iPad, and Mac. Use when asked to "test the apple app", "run the swift tests", "run xcuitests", "verify the native app", or to confirm a native feature works across devices. Covers xcodebuild test on simulators + macOS, the launch-arg seams, the ad-hoc macOS signing workaround, and the test layout.
---

# Test the native Fin app (Apple platforms)

Two layers, both at the repo root (no `apple/` subdirectory split — `project.yml`
and `fin.xcodeproj` live at the repo root itself):

1. **Unit tests** (`finTests/`) — pure logic, no UI: agent behavior, directive
   channel, memory sync, keychain, feedback gating, terminal session send, and
   more (multiplatform: iOS, macOS, visionOS — SwiftUI's macOS backend is a
   different implementation, so a view that lays out cleanly on iOS can still
   trap on Mac).
2. **XCUITests** (`finUITests/`) — drive the real, running app through its own
   synchronized accessibility protocol (`waitForExistence`, hittable checks)
   rather than generic AppleScript/System Events GUI scripting. macOS-only for
   now (`platform: macOS` in `project.yml`'s `finUITests` target).

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate              # if project.yml or the file list changed
```

## Test seams (launch environment)

Fin doesn't have PocketDJ's `PDJ_USE_FIXTURE`/`PDJ_START_SECTION`-style launch-arg
seams — no UI test today deep-links past navigation via an env var. The one
comparable seam Fin does have is **`FIN_AUTO_SESSION`**: a `project.yml` build
setting (default empty/dormant) that XcodeGen stamps into the Debug build's
Info.plist as `FinAutoSession`. `fin/Views/RootView.swift` reads it
(`Bundle.main.object(forInfoDictionaryKey: "FinAutoSession") as? String == "1"`)
and, when set, auto-connects the most-recently-used (or sole) server at launch —
bypassing the paywall — so a freshly installed Debug build reaches the live
terminal/agent UI with zero taps. It's `#if DEBUG`-gated in code (not just an
empty default), so it can never activate in a Release/TestFlight build even if a
build setting override leaked through. Useful for a UI test that wants to start
already-connected rather than navigating there itself; no test currently relies
on it.

UI tests query controls via `app.el("id")` / `app.any("id")` (`finUITests/
XCUIHelpers.swift`, ported from PocketDJ's) — the same identifier-lookup pattern
that resolves consistently across accessibility-tree shapes.

## iPhone / iPad (simulators — no signing)

```bash
# boot the target once
xcrun simctl boot 'iPhone 17'

# full suite (unit + UI, per the "fin" scheme's test targets) on a device, signing off
xcodebuild test -project fin.xcodeproj -scheme fin \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build-ios-test CODE_SIGNING_ALLOWED=NO
```

Run a single test: append `-only-testing:finTests` (unit) or
`-only-testing:finUITests/AgentHubWindowUITests/testHubWindowSurvivesSidebarSelectionChange`.

**Never run two `xcodebuild` invocations against the same `-derivedDataPath`
concurrently** — the second clobbers `TEST_HOST` and fails. Give each its own dir.

## macOS

> ### ⚠️ macOS **UI** tests cannot be run from an SSH/agent session — use the GUI runner
>
> Claude usually reaches this Mac over SSH, which lands in a launchd **Background**
> session (`launchctl managername` → `Background`) with **no window server**. In that
> context every macOS UI test fails for environmental reasons that look exactly like
> product bugs:
> `screencapture -x` → *"could not create image from display"*, every app reports
> **0 windows** to System Events, and XCUITest dies at *"Timed out while enabling
> automation mode"*. `ioreg`'s `CGSSessionScreenIsLocked` even reads **true** while the
> user is sitting at an unlocked desk — it describes a session the SSH process can't see.
> `launchctl asuser` would bridge it but needs root, and `sudo` wants a password.
>
> **Before believing ANY macOS UI failure, run the one-line check:**
> ```bash
> screencapture -x /tmp/x.png && echo "display OK" || echo "NO display — results are meaningless"
> ```
>
> **The fix — `scripts/mac-gui-runner.mjs`.** A human starts it *from Terminal.app on the
> Mac*, so it inherits the GUI session; the agent then drives it over loopback HTTP:
> ```bash
> bash scripts/mac-gui-runner-start.sh      # on the Mac, leave the window open
> ```
> It self-checks at startup (captures a real screenshot) and refuses to pretend: if it
> reports `gui: false` it was started in the wrong session. Two interfaces on
> `127.0.0.1:8792` (deliberately a different port from PocketDJ's identical runner at
> 8791, so both can run on this Mac at once) — **MCP** at `/mcp` (registered in
> `.mcp.json`, so Claude Code picks up `mac_health` / `mac_run_tests` /
> `mac_job_status` / `mac_screenshot` as tools) and plain REST (`GET /health`,
> `POST /run`, `GET /jobs/:id`). Logs land in `build-gui-runner-logs/` on the shared
> filesystem (matching the repo's existing `/build-*/` gitignore pattern, so it needs
> no ignore rule of its own), so the agent can read the full xcodebuild output
> directly. Always call `mac_health` first.
>
> **What still works fine over SSH:** everything non-UI — macOS *unit* tests, all
> compiles/archives, and every iOS-Simulator test (the simulator has its own window
> server; `xcrun simctl io … screenshot` needs no Screen Recording permission).

Gatekeeper kills the unsigned XCUITest runner ("damaged"), so the runner **must be
signed** — but a plain `xcodebuild test` also hangs (`The test runner hung before
establishing connection`). Use the ad-hoc helper, which **ad-hoc signs** the app +
runner (build unsigned → `codesign --sign -` → `test-without-building`):

```bash
bash scripts/test-macos.sh                 # full unit + UI suite on My Mac
# scope it (forwarded to test-without-building):
bash scripts/test-macos.sh build-mactest \
  -only-testing:finUITests/AgentHubWindowUITests -only-testing:finTests
```

Ad-hoc (`codesign --sign -`) is the right signing here, not a fallback: it needs **no
provisioning profile and no device registration**. The "real cert" route
(`-allowProvisioningUpdates`) does **not** work headlessly on this Mac — even with the
Apple Development key CLI-accessible it fails with *"Device 'Levi's iMac' isn't
registered in your developer account"* / *"No profiles for 'dev.levischoen.fin' were
found"*. Fixing that means registering the iMac's UDID in the Developer portal and
minting a Mac App Development profile — a portal action that buys nothing over ad-hoc
for local testing. So: **sign ad-hoc; don't chase a provisioning profile.**

This split is load-bearing for a second reason too, beyond the headless/SSH
convenience: Fin's macOS entitlements (`fin/fin-macOS.entitlements`) carry the Push
capability (`com.apple.developer.aps-environment`, for CloudKit's silent-sync
pushes) — the same category of capability PocketDJ found a Mac Development profile
simply won't grant. So even a from-scratch "real" provisioning fix wouldn't sidestep
this; ad-hoc is the actual right answer, not a workaround pending a portal fix.

`finUITests`' `project.yml` settings carry **no signing override at all** (same
shape as `finTests`' testing-relevant settings) — it just inherits the top-level
`CODE_SIGN_STYLE: Automatic` / `DEVELOPMENT_TEAM: EC27UF79GL`. That's fine for
interactive Xcode runs; the ad-hoc override for headless runs happens purely at the
`xcodebuild`-invocation level inside `test-macos.sh` (`CODE_SIGNING_ALLOWED=NO` on
`build-for-testing`, then `codesign`, then `test-without-building`) — never inside
`project.yml` itself.

**`Timed out while enabling automation mode` has FOUR distinct causes.** Work through
them in this order — each produces near-identical noise, and misreading one for another
has already cost real time on this Mac's sibling project (PocketDJ):

1. **Wrong session** (most common for agents) — you're on SSH with no window server.
   Check `screencapture -x /tmp/x.png`; if it errors, use the GUI runner above. No
   signing, TCC, or retry change will help.
2. **Stale `AutomationModeUI`** holding the automation session:
   `ps aux | grep '[A]utomationModeUI'` → `kill -9 <pid>` (it relaunches on demand).
   Killing `testmanagerd` does *not* fix this.
3. **Machine starvation** — a booted simulator can spawn a runaway `mediaanalysisd` at
   250-500% CPU. Check `uptime`; a load average over ~20 means stop and investigate.
   `launchctl disable` won't hold it; `xcrun simctl shutdown <udid>` does.
4. **First-run TCC** — genuinely the Automation/Accessibility permission for the runner.
   Grant it once (and quit any stale `fin` the script's `pkill` missed); it
   clears permanently.

**Never run a macOS UI suite concurrently with an iOS-Simulator UI suite** — they fight
over window focus and the loser fails with *"Failed to activate application"*. Unit
suites are safe to parallelize. Serialize display-driving runs through
`scratchpad/uitest.sh`-style locking (the GUI runner already does this internally via
a `flock` on `/tmp/fin-uitest.lock` for every job it starts).

## Proof / debugging

- Simulator screenshots: `xcrun simctl io <UDID> screenshot out.png` (no Screen
  Recording permission needed — unlike `screencapture`).
- A green run prints `** TEST SUCCEEDED **` and `Executed N tests, with 0 failures`.

## Related

- **apple-build** skill — generating + building + signing.
- **apple-publish** skill — the shared `pocketdj-ci` keychain this repo already
  reuses team-wide for TestFlight archiving (same team, `EC27UF79GL`).

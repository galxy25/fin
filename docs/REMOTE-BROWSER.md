# Remote Browser — sign in to the browser Claude is driving

Levi (2026-09-23): *"I want to be able to sign myself into browsers that Claude opens on
my work laptop with Playwright, such as GitHub and Gmail."* Claude can drive a browser;
it can't type Levi's password or approve his 2FA. Remote Browser puts that one browser —
live — in the Fin app, so he does the human part from wherever he is and hands it back.

Built as its own feature, **ahead of** full-desktop VNC (docs/VNC.md), because it serves
the actual need with a fraction of the risk and none of the blockers.

## Why not VNC for this

| | Full-desktop VNC | Remote Browser |
|---|---|---|
| What's exposed | The whole logged-in desktop | One browser |
| macOS permissions | Screen Recording + Accessibility (TCC) | **None** |
| Blocked by the work laptop's MDM | Screen Sharing: yes | **Nothing to block** |
| Protocol code in Fin | An RFB server | Chrome's own DevTools Protocol |
| iPhone / iPad | Needs a VNC client library | **Just frames and taps** — every platform |

## How it works

```
Fin app  ──(relay: output/input frames)──  fin-agentd  ──CDP (loopback)──  Chrome :9222
                                                                              │
                                     Claude's Playwright MCP ──CDP (loopback)─┘
```

- **One shared Chrome.** fin-agentd launches real Google Chrome (not Playwright's
  bundled Chromium, and without automation flags — Google refuses sign-in in a browser
  it sees as automated) with `--remote-debugging-port=9222` and a dedicated persistent
  profile (`~/Library/Application Support/fin-agentd/browser-profile`). A sign-in
  survives across sessions and restarts. If a Chrome is already listening on the port,
  the daemon attaches to it instead. No Chrome installed (the work laptop, 2026-09-23)?
  It falls back to Playwright's cached browser, newest first — launched without
  automation flags, so it's an ordinary browser to sign in to
  (`RemoteBrowserProtocol.browserCandidates`).
- **Claude attaches to the same browser.** On the site, Claude Code's Playwright MCP is
  pointed at that Chrome instead of launching its own — see *Setup* below. Whatever tab
  Claude is working in is the tab Levi sees.
- **Frames out, input in.** CDP `Page.startScreencast` gives JPEG frames; fin-agentd
  forwards them as relay `output` frames. Taps, scrolls, typed text and special keys
  come back as relay `input` frames and become `Input.dispatchMouseEvent` /
  `Input.insertText` / `Input.dispatchKeyEvent`. The wire format is
  `RemoteBrowserProtocol` in FinAgentCore, compiled by both the app and the daemon.
- **The relay is unchanged.** relay.py routes only on `action` and forwards whole frames
  verbatim; browser frames are just `output`/`input` with a `kind` it never reads. No
  relay redeploy. Frames are capped at 200 KiB base64 — over the relay's 256 KiB ceiling
  a frame would close the whole session, so the daemon drops it instead (the next frame
  is a complete picture).
- **Tabs.** The app shows the tab most recently active (Chrome lists `/json/list`
  most-recent first — the one Claude just used) and offers a tab menu; if the shown tab
  closes, it follows to the next.

## Security

- **Opt-in per site, off by default** (`remoteBrowser.enabled` in the daemon config),
  and enforced locally: the daemon refuses `browser-open` when not enabled, whatever the
  control plane or a stale capability cache says.
- **Face ID / Touch ID / Optic ID (or passcode) on every open**, in the app. The browser
  carries signed-in sessions; the relay `sessionId` alone shouldn't be the whole wall.
  A prompt approved on the Mac itself was rejected: it can't be answered when Levi is
  away from the Mac, which is exactly when this is used.
- **Loopback only.** Chrome's DevTools port is reachable from the Mac itself, never the
  network; the relay's pinned TLS carries everything off the machine.
- **Typed text is a `SecureField`.** Usually a password; it's never shown in the clear
  and is sent whole, never keystroke-by-keystroke.

## Setup on a site

1. Daemon config (`~/Library/Application Support/fin-agentd/config.json`):
   ```json
   "remoteBrowser": { "enabled": true }
   ```
   Optional: `port` (default 9222), `chromePath`, `profileDirectory`.
2. Point Claude Code's Playwright at the shared browser (`~/.claude.json` on that Mac):
   ```json
   "playwright": { "command": "npx", "args": ["@playwright/mcp@latest", "--cdp-endpoint", "http://127.0.0.1:9222"] }
   ```
3. Restart the daemon. The site's row under *Fin's Computers* shows a globe.

## Where it opens

A **window** on Mac and Vision Pro, beside the terminal (`FinScene.remoteBrowser`,
keyed by siteId). A **tab** on iPhone and iPad (`SessionManager.BrowserTab`), in the
same tab bar as the terminals; the session lives in SessionManager, so switching to a
terminal and back keeps the live page with no second Face ID. iPad could get windows
later: that needs `UIApplicationSupportsMultipleScenes`, which also lets the MAIN
window be opened twice, so it was left out of the first rollout.

## The carousel toolbar

A horizontally scrollable key bar (Levi, 2026-09-23: "we want it everywhere," unlike
the terminal's `KeyboardAccessoryRow`, which is UIKit-only and exists on iOS/iPadOS —
this one is plain SwiftUI, so macOS and Vision Pro get it for free): Ctrl/Opt/Cmd/Shift
as sticky latches (tap to arm, consumed by the next key and then cleared — the same
gesture as the terminal's Ctrl latch), backspace/tab/enter/escape/forward-delete,
arrows, and Home/End/PgUp/PgDn. `RemoteBrowserProtocol.Modifier` rides on `.key` and
reaches both backends: a CDP modifier bitmask in the browser, `CGEventFlags` on the
desktop.

Desktop mode also gets system-shortcut buttons (Levi, 2026-09-23, from a screenshot of
macOS's own Spaces/Mission Control menu — Mission Control, Application Windows, Show
Desktop, Move Left/Right a Space, Screenshot — plus Spotlight): each is an ordinary
chord over the same primitives (`.key(_, modifiers:)`), sent directly rather than
through the armed-modifier latch since these are one-tap, not two-step.

| Button | Chord |
|---|---|
| Mission Control | Ctrl+↑ |
| Space ← / Space → | Ctrl+← / Ctrl+→ (unverified against a real chord — depends on the target's own Keyboard Shortcuts settings, not provable from here) |
| App Windows | Ctrl+↓ |
| Desktop (Show Desktop) | F11, no modifier |
| Screenshot | Cmd+Shift+5 |
| Spotlight | Cmd+Space |

## Choose displays (Remote Desktop only)

A second display connected to the site shows up as a **Displays** menu in the
toolbar (mirroring the browser's Tabs menu) once there is more than one. Switching
sends `.selectDisplay(id)`, consumed by `DesktopRelayClient` before it ever reaches
CGEvent playback — the same shape as the browser's `selectTab`. Labels are
resolution-based ("Display 2 — secondary (1920x1080)"); there is no AppKit
dependency in the daemon for a friendlier name. An unplugged targeted display falls
back to the main display on the next capture, automatically.

## Telemetry

Levi, 2026-09-23: "thorough telemetry... to monitor and replay usage for both
debugging and evaling." What's captured is a session's SHAPE, never its content — no
page text, no typed characters, no frame pixels reach any logging system, because a
password typed here must never be more durable than the browser it was typed into.

- **App → control plane** (`ControlPlaneClient.logClientEvent`, CloudWatch-backed,
  the channel `TerminalSession` already used): `remote_screen_gate_failed` (Face ID
  reason), `remote_screen_opened` (first real frame), `remote_screen_closed`
  (duration, frame count, input counts BY TYPE, close reason) — plus the existing
  `relay_ws_open`/`relay_ws_open_failed`/`relay_ws_receive_failed`, now also emitted
  by `RemoteBrowserSession`. `aws logs tail /aws/lambda/fin-control-plane | grep
  client-event`.
- **Daemon → its own audit trail** (`BrowserRelayClient`/`DesktopRelayClient`, the
  same `record(AgentAuditEvent...)` path every other daemon breadcrumb uses, so it's
  durable and shows up in the site's own Logs/Traces): one structured line per
  session close — duration, frames sent, dropped frames, tab switches, input counts
  by type.
- **Not built (scope call, noted for later):** a queryable per-session store for true
  frame-by-frame replay. What exists today reconstructs a session's timeline (when,
  how long, how much, why it ended) from two independent trails that already existed
  for the terminal; it does not let anyone scrub through what was actually shown.

## Delivery

1. **Done:** protocol + tests, daemon client, `browser-open` command, `remote_browser`
   capability, app session + view + entry point.
2. **Live proof on the work laptop:** enable, attach Playwright, sign in to GitHub.
3. **Then VNC** (docs/VNC.md) for the whole desktop — a separate feature with its own
   auth decision.

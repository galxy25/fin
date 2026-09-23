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

## Delivery

1. **Done:** protocol + tests, daemon client, `browser-open` command, `remote_browser`
   capability, app session + view + entry point.
2. **Live proof on the work laptop:** enable, attach Playwright, sign in to GitHub.
3. **Then VNC** (docs/VNC.md) for the whole desktop — a separate feature with its own
   auth decision.

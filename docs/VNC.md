# VNC (GUI remote-control) support for Fin — recommended architecture

> **STATUS 2026-09-23 (later): Phase 1 BUILT — as "Remote Desktop", not RFB.**
> fin-agentd 1.12.0 `DesktopRelayClient` captures the main display with
> ScreenCaptureKit (`SCScreenshotManager`, ~4 fps, points not pixels, capped 1600 wide,
> unchanged frames skipped, JPEG quality stepped down to fit the relay's frame budget)
> and plays input back as CGEvents (`RemoteDesktopProtocol.events`, tested). It speaks
> Remote Browser's wire protocol (docs/REMOTE-BROWSER.md) unchanged, so the app reuses
> `RemoteBrowserSession`/`RemoteBrowserView` in `.desktop` mode — a window on Mac and
> Vision Pro, a tab on iPhone/iPad — with no VNC client and no relay or Lambda change
> (`vnc-open` has been relay-backed since Phase 0).
>
> - **Opt-in:** `"vncProxyEnabled": true` in the site's config.json (name kept from
>   Phase 0). Capability `vnc_proxy` = opted in AND Screen Recording granted.
> - **Grants:** Screen Recording (view) + Accessibility (input), reported per
>   heartbeat as `gui_permissions`; without Accessibility the app shows a view-only
>   banner. Grants survive updates because the binary is now signed with a stable
>   identity (publish-binary.sh, fin-agentd 1.11.6).
> - **Auth (§4's blocking question):** the same answer as Remote Browser — Face ID /
>   Touch ID / Optic ID (or passcode) in the app on every open, plus the per-site
>   opt-in enforced locally by the daemon.
> - **Not yet:** multiple displays (main only), right-click / drag, clipboard.
>   Modifier keys (Ctrl/Opt/Cmd/Shift) shipped 2026-09-23 as sticky carousel latches
>   (see docs/REMOTE-BROWSER.md's "Where it opens" section, which now also covers the
>   carousel toolbar and telemetry, shared with Remote Browser).
>
> **Root-caused live, 2026-09-23 (Levi):** a Remote Browser session that streamed once
> then went stale/stuck — Chrome throttles a tab's CDP screencast when its OS window
> isn't frontmost. Fixed with `Page.bringToFront` on every tab attach and every 3s tab
> refresh (`BrowserRelayClient`) — a CDP command built for exactly this, which also
> resolves the multi-window edge case since it targets the specific tab, not "the"
> Chrome window.

> **STATUS 2026-09-23: Phase 0 shipped. Phase 1 as written below is dead, but the
> feature is NOT — a different Phase 1 is viable. Read this before building.**
>
> **Update, 2026-09-23.** The follow-up question — is TCC blocked the same way the
> Screen Sharing service is? — is answered: **no. Screen Recording is available on
> the work laptop.** The two gates are different (a service toggle is admin/MDM
> territory; TCC is per-app and usually user-grantable), so the userspace path is
> open where the proxy path is shut. What that costs, plainly:
>
> - The design below is cheap *because it writes no RFB code*. A userspace server
>   means implementing the RFB **server** side — handshake, security type,
>   framebuffer updates, an encoding — plus ScreenCaptureKit capture and (for
>   anything beyond view-only) CGEvent input injection behind a **second, separate**
>   TCC permission, Accessibility.
> - **It deletes the free second factor.** §4 leans on Apple's own Screen Sharing
>   login as the wall an attacker holding only a stolen relay `sessionId` still hits.
>   A userspace server has no such wall. The auth question §4 defers to Phase 3 is
>   therefore **blocking for a userspace Phase 1**, not deferred — a full-desktop
>   takeover behind nothing but a relay capability is not a posture this design ever
>   argued for.
> - View-only (Screen Recording alone) and controllable (Screen Recording +
>   Accessibility) are a natural phase boundary, and the capability should degrade
>   per-permission rather than all-or-nothing, matching the nil-is-unsupported rule
>   every other capability here already follows.
>
> Phase 0 (capability plumbing, no data path) is implemented and merged: the
> `vncProxyEnabled` daemon config field, the loopback probe (now `LoopbackPortProbe`, shared with Remote Browser), the
> `vnc_proxy` capability at both `Daemon.siteCapabilities` call sites, `vnc-open`
> in `SITE_COMMAND_KINDS`/`RELAY_BACKED_COMMAND_KINDS`, and
> `FinSite.Capabilities.vncProxy` on the app side.
>
> Phase 0's own instruction was to resolve the work-laptop MDM question **before**
> Phase 1 was built. That question is now answered, and the answer kills the design:
> **Fin on the work laptop reports `VNC_CLOSED` (nothing listening on 5900), and
> Levi confirms MDM blocks Screen Sharing there, the same way it blocks sshd.**
>
> Phase 1 below is built entirely on "blind-proxy to macOS's own Screen Sharing,"
> which is what bought the free second factor in §4 and what made the phase cheap
> at all. On the one machine that motivated this whole feature, that server cannot
> be turned on. Phase 1 as written would deliver zero value for the actual use case.
>
> **The rethink starts from a different question than the one this document
> answered** — not "how do we tunnel to Apple's server" but "what do we serve, and
> what stands in front of it." The TCC-blocked-too worry that was flagged here on
> 09-22 has been checked and did not materialize (see the 09-23 update above); what
> remains is the auth question, which is now the real blocker rather than the
> permissions one.
>
> Everything below this line is the original, unamended proposal. It remains a
> correct and useful design **for a Mac whose owner controls it** (Levi's iMac, a
> personal machine) — it is only the work-laptop use case that it cannot serve.

*Design proposal. Grounds itself in the existing terminal-relay stack: `scripts/cloud-agent/relay/relay.py`, `daemon/Sources/fin-agentd/TerminalRelayClient.swift`, `fin/Session/RelayWebSocket.swift`/`RelayCertificatePin.swift`, `fin/Agent/SiteDirectory.swift`, `scripts/cloud-agent/control-plane/lambda.py`. File:line references below carry over from the research that preceded this document, not re-derived.*

## 1. Principle

Fin already solved "reach a box that can't be dialed directly" once, for terminals. The relay (`relay.py`) is a dumb, protocol-agnostic pairing switch — it inspects only a frame's `action` field to route it and blind-forwards `data`; it has never known it was carrying PTY bytes. VNC does not need a parallel system. It needs three small, additive extensions to the existing one (a capability key, a command kind, a role-declaring action pair) plus one genuinely new thing the terminal case never required: **a security posture proportional to what's actually being handed over.**

That last point is the design's center of gravity. A terminal-relay session hands the caller a shell scoped to one tmux pane (`TerminalRelayClient.swift:243`) — broad, but bounded by what's in that pane and mediated by what the user types. A VNC session hands the caller **the entire logged-in desktop**: clipboard, every other running app, an unlocked password manager, Keychain prompts, anything on screen. Every proposal that was drafted for this feature agreed on that asymmetry; where they disagreed was how much new machinery it justifies. This document resolves those disagreements explicitly rather than picking a proposal wholesale.

Two rules, both inherited from the terminal-relay design and re-affirmed here:

1. **The relay stays payload-agnostic.** It gets a second role-declaring action pair so it can apply per-session-kind limits, and nothing else. It must never parse RFB.
2. **The daemon never escalates privilege.** fin-agentd runs unprivileged today, by the same deliberate choice that produced the "no sshd, BY DESIGN" design on the work laptop. VNC support **detects** an already-running Screen Sharing server; it does not gain the ability to turn one on.

## 2. Capability flow: daemon → control plane → app

The `terminal_relay` capability already proves this whole path is additive end-to-end: a loose `[String: Any]` dict on the daemon, a schemaless DynamoDB map validated only for type and a 16 KiB cap (`lambda.py`, `MAX_CAPABILITIES_BYTES = 16*1024`), an `Optional` Swift property decoded through one new `CodingKeys` case. `vnc_proxy` rides the identical path with no schema migration anywhere:

```
Daemon.swift siteCapabilities()          [Daemon.swift:497-560]
  → DaemonSiteClient.capabilitiesProvider   [DaemonSiteClient.swift]
  → POST /sites/{siteId}/heartbeat, every 20s
  → lambda.py site_heartbeat()             — dict-type + 16KB check only
  → fin-sites DynamoDB row                 — schemaless map attribute
  → GET /sites → list_sites → _public_site — verbatim passthrough
  → ControlPlaneClient → SitesResponse → [FinSite]
  → FinSite.Capabilities (SiteDirectory.swift:24-78) — new `vncProxy: Bool?`
  → SiteDirectory.shared, read by ServerListView / ServerEditView
```

Where `vnc_proxy` deliberately **diverges** from `terminal_relay`'s pattern: `terminal_relay` is `true` for any enrolled site — it's a build-gate ("does this daemon binary know the relay protocol"), not a runtime opt-in, because a terminal is available the instant the relay feature is compiled in. VNC is not available the instant it's compiled in — it depends on a piece of macOS state (Screen Sharing) that a human has to have turned on, and it carries the higher stakes from §1. So `vnc_proxy` is gated on **two independent conditions**, both required, computed fresh every heartbeat cycle:

```swift
"vnc_proxy": config.vncProxyEnabled == true && vncPortReachable,
```

- **`config.vncProxyEnabled`** — a new daemon config field, default `false`, set by an explicit human action (a `fin config set vnc-proxy on` CLI verb, or the daemon's local config file). This is the mechanism that literally satisfies the requested framing — "only if that server is running the daemon with vnc proxy enabled" — and it must be a standing per-site decision a human makes, not something that defaults on. This is the one place all three drafted proposals should have agreed and one of them (proposal #1) blurred: don't conflate "opted in" with "currently reachable" into a single flag, keep them as two separate booleans that both have to hold.
- **`vncPortReachable`** — a plain loopback TCP connect-and-close probe against `127.0.0.1:5900`, re-run each heartbeat. This directly mirrors the control plane's own `_relay_is_accepting` reasoning (`lambda.py:1216-1234`, added because a dying EC2 instance reads "running" for the ~1 minute it takes to actually die) — don't trust config or OS service state that might be stale, TCP-probe the real thing. It also means the capability self-corrects within one heartbeat if Screen Sharing is toggled off outside Fin's control, and it's how the daemon avoids ever needing root: `launchctl load/unload` on `com.apple.screensharing`'s LaunchDaemon needs `sudo`, a plain `connect()` doesn't.

Both call sites — `Daemon.swift:514` (the `terminalReady == false` early-return branch) and `:550` (the full capabilities dict) — get this line next to the existing `terminal_relay` one.

`fin/Agent/SiteDirectory.swift:24-78` gets `let vncProxy: Bool?` on `FinSite.Capabilities`, decoded via one new `CodingKeys` case (`vnc_proxy`), same nil-is-unsupported rule already documented there for every other field.

## 3. Daemon-side VNC proxy

**New file: `daemon/Sources/fin-agentd/VNCRelayClient.swift`**, a sibling of `TerminalRelayClient.swift`, structurally close but diverging exactly where the payload diverges:

- No `exec tmux new-session -A -s \(tmuxSession)` (`TerminalRelayClient.swift:243-244`). Instead, on receiving a `vnc-open` site command, it dials a **raw TCP client socket to `127.0.0.1:5900`** (macOS Screen Sharing's RFB port) and pumps bytes bidirectionally over the relay connection — no RFB parsing, a pure byte pump, same as `relay.py` itself never parses.
- **Reuses the dial-failure-counting self-heal verbatim** (`TerminalRelayClient.swift:48-65`, the fix from the 2026-09-21 work-laptop relay incident: the daemon's `URLSession` can silently wedge for 45+ minutes with zero visible error, fixed by counting consecutive exhausted dial attempts and forcing a fresh `URLSession`). VNC sessions are longer-lived and idler than terminal sessions by nature, so this failure mode is *more* likely to hit here, not less — this is not optional hardening, it's inherited by construction if `VNCRelayClient` is built as a real sibling rather than a from-scratch class.
- **A new site-command kind, `vnc-open`**, added to `SITE_COMMAND_KINDS` (`lambda.py:3979`) and a new `case "vnc-open"` in `Daemon.swift`'s dispatch switch (sibling of `case "terminal-open"` at `Daemon.swift:2572-2594`). Args carry `sessionId`, `relayHost`, `relayPort` — no `tmuxSession` field, since the target is the fixed well-known `127.0.0.1:5900`, not a named session. `queue_site_command`'s existing `kind == "terminal-open"` branch that calls `_ensure_relay_worker` (`lambda.py:4297-4300`) gets a matching `kind == "vnc-open"` branch calling the *same* on-demand relay-worker machinery (`lambda.py:1216-1338`) — one relay instance per user already multiplexes arbitrary sessions by `sessionId`, so a VNC session shares the same EC2 box as an open terminal session for free.
- **The daemon refuses an incoming `vnc-open` command outright when `config.vncProxyEnabled != true`**, independent of whether the control plane issued one. This is a second, local enforcement point, not just a capability-advertisement nicety — a stale or spoofed capability cache on the app side must never be able to make an unwilling daemon open a GUI session. `TerminalRelayClient`'s input path (`sendAgentInput`, `:303`) has no such distinction today between "app-originated" and anything else; `VNCRelayClient` is built with this gate from day one rather than retrofitted.

**Relay changes (`scripts/cloud-agent/relay/relay.py`) — small, and scoped to stay payload-agnostic:**

Add a role-declaring action pair, `vnc-open` (app leg) / `vnc-attach` (site leg), parallel to today's `open`/`attach` (`relay.py:128-184`). This is not decoration: it lets the relay tag a `Session` object (`relay.py:68-90`) with its kind from the very first frame, and apply **per-kind** idle/half-open/frame-size constants without ever parsing the `data` payload — the same "route on `action`, never on content" discipline the relay already follows. Payload frames stay on the existing `input`/`output` actions unchanged; there's no need for `vnc-input`/`vnc-output` variants, since `relay.py` never interpreted `data` either way and the session already knows its own kind from the open/attach frame. (One of the three source proposals invented separate payload actions for VNC; that was unnecessary complexity the role-declaring pair alone already avoids.)

Two constants get **per-session-kind** values instead of shared ones, precisely because a shared value would be wrong in both directions:
- `MAX_FRAME_BYTES` (`relay.py:60`, currently 256 KiB, sized explicitly for base64'd 64 KiB PTY reads) stays tight for terminal sessions — it's the relay's only DoS-relevant limit, since the relay itself is unauthenticated at the frame layer (the sessionId is the only gate, §4). For VNC it's raised to accommodate an encoded RFB tile (proposed: 1 MiB, revisited once Phase 1 gives real numbers), with `VNCRelayClient` chunking anything larger on write. Raising the shared constant globally, as a naive patch would, would silently widen the terminal path's DoS ceiling for no reason — the per-kind split avoids that.
- Idle timeout: `TerminalRelayClient.idleTimeout = 10 * 60`, re-armed on *input only* (`TerminalRelayClient.swift:29`, `304`, `315-324`), is measurably wrong for VNC — a user reading a document or watching a build scroll with zero mouse/keyboard input for ten-plus minutes is normal GUI use, not abandonment, and a literal reuse would drop live sessions mid-use. `VNCRelayClient` gets its own timer, re-armed on **bytes in either direction**, not input alone — real desktop use almost never produces total silence on the wire for long (cursor blink, redraws), so this is a meaningfully better abandonment proxy than "no keystrokes." Proposed default: 30 minutes of total silence.
- **A new, second timer with no terminal analog: an absolute session-length cap**, independent of activity (proposed default: 4 hours). This directly answers "does the terminal idle model even make sense here" — no, not alone. An *active* but forgotten-open full-desktop session is itself a standing risk in a way an active terminal isn't, given §1's blast-radius asymmetry; bounding "I forgot to close it" to a known worst case, by forcing a fresh `sessionId` and a fresh Screen Sharing login on reconnect, is cheap insurance a shell never needed.
- `RELAY_IDLE_SECONDS`/`IDLE_SECONDS = 900` (instance-level: how long the *box* sits idle with zero sessions of any kind before self-terminating) and `HALF_OPEN_SECONDS = 180` (one side dialed, other never showed) stay shared, unchanged — nothing about a VNC user's between-session gap or dial-retry budget differs from a terminal user's, and there's no reason to duplicate these.

## 4. Security and auth posture

This is the section where the three drafted proposals differed most, and where this document makes explicit calls rather than deferring them all to Levi.

**What's inherited unchanged, and correctly so.** TLS identity is the relay's existing SHA-256 cert pin (`RelayCertificatePin.swift` in both the app and the daemon) — it authenticates *the relay*, not the payload, so it needs no VNC-specific change. Session identity is the existing control-plane-minted `sessionId`-as-capability model (`relay.py:25-31`: the relay does zero credential checking of its own; the sessionId itself, handed only to callers already bearer-authenticated to the control plane, is the whole authorization). Site identity is the existing per-site bearer token. None of this needs a new primitive for VNC — the relay's job stays "prove the wire is private and the two ends are who the control plane introduced," and that answer is identical for both payload types.

**What does not inherit, and needs a real decision:**

- **`config.vncProxyEnabled` defaults to `false` and requires an explicit human action to flip on, per-site, standing** (§2) — this is the correct generalization of "only if the daemon has vnc proxy enabled" from the request, and it deliberately diverges from `terminal_relay`'s always-on-for-any-enrolled-site pattern given the stakes difference from §1.
- **Classic VNC password fallback ("VNC viewers may control screen with password") is explicitly left disabled.** Screen Sharing supports both Apple's own DH/RA2 account-credential auth and a classic shared-VNC-password mode; the latter sends the RFB session unencrypted at the RFB layer after the challenge (mitigated in practice only because the exposed hop is loopback — everything from `127.0.0.1:5900` to the app already rides the relay's pinned TLS). Phase 1 supports Apple's native auth only. This is a real, named security choice, not a default — one of the three drafted proposals called it out explicitly and it survives into this design unchanged.
- **Phase 1's actual second factor is Apple's own login, for free, by construction of the chosen architecture** (§6): rather than Fin inventing a PIN/confirmation scheme before shipping anything, Phase 1's daemon-side proxy blind-pumps bytes to `127.0.0.1:5900`, where **Screen Sharing itself does the real RFB handshake**, including Apple's native account-credential authentication. "The relay says the right site was reached" and "Screen Sharing says this is a valid account login for this Mac" are two independent facts; an attacker holding only a stolen relay `sessionId` (e.g. a compromised control-plane account) is stopped at the second wall without Fin writing a single line of auth code. This is why the architecture in §6 is chosen over a native-client-from-day-one design — it is the cheapest path to a real second factor, not merely the cheapest path to *a* client.
- **A visible on-screen indicator whenever a VNC relay session is live** — a menu-bar icon or screen-edge tint, driven by `VNCRelayClient`'s active-session state, shown for the duration of any open session. A terminal someone is watching over your shoulder looks like normal terminal use; a silently-driven cursor has no equivalent tell, and Levi should be able to glance at his work laptop and know it's currently being remote-controlled. Cheap, and in scope for Phase 1, not deferred.
- **The PIN/second-factor question resurfaces, unresolved, for the Phase 3 native client** (§6) — once there's no Screen Sharing.app to lean on for auth (a native RFB decoder talking straight to the relay), Fin needs its own second factor, and neither "match SSH's zero-prompt trust tier" nor "require a PIN shown at connect time" is a default to pick silently. This is flagged in §7 as an open question for Levi, deliberately not resolved here, since it doesn't block Phase 1 or 2.

## 5. App-side "Terminal or GUI" UI

There is no connect-time menu in Fin today — `ServerListView.swift:118-124` wraps each server row in a plain `Button` whose action (`connect(to:)`, `:274-277`) calls `sessionManager.open(server)` immediately. This is the one place a real UI addition is needed, and the existing capability-gating precedent (`ServerEditView.swift:28-33`'s `relayCapableSites`, filtering `capabilities.terminalRelay == true`) is the template to copy:

```swift
private var vncCapableSites: [FinSite] {
    siteDirectory.sites.filter { $0.state != "retired" && $0.capabilities.vncProxy == true }
}
```

In `connect(to:)`: for a `.siteRelay` server, look up its site the same way `subtitle(for:)` already does (`ServerListView.swift:262`), and check **two** conditions before offering a choice — `site.capabilities.vncProxy == true` **and** `#if os(macOS)` on the *connecting client*. The platform check matters independently of the site's capability: Phase 1's handoff (§6) opens a loopback bridge and calls `NSWorkspace.shared.open(vnc://…)`, which only exists on macOS — an iPhone connecting to a fully VNC-capable Mac site still can't use it in Phase 1, and the UI must hide the "GUI" option on that client rather than advertise a capability it can't act on.

- **Both hold**: present a `.confirmationDialog("Connect to \(server.name)")` with **Terminal** and **GUI** actions. "Terminal" is today's unchanged path (`sessionManager.open(server)`). "GUI" calls a new `sessionManager.openVNC(server)`.
- **Either fails** (no capability, or a non-Mac client): fall straight through to today's behavior, unconditionally. This covers the entire current fleet and every `.direct` SSH server with **zero behavior change** — the whole feature is additive at the UI layer, exactly as the capability is additive at the wire layer.

New supporting pieces: `ControlPlaneClient.openVNCRelay` (sibling of `openTerminalRelay`, `ControlPlaneClient.swift:121-126`, same `POST /sites/{id}/commands` shape with `kind: "vnc-open"`, no `tmuxSession` arg), `SessionManager.openVNC(_:)` (sibling of `open(_:)`, `:372-403`), and `VNCRelayBridge.swift` (macOS-only, new) — a loopback TCP listener on an ephemeral port, pumping bytes to/from the relay over **`RelayWebSocket`'s existing `Network.framework` transport, not `URLSession`** (the ATS `-1200` trap that already forced the terminal path off `URLSession` inside the `.app` bundle applies identically here — any VNC networking code built against `URLSession` will hit the same wall the terminal path already solved), then `NSWorkspace.shared.open(URL(string: "vnc://127.0.0.1:\(port)")!)`.

No `Server`/`ServerEditView` model change is needed for Phase 1 — the mode choice is transient per-connect, not a saved server property. If "always open this server as GUI" becomes wanted later, that's a separate `Server.preferredMode` addition following `transportRaw`'s existing optional-string-with-fallback pattern (`Server.swift:23-39`), explicitly out of scope here.

## 6. Platform coverage — Phase 1 is macOS-to-macOS, and that's a real gap, not a footnote

CLAUDE.md's product framing is explicit: "the interface pillar is voice AND the native apps (iOS and macOS; tvOS/visionOS ride along)," and the standing TestFlight policy is that every ship goes to all four platforms together. This section names the tension with that framing directly rather than resolving it by omission.

**Phase 1 delivers GUI control to exactly one client platform: macOS.** The mechanism (§5) is a loopback TCP bridge that hands off to Screen Sharing.app via a `vnc://` URL — cheap (a proxy, not a protocol implementation), gets Apple's own auth/resize/clipboard/rendering for free, and is the only reason Phase 1 is affordable at all. But `NSWorkspace.shared.open(vnc://…)` and Screen Sharing.app both only exist on macOS. Apple ships no system VNC client and no OS-level `vnc://` handoff on iOS, iPadOS, tvOS, or visionOS — there is nothing equivalent to hand off to. An iPhone connecting to a fully `vnc_proxy`-capable Mac site gets no "GUI" option at all in Phase 1, by construction, regardless of how the site is configured.

Closing that gap for real means a native RFB client in the app — genuinely comparable in scope to building a lightweight remote-desktop app, not an incremental extension of the terminal work. **RoyalVNCKit** (`github.com/royalapplications/royalvnc`, MIT-licensed) is the right library if this is built: a real, maintained Swift RFB implementation, and critically MIT rather than **LibVNCClient**'s GPL — vendoring GPL code into an App-Store-distributed binary is a real legal-review problem (source-distribution/anti-restriction terms sit awkwardly against App Store DRM terms), not a preference, so RoyalVNCKit is the only one of the two options actually usable here. Even with the right library, the decode/render half (continuous compressed-tile decode onto a Metal texture at interactive framerate) is the *smaller* half of the remaining work — the harder, genuinely novel half is a distinct input model per platform: macOS mouse+keyboard is straightforward; iOS/iPadOS has no cursor concept at all and needs a trackpad-emulation gesture layer (a third-party community project, `local-ai-cat/vncat`, has already attempted exactly this on top of RoyalVNCKit and is worth reading as a reference before building from scratch, though it needs its own license/maturity review before anything is vendored from it); tvOS has no pointer concept and would need a d-pad-driven virtual cursor; visionOS's eye+pinch → RFB pointer mapping is genuinely unsolved design territory, not a known gap with a known answer.

Given that cost, this document recommends treating cross-platform native rendering as a **separate, later initiative (Phase 3, §7), scoped only if real demand shows up for GUI control from something other than another Mac** — not bundled into the same delivery as the work-laptop use case that actually motivated this feature. This is a scoping decision with a real tension against "native apps, plural," and it should be put to Levi explicitly alongside the Phase 0 sign-off in §7, not quietly assumed away. The honest fallback position if he pushes back: Phase 1 ships as designed (it's the only way to get *anything* live quickly), and Phase 3 is scheduled rather than merely optional.

## 7. Delivery plan

**Phase 0 — plumbing and policy, no data path.**
Capability round-trip only: `config.vncProxyEnabled` config field + TCP-probe reachability check + `vnc_proxy` capability reporting at both `Daemon.swift` call sites; `SITE_COMMAND_KINDS` gains `"vnc-open"`; `FinSite.Capabilities.vncProxy` decode. Nothing behind the wire actually opens a session yet — this validates the wiring (capability shows up, picker would gate correctly) with zero exposure, since there's no VNC data path to abuse. Also resolve, with Levi, whether the work laptop's MDM/IT posture toward Screen Sharing is any different from the posture that already blocked sshd there — if Screen Sharing is blocked the same way, Phase 1 as designed delivers zero value for the one use case that motivated the whole feature, and that needs to be known before Phase 1 is built, not discovered after.

**Phase 1 — macOS-to-macOS, Screen Sharing.app handoff, no RFB code in Fin.**
`relay.py`'s `vnc-open`/`vnc-attach` role actions + per-kind frame-size and idle constants; `VNCRelayClient` (daemon); `queue_site_command`'s `vnc-open` branch reusing the existing `_ensure_relay_worker`; `VNCRelayBridge` + `ControlPlaneClient.openVNCRelay` + `SessionManager.openVNC` (app); the `ServerListView` confirmation dialog gated on `vncProxy == true && macOS client`; the visible on-screen live-session indicator; classic VNC password fallback left off. Ship to Levi's own enrolled devices first, given this is genuinely new attack surface even with §4's mitigations in place.

**Phase 2 — hardening from real usage, not guesses.**
Verify the `MAX_FRAME_BYTES` value and the 30-minute/4-hour idle and absolute-cap timers against actual Screen Sharing traffic; confirm whether `t4g.nano`'s burstable (not guaranteed) network throughput holds up under one sustained VNC session, and whether the relay's whole "cheaper than an Elastic IP, standing" cost argument still holds once sessions run longer and heavier than a terminal ever did — this is flagged, not solved, until Phase 1 produces real numbers. Add distinct, loud daemon-side logging of vnc-open/close events (mirroring the terminal-open logging pattern from `24d97b1`), without a new external push — a VNC session opening is routine user-initiated activity, not an anomaly, per the standing "external pushes only when actionable" notification policy; reserve a push for a genuine anomaly this feature introduces, such as a `vnc-open` command arriving for a site whose local opt-in flag is off.

**Phase 3 — cross-platform native client, scoped only on demonstrated demand.**
A short spike first, before committing to RoyalVNCKit as the library: confirm it can actually be driven over a custom `Network.framework`-backed transport in bytes-in/bytes-out mode rather than opening its own socket (required by the same ATS trap noted in §5) — if it can't, the fallback is a materially larger project (forking it, or a hand-rolled minimal RFB decoder), not a contingency line item. If the spike succeeds: `VNCSession`/`VNCScreenView` (macOS input first, since it's the only straightforward one), then the harder per-platform input adapters from §6 in priority order (iOS trackpad emulation, then tvOS, then visionOS, each independently scoped). This is also where the auth-layering question flagged in §4 has to actually be answered — there's no Screen Sharing.app to lean on for a second factor here, so the choice between matching SSH's zero-prompt trust tier and requiring an explicit PIN/confirmation step needs to go to Levi before this phase starts, not be defaulted.

**Open questions this document deliberately leaves for Levi, rather than defaulting:**
1. Work-laptop MDM/IT posture toward Screen Sharing — same question that already shaped the no-sshd design there.
2. Whether Phase 1 shipping GUI control to macOS only, with cross-platform coverage deferred to a demand-gated Phase 3, is an acceptable read of "native apps, plural" for this specific feature.
3. The Phase 3 auth-layering choice (§4/§7) once there's no OS-native auth screen to lean on.
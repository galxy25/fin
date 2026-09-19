# Bundling fin-agentd inside the Fin app — feasibility

*Feasibility study, 2026-09-18. Repo state: `main @ 49dca2e`. Question (Levi): how
feasible is it to ship the daemon inside Fin itself, so a user installs Fin on their phone
and on any Mac, flips a toggle on the Mac, and connects to that Mac as a server from iOS —
with the Mac app running the terminal server as a background activity. Companion to
`docs/SITES.md` (the sites design) and `docs/SITES-ANY-MAC.md` (the local-PTY transport).*

Conventions: every repo claim carries `file:line`. Every platform claim carries a URL.
**KNOWN** = read from the repo, quoted from an Apple primary source, or measured on this
machine. **INFERRED** = reasoning from those, flagged as such. Claims that adversarial
review refuted or corrected are marked and carry the correction, not the original.

---

## 1. Verdict

**Feasible with conditions, but not in the shape the question describes.** The Mac App
Store build is sandboxed (`fin/fin-macOS.entitlements:5-6`, required by `project.yml:155-158`
and by Apple's own rule that "to distribute a macOS app through the Mac App Store, you must
enable the App Sandbox capability" — https://developer.apple.com/documentation/security/app-sandbox),
and every process a sandboxed process spawns inherits that sandbox unconditionally. That
kills the *local PTY* — the transport the current relay is built on and the one that makes
"just install Fin" attractive — inside the App Store build. What remains feasible in the
App Store is a narrower and still-useful product: Fin.app on a Mac registers a sandboxed
`SMAppService` launch agent, dials **loopback sshd** (`127.0.0.1:22`, the transport
`HeadlessTerminalSession` already implements), and serves the phone a relayed terminal —
at the cost of the user turning on Remote Login and authorizing a key, and with managed
Macs that cannot enable Remote Login (the work laptop) excluded entirely. The shape Levi
described — no sshd, the app opens the PTY itself — is achievable only outside the Mac App
Store, in a Developer ID notarized build, which forfeits TestFlight, StoreKit/Fin Pro, and
the "one universal purchase, all platforms" framing in `CLAUDE.md`. So: two viable designs,
one of them a distribution decision rather than an engineering one.

---

## 2. The one fact that decides the architecture

A sandboxed process's children are sandboxed. Apple DTS: "A child process always inherits
its sandbox from its parent. An independent app does not"
(https://developer.apple.com/forums/thread/685544), and "A process is not allowed to change
its sandbox" (https://developer.apple.com/forums/thread/706390). The
`com.apple.security.app-sandbox` + `com.apple.security.inherit` pair
(https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
is the signing requirement for a *bundled helper* so App Review sees it as sandboxed and so
the `exec` does not trap — it is not a switch that turns inheritance on. System binaries
(`/bin/sh`, Homebrew `tmux`) carry no sandbox entitlements and simply inherit.

**Measured on this Mac, 2026-09-18** (KNOWN): a minimal `SBTest.app`, ad-hoc-signed with
only `com.apple.security.app-sandbox` + `network.client`, run from `Contents/MacOS`:

| probe | result |
|---|---|
| `$HOME` | redirected to `~/Library/Containers/dev.levischoen.sbtest/Data` |
| `ls ~/forges` | Operation not permitted |
| `touch /tmp/x`, `mkdir /tmp/tmux-501-sbtest` | Operation not permitted |
| `/opt/homebrew/bin/tmux -L sbtest new-session -d` | Operation not permitted — the **exec itself** is denied, `TMUX_TMPDIR` makes no difference |
| `ls /private/tmp/tmux-501/` | Operation not permitted (cannot see the user's tmux server) |
| `git status` | `xcrun: error: cannot be used within an App Sandbox` |

The identical unsigned binary passed all nine probes. A sandboxed CLI *outside* a bundle
crashed at load in `_libsecinit_appsandbox`, so a sandboxed helper must live in a bundle.

This matches Apple DTS on exactly this use case — a MAS app `forkpty`ing a shell gets
`zsh: can't set tty pgrp: operation not permitted` and `ls /Users` → EPERM
(https://developer.apple.com/forums/thread/685544) — and the reason execution outside
`/usr/bin`, `/bin`, `/Applications` fails at all: "For that you'd need an execute extension,
and the OS simply has no support for this" (https://developer.apple.com/forums/thread/683158;
see also https://developer.apple.com/forums/thread/654579 on `/usr/local` needing a dynamic
extension). The repo already suspected this in a comment
(`daemon/Sources/FinAgentCore/LocalTerminalSession.swift:70-72`); it is now measured.

Consequence, in repo terms: `LocalTerminalSession`'s `forkpty`+`execve`
(`daemon/Sources/FinAgentCore/LocalTerminalSession.swift:172`, `:360`, `:366`) and
`TerminalRelayClient`'s `exec tmux new-session -A -s <name>`
(`daemon/Sources/fin-agentd/TerminalRelayClient.swift:157-158`) would, inside the MAS app,
serve a shell confined to Fin's container: no user files, no Homebrew, no `git`, no
`swift build`, no `claude`, and no view of the user's existing tmux server. That is not
"connect to my Mac"; it is a sandboxed toy.

Also **KNOWN and load-bearing**: `TerminalRelayClient` is constructed for *every* enrolled
site regardless of the configured transport (`daemon/Sources/fin-agentd/Daemon.swift:1860`,
dispatched at `:2457`), and it always uses a local PTY on the **default** tmux socket — not
Fin's private `-L fin` one. So even an `ssh`-transport site serves the relayed terminal via
`forkpty` today. Moving the daemon into the app therefore requires re-plumbing the relay,
not just relinking it.

---

## 3. Proposed architecture

### 3.1 Variant A — Mac App Store, sandboxed helper, loopback SSH

```
Fin.app (sandboxed, MAS)
├── in-app toggle "Let my other devices use this Mac"
│     → SMAppService.agent(plistName:).register()
│     → walks the user through Remote Login + authorizing the key
└── Contents/Library/LaunchAgents/dev.levischoen.fin.site.plist
      └── Contents/MacOS/fin-site   (sandboxed helper; app-sandbox + network.client)
            ├── FinAgentCore.HeadlessTerminalSession → ssh 127.0.0.1:22  (unsandboxed shell via sshd)
            ├── DaemonSiteClient → control plane (heartbeat/claim/ack/presign)
            └── RelayWebSocket (Network.framework) → wss://<relay>:<port>
```

What is reused verbatim: everything in `FinAgentCore`, which already compiles into the app
target as sources (`project.yml:34-39`) — the turn engine, `HeadlessTerminalSession`, the
tmux guards, goals ledger/sync, routing registry, stall/notify gates. What moves out of
`daemon/Sources/fin-agentd` (16 files, ~7.4k lines, all `internal`): `Daemon.swift`'s loop
and prompt composition, `DaemonSiteClient`, `DaemonDirectiveClient`, the notify/memory/
artifact/device-status/inbox-lock/goals-sync/transcript clients, `SessionInventoryScanner`,
`PaneThreadMap`. What must be rewritten, not moved:

1. **The relay socket.** `TerminalRelayClient` uses `URLSessionWebSocketTask` with a
   `RelayPinningDelegate` (`daemon/Sources/fin-agentd/TerminalRelayClient.swift:67`, `:119`).
   Proven 2026-09-17: ATS refuses the relay's pinned self-signed cert inside an `.app`
   before the delegate ever runs (`NSURLErrorDomain -1200`), while the same code works as a
   bare CLI — which is why the app moved that one socket to Network.framework
   (`fin/Session/RelayWebSocket.swift:5-20`). The in-app site must use `RelayWebSocket`.
   Apple confirms Network.framework accepts a self-signed cert via a verify block
   (https://developer.apple.com/forums/thread/672190).
2. **The relay's terminal backend.** `HeadlessTerminalSession` exposes **no** raw-output
   hook and **no** resize: its inbound bytes go only to `eventLog.recordOutput`
   (`daemon/Sources/FinAgentCore/HeadlessTerminalSession.swift:610-613`), and its PTY
   dimensions are fixed at construction. `LocalTerminalSession` has both
   (`LocalTerminalSession.swift:172`, `:360`, `:366`). Adding an `onRawOutput` in `feed(_:)`
   and a window-change request is small — the app's own Citadel session already streams the
   same chunks to SwiftTerm — but it is new code on the SSH class.
3. **The launch preflight.** `scripts/mac-fin-agentd/launch-agentd.sh`'s checks (brain
   reachable *and actually serving the requested model*, presigned-URL expiry, the
   interactive-login-shell `LC_FIN_AGENT` probe) become Swift.
4. **Duplicate symbols.** `RelayCertificatePin`/`RelayPinningDelegate` exist in both
   `fin/Session/RelayCertificatePin.swift` and `daemon/Sources/fin-agentd/RelayCertificatePin.swift`;
   one must go. And any `Process`/`forkpty` code that lands in `FinAgentCore` needs
   `#if os(macOS)` — the 2026-09-15 TestFlight failure ("cannot find 'Process' in scope" on
   three of four platforms) is the precedent, recorded at `LocalTerminalSession.swift:66-78`.

**Helper vs in-app process.** Both are needed, for different halves. The app process can
host the loop while Fin is open; only a launch agent survives Cmd-Q and login. Today the
app's site heartbeat runs only while `isAppActive` (`fin/Session/SessionManager.swift:74-90`),
which on macOS must be decoupled from `scenePhase`. `SMAppService.agent(plistName:)` is
available to sandboxed MAS apps (the plist lives in `Contents/Library/LaunchAgents`,
`BundleProgram` bundle-relative) — https://developer.apple.com/documentation/servicemanagement/smappservice.
Since macOS 14.2 the registered executable "must be sandboxed if the main app is sandboxed"
(release note 113037504, quoted at https://developer.apple.com/forums/thread/743395;
failure mode is `BTM: error: sandbox required`, `SMAppServiceErrorDomain Code=1`), and
app↔agent XPC needs a shared app-group entitlement — which `fin/fin-macOS.entitlements` does
not currently declare. `LaunchDaemon` is out: it runs as root, and guideline 2.4.5(v) bars
root escalation (Quinn: "Daemons fall foul of clause 2.4.5(v). OTOH, agents don't run as
root and thus are fine" — https://developer.apple.com/forums/thread/750484).

**Control plane.** Essentially no change. `terminal-open` is authorized by ownership, not
kind (`scripts/cloud-agent/control-plane/lambda.py:3975`, `:4274`), and the iOS picker
filters solely on `capabilities.terminal_relay == true` (`fin/Views/ServerEditView.swift:29-31`).
What *is* missing in the app: `AppSiteClient` never reads the heartbeat's `commands` array
(zero occurrences in `fin/Agent/AppSiteClient.swift`) and never advertises `terminal_relay`
(`:247`). A Mac hosting the runtime should also enroll as something other than kind `app`,
whose default priority is 1 and whose glyph is a phone (`lambda.py:3951`, `:3956`).

### 3.2 Variant B — Developer ID, non-sandboxed, the shape Levi described

The app embeds `fin-agentd` as an `SMAppService` agent with no sandbox, keeps
`LocalTerminalSession`, and needs no sshd, no key, no `authorized_keys`. Every blocker in
§2 disappears. What does not disappear (CORRECTED — an earlier draft claimed Developer ID
"removes every transport limit"): tmux still has to be installed (the plist's PATH assumes
Homebrew, `scripts/mac-fin-agentd/dev.levischoen.fin.agentd.plist:37-38`; the preflight
refuses without it, `launch-agentd.sh:246`), a brain endpoint must exist, and the app must
provision the `config.json` and presigned-URL refresh that `install.sh`/`refresh.sh` do
today — so "embed it as-is" is true of the source, not the packaging. The real cost is
distribution: TestFlight requires App Store Connect distribution signing, so a Developer ID
build cannot ride `scripts/testflight-macos.sh` (`:5-8`, `:96-97` export method
`app-store-connect`), cannot ship in sync with the other three platforms, and cannot carry
the StoreKit entitlement gate (`fin/Views/RootView.swift:47`, `fin/Store/EntitlementStore.swift:51-53`).
Since MAS submission requires the sandbox, Variant B is a *second* macOS build, not a
replacement — unless the Mac App Store build is abandoned.

---

## 4. Apple rules that bind this

**Sandbox / helper mechanics.**
- App Sandbox is mandatory for MAS — https://developer.apple.com/documentation/security/app-sandbox
- Children always inherit; bundled helpers sign with exactly app-sandbox + inherit —
  https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html,
  https://developer.apple.com/forums/thread/706390
- No "execute extension" exists, so user-granted folders are still non-executable —
  https://developer.apple.com/forums/thread/683158
- `SMAppService` (macOS 13+), plist in `Contents/Library/LaunchAgents` —
  https://developer.apple.com/documentation/servicemanagement/smappservice
- Since macOS 14.2 the registered agent must itself be sandboxed —
  https://developer.apple.com/forums/thread/743395

**Consent (CORRECTED — the original research had this backwards).** Registering a
LaunchAgent does **not** wait for approval: "If the service corresponds to a LaunchAgent,
the LaunchAgent is immediately bootstrapped and may begin running… [and] bootstrap on each
subsequent login" (https://developer.apple.com/documentation/servicemanagement/smappservice/register()).
macOS posts a "Background Items Added" notification and adds a switch under System Settings
› General › Login Items; `.requiresApproval` is the *revoked or pending* state, returned
"if the user revokes consent"
(https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval).
Only LaunchDaemons wait for an admin. **On macOS 26+ there is an additional prompt**: "if
background tasks are started by an app and remain active after a user quits the app, the
user is prompted to allow or not allow the background tasks to remain active"
(https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web).
So the consent story must be an in-app, default-off toggle, not reliance on the OS
notification.

**App Review guidelines** (https://developer.apple.com/app-store/review/guidelines/):
- **2.4.5(i)** sandboxed. **(ii)** "self-contained, single app installation bundles and
  cannot install code or resources in shared locations" — today's installer writes
  `~/Library/LaunchAgents` and `~/Library/Application Support/fin-agentd`
  (`scripts/mac-fin-agentd/install.sh:53`), which a MAS build may not do.
  **(iii)** no auto-launch at login *and* no "processes that continue to run without consent
  after a user has quit the app" — both clauses apply to an always-on site.
  **(iv)/(vii)** no downloading additional code; updates only via the Mac App Store — this
  deletes the daemon's self-update, which today GETs a presigned binary and renames it over
  itself (`daemon/Sources/fin-agentd/DaemonSiteClient.swift:383`, `:410`).
  **(v)** no root/setuid — so the dedicated-UNIX-user hardening discussed in
  `docs/SITES-ANY-MAC.md` is permanently unavailable in this design.
- **2.5.2** self-containment / no executing code that changes features.
- **4.2.3(i)** "Your app should work on its own without requiring installation of another
  app to function" — an iPhone↔Mac pairing feature invites this, though universal purchase
  of the *same* app is the defence.
- **REFUTED** (do not repeat): that **2.5.4** is the relevant hook. 2.5.4 lists iOS
  multitasking background modes ("VoIP, audio playback, location, task completion, local
  notifications"); it has no macOS analogue. 2.4.5(iii) is the rule that governs background
  activity on macOS.
- **CORRECTED**: **4.2.7** (remote desktop) is conditional — it binds only an app that
  "acts as a mirror of specific software or services rather than a generic mirror of the
  host device". A generic terminal is outside it; a reviewer may still cite it. A developer
  asking about SSH-into-your-own-Mac from a MAS app expected **4.7.2** ("may not extend or
  expose native platform APIs or technologies to the software") to be raised
  (https://developer.apple.com/forums/thread/807395).
- No guideline mentions SSH or terminals. Apple's only on-record answer to "can a MAS app
  SSH into the user's own Mac" was App Review referring the developer to a one-on-one
  consultation (thread 807395). Separately, Apple DTS **recommended this exact pattern**:
  "one option here would be to not provide the local target at all. The user can then enable
  SSH on their machine if they want to run locally"
  (https://developer.apple.com/forums/thread/685544) — while warning that App Review is
  "very wary of apps that require help from a non-App Store component to achieve their core
  functionality", which is a point against today's separately-installed `fin-agentd`, not
  against Variant A.
- Wording hygiene ("remote terminal to your own Mac", not "SSH-over-HTTP proxy" or
  "server") is an INFERENCE with no evidence behind it. The reliable step is the App Review
  consultation Apple itself recommends.

**Networking and privacy strings.** Outbound HTTPS/WSS needs only
`com.apple.security.network.client`, already present (`fin/fin-macOS.entitlements:7`). No
`network.server` is needed — the site dials *out* to the relay. Local Network privacy
arrived on macOS 15 and defines a local network as one "associated with a broadcast-capable
network interface… not cellular (WWAN) or VPN"
(https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
Loopback is exempt — Apple DTS: "Loopback addresses (127.0.0.1 and ::1) are exceptions to
the local network restrictions" (https://developer.apple.com/forums/thread/650810) — so
`ssh 127.0.0.1` prompts nothing. Two caveats the first pass got wrong:
- TN3179 says the launchd exemption "doesn't apply to launchd agents", and that macOS
  attributes a helper's local-network operation to the responsible app only when the agent
  is registered via `SMAppService` or declares `AssociatedBundleIdentifiers`. Today's
  script-installed agent declares neither — latent, because its traffic is loopback plus an
  internet-routed relay.
- Tailscale rides a `utun` (VPN) interface, so it is *not* local network;
  `NSLocalNetworkUsageDescription` (`project.yml:89`) is not what covers LM Studio over
  Tailscale. The ATS exemption `NSAllowsLocalNetworking` (`project.yml:102-103`) is.

**Brains.** OpenRouter over HTTPS is unproblematic. LM Studio on `http://127.0.0.1:1234` is
gated by ATS, not the sandbox, and works only because of `project.yml:102-103` — and there
is an *unverified* third-party report that macOS 26.5 stopped honouring
`NSAllowsLocalNetworking` for `http://127.0.0.1`, which must be tested on a 26.x box before
anyone depends on it. Apple on-device (Foundation Models) needs macOS 26+ on
Apple-Intelligence hardware (https://developer.apple.com/documentation/foundationmodels)
while the app's floor is macOS 15.0, pinned there by Citadel's `@available(macOS 15.0, *)`
PTY APIs (`project.yml:5-10`); the app already degrades gracefully
(`fin/Agent/AppleOnDeviceBackend.swift:39-56`, surfaced in `fin/Views/AgentEditView.swift:168-171`).
Whether Foundation Models works from a non-UI helper process is **unverified** — there is no
`SMAppService` anywhere in the repo to test against. Apple also publishes separate
Acceptable Use Requirements for that framework
(https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/),
which should be read before assuming an on-device model may drive a shell.

---

## 5. Phased plan

**Phase 0 — decide the distribution question (days, not weeks).** Two things gate
everything: (a) is the Mac App Store build the *only* macOS build? (b) book the one-on-one
App Review consultation Apple recommends (thread 807395) and ask, in writing, whether a MAS
app whose Mac feature requires the user to enable Remote Login and authorize a key is
acceptable. The §2 sandbox probe is already done; do not redo it.

**Phase 1 — terminal server only, no agent runtime (~1–2 weeks).** The daemon's brain is
provably not on the relay path: `TerminalRelayClient` is built from `config.site` alone and
the pre-readiness capability branch already advertises `terminal_relay`
(`daemon/Sources/fin-agentd/Daemon.swift:1860`, `:507-518`). So ship the serving half first:
1. Move `TerminalRelayClient` + the relay frame types into `FinAgentCore` behind
   `#if os(macOS)`, abstracting its terminal behind a protocol (~300 lines touched).
2. Re-base its socket on `RelayWebSocket` (Network.framework) (~200 lines).
3. Add `onRawOutput` and a resize/window-change to `HeadlessTerminalSession` (~80 lines).
4. `AppSiteClient`: parse `commands`, dispatch `terminal-open`, advertise `terminal_relay`
   when the toggle is on, and run the heartbeat independent of `scenePhase` on macOS (~150).
5. macOS UI: the toggle, `SMAppService` register/unregister with the Login Items deep link,
   a `ProcessInfo.beginActivity` assertion (optionally `.idleSystemSleepDisabled`, which
   holds off idle sleep with no root — strictly better than today's printed
   `sudo pmset -a sleep 0`), Remote Login onboarding, key generation into the existing key
   vault, and the `authorized_keys` line (~250 lines).
6. iOS: picker footer copy (`fin/Views/ServerEditView.swift:95` still says "make sure the
   target Mac is running an up-to-date fin-agentd") and a Mac glyph (~30 lines).
7. Control plane: nothing required; optionally a kind or flag so a Mac-app site is not
   drawn as a phone and is covered by the lost-contact push (`lambda.py:5249-5253`).

**Phase 2 — agent runtime inside the app (~2–3 weeks).** Lift the 16 `fin-agentd` files
into `FinAgentCore` as a `SiteRuntime`: replace the ~10 CLI/launchd touch points in
`Daemon.swift` (argv at `:25-45`, `exit()`, `print` logging, the restart/stop/update
commands, the relative default audit path) with injected config, an `os.Logger` sink, a
lifecycle API and container-rooted paths; delete the self-update entirely (guideline
2.4.5(iv)); port `launch-agentd.sh`'s preflights to Swift. The existing test seams
(`Daemon.swift:356-371`, driven by `DaemonLaunchOrderTests`) carry over. Open design
question inside this phase: a daemon-derived `SiteRuntime` beside the app's own 2,522-line
`AgentRuntime` (`fin/Agent/AgentRuntime.swift`) is less work but leaves two loops; folding
the site protocol into `AgentRuntime` removes the duplication and costs more.

**Phase 3 — the Developer ID fork, if Phase 0 chose it (~3–5 days on top of Phase 2).**
Second archive/signing/notarization path, an out-of-store updater, no StoreKit. Only worth
doing if managed Macs (no sshd) must be served by Fin.app rather than by `install.sh`.

---

## 6. Risks and blockers

1. **Sandbox inheritance (blocker for the described shape).** Measured, §2. In the MAS
   build the local-PTY transport cannot exist, so the work-laptop case regresses to
   `install.sh --transport local` permanently.
2. **Remote Login is not a thing the app can turn on.** Nor can it write
   `~/.ssh/authorized_keys` from the container without a powerbox grant or a user-pasted
   line. "Just install Fin" is not achievable for the Mac side under MAS rules — the flow
   is "install Fin, enable Remote Login, authorize this key".
3. **App Review has never ruled on this pattern.** Its only answer on record is a referral
   to a consultation; the macOS 1.0 submission was already rejected 2.1 "steps to verify",
   and the tvOS thread shows Apple treating the SSH-server Mac as "designated hardware" and
   demanding a video with both devices on camera, delivered as a link
   (`docs/app-review/apple-tv-screen-recording.md:3-15`). Note this is App Review
   correspondence language, not guideline text — 2.1(a) covers demo accounts and back-end
   services and says nothing about videos.
4. **Review notes differ per variant, and getting it backwards is a rejection.** Variant A
   *must* document Remote Login + Login Items + that the agent starts only on the toggle and
   stops when revoked. Variant B must say the opposite (no Remote Login, no Terminal, no
   keys). Do not reuse one variant's notes for the other.
5. **ATS and the pinned relay cert.** Already cost one debugging cycle
   (`fin/Session/RelayWebSocket.swift:5-20`); any in-app relay that forgets this fails with
   `-1200` and no visible cause.
6. **Two agent loops.** `AgentRuntime` (app) and `Daemon` (site) would coexist; the
   duplication is a standing maintenance cost until one absorbs the other.
7. **Sleep.** Unchanged by any of this: a sleeping Mac is a `stale` site, there is no
   wake-on-LAN or APNs wake, and the app cannot run `pmset`. `beginActivity(.idleSystemSleepDisabled)`
   helps only while the helper is alive and only against *idle* sleep.
8. **Pro entitlement reaching the helper.** The UI is gated on `isUnlocked`
   (`fin/Views/RootView.swift:47`), but a background helper would keep heartbeating after a
   trial lapses unless the entitlement is written somewhere it reads, or the control plane
   refuses the site.

---

## 7. Open questions

1. Is a Developer ID macOS build acceptable as a second channel? This single answer picks
   the architecture. (It forfeits TestFlight, StoreKit, and ship-in-sync.)
2. What does App Review say, in the consultation, about Remote Login as a prerequisite?
3. Can a sandboxed helper resolve security-scoped bookmarks the app minted? Apple's sandbox
   doc says a bookmark can be passed "to another process, like a launch agent"
   (https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
   but DTS says a helper that resolves bookmarks without presenting panels wants
   `com.apple.security.files.bookmarks.app-scope` (https://developer.apple.com/forums/thread/798402),
   which `fin/fin-macOS.entitlements` does not declare. Even if it works, it grants **read**,
   never **execute**.
4. Should a Mac hosting the runtime enroll as kind `resident` (priority 100) or as `app`
   plus a capability flag — and how do the app site and the hosted-runtime site on the same
   Mac (or two macOS user accounts) avoid looking like unrelated bodies? There is no
   `hostId` anywhere in the repo today.
5. Does Foundation Models work inside an `SMAppService` helper process? Unverifiable from
   this repo; needs a spike on macOS 26.
6. Does `NSAllowsLocalNetworking` still cover `http://127.0.0.1` on macOS 26.5? One
   unconfirmed third-party report says no.
7. Should the relay frame protocol (attach/output/input/resize/close) be extracted into one
   shared `FinAgentCore` file so the serving and client sides cannot drift once the app
   does both?

---

## 8. What this retires — and what it does not

**Retired in Variant A (personal Macs with sshd):**
- `scripts/mac-fin-agentd/install.sh` for *Macs the user owns*: no rendered LaunchAgent
  plist, no `~/Library/Application Support/fin-agentd`, no `config.json` by hand, no
  `launchctl bootstrap`. (Required by 2.4.5(ii) anyway.)
- The S3 macOS binary for those Macs, `publish-binary.sh`'s role in their updates, and the
  daemon's self-update command (`DaemonSiteClient.swift:383-410`) — App Store updates only.
- `refresh.sh` and the 7-day presigned-URL re-signing LaunchAgent: the app holds the site
  token in the Keychain and refreshes URLs from the heartbeat (`Daemon.swift:1936-1940`).
- The enroll-token round trip in `fin/Views/AgentKeyView.swift:181-191` — the app
  self-enrolls, idempotently by `enrollKey` (`fin/Agent/AppSiteClient.swift:87-128`).
- The one-time install command the user copy-pastes into a Terminal.

**NOT retired in Variant A (this is the honest cost):** site keys and the
`restrict,pty,from="127.0.0.1,::1"` `authorized_keys` line come *back* — the local transport
had deleted them (`docs/SITES-ANY-MAC.md` §2.4: "Deleted, and good riddance: the site key,
the authorized_keys line, the from pin, the sshd requirement, AcceptEnv"). So does the
interactive-login-shell auto-attach hazard the `LC_FIN_AGENT` marker guards
(`daemon/Sources/fin-agentd/Daemon.swift:113-147`). Variant A trades installer friction for
sshd friction; it does not remove friction.

**Retired only in Variant B:** the site key, `authorized_keys`, the sshd requirement, and
the login-shell guard — the full `SITES-ANY-MAC` §2.4 list — at the price of leaving the
Mac App Store for that build.

**Never retired, either way:** `install.sh --transport local` for managed Macs where Remote
Login is off by policy (the work laptop — see the memory note on that incident), Linux BYO
(`install-linux.sh`, systemd), and EC2 (`_provision_config` inside `create_worker`). The
S3 binary and publish pipeline stay for those three.

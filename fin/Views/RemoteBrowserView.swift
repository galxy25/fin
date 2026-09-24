import SwiftUI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Remote Browser (docs/REMOTE-BROWSER.md): the live view of a site's Chrome — the one its
/// Claude sessions drive — where Levi signs in to GitHub, Gmail, anything that wants a
/// password or 2FA, then hands the browser back.
///
/// Gated by Face ID / Touch ID / Optic ID (or the device passcode) on every open. That
/// browser carries signed-in sessions, and the relay's `sessionId` is the only other
/// thing standing in front of it; a biometric check means a stolen phone or a leaked
/// session is not, on its own, a way into Levi's Gmail. Chosen over a prompt approved ON
/// the target Mac because that one can't be answered when Levi is away from it — which
/// is exactly when he'd reach for this.
struct RemoteBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: RemoteBrowserSession
    @State private var typed = ""
    @State private var address = ""
    @State private var gateFailed: String?
    @State private var lastDrag: CGSize = .zero
    /// The carousel's sticky modifiers (Levi, 2026-09-23: a toolbar "everywhere," not
    /// only iOS/iPadOS like the terminal's UIKit accessory row — built in SwiftUI here
    /// so macOS and Vision Pro get it for free). Tapping one arms it; it applies to the
    /// NEXT key send and then clears, mirroring the terminal's Ctrl latch.
    @State private var armedModifiers: Set<RemoteBrowserProtocol.Modifier> = []

    /// Set for the tab presentation: the session belongs to `SessionManager`, so the
    /// view must neither close it on disappear (switching tabs) nor dismiss itself
    /// on Done (there is nothing to dismiss — Done closes the tab).
    private let onDone: (() -> Void)?
    private let siteName: String

    /// Whether typing and taps will do anything: false when the site's daemon lacks the
    /// Accessibility grant (desktop only — the browser needs no grant). nil = unknown.
    private let inputAvailable: Bool?

    /// Window: the view owns a fresh session and ends it when it goes away.
    init(site: FinSite, mode: RemoteBrowserSession.Mode = .browser) {
        self.siteName = site.displayName
        self.onDone = nil
        self.inputAvailable = mode == .desktop ? site.capabilities.guiPermissions?.accessibility : true
        _session = StateObject(wrappedValue: RemoteBrowserSession(siteID: site.siteId, mode: mode))
    }

    /// Tab: the session outlives this view (see `SessionManager.BrowserTab`).
    init(tab: SessionManager.BrowserTab, onDone: @escaping () -> Void) {
        self.siteName = tab.displayName
        self.onDone = onDone
        self.inputAvailable = tab.inputAvailable
        _session = StateObject(wrappedValue: tab.session)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                page
                Divider()
                inputBar
            }
            .navigationTitle(session.title?.isEmpty == false ? session.title! : siteName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onDone { onDone() } else { session.close(); dismiss() }
                    }
                }
                if session.mode == .browser {
                    ToolbarItem(placement: .primaryAction) { tabMenu }
                } else {
                    ToolbarItem(placement: .primaryAction) { displaysMenu }
                }
            }
            .safeAreaInset(edge: .top) {
                // A desktop has no address or tabs; what it may have is no input.
                if session.mode == .browser {
                    addressBar
                } else if inputAvailable == false {
                    Label("View only \u{2014} fin-agentd on \(siteName) has no Accessibility permission",
                          systemImage: "eye")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(6).background(.bar)
                }
            }
        }
        .task { await gateThenOpen() }
        .onDisappear { if onDone == nil { session.close() } }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    // MARK: - Page

    @ViewBuilder
    private var page: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.9)
                if let frame = session.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in
                            tap(at: point, in: geometry.size, image: frame)
                        }
                        .gesture(scrollGesture(in: geometry.size, image: frame))
                        .accessibilityIdentifier("remoteBrowserFrame")
                }
                statusOverlay
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let gateFailed {
            ContentUnavailableView("Not unlocked", systemImage: "lock", description: Text(gateFailed))
        } else {
            switch session.state {
            case .idle, .waking:
                if session.frame == nil {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Waking \(siteName)\u{2019}s \(session.mode == .desktop ? "desktop" : "browser")\u{2026}")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("The first session after a quiet spell takes about a minute.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            case .connected:
                EmptyView()
            case .closed(let reason):
                ContentUnavailableView(
                    session.mode == .desktop ? "Desktop closed" : "Browser closed",
                    systemImage: session.mode == .desktop ? "display" : "globe.badge.chevron.backward",
                    description: Text(reason ?? "The session ended.")
                )
            }
        }
    }

    private func tap(at point: CGPoint, in viewSize: CGSize, image: CGImage) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let normalized = RemoteBrowserSession.normalizedPoint(point, in: viewSize, imageSize: imageSize) else { return }
        session.send(.tap(x: normalized.x, y: normalized.y))
    }

    /// Drag to scroll, the way a touchscreen user expects: content follows the finger,
    /// so dragging UP scrolls the page DOWN. Sent in steps rather than every point of the
    /// drag, since each is a round trip through the relay.
    private func scrollGesture(in viewSize: CGSize, image: CGImage) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dx = value.translation.width - lastDrag.width
                let dy = value.translation.height - lastDrag.height
                guard abs(dx) > 12 || abs(dy) > 12 else { return }
                lastDrag = value.translation
                let imageSize = CGSize(width: image.width, height: image.height)
                let at = RemoteBrowserSession.normalizedPoint(value.location, in: viewSize, imageSize: imageSize)
                    ?? CGPoint(x: 0.5, y: 0.5)
                // Scale finger points to page CSS pixels so a drag moves the page by
                // about the distance the finger traveled.
                let scale = session.viewport.width > 0 ? session.viewport.width / max(viewSize.width, 1) : 1
                session.send(.scroll(x: at.x, y: at.y, deltaX: -dx * scale, deltaY: -dy * scale))
            }
            .onEnded { _ in lastDrag = .zero }
    }

    // MARK: - Bars

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            TextField(session.url ?? "Address", text: $address)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onSubmit {
                    guard !address.isEmpty else { return }
                    session.send(.navigate(address))
                    address = ""
                }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Secure-by-default entry: what's typed here is usually a password, so
                // it never sits on screen in the clear. Sent whole via Input.insertText.
                SecureField("Type into the page", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendTyped)
                    .accessibilityIdentifier("remoteBrowserTyping")
                Button("Send", action: sendTyped)
                    .disabled(typed.isEmpty)
            }
            keyCarousel
        }
        .padding()
        .background(.bar)
        .disabled(session.state != .connected)
    }

    /// A horizontally scrollable row, so it holds every key worth having (modifiers,
    /// navigation, arrows) without crowding a phone-width screen — a real carousel,
    /// unlike the fixed four-button row it replaces. Same content on every platform:
    /// this is SwiftUI, not the terminal's UIKit-only `KeyboardAccessoryRow`.
    private var keyCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(RemoteBrowserProtocol.Modifier.allCases, id: \.self) { modifier in
                    modifierButton(modifier)
                }
                Divider().frame(height: 20)
                keyButton("delete.left", .backspace)
                keyButton("arrow.right.to.line", .tab)
                keyButton("return", .enter)
                keyButton("escape", .escape)
                keyButton("delete.forward", .forwardDelete)
                Divider().frame(height: 20)
                keyButton("arrow.left", .arrowLeft)
                keyButton("arrow.up", .arrowUp)
                keyButton("arrow.down", .arrowDown)
                keyButton("arrow.right", .arrowRight)
                Divider().frame(height: 20)
                textKeyButton("Home", .home)
                textKeyButton("End", .end)
                textKeyButton("PgUp", .pageUp)
                textKeyButton("PgDn", .pageDown)
                if session.mode == .desktop {
                    Divider().frame(height: 20)
                    systemShortcutButtons
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 2)
        }
    }

    private func modifierButton(_ modifier: RemoteBrowserProtocol.Modifier) -> some View {
        let armed = armedModifiers.contains(modifier)
        return Button {
            if armed { armedModifiers.remove(modifier) } else { armedModifiers.insert(modifier) }
        } label: {
            Text(modifierLabel(modifier))
        }
        .tint(armed ? Color.accentColor : nil)
        .accessibilityLabel("\(modifier.rawValue) \(armed ? "armed" : "")")
    }

    private func modifierLabel(_ modifier: RemoteBrowserProtocol.Modifier) -> String {
        switch modifier {
        case .shift: return "\u{21e7}"
        case .control: return "\u{2303}"
        case .option: return "\u{2325}"
        case .command: return "\u{2318}"
        }
    }

    private func keyButton(_ symbol: String, _ key: RemoteBrowserProtocol.SpecialKey) -> some View {
        Button(action: { sendKey(key) }) { Image(systemName: symbol) }
            .accessibilityLabel(key.rawValue)
    }

    /// A few keys have no crisp glyph worth guessing at — a label reads better than a
    /// wrong or missing SF Symbol.
    private func textKeyButton(_ title: String, _ key: RemoteBrowserProtocol.SpecialKey) -> some View {
        Button(title, action: { sendKey(key) })
            .font(.caption)
            .accessibilityLabel(key.rawValue)
    }

    /// Sends the key with whatever modifiers are armed, then clears them — a chord is
    /// one shot, not a mode you forget you left on.
    private func sendKey(_ key: RemoteBrowserProtocol.SpecialKey) {
        session.send(.key(key, modifiers: Array(armedModifiers)))
        armedModifiers.removeAll()
    }

    private func sendTyped() {
        guard !typed.isEmpty else { return }
        session.send(.text(typed))
        typed = ""
    }

    /// The desktop's system-level chords (Levi, 2026-09-23) — all ordinary modifier+key
    /// combinations `RemoteDesktopProtocol` already maps, sent directly rather than
    /// through the armed-modifier latch (a one-tap shortcut, not a two-step chord).
    /// Meaningless to a browser (macOS system UI, not page content), so desktop-only.
    private var systemShortcutButtons: some View {
        Group {
            // Default shortcut: Control+↑. A real button because it's the one command
            // Levi is likeliest to reach for on a screen he can't otherwise see the Dock of.
            shortcutButton("Mission Ctrl", .arrowUp, modifiers: [.control])
            // Default shortcuts: Control+←/→. Genuinely uncertain this reaches a
            // Space the way a physical key does — depends on the target's own Keyboard
            // Shortcuts settings and isn't provable from here; try it and see (Levi
            // flagged the same doubt, 2026-09-23).
            shortcutButton("Space ←", .arrowLeft, modifiers: [.control])
            shortcutButton("Space →", .arrowRight, modifiers: [.control])
            // Default shortcut: Control+↓.
            shortcutButton("App Windows", .arrowDown, modifiers: [.control])
            // Default shortcut: bare F11, no modifier.
            shortcutButton("Desktop", .f11, modifiers: [])
            // Default shortcut: Cmd+Shift+5 — opens the screenshot/recording toolbar,
            // the same one Screenshot.app's own on-screen button opens.
            shortcutButton("Screenshot", .digit5, modifiers: [.command, .shift])
            // Default shortcut: Cmd+Space.
            shortcutButton("Spotlight", .space, modifiers: [.command])
        }
    }

    private func shortcutButton(_ title: String, _ key: RemoteBrowserProtocol.SpecialKey, modifiers: [RemoteBrowserProtocol.Modifier]) -> some View {
        Button(title) { session.send(.key(key, modifiers: modifiers)) }
            .font(.caption)
    }

    @ViewBuilder
    private var displaysMenu: some View {
        if session.displays.count > 1 {
            Menu {
                ForEach(session.displays, id: \.id) { display in
                    Button {
                        session.send(.selectDisplay(display.id))
                    } label: {
                        Label(display.label, systemImage: display.id == session.selectedDisplay ? "checkmark" : "display")
                    }
                }
            } label: {
                Label("Displays", systemImage: "rectangle.on.rectangle")
            }
        }
    }

    @ViewBuilder
    private var tabMenu: some View {
        if session.tabs.count > 1 {
            Menu {
                ForEach(session.tabs, id: \.id) { tab in
                    Button {
                        session.send(.selectTab(tab.id))
                    } label: {
                        Label(tab.title.isEmpty ? tab.url : tab.title,
                              systemImage: tab.id == session.selectedTab ? "checkmark" : "globe")
                    }
                }
            } label: {
                Label("Tabs", systemImage: "square.on.square")
            }
        }
    }

    // MARK: - Gate

    private func gateThenOpen() async {
        // A tab coming back to front already has its session: no second Face ID
        // prompt for switching away to a terminal and back.
        guard session.state == .idle else { return }
        #if canImport(LocalAuthentication) && !os(tvOS)
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication, not ...WithBiometrics: falls back to the passcode,
        // so a device without (or with a failed) Face ID still opens after a real check.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            gateFailed = "This device has no passcode set, so the browser can\u{2019}t be unlocked here."
            ControlPlaneClient.logClientEvent(.remoteScreenGateFailed, detail: ["mode": session.mode.rawValue, "reason": "no_passcode"])
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Open \(siteName)\u{2019}s \(session.mode == .desktop ? "desktop" : "browser")"
            )
            guard ok else {
                gateFailed = "Authentication failed."
                ControlPlaneClient.logClientEvent(.remoteScreenGateFailed, detail: ["mode": session.mode.rawValue, "reason": "not_ok"])
                return
            }
        } catch {
            gateFailed = "Authentication was cancelled."
            ControlPlaneClient.logClientEvent(.remoteScreenGateFailed, detail: ["mode": session.mode.rawValue, "reason": "cancelled"])
            return
        }
        #endif
        session.open()
    }
}

/// Which remote screen a window or tab shows: a site's browser or its whole desktop.
/// Codable + Hashable because it is the `openWindow(value:)` payload.
struct RemoteScreenTarget: Codable, Hashable {
    let siteID: String
    let mode: RemoteBrowserSession.Mode

    /// The tab identity (`SessionManager.BrowserTab.id`).
    var tabID: String { "\(mode.rawValue):\(siteID)" }
}

/// A remote screen as its own window (`FinScene.remoteBrowser`). The window gets only
/// the target across the `openWindow` boundary, so it resolves the site from the shared
/// directory — and says so plainly if the site has gone away (a window restored at
/// launch for a site since retired or turned off).
struct RemoteBrowserWindowView: View {
    let target: RemoteScreenTarget?
    @ObservedObject private var directory = SiteDirectory.shared
    @State private var looked = false

    var body: some View {
        if let target, let site = directory.sites.first(where: { $0.siteId == target.siteID }) {
            RemoteBrowserView(site: site, mode: target.mode)
        } else {
            Group {
                if looked {
                    ContentUnavailableView(
                        "Unavailable", systemImage: target?.mode == .desktop ? "display" : "globe",
                        description: Text("That computer isn\u{2019}t offering this any more.")
                    )
                } else {
                    ProgressView()
                }
            }
            .task {
                await directory.refresh()
                looked = true
            }
        }
    }
}

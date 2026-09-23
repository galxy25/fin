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
    let site: FinSite
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: RemoteBrowserSession
    @State private var typed = ""
    @State private var address = ""
    @State private var gateFailed: String?
    @State private var lastDrag: CGSize = .zero

    init(site: FinSite) {
        self.site = site
        _session = StateObject(wrappedValue: RemoteBrowserSession(siteID: site.siteId))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                page
                Divider()
                inputBar
            }
            .navigationTitle(session.title?.isEmpty == false ? session.title! : site.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { session.close(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { tabMenu }
            }
            .safeAreaInset(edge: .top) { addressBar }
        }
        .task { await gateThenOpen() }
        .onDisappear { session.close() }
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
                        Text("Waking \(site.displayName)\u{2019}s browser\u{2026}")
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
                    "Browser closed", systemImage: "globe.badge.chevron.backward",
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
            HStack(spacing: 14) {
                keyButton("return", .enter)
                keyButton("arrow.right.to.line", .tab)
                keyButton("delete.left", .backspace)
                keyButton("escape", .escape)
                Spacer()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.bar)
        .disabled(session.state != .connected)
    }

    private func keyButton(_ symbol: String, _ key: RemoteBrowserProtocol.SpecialKey) -> some View {
        Button { session.send(.key(key)) } label: { Image(systemName: symbol) }
            .accessibilityLabel(key.rawValue)
    }

    private func sendTyped() {
        guard !typed.isEmpty else { return }
        session.send(.text(typed))
        typed = ""
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
        #if canImport(LocalAuthentication) && !os(tvOS)
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication, not ...WithBiometrics: falls back to the passcode,
        // so a device without (or with a failed) Face ID still opens after a real check.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            gateFailed = "This device has no passcode set, so the browser can\u{2019}t be unlocked here."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Open \(site.displayName)\u{2019}s browser"
            )
            guard ok else { gateFailed = "Authentication failed."; return }
        } catch {
            gateFailed = "Authentication was cancelled."
            return
        }
        #endif
        session.open()
    }
}

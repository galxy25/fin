import Foundation
import CoreGraphics
import ImageIO

/// The app's end of Remote Browser (docs/REMOTE-BROWSER.md): one live view of the Chrome
/// a site's Claude sessions use, with Levi's taps and typing sent back into it.
///
/// Rides the same relay as a terminal, through the same pinned `RelayWebSocket` (ATS
/// refuses the relay's self-signed certificate on URLSession inside an app bundle — see
/// that file), and the same wake-then-dial shape as `TerminalSession.runSiteRelay`: the
/// control-plane call both launches (or reuses) the relay and tells both ends its address.
/// What differs is only the payload, and that is `RemoteBrowserProtocol`, which the
/// daemon compiles too.
///
/// Also Remote Desktop's session (docs/VNC.md): the daemon streams the whole screen in
/// this same protocol, so only the command that opens it differs (`Mode`).
@MainActor
final class RemoteBrowserSession: ObservableObject {
    /// What the site streams. Codable/Hashable because it rides `openWindow(value:)`
    /// inside `RemoteScreenTarget`.
    enum Mode: String, Codable, Hashable {
        case browser
        case desktop
    }

    enum State: Equatable {
        case idle
        /// Relay launching / daemon dialing in / Chrome starting — the first session
        /// after a quiet spell spends most of a minute here, and that is normal.
        case waking
        case connected
        case closed(String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frame: CGImage?
    /// The page viewport in CSS pixels, from the latest frame.
    @Published private(set) var viewport: CGSize = .zero
    @Published private(set) var url: String?
    @Published private(set) var title: String?
    @Published private(set) var tabs: [RemoteBrowserProtocol.Tab] = []
    @Published private(set) var selectedTab: String?
    /// Desktop mode only ("choose displays" — Levi, 2026-09-23): every display the site
    /// can capture, and which one is showing.
    @Published private(set) var displays: [RemoteBrowserProtocol.Display] = []
    @Published private(set) var selectedDisplay: String?

    let siteID: String
    let mode: Mode
    private var socket: RelayWebSocket?
    private var sessionId: String?
    private var runTask: Task<Void, Never>?
    /// Same patience as the terminal: an on-demand relay needs about a minute to boot.
    private let connectAttempts = 45

    // MARK: - Telemetry (Levi, 2026-09-23: "thorough telemetry... to monitor and replay
    // usage for both debugging and evaling"). None of this is page content, keystrokes
    // or screenshots — those stay off the wire to any logging system by design (a
    // password typed here must never be more durable than the browser it was typed
    // into). What's captured is a session's SHAPE: when it opened and for how long, how
    // many frames it streamed, and a count of each input TYPE sent — enough to
    // reconstruct a timeline (a "replay" of what happened, not what was shown) and to
    // eval things like "how often does a session end in under 5 frames" without ever
    // holding anything sensitive. Emitted once at close via the existing client-events
    // channel (`ControlPlaneClient.logClientEvent`, CloudWatch-backed, the same one
    // TerminalSession uses) rather than a new store — see docs/REMOTE-BROWSER.md.
    private var openedAt: Date?
    private var connectedLogged = false
    private var frameCount = 0
    private var inputCounts: [String: Int] = [:]

    init(siteID: String, mode: Mode = .browser) {
        self.siteID = siteID
        self.mode = mode
    }

    func open() {
        guard runTask == nil else { return }
        let sessionId = (mode == .desktop ? "d-" : "b-") + UUID().uuidString.lowercased()
        self.sessionId = sessionId
        state = .waking
        openedAt = Date()
        frameCount = 0
        inputCounts = [:]
        connectedLogged = false
        runTask = Task { [weak self] in
            await self?.run(sessionId: sessionId)
        }
    }

    func close() {
        if let socket, let sessionId,
           let data = try? JSONSerialization.data(withJSONObject: ["action": "close", "sessionId": sessionId]) {
            Task { try? await socket.send(data); socket.cancel() }
        }
        runTask?.cancel()
        runTask = nil
        socket = nil
        logClosed(reason: nil)
        if case .closed = state {} else { state = .closed(nil) }
    }

    func send(_ input: RemoteBrowserProtocol.Input) {
        guard let socket, let sessionId,
              let data = try? JSONSerialization.data(withJSONObject: RemoteBrowserProtocol.inputFrame(sessionId: sessionId, input: input))
        else { return }
        if case .selectTab(let id) = input { selectedTab = id }
        if case .selectDisplay(let id) = input { selectedDisplay = id }
        inputCounts[Self.inputTypeName(input), default: 0] += 1
        Task { try? await socket.send(data) }
    }

    /// Fires once, whichever path closes the session first (`close()` or a relay-side
    /// "close"/socket-failure landing in `handle`) — never twice, so a duration or
    /// count is never double-reported for one session.
    private func logClosed(reason: String?) {
        guard let openedAt else { return }
        self.openedAt = nil
        var detail: [String: Any] = [
            "mode": mode.rawValue, "siteId": siteID,
            "durationSeconds": Int(Date().timeIntervalSince(openedAt)),
            "frameCount": frameCount, "connected": connectedLogged,
        ]
        if let reason { detail["reason"] = reason }
        if !inputCounts.isEmpty { detail["inputCounts"] = inputCounts }
        ControlPlaneClient.logClientEvent(.remoteScreenClosed, detail: detail)
    }

    private static func inputTypeName(_ input: RemoteBrowserProtocol.Input) -> String {
        switch input {
        case .tap: return "tap"
        case .scroll: return "scroll"
        case .text: return "text"
        case .key: return "key"
        case .navigate: return "navigate"
        case .selectTab: return "selectTab"
        case .selectDisplay: return "selectDisplay"
        }
    }

    // MARK: - Connection

    private func run(sessionId: String) async {
        let relay: ControlPlaneClient.RelayAddress
        let opened = mode == .desktop
            ? await ControlPlaneClient.openDesktopRelay(siteID, sessionId: sessionId)
            : await ControlPlaneClient.openBrowserRelay(siteID, sessionId: sessionId)
        switch opened {
        case .failure(let failure):
            state = .closed("Could not reach the control plane: \(failure)")
            return
        case .success(let address):
            relay = address
        }

        guard let openFrame = try? JSONSerialization.data(withJSONObject: [
            "action": "open", "sessionId": sessionId, "siteId": siteID,
        ]) else { return }

        var connected: RelayWebSocket?
        for attempt in 1...connectAttempts {
            guard !Task.isCancelled else { return }
            let candidate = RelayWebSocket(host: relay.relayHost, port: relay.relayPort)
            do {
                try await candidate.connect()
                try await candidate.send(openFrame)
                connected = candidate
                break
            } catch {
                candidate.cancel()
                if attempt == connectAttempts {
                    ControlPlaneClient.logClientEvent(.relayWSOpenFailed, detail: [
                        "mode": mode.rawValue, "siteId": siteID, "error": error.localizedDescription,
                    ])
                    state = .closed("The relay never came up.")
                    logClosed(reason: "relay never came up")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let socket = connected else { return }
        self.socket = socket
        ControlPlaneClient.logClientEvent(.relayWSOpen, detail: ["mode": mode.rawValue, "siteId": siteID, "sessionId": sessionId])

        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                ControlPlaneClient.logClientEvent(.relayWSReceiveFailed, detail: [
                    "mode": mode.rawValue, "siteId": siteID, "error": error.localizedDescription,
                ])
                if case .closed = state {} else { state = .closed("Disconnected.") }
                logClosed(reason: "socket receive failed")
                return
            }
            await handle(data)
        }
    }

    private func handle(_ data: Data) async {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String else { return }
        switch action {
        case "attached":
            if state == .waking { state = .connected }
        case "close":
            let reason = object["reason"] as? String
            state = .closed(reason)
            socket?.cancel()
            socket = nil
            logClosed(reason: reason ?? "closed by site")
        case "output":
            if let decoded = RemoteBrowserProtocol.Frame(relayFrame: object) {
                // JPEG decode off the main actor — at screencast rates it is the one
                // piece of this that could make scrolling the view stutter.
                let image = await Task.detached(priority: .userInitiated) {
                    Self.decodeJPEG(base64: decoded.jpegBase64)
                }.value
                guard let image else { return }
                frame = image
                frameCount += 1
                viewport = CGSize(width: decoded.width, height: decoded.height)
                url = decoded.url ?? url
                title = decoded.title ?? title
                if state != .connected { state = .connected }
                if !connectedLogged {
                    connectedLogged = true
                    ControlPlaneClient.logClientEvent(.remoteScreenOpened, detail: ["mode": mode.rawValue, "siteId": siteID])
                }
            } else if let list = RemoteBrowserProtocol.tabs(fromRelayFrame: object) {
                tabs = list.tabs
                selectedTab = list.selected ?? selectedTab
            } else if let list = RemoteBrowserProtocol.displays(fromRelayFrame: object) {
                displays = list.displays
                selectedDisplay = list.selected ?? selectedDisplay
            }
        default:
            break
        }
    }

    nonisolated static func decodeJPEG(base64: String) -> CGImage? {
        guard let bytes = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Geometry (pure, tested)

    /// Where a point in the view falls on the page, normalized 0…1 — or nil when it
    /// landed in the letterbox around the frame. The frame is shown aspect-FIT, so the
    /// displayed rect is centered with bars on two sides; a tap on a bar is a tap on
    /// nothing rather than a click at the page's edge.
    nonisolated static func normalizedPoint(_ point: CGPoint, in viewSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        let x = (point.x - origin.x) / shown.width
        let y = (point.y - origin.y) / shown.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

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
@MainActor
final class RemoteBrowserSession: ObservableObject {
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

    let siteID: String
    private var socket: RelayWebSocket?
    private var sessionId: String?
    private var runTask: Task<Void, Never>?
    /// Same patience as the terminal: an on-demand relay needs about a minute to boot.
    private let connectAttempts = 45

    init(siteID: String) {
        self.siteID = siteID
    }

    func open() {
        guard runTask == nil else { return }
        let sessionId = "b-" + UUID().uuidString.lowercased()
        self.sessionId = sessionId
        state = .waking
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
        if case .closed = state {} else { state = .closed(nil) }
    }

    func send(_ input: RemoteBrowserProtocol.Input) {
        guard let socket, let sessionId,
              let data = try? JSONSerialization.data(withJSONObject: RemoteBrowserProtocol.inputFrame(sessionId: sessionId, input: input))
        else { return }
        if case .selectTab(let id) = input { selectedTab = id }
        Task { try? await socket.send(data) }
    }

    // MARK: - Connection

    private func run(sessionId: String) async {
        let relay: ControlPlaneClient.RelayAddress
        switch await ControlPlaneClient.openBrowserRelay(siteID, sessionId: sessionId) {
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
                    state = .closed("The relay never came up.")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let socket = connected else { return }
        self.socket = socket

        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                if case .closed = state {} else { state = .closed("Disconnected.") }
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
            state = .closed(object["reason"] as? String)
            socket?.cancel()
            socket = nil
        case "output":
            if let decoded = RemoteBrowserProtocol.Frame(relayFrame: object) {
                // JPEG decode off the main actor — at screencast rates it is the one
                // piece of this that could make scrolling the view stutter.
                let image = await Task.detached(priority: .userInitiated) {
                    Self.decodeJPEG(base64: decoded.jpegBase64)
                }.value
                guard let image else { return }
                frame = image
                viewport = CGSize(width: decoded.width, height: decoded.height)
                url = decoded.url ?? url
                title = decoded.title ?? title
                if state != .connected { state = .connected }
            } else if let list = RemoteBrowserProtocol.tabs(fromRelayFrame: object) {
                tabs = list.tabs
                selectedTab = list.selected ?? selectedTab
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

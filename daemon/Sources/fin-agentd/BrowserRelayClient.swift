import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Remote Browser (docs/REMOTE-BROWSER.md): relays ONE Chrome on this Mac — the same
/// browser Claude's Playwright drives here — to the Fin app, so Levi can type a password,
/// approve 2FA, or clear a captcha himself, then hand the signed-in browser back.
///
/// Why this instead of a full desktop: it needs no Screen Recording, no Accessibility, no
/// TCC grant and no macOS service an MDM profile can switch off — the page is streamed by
/// Chrome's own DevTools Protocol (`Page.startScreencast`), and input goes back the same
/// way (`Input.dispatchMouseEvent`, `Input.insertText`). It also exposes the browser, not
/// the desktop, which is most of the security argument docs/VNC.md had to have.
///
/// Rides the terminal relay unchanged: frames are `output`, input is `input`, each with a
/// `kind` relay.py forwards verbatim and never reads (see `RemoteBrowserProtocol`).
///
/// Deliberately a SIBLING of `TerminalRelayClient`, not a refactor of it. That file is
/// incident-hardened (the 2026-09-21 URLSession self-heal) and has no tests; generalizing
/// it to carry this payload would put the working terminal path at risk to save lines.
/// The dial / self-heal / idle logic below follows it on purpose, so a fix to one reads
/// as a fix to both — fold them together once the terminal path has tests.
@MainActor
public final class BrowserRelayClient {
    /// Longer than the terminal's ten minutes: watching Claude drive a page, or reading a
    /// long 2FA email, produces no input for a while without being abandonment.
    static let idleTimeout: TimeInterval = 15 * 60
    static let connectAttempts = 45
    static let dialFailuresBeforeSelfHeal = 2
    /// How often the tab list is re-read while a session is open: Claude opens and closes
    /// tabs, and a tab the app is showing can disappear underneath it.
    static let tabRefreshInterval: TimeInterval = 3

    public struct Configuration: Equatable {
        public var port: Int
        /// nil = discover (`RemoteBrowserProtocol.findBrowser`).
        public var chromePath: String?
        public var profileDirectory: String
        public init(port: Int, chromePath: String?, profileDirectory: String) {
            self.port = port
            self.chromePath = chromePath
            self.profileDirectory = profileDirectory
        }
    }

    private let siteID: String
    private let siteToken: String
    private let controlPlaneURL: String?
    private let configuration: Configuration
    private var relaySession: URLSession
    /// Plain, unpinned: the DevTools endpoint is loopback `ws://`, with no certificate to pin.
    private let cdpSession = URLSession(configuration: .default)
    private let audit: (String) -> Void
    private var consecutiveDialFailures = 0

    private final class Session {
        let socket: URLSessionWebSocketTask
        var page: CDPPage?
        var targetID: String?
        var lastTabs: [RemoteBrowserProtocol.Tab] = []
        var idleTask: Task<Void, Never>?
        var tabTask: Task<Void, Never>?
        var droppedFrames = 0
        // Telemetry (Levi, 2026-09-23): a session's SHAPE, never its content — no page
        // text, no typed characters, no JPEG bytes leave this struct. `inputCounts` is
        // by TYPE only.
        let openedAt = Date()
        var framesSent = 0
        var inputCounts: [String: Int] = [:]
        var tabSwitches = 0
        init(socket: URLSessionWebSocketTask) { self.socket = socket }
    }

    private var sessions: [String: Session] = [:]

    public init(
        siteID: String, siteToken: String, controlPlaneURL: String?, configuration: Configuration,
        audit: @escaping (String) -> Void
    ) {
        self.siteID = siteID
        self.siteToken = siteToken
        self.controlPlaneURL = controlPlaneURL
        self.configuration = configuration
        self.relaySession = Self.freshRelaySession()
        self.audit = audit
    }

    private static func freshRelaySession() -> URLSession {
        URLSession(configuration: .default, delegate: RelayPinningDelegate(), delegateQueue: nil)
    }

    // MARK: - Open

    public func open(sessionId: String, relayHost: String, relayPort: Int) {
        // Logged on ENTRY, before any guard — see TerminalRelayClient.open for the
        // 2026-09-21 gap this closes ("did the command even arrive" must never be
        // inferred from silence).
        audit("[browser] browser-open \(sessionId): received (relay=\(relayHost):\(relayPort))")
        guard sessions[sessionId] == nil else {
            audit("[browser] browser-open \(sessionId): ignored — already relaying (duplicate command)")
            return
        }
        guard let url = URL(string: "wss://\(relayHost):\(relayPort)/") else {
            audit("[browser] browser-open \(sessionId): unusable relay address")
            return
        }
        dial(sessionId: sessionId, url: url, attemptsRemaining: Self.connectAttempts)
    }

    private func dial(sessionId: String, url: URL, attemptsRemaining: Int) {
        guard sessions[sessionId] == nil else { return }
        let socket = relaySession.webSocketTask(with: url)
        socket.resume()
        guard let attach = try? JSONSerialization.data(withJSONObject: ["action": "attach", "sessionId": sessionId]) else { return }
        socket.send(.data(attach)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let error else {
                    self.consecutiveDialFailures = 0
                    await self.startRelaying(sessionId: sessionId, socket: socket)
                    return
                }
                socket.cancel(with: .goingAway, reason: nil)
                guard attemptsRemaining > 1 else {
                    self.audit("[browser] \(sessionId): relay never came up — \(error.localizedDescription.prefix(160))")
                    self.consecutiveDialFailures += 1
                    if self.consecutiveDialFailures >= Self.dialFailuresBeforeSelfHeal {
                        self.audit("[browser] \(self.consecutiveDialFailures) consecutive dial failures — replacing the relay URLSession")
                        self.relaySession.invalidateAndCancel()
                        self.relaySession = Self.freshRelaySession()
                        self.consecutiveDialFailures = 0
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                self.dial(sessionId: sessionId, url: url, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func startRelaying(sessionId: String, socket: URLSessionWebSocketTask) async {
        guard sessions[sessionId] == nil else {
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        let session = Session(socket: socket)
        sessions[sessionId] = session
        receiveLoop(sessionId: sessionId)
        armIdleTimeout(sessionId: sessionId)

        guard await ensureBrowser() else {
            audit("[browser] \(sessionId): no browser — could not reach or launch Chrome on :\(configuration.port)")
            close(sessionId: sessionId, sendCloseFrame: true)
            return
        }
        await attachToTab(sessionId: sessionId, preferring: nil)
        session.tabTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tabRefreshInterval))
                guard !Task.isCancelled else { return }
                await self?.refreshTabs(sessionId: sessionId)
            }
        }
        audit("[browser] browser-open \(sessionId): streaming")
    }

    // MARK: - Browser

    private var devToolsBase: URL { URL(string: "http://127.0.0.1:\(configuration.port)")! }

    /// Reachable already (Chrome running with remote debugging — Claude's Playwright may
    /// have attached to it, or a previous session launched it), or launched now. Launched
    /// with real Chrome when it is installed (else Playwright's bundled browser — see
    /// `RemoteBrowserProtocol.browserCandidates`), and never with automation flags:
    /// Google refuses sign-in in a browser it sees as automated, which is the exact
    /// thing this feature exists to let Levi do. Resolved per launch, not at daemon
    /// start, so a browser installed afterwards is found without a restart.
    private func ensureBrowser() async -> Bool {
        if LoopbackPortProbe.isReachable(port: UInt16(configuration.port)) { return true }
        guard let browserPath = RemoteBrowserProtocol.findBrowser(
            configured: configuration.chromePath, home: NSHomeDirectory()
        ) else {
            audit("[browser] no browser to launch (configured: \(configuration.chromePath ?? "none"))")
            return false
        }
        try? FileManager.default.createDirectory(atPath: configuration.profileDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: browserPath)
        // A dedicated, persistent profile: sign-ins survive across sessions and daemon
        // restarts. Also required — Chrome refuses --remote-debugging-port on the
        // user's DEFAULT profile (Chrome 136+).
        process.arguments = [
            "--remote-debugging-port=\(configuration.port)",
            "--user-data-dir=\(configuration.profileDirectory)",
            "--no-first-run", "--no-default-browser-check",
            "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            audit("[browser] Chrome failed to launch: \(error.localizedDescription)")
            return false
        }
        audit("[browser] launched Chrome (pid \(process.processIdentifier)) on :\(configuration.port)")
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if LoopbackPortProbe.isReachable(port: UInt16(configuration.port)) { return true }
        }
        return false
    }

    private func listTargets() async -> [RemoteBrowserProtocol.Target] {
        guard let (data, _) = try? await cdpSession.data(from: devToolsBase.appendingPathComponent("json/list")) else { return [] }
        return RemoteBrowserProtocol.targets(fromJSONList: data)
    }

    private func attachToTab(sessionId: String, preferring preferred: String?) async {
        guard let session = sessions[sessionId] else { return }
        let targets = await listTargets()
        guard let target = RemoteBrowserProtocol.pickTab(targets, preferring: preferred),
              let wsString = target.webSocketDebuggerUrl, let wsURL = URL(string: wsString)
        else {
            audit("[browser] \(sessionId): no open tab to show")
            return
        }
        session.page?.stop()
        let page = CDPPage(url: wsURL, urlSession: cdpSession)
        session.page = page
        session.targetID = target.id
        page.onFrame = { [weak self] data, width, height in
            self?.forward(sessionId: sessionId, jpegBase64: data, width: width, height: height)
        }
        page.start()
        // THE fix for "stuck on the same page" / "won't navigate anywhere I type": Chrome
        // throttles (and eventually stops) a screencast on a tab whose window isn't
        // frontmost — confirmed live, 2026-09-23, by Levi ("if it isn't the active window
        // it doesn't work"). Page.bringToFront targets THIS target specifically, so it
        // also resolves the multi-window edge case without knowing which OS window a tab
        // lives in. Sent on every attach — a fresh session, a tab switch, and Claude
        // opening a new tab all attach again.
        page.bringToFront()
        sendTabs(sessionId: sessionId, targets: targets)
    }

    private func refreshTabs(sessionId: String) async {
        guard let session = sessions[sessionId] else { return }
        let targets = await listTargets()
        let viewable = RemoteBrowserProtocol.viewableTabs(targets)
        // The tab being shown was closed (Claude finished with it): follow to whatever is
        // now most recent rather than stream a dead page.
        if let current = session.targetID, !viewable.contains(where: { $0.id == current }) {
            await attachToTab(sessionId: sessionId, preferring: nil)
            return
        }
        // Re-asserted on this same 3s tick, not just on attach: Levi using the laptop
        // himself, Claude opening an unrelated app, or macOS's own window-cycling can all
        // steal front-most status from Chrome mid-session, and each one silently stalls
        // the screencast until this brings it back.
        session.page?.bringToFront()
        sendTabs(sessionId: sessionId, targets: targets)
    }

    private func sendTabs(sessionId: String, targets: [RemoteBrowserProtocol.Target]) {
        guard let session = sessions[sessionId] else { return }
        let tabs = RemoteBrowserProtocol.viewableTabs(targets).map {
            RemoteBrowserProtocol.Tab(id: $0.id, title: $0.title, url: $0.url)
        }
        guard tabs != session.lastTabs else { return }
        session.lastTabs = tabs
        send(sessionId: sessionId, frame: RemoteBrowserProtocol.tabsFrame(sessionId: sessionId, tabs: tabs, selected: session.targetID))
    }

    private func forward(sessionId: String, jpegBase64: String, width: Double, height: Double) {
        guard let session = sessions[sessionId] else { return }
        guard jpegBase64.utf8.count <= RemoteBrowserProtocol.maxFrameBase64Bytes else {
            // Over the relay's ceiling a frame would close the WHOLE session — drop it;
            // the next frame is a complete picture anyway.
            session.droppedFrames += 1
            if session.droppedFrames == 1 || session.droppedFrames % 50 == 0 {
                audit("[browser] \(sessionId): dropped \(session.droppedFrames) oversize frame(s)")
            }
            return
        }
        let tab = session.lastTabs.first { $0.id == session.targetID }
        session.framesSent += 1
        let frame = RemoteBrowserProtocol.Frame(jpegBase64: jpegBase64, width: width, height: height, url: tab?.url, title: tab?.title)
        send(sessionId: sessionId, frame: frame.relayFrame(sessionId: sessionId))
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

    // MARK: - Relay socket

    private func receiveLoop(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessions[sessionId] != nil else { return }
                switch result {
                case .failure(let error):
                    self.audit("[browser] \(sessionId): socket error — \(error.localizedDescription.prefix(160))")
                    self.close(sessionId: sessionId, sendCloseFrame: false)
                case .success(let message):
                    await self.handle(sessionId: sessionId, message: message)
                    self.receiveLoop(sessionId: sessionId)
                }
            }
        }
    }

    private func handle(sessionId: String, message: URLSessionWebSocketTask.Message) async {
        guard let session = sessions[sessionId] else { return }
        let data: Data
        switch message {
        case .data(let raw): data = raw
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String else { return }
        if action == "close" {
            close(sessionId: sessionId, sendCloseFrame: false)
            return
        }
        guard action == "input", let input = RemoteBrowserProtocol.input(fromRelayFrame: object) else { return }
        armIdleTimeout(sessionId: sessionId)
        session.inputCounts[Self.inputTypeName(input), default: 0] += 1
        if case .selectTab(let id) = input {
            session.tabSwitches += 1
            await attachToTab(sessionId: sessionId, preferring: id)
            return
        }
        guard let page = session.page else { return }
        for command in RemoteBrowserProtocol.cdpCommands(
            for: input, viewportWidth: page.viewportWidth, viewportHeight: page.viewportHeight
        ) {
            page.send(command)
        }
    }

    private func armIdleTimeout(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.idleTask?.cancel()
        session.idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.audit("[browser] \(sessionId): idle \(Int(Self.idleTimeout))s — closing")
            self?.close(sessionId: sessionId, sendCloseFrame: true)
        }
    }

    private func send(sessionId: String, frame: [String: Any]) {
        guard let session = sessions[sessionId], let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        session.socket.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.audit("[browser] \(sessionId): send failed — \(error.localizedDescription.prefix(160))")
            }
        }
    }

    private func close(sessionId: String, sendCloseFrame: Bool) {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        session.idleTask?.cancel()
        session.tabTask?.cancel()
        // Stops the screencast only. The browser itself stays up: it is Claude's too, and
        // its signed-in state is the whole point of having been here.
        session.page?.stop()
        if sendCloseFrame, let data = try? JSONSerialization.data(withJSONObject: ["action": "close", "sessionId": sessionId]) {
            session.socket.send(.data(data)) { _ in }
        }
        session.socket.cancel(with: .normalClosure, reason: nil)
        // One structured line per session (monitor/replay, Levi 2026-09-23): duration,
        // frames sent, dropped, tab switches, and input counts BY TYPE — the same shape
        // the app logs its half of, `record`ed into the site's own durable audit trail
        // (Logs/Traces), not just this process's stdout.
        let duration = Int(Date().timeIntervalSince(session.openedAt))
        audit("[browser] \(sessionId): closed — \(duration)s, \(session.framesSent) frames"
            + (session.droppedFrames > 0 ? " (\(session.droppedFrames) dropped)" : "")
            + ", \(session.tabSwitches) tab switches, input=\(session.inputCounts)")
    }
}

/// One DevTools connection to one page: runs the screencast, acks each frame (Chrome
/// stops sending after a few unacked ones), and sends input commands.
@MainActor
final class CDPPage {
    private let socket: URLSessionWebSocketTask
    private var nextID = 1
    private var stopped = false
    /// The page's CSS viewport, from the latest frame's metadata — what normalized input
    /// is scaled by. A plausible default until the first frame lands.
    private(set) var viewportWidth: Double = 1280
    private(set) var viewportHeight: Double = 800
    var onFrame: ((_ jpegBase64: String, _ width: Double, _ height: Double) -> Void)?

    /// JPEG at this quality and size stays well under the relay's frame budget for
    /// ordinary pages; the relay client still drops anything that doesn't.
    static let screencastParams: [String: AnyHashable] = [
        "format": "jpeg", "quality": 55, "maxWidth": 1280, "maxHeight": 1600, "everyNthFrame": 1,
    ]

    init(url: URL, urlSession: URLSession) {
        socket = urlSession.webSocketTask(with: url)
        // Screencast frames are large; the default 1 MiB receive ceiling is fine for a
        // 1280-wide JPEG but not for a tall retina one — give it room.
        socket.maximumMessageSize = 16 * 1024 * 1024
    }

    func start() {
        socket.resume()
        receive()
        send(.init("Page.enable"))
        send(.init("Page.startScreencast", Self.screencastParams))
    }

    /// See the call site in `attachToTab`: without this, Chrome throttles (and then
    /// stops) the screencast on any tab whose window isn't the frontmost one — the
    /// confirmed root cause of a session that streamed once and then went stale.
    func bringToFront() {
        send(.init("Page.bringToFront"))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        send(.init("Page.stopScreencast"))
        socket.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ command: RemoteBrowserProtocol.CDPCommand) {
        let message: [String: Any] = ["id": nextID, "method": command.method, "params": command.params]
        nextID += 1
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive() {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, case .success(let message) = result else { return }
                self.handle(message)
                self.receive()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let raw): data = raw
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["method"] as? String == "Page.screencastFrame",
              let params = object["params"] as? [String: Any],
              let frameData = params["data"] as? String else { return }
        // Ack FIRST, unconditionally: Chrome throttles and then stops the screencast
        // after a few unacknowledged frames, even ones this side decided to drop.
        if let ackID = params["sessionId"] as? Int {
            send(.init("Page.screencastFrameAck", ["sessionId": ackID]))
        }
        if let metadata = params["metadata"] as? [String: Any] {
            if let width = (metadata["deviceWidth"] as? NSNumber)?.doubleValue, width > 0 { viewportWidth = width }
            if let height = (metadata["deviceHeight"] as? NSNumber)?.doubleValue, height > 0 { viewportHeight = height }
        }
        onFrame?(frameData, viewportWidth, viewportHeight)
    }
}

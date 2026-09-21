import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Relays one interactive terminal — a local PTY attached to the caller's own tmux session,
/// via `LocalTerminalSession` — over a short-lived WebSocket to the terminal relay
/// (`scripts/cloud-agent/relay/relay.py`). Woken by a `terminal-open` site command
/// (`DaemonSiteClient.Command`, delivered on the next 20s heartbeat, per docs/SITES.md's
/// forced-command precedent), not held open continuously: a session's socket opens on
/// `open(sessionId:tmuxSession:relayHost:relayPort:)` and closes on a `close` frame, a
/// socket error, or 10 minutes with no input.
///
/// The relay used to be an API Gateway WebSocket API, and could not be: `URLSessionWebSocketTask`
/// cannot hold a connection to one (connect and first send succeed, the next receive fails
/// ENOTCONN, every time — see relay.py's header for the full repro). It is now an ordinary
/// WebSocket server on an instance the control plane launches per demand and which terminates
/// itself when idle, so this body still pays for a relay only while someone is looking at a
/// terminal — and the address, being new on every launch, arrives with the command rather than
/// living in config.
///
/// No SSH anywhere in this path: the daemon execs `tmux new-session -A` itself, exactly the
/// way `LocalTerminalSession` already does for the agent's own pane (see that file's header
/// for why — no sshd, no key, no login-shell auto-attach hazard), just against the caller's
/// own tmux session instead of Fin's private `-L fin` socket.
@MainActor
public final class TerminalRelayClient {
    static let idleTimeout: TimeInterval = 10 * 60

    private let siteID: String
    private let siteToken: String
    private let controlPlaneURL: String?
    private let urlSession: URLSession
    private let audit: (String) -> Void

    /// How many two-second dials the relay gets before this body gives up on a
    /// session. The relay is launched ON DEMAND by the same control-plane call
    /// that queued this command, so the first session after a quiet spell is
    /// dialing an instance that is still installing python — a refused
    /// connection for the first minute is the normal path, not a failure.
    static let connectAttempts = 45

    private final class RelaySession {
        let socket: URLSessionWebSocketTask
        let terminal: LocalTerminalSession
        var idleTask: Task<Void, Never>?

        init(socket: URLSessionWebSocketTask, terminal: LocalTerminalSession) {
            self.socket = socket
            self.terminal = terminal
        }
    }

    private var sessions: [String: RelaySession] = [:]

    public init(
        siteID: String, siteToken: String, controlPlaneURL: String? = nil,
        urlSession: URLSession? = nil, audit: @escaping (String) -> Void
    ) {
        self.siteID = siteID
        self.siteToken = siteToken
        self.controlPlaneURL = controlPlaneURL
        // Pinned by default: the relay has no name worth checking, so its
        // certificate IS its identity (see RelayCertificatePin).
        self.urlSession = urlSession
            ?? URLSession(configuration: .default, delegate: RelayPinningDelegate(), delegateQueue: nil)
        self.audit = audit
    }

    /// Best-effort breadcrumb to the same `/client-events` endpoint the app posts
    /// to (`kind` must match `CLIENT_EVENT_KINDS` in the control plane's
    /// `lambda.py`), so a session that dies on this body's end shows up next to
    /// the app's side of the same story instead of only in a local log file
    /// nobody but this Mac can read. Never awaited, never lets a failure here
    /// touch the relay it's reporting on.
    private func logClientEvent(_ kind: String, sessionId: String, detail: [String: Any] = [:]) {
        guard let controlPlaneURL, var components = URLComponents(string: controlPlaneURL) else { return }
        components.path += (components.path.hasSuffix("/") ? "" : "/") + "client-events"
        guard let url = components.url else { return }
        var body: [String: Any] = ["kind": kind]
        var fullDetail = detail
        fullDetail["sessionId"] = sessionId
        body["detail"] = fullDetail
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(siteToken)", forHTTPHeaderField: "authorization")
        request.setValue(siteID, forHTTPHeaderField: "X-Fin-Site")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        urlSession.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// Handles a `terminal-open` command's args. Idempotent — a duplicate open
    /// for a session already relaying is ignored, since the heartbeat that
    /// delivered the command may repeat it before the control plane sees this
    /// body connect.
    ///
    /// `relayHost`/`relayPort` come from the command rather than from config:
    /// the relay is an on-demand instance with a fresh address every launch,
    /// and taking it from the same control-plane call that told the app makes
    /// it impossible for the two sides to dial different relays.
    public func open(sessionId: String, tmuxSession: String, relayHost: String, relayPort: Int) {
        // ALWAYS the first thing this body does with the command, before any
        // guard can return early — so "did the command even arrive here" is
        // answered by the log/breadcrumb alone, never inferred from its
        // absence. Live gap (2026-09-21): every stage past this point already
        // logged on both success and failure, but nothing logged on ENTRY, so
        // a run of failed connects from the work laptop looked identical —
        // zero site-side events — whether `open` was never called at all, was
        // called and silently deduped by the guard below, or was called and
        // every dial attempt failed. `relay_state` is allow-listed
        // server-side (`CLIENT_EVENT_KINDS`) but was never actually emitted
        // by anything until now.
        audit("[relay] terminal-open \(sessionId): received (tmux=\(tmuxSession), relay=\(relayHost):\(relayPort))")
        logClientEvent("relay_state", sessionId: sessionId, detail: [
            "stage": "received", "tmuxSession": tmuxSession, "relayHost": relayHost,
        ])
        guard sessions[sessionId] == nil else {
            audit("[relay] terminal-open \(sessionId): ignored — already relaying (duplicate command)")
            return
        }
        guard let url = URL(string: "wss://\(relayHost):\(relayPort)/") else {
            audit("[relay] terminal-open \(sessionId): unusable relay address \(relayHost):\(relayPort)")
            logClientEvent("relay_ws_open_failed", sessionId: sessionId, detail: ["reason": "bad_relay_address"])
            return
        }
        dial(sessionId: sessionId, tmuxSession: tmuxSession, url: url, attemptsRemaining: Self.connectAttempts)
    }

    /// One dial attempt. A fresh task per attempt on purpose: once a
    /// `URLSessionWebSocketTask` has failed its connection there is nothing to
    /// retry ON — it has to be replaced, not resent.
    private func dial(sessionId: String, tmuxSession: String, url: URL, attemptsRemaining: Int) {
        guard sessions[sessionId] == nil else {
            audit("[relay] terminal-open \(sessionId): dial abandoned — session already relaying")
            return
        }
        if attemptsRemaining == Self.connectAttempts {
            audit("[relay] terminal-open \(sessionId): dialing \(url.host ?? "?"):\(url.port ?? 0)")
        }
        let socket = urlSession.webSocketTask(with: url)
        socket.resume()
        guard let attach = try? JSONSerialization.data(withJSONObject: [
            "action": "attach", "sessionId": sessionId,
        ]) else { return }
        // The attach send doubles as the reachability test: a relay still
        // booting refuses here, and the session has not been created yet, so
        // there is nothing to unwind before trying again.
        socket.send(.data(attach)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let error else {
                    self.startRelaying(sessionId: sessionId, tmuxSession: tmuxSession, socket: socket)
                    return
                }
                socket.cancel(with: .goingAway, reason: nil)
                guard attemptsRemaining > 1 else {
                    self.audit("[relay] \(sessionId): relay never came up — \(error.localizedDescription.prefix(160))")
                    self.logClientEvent("relay_ws_open_failed", sessionId: sessionId, detail: [
                        "reason": "relay_unreachable", "error": String(describing: error),
                    ])
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                self.dial(
                    sessionId: sessionId, tmuxSession: tmuxSession, url: url,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }

    /// The socket is up and attached: bring up the PTY and start pumping.
    private func startRelaying(sessionId: String, tmuxSession: String, socket: URLSessionWebSocketTask) {
        guard sessions[sessionId] == nil else {
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        let command = "exec tmux new-session -A -s \(Self.shellQuote(tmuxSession))"
        let terminal = LocalTerminalSession(configuration: LocalSessionConfiguration(connectCommand: command))
        let relay = RelaySession(socket: socket, terminal: terminal)
        sessions[sessionId] = relay

        terminal.onRawOutput = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.send(sessionId: sessionId, frame: [
                    "action": "output", "sessionId": sessionId, "data": data.base64EncodedString(),
                ])
            }
        }

        logClientEvent("relay_ws_open", sessionId: sessionId, detail: ["tmuxSession": tmuxSession])
        terminal.connect()
        armIdleTimeout(sessionId: sessionId)
        receiveLoop(sessionId: sessionId)
        audit("[relay] terminal-open \(sessionId): attaching tmux session \(tmuxSession)")
    }

    // MARK: - Socket loop

    /// No startup grace here any more. The old version retried the first
    /// `receive()` for six seconds because against API Gateway it ALWAYS
    /// failed once (ENOTCONN) even though the socket had just connected and
    /// sent — the retry was papering over the incompatibility this whole relay
    /// exists to escape. Against an ordinary WebSocket server the first
    /// receive works, so a failure here is now a real drop and is treated as
    /// one immediately rather than being sat on.
    private func receiveLoop(sessionId: String) {
        guard let relay = sessions[sessionId] else { return }
        relay.socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessions[sessionId] != nil else { return }
                switch result {
                case .failure(let error):
                    self.audit("[relay] \(sessionId): socket error — \(error.localizedDescription.prefix(160))")
                    self.logClientEvent("relay_ws_receive_failed", sessionId: sessionId, detail: ["error": String(describing: error)])
                    self.close(sessionId: sessionId, sendCloseFrame: false)
                case .success(let message):
                    self.handle(sessionId: sessionId, message: message)
                    self.receiveLoop(sessionId: sessionId)
                }
            }
        }
    }

    private func handle(sessionId: String, message: URLSessionWebSocketTask.Message) {
        guard let relay = sessions[sessionId] else { return }
        let data: Data
        switch message {
        case .data(let raw): data = raw
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = object["action"] as? String else { return }
        switch action {
        case "input":
            guard let base64 = object["data"] as? String, let bytes = Data(base64Encoded: base64) else { return }
            relay.terminal.sendAgentInput(String(decoding: bytes, as: UTF8.self))
            armIdleTimeout(sessionId: sessionId)
        case "resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { return }
            relay.terminal.resize(columns: cols, rows: rows)
        case "close":
            close(sessionId: sessionId, sendCloseFrame: false)
        default:
            break
        }
    }

    private func armIdleTimeout(sessionId: String) {
        guard let relay = sessions[sessionId] else { return }
        relay.idleTask?.cancel()
        relay.idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            self?.audit("[relay] \(sessionId): idle \(Int(Self.idleTimeout))s — closing")
            self?.close(sessionId: sessionId, sendCloseFrame: true)
        }
    }

    /// Only ever called on a socket that already completed its attach, so a
    /// failure is a real drop rather than a handshake still in flight — the
    /// retries this used to carry were the API Gateway workaround, removed
    /// with the rest of it.
    private func send(sessionId: String, frame: [String: Any]) {
        guard let relay = sessions[sessionId], let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        relay.socket.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.audit("[relay] \(sessionId): send failed — \(error.localizedDescription.prefix(160))")
            }
        }
    }

    private func close(sessionId: String, sendCloseFrame: Bool) {
        guard let relay = sessions.removeValue(forKey: sessionId) else { return }
        relay.idleTask?.cancel()
        if sendCloseFrame, let data = try? JSONSerialization.data(withJSONObject: ["action": "close", "sessionId": sessionId]) {
            relay.socket.send(.data(data)) { _ in }
        }
        relay.terminal.disconnect()
        relay.socket.cancel(with: .normalClosure, reason: nil)
        audit("[relay] \(sessionId): closed")
        logClientEvent("relay_closed", sessionId: sessionId, detail: ["sendCloseFrame": sendCloseFrame])
    }

    // MARK: - Helpers

    /// Single-quotes a tmux session name for `sh -c`, the same defensive posture
    /// `LocalTerminalSession`'s own connect commands are built with elsewhere in the daemon.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

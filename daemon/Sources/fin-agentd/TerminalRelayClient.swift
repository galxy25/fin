import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Relays one interactive terminal — a local PTY attached to the caller's own tmux session,
/// via `LocalTerminalSession` — over a short-lived WebSocket to the control plane's terminal
/// relay endpoint. Woken by a `terminal-open` site command (`DaemonSiteClient.Command`,
/// delivered on the next 20s heartbeat, per docs/SITES.md's forced-command precedent), not
/// held open continuously: a session's socket opens on `open(sessionId:tmuxSession:)` and
/// closes on a `close` frame, a socket error, or 10 minutes with no input. That keeps the
/// WebSocket API Gateway's connection-minute charge at zero between uses — this body pays
/// for the relay only while someone is actually looking at the terminal.
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
    private let relayURL: String
    private let urlSession: URLSession
    private let audit: (String) -> Void

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
        siteID: String, siteToken: String, relayURL: String,
        urlSession: URLSession = .shared, audit: @escaping (String) -> Void
    ) {
        self.siteID = siteID
        self.siteToken = siteToken
        self.relayURL = relayURL
        self.urlSession = urlSession
        self.audit = audit
    }

    /// Handles a `terminal-open` command's args (`sessionId`, `tmuxSession`). Idempotent —
    /// a duplicate open for a session already relaying is ignored, since the heartbeat that
    /// delivered the command may repeat it before the control plane sees this body connect.
    public func open(sessionId: String, tmuxSession: String) {
        guard sessions[sessionId] == nil else { return }
        guard let url = Self.webSocketURL(from: relayURL, siteID: siteID, siteToken: siteToken) else {
            audit("[relay] terminal-open \(sessionId): could not build a wss:// URL from \(relayURL)")
            return
        }
        // Query-string auth, not headers — see `Self.webSocketURL`'s doc comment.
        let socket = urlSession.webSocketTask(with: url)

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

        socket.resume()
        send(sessionId: sessionId, frame: ["action": "attach", "sessionId": sessionId])
        terminal.connect()
        armIdleTimeout(sessionId: sessionId)
        receiveLoop(sessionId: sessionId)
        audit("[relay] terminal-open \(sessionId): attaching tmux session \(tmuxSession)")
    }

    // MARK: - Socket loop

    /// `startupAttemptsRemaining` covers the same brief post-`resume()`
    /// handshake window `send(sessionId:frame:)` retries around: the very
    /// first `receive()` can fail with "Socket is not connected" before the
    /// WebSocket upgrade actually lands, and — unlike every later failure,
    /// which is a real drop worth tearing the session down for — that one is
    /// nothing having gone wrong yet. Only the FIRST receive gets this grace;
    /// once a message has come through, a subsequent failure is real.
    private func receiveLoop(sessionId: String, startupAttemptsRemaining: Int = 20) {
        guard let relay = sessions[sessionId] else { return }
        relay.socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessions[sessionId] != nil else { return }
                switch result {
                case .failure(let error):
                    guard startupAttemptsRemaining > 1 else {
                        self.audit("[relay] \(sessionId): socket error — \(error.localizedDescription.prefix(160))")
                        self.close(sessionId: sessionId, sendCloseFrame: false)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    self.receiveLoop(sessionId: sessionId, startupAttemptsRemaining: startupAttemptsRemaining - 1)
                case .success(let message):
                    self.handle(sessionId: sessionId, message: message)
                    self.receiveLoop(sessionId: sessionId, startupAttemptsRemaining: 1)
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

    /// `send(_:completionHandler:)` can fail with "Socket is not connected"
    /// when called in the brief window right after `resume()`, before the
    /// WebSocket handshake actually finishes — `open()` sends the first
    /// `attach` frame synchronously in that window. A few short retries ride
    /// out that window without the caller (or `open()`) needing to know
    /// whether the handshake has landed yet; a failure past the last retry is
    /// a real problem and still gets audited.
    private func send(sessionId: String, frame: [String: Any], attemptsRemaining: Int = 20) {
        guard let relay = sessions[sessionId], let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        relay.socket.send(.data(data)) { [weak self] error in
            guard let error else { return }
            guard attemptsRemaining > 1 else {
                Task { @MainActor [weak self] in
                    self?.audit("[relay] \(sessionId): send failed — \(error.localizedDescription.prefix(160))")
                }
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.send(sessionId: sessionId, frame: frame, attemptsRemaining: attemptsRemaining - 1)
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
    }

    // MARK: - Helpers

    /// Auth rides the query string (`?token=...&site=...`), not headers set on a
    /// `URLRequest`. `URLSessionWebSocketTask` has a real bug on this OS/Foundation:
    /// a handshake `URLRequest` carrying custom HTTP headers connects and even sends
    /// its first frame successfully, but the very next `receive()` fails immediately
    /// with ENOTCONN — reproduced with a minimal script against this exact endpoint,
    /// with no custom headers at all as the one thing that made it go away. The
    /// control plane's `_augment_websocket_query_auth` folds these back into headers
    /// server-side, so nothing else about the wire protocol changes.
    private static func webSocketURL(from httpish: String, siteID: String, siteToken: String) -> URL? {
        guard var components = URLComponents(string: httpish.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "token", value: siteToken))
        query.append(URLQueryItem(name: "site", value: siteID))
        components.queryItems = query
        return components.url
    }

    /// Single-quotes a tmux session name for `sh -c`, the same defensive posture
    /// `LocalTerminalSession`'s own connect commands are built with elsewhere in the daemon.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

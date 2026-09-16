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
        guard let url = Self.webSocketURL(from: relayURL) else {
            audit("[relay] terminal-open \(sessionId): could not build a wss:// URL from \(relayURL)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(siteToken)", forHTTPHeaderField: "authorization")
        request.setValue(siteID, forHTTPHeaderField: "X-Fin-Site")
        let socket = urlSession.webSocketTask(with: request)

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

    private func receiveLoop(sessionId: String) {
        guard let relay = sessions[sessionId] else { return }
        relay.socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.sessions[sessionId] != nil else { return }
                switch result {
                case .failure(let error):
                    self.audit("[relay] \(sessionId): socket error — \(error.localizedDescription.prefix(160))")
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
    }

    // MARK: - Helpers

    private static func webSocketURL(from httpish: String) -> URL? {
        guard var components = URLComponents(string: httpish.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        return components.url
    }

    /// Single-quotes a tmux session name for `sh -c`, the same defensive posture
    /// `LocalTerminalSession`'s own connect commands are built with elsewhere in the daemon.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

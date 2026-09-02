// Lean tvOS counterpart of fin/Session/SessionManager.swift: the session cache,
// credential resolution, and last-active tracking, without the agent machinery
// (runtimes, relay, watchdog) that the TV shell doesn't ship yet.
import Foundation

@MainActor
final class TVSessionManager: ObservableObject {
    @Published private(set) var sessions: [UUID: TVTerminalSession] = [:]
    @Published var activeServerID: UUID?

    /// Injected from FinTVApp — joins Server.keyID against KeyMetadata + Keychain.
    var resolveCredentials: (Server) -> ServerCredentials? = { _ in nil }

    func session(for serverID: UUID) -> TVTerminalSession {
        if let existing = sessions[serverID] { return existing }
        let session = TVTerminalSession(serverID: serverID)
        sessions[serverID] = session
        return session
    }

    /// The session remote input (iPhone companion) should land in: the active one.
    var activeSession: TVTerminalSession? {
        activeServerID.flatMap { sessions[$0] }
    }

    func open(_ server: Server) {
        activeServerID = server.id
        let session = session(for: server.id)
        guard session.state == .disconnected else { return }
        guard let credentials = resolveCredentials(server) else {
            session.reportMissingCredentials()
            return
        }
        session.connect(server: server, credentials: credentials)
    }

    /// Foreground resume: the socket may have died while the app was suspended.
    func resumeActiveSessionIfNeeded(servers: [Server]) {
        guard let id = activeServerID,
              let session = sessions[id],
              !session.isConnected,
              session.state == .connected || session.state == .disconnected,
              let server = servers.first(where: { $0.id == id }),
              let credentials = resolveCredentials(server) else { return }
        session.markNeedsReconnect()
        session.connect(server: server, credentials: credentials)
    }

    func close(_ serverID: UUID) {
        sessions[serverID]?.disconnect()
        sessions[serverID] = nil
        if activeServerID == serverID {
            activeServerID = nil
        }
    }
}

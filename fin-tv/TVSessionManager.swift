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

    /// The control-plane endpoint and session token Sign in with Apple earned this TV — what a
    /// `.siteRelay` server needs INSTEAD of an SSH key. Nil until the TV is signed in.
    var relayLogin: () -> (endpoint: String, token: String)? = { nil }

    /// A relay server has no key and no address: it names a Fin computer, and the control plane
    /// relays a PTY through that computer's own outbound channel.
    private func relayTarget(for server: Server, session: TVTerminalSession) -> TVTerminalSession.RelayTarget? {
        guard let siteID = server.relaySiteId, !siteID.isEmpty else {
            session.reportRelayUnavailable("No Fin computer is selected for this server. Choose one in Fin on your iPhone or Mac.")
            return nil
        }
        guard let login = relayLogin() else {
            session.reportRelayUnavailable("Sign in with Apple on this Apple TV (top of the server list) to connect through Fin's relay.")
            return nil
        }
        return TVTerminalSession.RelayTarget(server: server, siteID: siteID, endpoint: login.endpoint, token: login.token)
    }

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
        switch server.transport {
        case .siteRelay:
            if let target = relayTarget(for: server, session: session) { session.connectSiteRelay(target) }
        case .direct:
            guard let credentials = resolveCredentials(server) else {
                session.reportMissingCredentials()
                return
            }
            session.connect(server: server, credentials: credentials)
        }
    }

    /// Foreground resume: the socket may have died while the app was suspended.
    func resumeActiveSessionIfNeeded(servers: [Server]) {
        guard let id = activeServerID,
              let session = sessions[id],
              !session.isConnected,
              session.state == .connected || session.state == .disconnected,
              let server = servers.first(where: { $0.id == id }) else { return }
        switch server.transport {
        case .siteRelay:
            guard let target = relayTarget(for: server, session: session) else { return }
            session.markNeedsReconnect()
            session.connectSiteRelay(target)
        case .direct:
            guard let credentials = resolveCredentials(server) else { return }
            session.markNeedsReconnect()
            session.connect(server: server, credentials: credentials)
        }
    }

    func close(_ serverID: UUID) {
        sessions[serverID]?.disconnect()
        sessions[serverID] = nil
        if activeServerID == serverID {
            activeServerID = nil
        }
    }
}

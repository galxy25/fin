import Foundation

@MainActor
final class SessionManager: ObservableObject {
    private static let lastActiveKey = "lastActiveServerID"
    private static let lastActiveTouchedAtKey = "lastActiveServerTouchedAt"

    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    @Published var activeServerID: UUID? {
        didSet {
            // Restoring the persisted value at launch must not stamp "now" as the
            // touched-at time — that would always beat a markdown file's real
            // last-opened time and defeat RootView's actual-recency comparison.
            guard !isRestoringFromStorage else { return }
            if let activeServerID {
                UserDefaults.standard.set(activeServerID.uuidString, forKey: Self.lastActiveKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastActiveTouchedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastActiveKey)
                UserDefaults.standard.removeObject(forKey: Self.lastActiveTouchedAtKey)
            }
        }
    }

    private var isRestoringFromStorage = false

    var resolveCredentials: (Server) -> ServerCredentials? = { _ in nil }
    var onCapturedClipping: (String) -> Void = { _ in }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.lastActiveKey),
           let uuid = UUID(uuidString: stored) {
            isRestoringFromStorage = true
            activeServerID = uuid
            isRestoringFromStorage = false
        }
    }

    func session(for server: Server) -> TerminalSession {
        if let existing = sessions[server.id] {
            return existing
        }
        let session = TerminalSession(serverID: server.id)
        session.onCapturedClipping = { [weak self] text in
            self?.onCapturedClipping(text)
        }
        sessions[server.id] = session
        return session
    }

    @discardableResult
    func open(_ server: Server) -> TerminalSession {
        activeServerID = server.id
        let session = session(for: server)
        guard session.state == .disconnected else { return session }
        guard let credentials = resolveCredentials(server) else {
            session.reportMissingCredentials()
            return session
        }
        session.connect(server: server, credentials: credentials)
        return session
    }

    func resumeActiveSessionIfNeeded(servers: [Server]) {
        guard let activeServerID, let session = sessions[activeServerID] else { return }
        guard !session.isConnected, session.state == .connected || session.state == .disconnected else { return }
        guard let server = servers.first(where: { $0.id == activeServerID }) else { return }
        guard let credentials = resolveCredentials(server) else { return }
        session.markNeedsReconnect()
        session.connect(server: server, credentials: credentials)
    }

    func close(_ serverID: UUID) {
        sessions[serverID]?.disconnect()
        sessions.removeValue(forKey: serverID)
        if activeServerID == serverID {
            activeServerID = nil
        }
    }
}

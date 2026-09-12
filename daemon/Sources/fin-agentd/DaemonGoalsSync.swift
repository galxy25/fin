import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's half of the shared goals ledger (docs/SITES.md §8): pull
/// `GET /agents/{agent}/goals`, three-way merge into the local store, push with
/// `If-Match` when the local document changed, and on a 412 merge against the
/// current version and retry. Runs after every goal mutation (debounced) and on
/// a slow tick, so a freshly launched cloud body inherits the iMac's mission on
/// its first turn and a goal closed on one body closes everywhere.
///
/// State in `goals-sync.json` beside the ledger: the last version pulled and
/// the document at that version (the merge base), so a restart resumes with a
/// real base instead of a two-way union.
actor DaemonGoalsSync {
    static let requestTimeout: TimeInterval = 10
    static let tickInterval: TimeInterval = 60
    static let debounce: TimeInterval = 2
    static let failureAuditWindow: TimeInterval = 5 * 60

    struct State: Codable {
        var version: Int = 0
        var base: LedgerDocument?
    }

    private let endpointURL: String
    private let token: String
    private let siteID: String?
    private let agentName: String
    private let store: GoalsLedgerStore
    private let statePath: String
    private let audit: @Sendable (String) -> Void
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private var state: State
    private var lastSyncAt: Date?
    private var pending: Task<Void, Never>?
    private var lastFailureAuditAt: [String: Date] = [:]
    private(set) var lastOutcome: String = "never"

    init(endpointURL: String, token: String, siteID: String?, agentName: String,
         store: GoalsLedgerStore, statePath: String, audit: @escaping @Sendable (String) -> Void) {
        self.endpointURL = endpointURL
        self.token = token
        self.siteID = siteID
        self.agentName = agentName
        self.store = store
        self.statePath = statePath
        self.audit = audit
        self.state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))) ?? State()
    }

    func setTransport(_ transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.transport = transport
    }

    /// Debounced: several tool calls in one turn become one round trip.
    func syncSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounce))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func tickIfDue(now: Date = Date()) async {
        if let lastSyncAt, now.timeIntervalSince(lastSyncAt) < Self.tickInterval { return }
        await sync()
    }

    @discardableResult
    func sync() async -> String {
        lastSyncAt = Date()
        guard let remote = await pull() else { return finish("pull failed") }
        let local = await store.document
        var known = state.version
        var base = state.base
        if remote.version > known {
            let merged = GoalsLedgerSync.merge(base: base, local: local, remote: remote.document ?? LedgerDocument())
            if GoalsLedgerSync.fingerprint(merged) != GoalsLedgerSync.fingerprint(local) {
                do { try await store.replace(merged) } catch { return finish("local write failed") }
            }
            known = remote.version
            base = remote.document
        }
        var current = await store.document
        let baseFingerprint = GoalsLedgerSync.fingerprint(base ?? LedgerDocument())
        var attempts = 0
        while GoalsLedgerSync.fingerprint(current) != baseFingerprint || (known == 0 && !current.goals.isEmpty) {
            attempts += 1
            guard attempts <= 3 else { return finish("conflict", version: known, base: base) }
            switch await push(current, ifMatch: known) {
            case .accepted(let version):
                known = version
                base = current
                return finish("pushed v\(version)", version: known, base: base)
            case .conflict(let theirs):
                let merged = GoalsLedgerSync.merge(base: base, local: current, remote: theirs.document ?? LedgerDocument())
                do { try await store.replace(merged) } catch { return finish("local write failed") }
                known = theirs.version
                base = theirs.document
                current = merged
            case .failed:
                return finish("push failed", version: known, base: base)
            }
        }
        return finish("in sync v\(known)", version: known, base: base)
    }

    private func finish(_ outcome: String, version: Int? = nil, base: LedgerDocument? = nil) -> String {
        if let version {
            state.version = version
            state.base = base
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
            }
        }
        if outcome != lastOutcome {
            audit("[goals-sync] \(outcome)")
            lastOutcome = outcome
        }
        return outcome
    }

    // MARK: - Transport

    private enum PushResult { case accepted(Int), conflict(GoalsLedgerSync.Remote), failed }

    private func pull() async -> GoalsLedgerSync.Remote? {
        guard let request = request("GET", path: "/agents/\(slug)/goals", body: nil) else { return nil }
        do {
            let (data, response) = try await transport(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                registerFailure("[goals-sync] pull failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return GoalsLedgerSync.decodeRemote(data)
        } catch {
            registerFailure("[goals-sync] pull unreachable: \(error.localizedDescription.prefix(120))")
            return nil
        }
    }

    private func push(_ document: LedgerDocument, ifMatch: Int) async -> PushResult {
        guard var request = request("PUT", path: "/agents/\(slug)/goals", body: GoalsLedgerSync.encodeForPut(document)) else { return .failed }
        request.setValue(String(ifMatch), forHTTPHeaderField: "If-Match")
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let version = object["version"] as? Int {
                return .accepted(version)
            }
            if status == 412, let theirs = GoalsLedgerSync.decodeRemote(data) {
                return .conflict(theirs)
            }
            registerFailure("[goals-sync] push failed: HTTP \(status)")
            return .failed
        } catch {
            registerFailure("[goals-sync] push unreachable: \(error.localizedDescription.prefix(120))")
            return .failed
        }
    }

    private var slug: String {
        agentName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentName
    }

    private func request(_ method: String, path: String, body: Data?) -> URLRequest? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        if let siteID { request.setValue(siteID, forHTTPHeaderField: "X-Fin-Site") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func registerFailure(_ line: String) {
        let key = String(line.prefix(40))
        let now = Date()
        if let last = lastFailureAuditAt[key], now.timeIntervalSince(last) < Self.failureAuditWindow { return }
        lastFailureAuditAt[key] = now
        audit(line)
    }
}

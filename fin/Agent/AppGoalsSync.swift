import Foundation

/// The app's half of the shared goals ledger (docs/SITES.md §8): pull
/// `GET /agents/{agent}/goals`, three-way merge into this device's ledger file
/// (`GoalsLedgerLocation.fileURL`), push with `If-Match` when the local document
/// differs, and on 412 merge against the current version. The merge is the
/// shared pure `GoalsLedgerSync`, so the app and every daemon run one rule.
///
/// The agent is whichever local agent is named "Fin" — the design's one
/// conversation — falling back to the first hosted agent's name the caller
/// supplies. State (last version + merge base) lives beside the ledger file.
@MainActor
final class AppGoalsSync {
    static let minInterval: TimeInterval = 5 * 60

    struct State: Codable {
        var version = 0
        var base: LedgerDocument?
    }

    var agentName = "Fin"
    private var lastSyncAt: Date?
    private(set) var lastOutcome = "never"
    private let store = GoalsLedgerStore(fileURL: GoalsLedgerLocation.fileURL)
    private var stateURL: URL {
        GoalsLedgerLocation.fileURL.deletingLastPathComponent().appendingPathComponent("goals-sync.json")
    }

    func syncIfDue(now: Date = Date()) async {
        guard CloudControlPlaneConfig.isConfigured else { return }
        if let lastSyncAt, now.timeIntervalSince(lastSyncAt) < Self.minInterval { return }
        lastSyncAt = now
        await sync()
    }

    @discardableResult
    func sync() async -> String {
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        _ = try? await store.load()
        guard case .success((let status, let data)) = await ControlPlaneClient.perform(
            ControlPlaneClient.request("GET", path: "/agents/\(slug)/goals")
        ), status == 200, let remote = GoalsLedgerSync.decodeRemote(data) else {
            return finish("pull failed")
        }
        let local = await store.document
        if remote.version > state.version {
            let merged = GoalsLedgerSync.merge(base: state.base, local: local, remote: remote.document ?? LedgerDocument())
            if GoalsLedgerSync.fingerprint(merged) != GoalsLedgerSync.fingerprint(local) {
                try? await store.replace(merged)
            }
            state.version = remote.version
            state.base = remote.document
        }
        var current = await store.document
        var attempts = 0
        while GoalsLedgerSync.fingerprint(current) != GoalsLedgerSync.fingerprint(state.base ?? LedgerDocument())
            || (state.version == 0 && !current.goals.isEmpty) {
            attempts += 1
            guard attempts <= 3 else { break }
            guard var request = ControlPlaneClient.request("PUT", path: "/agents/\(slug)/goals"),
                  let body = GoalsLedgerSync.encodeForPut(current) else { break }
            request.setValue(String(state.version), forHTTPHeaderField: "If-Match")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard case .success((let putStatus, let putData)) = await ControlPlaneClient.perform(request) else { break }
            if putStatus == 200, let object = (try? JSONSerialization.jsonObject(with: putData)) as? [String: Any],
               let version = object["version"] as? Int {
                state.version = version
                state.base = current
                break
            }
            if putStatus == 412, let theirs = GoalsLedgerSync.decodeRemote(putData) {
                let merged = GoalsLedgerSync.merge(base: state.base, local: current, remote: theirs.document ?? LedgerDocument())
                try? await store.replace(merged)
                state.version = theirs.version
                state.base = theirs.document
                current = merged
                continue
            }
            break
        }
        if let encoded = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: stateURL, options: .atomic)
        }
        return finish("in sync v\(state.version)")
    }

    private var slug: String {
        agentName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentName
    }

    private func finish(_ outcome: String) -> String {
        lastOutcome = outcome
        return outcome
    }
}

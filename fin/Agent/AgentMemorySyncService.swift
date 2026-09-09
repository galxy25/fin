import Foundation
import SwiftData

/// Keeps local `AgentMemory` rows and the control plane's per-agent `/memory` document in
/// sync, so "the memory is something that both the client side and cloud agents should
/// keep in sync" holds in both directions — a fact the daemon's `remember` tool learns
/// shows up here, and a fact this device's `remember` tool learns shows up wherever the
/// daemon (or another device) next pulls.
///
/// Two independent halves, run back to back on every pass:
/// - **Push**: local episodic rows THIS device authored (`originDeviceID8 ==
///   DeviceIdentity.short`) whose `updatedAt` is newer than the last confirmed push,
///   POSTed one at a time, oldest first — stops at the first failure so the watermark
///   only ever advances past rows the control plane actually accepted.
/// - **Pull**: GETs the whole document and upserts every entry NOT authored by this
///   device into the local store, keyed by a local id deterministically derived from the
///   entry's ledger id (`localID(forLedgerID:)`) rather than `conversationID` — a
///   daemon-authored entry carries no conversation grouping (one `remember` call is one
///   entry there), so `MemoryStore.saveEpisodic`'s conversationID upsert doesn't apply.
///
/// Modeled on `AgentRelayApplier`'s per-agent UserDefaults watermark and
/// `AgentWatchdog`'s floor/pacing pair, not on its CloudKit observer — this rides the
/// control plane over HTTP, so callers drive it explicitly at the same two trigger points
/// `AgentRuntime`'s own consolidation floor uses: turn finish and the watchdog tick.
@MainActor
final class AgentMemorySyncService {
    /// Floor between sync passes for one agent — cheap enough to ride the 5s watchdog
    /// tick without hammering the control plane on every beat.
    static let minSyncInterval: TimeInterval = 60
    static let requestTimeout: TimeInterval = 10
    /// Rows pushed per pass — generous headroom over the common case (one dirty row: the
    /// currently open conversation), while bounding one sync tick's work.
    static let maxPushPerPass = 20
    /// Same throttle shape as the daemon's control-plane clients: one audit line per
    /// window per distinct failure, not one per tick.
    static let failureAuditWindow: TimeInterval = 5 * 60

    private let context: ModelContext
    private let deviceID8: String
    private let defaults: UserDefaults
    var transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// Routes a line into the agent's own visible trail when a live runtime exists for
    /// it — "we shouldn't be hiding away what the cloud agent is up to" applies to this
    /// device's own sync activity too. A no-op default; `SessionManager` wires the real
    /// one to whichever runtime is currently live for the id.
    var audit: (_ agentID: UUID, _ line: String) -> Void = { _, _ in }

    private var lastSyncAt: [UUID: Date] = [:]
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var lastFailureAuditAt: [String: Date] = [:]

    /// Ceiling between app-open-triggered profile syncs — Levi: "compaction should
    /// happen by the app whenever I open it... no more frequently than every 15
    /// minutes." Not per-agent (the profile isn't agent-scoped) and in-memory only
    /// (matching every other pacing stamp on this type) — a cold launch always syncs
    /// once; this ceiling only stops repeat triggers within one running session.
    static let profileSyncCeiling: TimeInterval = 15 * 60
    private static let lastPushedProfileKey = "fin.memory.profile.lastPushed"

    private var lastProfileSyncAt: Date?
    private var profileSyncTask: Task<Void, Never>?

    init(context: ModelContext, deviceID8: String = DeviceIdentity.short, defaults: UserDefaults = .standard) {
        self.context = context
        self.deviceID8 = deviceID8
        self.defaults = defaults
    }

    /// Kicks one pull+push pass for `agentID`, paced at `minSyncInterval` and coalesced
    /// against an already-running pass — the same "cheap enough to call from every tick"
    /// contract `applyPending`/`consolidateIfDailyFloorDue` already carry. A silent no-op
    /// with no control plane configured: this feature simply does nothing on a device
    /// that never set one up.
    func syncIfDue(agentID: UUID, agentName: String, now: Date = Date()) {
        guard CloudControlPlaneConfig.isConfigured else { return }
        guard syncTasks[agentID] == nil else { return }
        if let last = lastSyncAt[agentID], now.timeIntervalSince(last) < Self.minSyncInterval { return }
        lastSyncAt[agentID] = now
        syncTasks[agentID] = Task { [weak self] in
            await self?.sync(agentID: agentID, agentName: agentName)
            self?.syncTasks[agentID] = nil
        }
    }

    func sync(agentID: UUID, agentName: String) async {
        await push(agentID: agentID, agentName: agentName)
        await pull(agentID: agentID, agentName: agentName)
    }

    // MARK: - Push

    private static func lastPushedKey(agentID: UUID) -> String {
        "fin.memory.sync.lastPushed.\(agentID.uuidString.lowercased())"
    }

    private func push(agentID: UUID, agentName: String) async {
        let watermark = defaults.object(forKey: Self.lastPushedKey(agentID: agentID)) as? Date ?? .distantPast
        let kind = MemoryKind.episodic.rawValue
        let deviceID8 = self.deviceID8
        var descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> {
                $0.kindRaw == kind && $0.agentID == agentID
                    && $0.originDeviceID8 == deviceID8 && $0.updatedAt > watermark
            },
            sortBy: [SortDescriptor(\AgentMemory.updatedAt, order: .forward)]
        )
        descriptor.fetchLimit = Self.maxPushPerPass
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }

        var newWatermark = watermark
        for row in rows {
            guard await pushOne(row, agentID: agentID, agentName: agentName) else { break }
            newWatermark = row.updatedAt
        }
        if newWatermark > watermark {
            defaults.set(newWatermark, forKey: Self.lastPushedKey(agentID: agentID))
        }
    }

    private func pushOne(_ row: AgentMemory, agentID: UUID, agentName: String) async -> Bool {
        guard var httpRequest = request(path: "/memory", method: "POST") else { return false }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var object: [String: Any] = [
            "agent": agentName,
            "id": Self.ledgerID(forLocalID: row.id),
            "agentId": agentID.uuidString,
            "kind": "episodic",
            "title": row.title,
            "content": row.content,
            "createdAt": Self.iso(row.createdAt),
            "updatedAt": Self.iso(row.updatedAt),
            "originDevice8": deviceID8,
        ]
        if let conversationID = row.conversationID { object["conversationId"] = conversationID.uuidString }
        if !row.tags.isEmpty { object["tags"] = row.tags }
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return false }
        httpRequest.httpBody = body
        do {
            let (_, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure(agentID: agentID, "[memory] push failed: HTTP \(status)")
                return false
            }
            return true
        } catch {
            registerFailure(agentID: agentID, "[memory] push failed: could not reach the control plane")
            return false
        }
    }

    // MARK: - Pull

    private func pull(agentID: UUID, agentName: String) async {
        guard let encodedName = agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let httpRequest = request(path: "/memory?agent=\(encodedName)", method: "GET")
        else { return }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure(agentID: agentID, "[memory] pull failed: HTTP \(status)")
                return
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entries = object["entries"] as? [[String: Any]]
            else { return }
            var applied = 0
            for entry in entries where apply(entry, agentID: agentID) {
                applied += 1
            }
            if applied > 0 {
                try? context.save()
                audit(agentID, "[memory] synced \(applied) entr\(applied == 1 ? "y" : "ies") from the control plane")
            }
        } catch {
            registerFailure(agentID: agentID, "[memory] pull failed: could not reach the control plane")
        }
    }

    /// One pulled entry applied into the local store. Returns whether it changed
    /// anything (a fresh insert or an update to an existing row) — this device's own
    /// entries (already authoritative locally) and non-episodic entries are skipped
    /// without counting.
    private func apply(_ entry: [String: Any], agentID: UUID) -> Bool {
        guard let entryID = entry["id"] as? String, !entryID.isEmpty,
              (entry["kind"] as? String ?? "episodic") == "episodic",
              let title = entry["title"] as? String,
              let content = entry["content"] as? String
        else { return false }
        let originDevice8 = entry["originDevice8"] as? String
        guard originDevice8 != deviceID8 else { return false }

        let updatedAt = Self.parseISO(entry["updatedAt"] as? String) ?? Date()
        let createdAt = Self.parseISO(entry["createdAt"] as? String) ?? updatedAt
        let localID = Self.localID(forLedgerID: entryID)
        let safeTitle = MemoryRedactor.redact(title)
        let safeContent = MemoryRedactor.redact(content)
        let tags = entry["tags"] as? String ?? ""

        var descriptor = FetchDescriptor<AgentMemory>(predicate: #Predicate<AgentMemory> { $0.id == localID })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            guard updatedAt > existing.updatedAt else { return false }
            existing.title = safeTitle
            existing.content = safeContent
            existing.tags = tags
            existing.updatedAt = updatedAt
            existing.originDeviceID8 = originDevice8
            return true
        }

        let record = AgentMemory(
            kind: .episodic,
            agentID: (entry["agentId"] as? String).flatMap { UUID(uuidString: $0) } ?? agentID,
            conversationID: (entry["conversationId"] as? String).flatMap { UUID(uuidString: $0) },
            title: safeTitle,
            content: safeContent,
            tags: tags,
            startedAt: createdAt
        )
        record.id = localID
        record.createdAt = createdAt
        record.updatedAt = updatedAt
        record.originDeviceID8 = originDevice8
        context.insert(record)
        return true
    }

    // MARK: - Cumulative profile (shared, cross-agent)

    /// Kicks one profile sync pass, paced at `profileSyncCeiling` and coalesced against
    /// an already-running pass. Called from `SessionManager.isAppActive`'s foreground
    /// transition — "the app whenever I open it." A silent no-op with no control plane
    /// configured, same as `syncIfDue`.
    func compactCumulativeProfileIfDue(now: Date = Date()) {
        guard CloudControlPlaneConfig.isConfigured else { return }
        guard profileSyncTask == nil else { return }
        if let last = lastProfileSyncAt, now.timeIntervalSince(last) < Self.profileSyncCeiling { return }
        lastProfileSyncAt = now
        profileSyncTask = Task { [weak self] in
            await self?.syncCumulativeProfile()
            self?.profileSyncTask = nil
        }
    }

    /// Pull-then-push against `/memory/profile`. No claim lock here: this shares
    /// whatever this device's OWN existing consolidation (`AgentRuntime.consolidateMemoriesIfDue`,
    /// unchanged, still watchdog-tick-driven and 24h-floored for agents that can run it
    /// locally) already computed — it never decides to spend a fresh round of model
    /// tokens on a new summary itself, so it never needs to become "the active runner"
    /// the lock exists to arbitrate. Today only the daemon's own heartbeat-driven
    /// compaction (Part B) does that; a device with no locally-runnable agent (Levi's
    /// current setup: one cloud-hosted agent) still benefits fully from the pull half.
    func syncCumulativeProfile() async {
        guard case .found(let remote) = await fetchSharedProfile() else { return }
        pullCumulativeProfileIfNewer(remote)
        await pushCumulativeProfileIfNewer()
    }

    private struct SharedProfile {
        let content: String
        let updatedAt: Date?
    }

    private enum SharedProfileOutcome {
        case found(SharedProfile)
        case failed
    }

    private func fetchSharedProfile() async -> SharedProfileOutcome {
        guard let httpRequest = request(path: "/memory/profile", method: "GET") else { return .failed }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                registerFailure(agentID: Self.profileAuditID, "[memory] profile read failed")
                return .failed
            }
            let updatedAt = (object["updatedAt"] as? String).flatMap { Self.parseISO($0) }
            return .found(SharedProfile(content: object["content"] as? String ?? "", updatedAt: updatedAt))
        } catch {
            registerFailure(agentID: Self.profileAuditID, "[memory] profile read failed: could not reach the control plane")
            return .failed
        }
    }

    /// Sentinel id `audit` is called with for profile-sync lines — there's no single
    /// owning agent for a cross-agent document, so this can't route into one runtime's
    /// trail the way episodic sync failures do; `SessionManager` simply won't find a
    /// live runtime for it and the line is dropped, same as any agent with no local
    /// runtime today.
    private static let profileAuditID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func pullCumulativeProfileIfNewer(_ remote: SharedProfile) {
        guard let remoteUpdatedAt = remote.updatedAt, !remote.content.isEmpty else { return }
        let kind = MemoryKind.cumulative.rawValue
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\AgentMemory.createdAt, order: .forward)]
        )
        let existing = (try? context.fetch(descriptor))?.first
        guard existing == nil || existing!.updatedAt < remoteUpdatedAt else { return }

        let record = existing ?? AgentMemory(kind: .cumulative, title: "User profile", tags: "profile")
        if existing == nil { context.insert(record) }
        record.content = MemoryRedactor.redact(remote.content)
        record.updatedAt = remoteUpdatedAt
        try? context.save()
    }

    private func pushCumulativeProfileIfNewer() async {
        let kind = MemoryKind.cumulative.rawValue
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\AgentMemory.createdAt, order: .forward)]
        )
        guard let local = (try? context.fetch(descriptor))?.first, !local.content.isEmpty else { return }
        let watermark = defaults.object(forKey: Self.lastPushedProfileKey) as? Date ?? .distantPast
        guard local.updatedAt > watermark else { return }

        guard var httpRequest = request(path: "/memory/profile", method: "PUT") else { return }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": local.content]) else { return }
        httpRequest.httpBody = body
        do {
            let (_, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                registerFailure(agentID: Self.profileAuditID, "[memory] profile push failed")
                return
            }
            defaults.set(local.updatedAt, forKey: Self.lastPushedProfileKey)
        } catch {
            registerFailure(agentID: Self.profileAuditID, "[memory] profile push failed: could not reach the control plane")
        }
    }

    // MARK: - Ledger id <-> local id

    /// The id this device mints when pushing a local row — deterministic from the row's
    /// own local id, so repeated pushes of the same row always upsert the same server
    /// entry (idempotent) and a later pull of that same entry maps straight back.
    nonisolated static func ledgerID(forLocalID id: UUID) -> String {
        "m-\(id.uuidString.lowercased())"
    }

    /// The inverse: a pulled entry's ledger id back to a STABLE local id. The "m-<uuid>"
    /// shape every writer here uses (this service, `DaemonMemoryClient`) round-trips
    /// exactly. Anything else hashes to a stable id via FNV-1a (the same construction
    /// `AgentRelayApplier.claimJitterMillis` uses for its own deterministic hash) so a
    /// foreign-shaped id seen on repeated pulls always maps to the same local row
    /// instead of duplicating it.
    nonisolated static func localID(forLedgerID ledgerID: String) -> UUID {
        if ledgerID.hasPrefix("m-"), let parsed = UUID(uuidString: String(ledgerID.dropFirst(2))) {
            return parsed
        }
        func fnv1a(_ seed: UInt64, _ bytes: some Sequence<UInt8>) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return hash
        }
        let first = fnv1a(0xcbf2_9ce4_8422_2325, ledgerID.utf8)
        let second = fnv1a(0x1000_0000_01b3_9ce4, ledgerID.utf8.reversed())
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: first.bigEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: second.bigEndian) { bytes.replaceSubrange(8..<16, with: $0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Transport helpers

    private func request(path: String, method: String) -> URLRequest? {
        var base = CloudControlPlaneConfig.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        return request
    }

    private static let isoFormatter = ISO8601DateFormatter()

    nonisolated static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    nonisolated static func parseISO(_ text: String?) -> Date? { text.flatMap { isoFormatter.date(from: $0) } }

    private func registerFailure(agentID: UUID, _ message: String) {
        let now = Date()
        if let last = lastFailureAuditAt[message], now.timeIntervalSince(last) < Self.failureAuditWindow {
            return
        }
        lastFailureAuditAt[message] = now
        audit(agentID, message)
    }
}

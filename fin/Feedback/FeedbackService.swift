import Foundation
import SwiftData
import os

/// The app side of the model factory's training-signal loop: a device-local queue
/// of feedback items (direct ratings and trajectory digests) that posts to the
/// control plane's `/feedback` endpoint.
///
/// Privacy invariants, in order of importance:
///   - Nothing is sent unless the matching "Help improve Fin" toggle is ON and the
///     control plane is configured — both default off, so a fresh install sends nothing.
///   - The queue lives in Application Support, device-local by construction: feedback
///     telemetry never rides CloudKit, unlike almost everything else in the app.
///   - Comments pass through `MemoryRedactor` before they are even queued; trajectory
///     payloads are metadata-only by type (`TrajectoryDigest` has no content fields).
///   - Turning a toggle OFF discards that kind's queued items — revoked consent is
///     honored at the queue, not just at the socket — with an audit line, because this
///     service drops nothing silently: every give-up and every discard logs a line
///     through the same audit channel other services use.
///
/// The endpoint may not exist yet (the control-plane deploy is a separate track), so
/// a 404 is "not deployed" — held and retried slowly without burning the item's
/// attempt budget. Real failures back off exponentially and give up loudly.
@MainActor
final class FeedbackService: ObservableObject {
    static let shared = FeedbackService()

    private static let logger = Logger(subsystem: "dev.levischoen.fin", category: "FeedbackService")

    struct Item: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            case userFeedback = "user_feedback"
            case trajectory
        }

        let id: UUID
        let kind: Kind
        let rating: Int?
        let comment: String?
        /// The contract's `payload` object, pre-serialized so the queue stays Codable.
        let payloadJSON: Data?
        let appVersion: String
        let platform: String
        let createdAt: Date
        var attempts: Int = 0
        var nextAttemptAt: Date
    }

    /// Attempt budget for failures that actually reached the control plane (or
    /// provably couldn't). With the backoff cap this spans roughly a day of retries
    /// across launches before the audited give-up.
    static let maxAttempts = 10
    static let baseRetryDelay: TimeInterval = 30
    static let maxRetryDelay: TimeInterval = 6 * 3600
    /// How long a "not deployed yet" 404 parks the queue before the next try.
    static let notDeployedRetryDelay: TimeInterval = 3600
    /// Queue ceiling; the oldest item is dropped (with an audit line) past this.
    static let maxQueuedItems = 200

    /// Audit sink — wired to `SessionManager.recordLifecycleEvent` at bootstrap so
    /// give-ups land in the agent trail and iCloud mirror like other services' lines.
    /// Defaults to os_log so nothing is ever dropped without at least a logger line.
    var audit: @MainActor (String) -> Void = { FeedbackService.logger.warning("\($0, privacy: .public)") }

    // MARK: Injection seams (production defaults; tests replace)

    /// Whether consent currently allows sending this kind.
    var isSharingAllowed: (Item.Kind) -> Bool = { kind in
        switch kind {
        case .userFeedback: return FeedbackSettings.shareRatings()
        case .trajectory: return FeedbackSettings.shareActivity()
        }
    }
    /// The configured control plane, or nil — the queue holds while unconfigured.
    var controlPlane: () -> (endpoint: String, token: String)? = {
        guard CloudControlPlaneConfig.isConfigured else { return nil }
        return (CloudControlPlaneConfig.endpointURL, CloudControlPlaneConfig.token)
    }
    /// One HTTP round-trip; returns (status, body). Nil status is a network error.
    var transport: (URLRequest) async -> (Int?, Data?) = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (nil, nil)
        }
        return ((response as? HTTPURLResponse)?.statusCode, data)
    }
    var now: () -> Date = Date.init

    let gate: FeedbackPromptGate
    private let defaults: UserDefaults
    private let queueFileURL: URL
    private(set) var items: [Item] = []
    private var processTask: Task<Void, Never>?
    private var warnedNotDeployed = false

    init(
        defaults: UserDefaults = .standard,
        queueDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.gate = FeedbackPromptGate(defaults: defaults)
        let directory = queueDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Feedback", isDirectory: true)
        self.queueFileURL = directory.appendingPathComponent("queue.json")
        loadQueue()
        NotificationCenter.default.addObserver(
            forName: FeedbackSettings.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.consentChanged() }
        }
    }

    // MARK: - Enqueue

    /// Direct "How's Fin doing?" feedback. The comment is redacted BEFORE it is
    /// stored — a pasted terminal snippet must not sit in the queue file raw.
    /// Consent is the caller's UI contract; re-checked here so a stray call while
    /// sharing is off drops loudly, never queues.
    func submitUserFeedback(rating: Int?, comment: String?) {
        guard isSharingAllowed(.userFeedback) else {
            audit("[feedback] rating dropped — Share Ratings & Comments is off")
            return
        }
        let cleaned = comment
            .map { MemoryRedactor.redact($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        enqueue(Item(
            id: UUID(),
            kind: .userFeedback,
            rating: rating,
            comment: cleaned,
            payloadJSON: nil,
            appVersion: Self.appVersion,
            platform: Self.platform,
            createdAt: now(),
            nextAttemptAt: now()
        ))
    }

    func submitTrajectory(_ digest: TrajectoryDigest) {
        guard isSharingAllowed(.trajectory) else { return }
        guard let payload = digest.payloadObject(),
              let payloadJSON = try? JSONSerialization.data(withJSONObject: payload)
        else {
            audit("[feedback] trajectory digest failed to encode — dropped")
            return
        }
        enqueue(Item(
            id: UUID(),
            kind: .trajectory,
            rating: nil,
            comment: nil,
            payloadJSON: payloadJSON,
            appVersion: Self.appVersion,
            platform: Self.platform,
            createdAt: now(),
            nextAttemptAt: now()
        ))
    }

    private func enqueue(_ item: Item) {
        items.append(item)
        if items.count > Self.maxQueuedItems {
            let dropped = items.removeFirst()
            audit("[feedback] queue full — dropped oldest \(dropped.kind.rawValue) item")
        }
        saveQueue()
        kick()
    }

    // MARK: - Trajectory sweep

    /// Digests finished conversations out of the local audit trail. Grouping and
    /// counting always run (they only advance device-local markers and the prompt
    /// gate); SENDING a digest additionally requires toggle (b) — and only
    /// conversations that finish after opt-in are ever sent, because the marker
    /// advances regardless.
    ///
    /// `endingAgentID` marks that agent's trailing conversation finished right now
    /// (the user cleared the console) instead of waiting out the quiet gap.
    func sweepTrajectories(context: ModelContext, endingAgentID: UUID? = nil) {
        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        for agent in agents {
            sweepAgent(agent, context: context, endedExplicitly: agent.id == endingAgentID)
        }
        kick()
    }

    private func sweepAgent(_ agent: Agent, context: ModelContext, endedExplicitly: Bool) {
        let marker = trajectoryMarker(agentID: agent.id)
        let agentID = agent.id
        let descriptor = FetchDescriptor<AgentLogEntry>(
            predicate: #Predicate<AgentLogEntry> {
                $0.agentID == agentID && $0.timestamp > marker
            },
            sortBy: [SortDescriptor(\AgentLogEntry.timestamp)]
        )
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return }

        var groups = TrajectoryDigestBuilder.conversationGroups(entries: entries)
        guard !groups.isEmpty else { return }

        // The trailing group is still live unless it went quiet or was ended by hand.
        if let last = groups.last?.last,
           !endedExplicitly,
           now().timeIntervalSince(last.timestamp) < TrajectoryDigestBuilder.conversationGapSeconds {
            groups.removeLast()
        }

        for group in groups {
            if TrajectoryDigestBuilder.hasDirectUserTraffic(group) {
                gate.noteConversationCompleted()
            }
            if let digest = TrajectoryDigestBuilder.digest(
                entries: group, hostingMode: agent.hostingMode.rawValue
            ) {
                submitTrajectory(digest)
            }
            if let lastTimestamp = group.last?.timestamp {
                setTrajectoryMarker(lastTimestamp, agentID: agent.id)
            }
        }
    }

    private func trajectoryMarker(agentID: UUID) -> Date {
        defaults.object(forKey: "fin.feedback.trajectoryMarker.\(agentID.uuidString)") as? Date
            ?? .distantPast
    }

    private func setTrajectoryMarker(_ date: Date, agentID: UUID) {
        defaults.set(date, forKey: "fin.feedback.trajectoryMarker.\(agentID.uuidString)")
    }

    // MARK: - Consent changes

    /// Revoked consent empties that kind's queue: data collected under an opt-in
    /// must not outlive it waiting for a re-enable. Fresh consent releases holds.
    private func consentChanged() {
        for kind in [Item.Kind.userFeedback, .trajectory] where !isSharingAllowed(kind) {
            let revoked = items.filter { $0.kind == kind }
            guard !revoked.isEmpty else { continue }
            items.removeAll { $0.kind == kind }
            audit("[feedback] discarded \(revoked.count) queued \(kind.rawValue) item(s) — sharing turned off")
        }
        saveQueue()
        kick()
    }

    // MARK: - Sending

    /// Test seam: false stops `kick()` from spawning the background send loop, so
    /// tests drive `processOnce()` by hand with no concurrent sender racing them.
    var automaticProcessing = true

    /// Nudges the queue: sends everything due, then sleeps until the next item is.
    /// Call sites are cheap-and-frequent (enqueue, foreground, turn completion);
    /// a single in-flight task coalesces them.
    func kick() {
        guard automaticProcessing, processTask == nil else { return }
        processTask = Task { [weak self] in
            await self?.processLoop()
            self?.processTask = nil
        }
    }

    /// Test hook: runs one full pass over due items and returns, no sleeping.
    func processOnce() async {
        while let index = nextDueIndex() {
            let done = await attemptSend(itemAt: index)
            if !done { break }
        }
    }

    private func processLoop() async {
        while true {
            await processOnce()
            // Sleep only when something is queued, eligible, and merely early.
            guard let wakeAt = earliestEligibleAttempt(), !Task.isCancelled else { return }
            let interval = wakeAt.timeIntervalSince(now())
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if Task.isCancelled { return }
        }
    }

    private func nextDueIndex() -> Int? {
        guard controlPlane() != nil else { return nil }
        let currentTime = now()
        return items.firstIndex {
            isSharingAllowed($0.kind) && $0.nextAttemptAt <= currentTime
        }
    }

    private func earliestEligibleAttempt() -> Date? {
        guard controlPlane() != nil else { return nil }
        return items.filter { isSharingAllowed($0.kind) }
            .map(\.nextAttemptAt)
            .min()
    }

    /// One attempt for one item. Returns false when the loop should pause (the
    /// endpoint isn't deployed or reachable — retrying the next item now would
    /// just burn its budget against the same outage).
    private func attemptSend(itemAt index: Int) async -> Bool {
        guard let plane = controlPlane(), items.indices.contains(index) else { return false }
        var item = items[index]

        guard let request = Self.request(for: item, endpoint: plane.endpoint, token: plane.token) else {
            items.remove(at: index)
            saveQueue()
            audit("[feedback] dropped \(item.kind.rawValue) item — control plane URL is invalid")
            return true
        }

        let (status, _) = await transport(request)
        guard items.indices.contains(index), items[index].id == item.id else { return true }

        switch status {
        case .some(200...299):
            items.remove(at: index)
            saveQueue()
            warnedNotDeployed = false
            return true
        case 404?:
            // The ingest deploy hasn't landed yet — hold everything, budget intact.
            if !warnedNotDeployed {
                warnedNotDeployed = true
                audit("[feedback] endpoint not deployed yet (HTTP 404) — holding \(items.count) item(s)")
            }
            let retryAt = now().addingTimeInterval(Self.notDeployedRetryDelay)
            for heldIndex in items.indices {
                items[heldIndex].nextAttemptAt = max(items[heldIndex].nextAttemptAt, retryAt)
            }
            saveQueue()
            return false
        case 400?, 413?:
            // The control plane understood and refused: retrying identical bytes
            // can't succeed. Loudly dropped, per the no-silent-drops rule.
            items.remove(at: index)
            saveQueue()
            audit("[feedback] \(item.kind.rawValue) item rejected (HTTP \(status ?? 0)) — dropped")
            return true
        default:
            // Network error, 5xx, auth problems: back off, give up loudly at the cap.
            item.attempts += 1
            if item.attempts >= Self.maxAttempts {
                items.remove(at: index)
                saveQueue()
                let reason = status.map { "HTTP \($0)" } ?? "network error"
                audit("[feedback] gave up on \(item.kind.rawValue) item after \(item.attempts) attempts (\(reason))")
                return true
            }
            item.nextAttemptAt = now().addingTimeInterval(Self.backoffDelay(attempts: item.attempts))
            items[index] = item
            saveQueue()
            // A network-level failure likely affects every item; pause the pass.
            return status != nil
        }
    }

    /// 30s, 1m, 2m, … doubling to the 6h cap.
    static func backoffDelay(attempts: Int) -> TimeInterval {
        min(baseRetryDelay * pow(2, Double(max(attempts - 1, 0))), maxRetryDelay)
    }

    // MARK: - Wire shape

    /// The frozen ingest contract, verbatim: POST /feedback, bearer auth, JSON body
    /// {kind, rating, comment, payload, appVersion, platform, createdAt}. Nullable
    /// fields are sent as explicit nulls so the body shape never varies.
    static func request(for item: Item, endpoint: String, token: String) -> URLRequest? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/feedback") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(for: item)
        request.timeoutInterval = 15
        return request
    }

    static func body(for item: Item) -> Data? {
        let payload = item.payloadJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let object: [String: Any] = [
            "kind": item.kind.rawValue,
            "rating": item.rating as Any? ?? NSNull(),
            "comment": item.comment as Any? ?? NSNull(),
            "payload": payload ?? NSNull(),
            "appVersion": item.appVersion,
            "platform": item.platform,
            "createdAt": isoFormatter.string(from: item.createdAt),
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "iOS"
        #endif
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([Item].self, from: data)) ?? []
    }

    private func saveQueue() {
        do {
            try FileManager.default.createDirectory(
                at: queueFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            Self.logger.error("queue save failed: \(error.localizedDescription)")
        }
    }
}

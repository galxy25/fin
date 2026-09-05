import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Configuration for remote supervision — a Claude Code session on another
/// machine driving this device's Fin agent through two presigned S3 URLs: one it
/// writes directives to (polled here), one this device PUTs status to.
///
/// Split storage, on purpose. The ENABLED flag is portable intent ("supervise my
/// devices") and syncs across them via iCloud KVS (`SyncedDeviceConfig`): with
/// the control-plane pair synced too (`CloudControlPlaneConfig`), a brand-new
/// device that receives enabled=true self-vends its own directive/status URLs
/// through `POST /presign` (see `performPoll`) and comes up supervised with zero
/// pastes. The URLs themselves stay in device-local UserDefaults: a presigned
/// URL is a short-lived per-device capability grant that every device can
/// re-vend on demand — syncing one would be pointless (it dies within the hour,
/// and each device refreshes its own) while still handing every device the same
/// writable bucket key in plaintext KVS. Never the CloudKit-synced models
/// either: schema promotion is expensive and none of this is model data.
enum RemoteSupervisionConfig {
    static let directiveURLKey = "fin.remote.directiveURL"
    static let statusURLKey = "fin.remote.statusURL"
    static let enabledKey = "fin.remote.enabled"
    static let appliedIDsKey = "fin.remote.applied"
    static let lastAppliedOrdinalKey = "fin.remote.lastAppliedOrdinal"
    static let deferredOrdinalsKey = "fin.remote.deferredOrdinals"
    static let lastPollAtKey = "fin.remote.lastPollAt"
    static let lastPollStatusKey = "fin.remote.lastPollStatus"
    /// When the last auto-vended directive/status URLs are stated to expire (seconds
    /// since 1970). An upper bound only: URLs signed by the Lambda role die with its
    /// temporary credentials, often sooner — a 403 on poll/PUT is the real trigger to
    /// re-vend. Not a URL, so it is safe to keep in an inspectable defaults value.
    static let urlExpiresAtKey = "fin.remote.urlExpiresAt"

    /// Posted by every setter, so the channel starts/stops on an edit without ever
    /// polling UserDefaults from a timer — the disabled path must cost nothing.
    static let changedNotification = Notification.Name("fin.remote.configurationChanged")

    /// Posted after every poll-outcome write, so the health badge refreshes live.
    /// Deliberately NOT `changedNotification`: the channel re-polls on that one, and
    /// a poll posting it from inside its own poll pass would mark a follow-up poll
    /// pending every pass — a self-sustaining poll loop.
    static let pollOutcomeNotification = Notification.Name("fin.remote.pollOutcome")

    /// How stale the last successful poll may be before the badge goes dark. Three
    /// missed 30s ticks feels broken; one slow cycle shouldn't flicker the icon.
    static let healthyWindowSeconds: TimeInterval = 90

    /// True when supervision is enabled AND the most recent poll succeeded AND it
    /// happened within `healthyWindowSeconds` of `now`. Pure read of the stored
    /// outcome keys, so views and tests share one definition of "healthy".
    static func isHealthy(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: enabledKey),
              let lastPollAt = defaults.object(forKey: lastPollAtKey) as? Date,
              let status = defaults.string(forKey: lastPollStatusKey),
              status.hasPrefix("ok") || status == "not modified"
        else { return false }
        return now.timeIntervalSince(lastPollAt) <= healthyWindowSeconds
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var directiveURL: String { UserDefaults.standard.string(forKey: directiveURLKey) ?? "" }
    static var statusURL: String { UserDefaults.standard.string(forKey: statusURLKey) ?? "" }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        // Mirrored to iCloud KVS so the user's other devices adopt the decision
        // (both directions — an explicit OFF propagates too).
        SyncedDeviceConfig.push(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func setDirectiveURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: directiveURLKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func setStatusURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: statusURLKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func urlExpiresAt() -> Date? {
        let stamp = UserDefaults.standard.double(forKey: urlExpiresAtKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Stores auto-vended directive/status URLs (and their expiry) WITHOUT posting
    /// `changedNotification`. A presigned refresh retargets the same directive/status
    /// object with fresh credentials, so unlike a user paste it must NOT restart the
    /// poller or invalidate the in-memory ETag (the ETag belongs to the S3 object, not
    /// the signature) — `AgentDirectiveChannel` drives the refresh inline and keeps its
    /// own cache key coherent. Only a non-nil URL overwrites, so a partial vend never
    /// blanks a URL the channel still needs. The manual-paste setters stay the way a
    /// user replaces a URL, and still notify.
    static func applyPresigned(directiveGet: String?, statusPut: String?, expiresAt: Date?) {
        if let directiveGet { UserDefaults.standard.set(directiveGet, forKey: directiveURLKey) }
        if let statusPut { UserDefaults.standard.set(statusPut, forKey: statusURLKey) }
        if let expiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: urlExpiresAtKey)
        }
    }

    /// Editor display form: host plus a truncated path. A presigned URL's query
    /// string IS the credential, so the full URL is never rendered back — replacing
    /// it means pasting a new one.
    static func redactedDisplay(_ urlString: String) -> String {
        guard !urlString.isEmpty else { return "not set" }
        guard let url = URL(string: urlString), let host = url.host else {
            return "(unparseable URL)"
        }
        let path = url.path
        let shown = path.count > 18 ? String(path.prefix(18)) + "…" : path
        return host + shown
    }

    /// Info.plist seeding (`FinDirectiveURL` / `FinStatusURL`, resolved from build
    /// settings): fills only empty defaults — a URL the user pasted always wins —
    /// and ignores empty plist values, so the dormant default build seeds nothing.
    /// A seed that actually lands also enables the channel: a build stamped with
    /// capability URLs exists to be supervised.
    @discardableResult
    static func seedFromInfoPlist(
        _ info: [String: Any]? = Bundle.main.infoDictionary,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var seeded = false
        let pairs: [(plist: String, key: String)] = [
            ("FinDirectiveURL", directiveURLKey),
            ("FinStatusURL", statusURLKey),
        ]
        for pair in pairs {
            guard let value = (info?[pair.plist] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty,
                (defaults.string(forKey: pair.key) ?? "").isEmpty
            else { continue }
            defaults.set(value, forKey: pair.key)
            seeded = true
        }
        if seeded { defaults.set(true, forKey: enabledKey) }
        return seeded
    }
}

/// One remote instruction. Tolerant by construction: unknown fields are ignored,
/// `agent` defaults to the "*" wildcard, and the optional monitor fields may be
/// absent — a newer supervisor must be able to talk to an older app.
struct RemoteDirective: Decodable, Equatable {
    let id: String
    let agent: String
    let kind: String
    let text: String?
    let armMonitor: Bool?
    let intervalSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, agent, kind, text
        case armMonitor = "arm_monitor"
        case intervalSeconds = "interval_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? "*"
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        armMonitor = try container.decodeIfPresent(Bool.self, forKey: .armMonitor)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
    }

    init(id: String, agent: String = "*", kind: String = "user_message",
         text: String? = nil, armMonitor: Bool? = nil, intervalSeconds: Int? = nil) {
        self.id = id
        self.agent = agent
        self.kind = kind
        self.text = text
        self.armMonitor = armMonitor
        self.intervalSeconds = intervalSeconds
    }

    func matches(agentNamed name: String) -> Bool {
        agent == "*" || agent.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// The polled JSON document. A malformed directive element is dropped rather than
/// failing the whole document, so one bad entry can't wedge the channel.
struct RemoteDirectiveDocument: Decodable {
    let version: Int
    let issuedAt: String?
    let directives: [RemoteDirective]

    private struct TolerantElement: Decodable {
        let value: RemoteDirective?
        init(from decoder: Decoder) throws {
            value = try? RemoteDirective(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, directives
        case issuedAt = "issued_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        issuedAt = try container.decodeIfPresent(String.self, forKey: .issuedAt)
        directives = try container
            .decodeIfPresent([TolerantElement].self, forKey: .directives)?
            .compactMap(\.value) ?? []
    }

    static func parse(_ data: Data) -> RemoteDirectiveDocument? {
        try? JSONDecoder().decode(RemoteDirectiveDocument.self, from: data)
    }
}

/// Ordered, capped record of applied directive ids. Device-local, stored as a JSON
/// array string so the defaults value stays inspectable from the shell.
///
/// The id list alone can't survive its own cap: a supervisor document that keeps
/// more than `cap` historical entries would see the oldest ids evicted here and
/// re-applied after a relaunch. Ids of the conventional `d-<number>` shape also
/// maintain a persisted high-water ordinal, so an evicted-but-old id is still
/// recognizable as already applied. Free-form ids keep set-only semantics.
///
/// The mark alone would misclassify a legitimately deferred lower ordinal as an
/// evicted replay once any higher ordinal applies (application is not in ordinal
/// order — deferral is per-directive). So every deferred ordinal is also recorded
/// in a persisted ledger; an ordinal in the ledger is always eligible for retry
/// no matter how far the mark has advanced, and leaves the ledger only when its
/// directive applies, hard-skips, or is pruned from a freshly fetched document.
struct AppliedDirectiveStore {
    static let cap = 500
    /// Deferred-ordinal ledger cap; past it the oldest entry is evicted (the
    /// channel audits the first eviction each launch).
    static let deferredCap = 200

    private(set) var ids: [String]
    private(set) var lastAppliedOrdinal: Int
    private(set) var deferredOrdinals: [Int]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: RemoteSupervisionConfig.appliedIDsKey) ?? "[]"
        ids = (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
        lastAppliedOrdinal = defaults.integer(forKey: RemoteSupervisionConfig.lastAppliedOrdinalKey)
        let deferred = defaults.string(forKey: RemoteSupervisionConfig.deferredOrdinalsKey) ?? "[]"
        deferredOrdinals = (try? JSONDecoder().decode([Int].self, from: Data(deferred.utf8))) ?? []
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    var lastAppliedID: String? { ids.last }

    /// The numeric ordinal of a `d-<digits>` id; nil for any other shape (including
    /// non-ASCII digits and overflow), which keeps such ids on set-only semantics.
    static func ordinal(of id: String) -> Int? {
        guard id.hasPrefix("d-") else { return nil }
        let digits = id.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// True when the id's ordinal says it was applied before the id itself was
    /// evicted from the capped set — treat as already applied, never re-inject.
    /// A ledgered (deferred, never applied) ordinal is exempt: it must stay
    /// retryable however far the mark has advanced past it.
    ///
    /// `mark` lets the apply loop classify against the mark as of the start of
    /// its pass: an out-of-ordinal-order document ([d-2, d-1]) applies d-2 and
    /// advances the live mark before d-1 is even examined — d-1 is a fresh
    /// directive to defer, not an evicted replay.
    func isBelowHighWaterMark(_ id: String, mark: Int? = nil) -> Bool {
        guard let ordinal = Self.ordinal(of: id) else { return false }
        return ordinal <= (mark ?? lastAppliedOrdinal)
            && !contains(id)
            && !deferredOrdinals.contains(ordinal)
    }

    mutating func markApplied(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.cap { ids.removeFirst(ids.count - Self.cap) }
        if let data = try? JSONEncoder().encode(ids) {
            defaults.set(String(decoding: data, as: UTF8.self),
                         forKey: RemoteSupervisionConfig.appliedIDsKey)
        }
        if let ordinal = Self.ordinal(of: id) {
            advanceMark(ordinal)
            removeDeferred(ordinal)
        }
    }

    /// A hard skip (unknown kind, empty or overlong text) resolves the ordinal the
    /// same way an apply does: the mark advances and any ledger entry is released —
    /// this build will never inject it, so it must not hold either back.
    mutating func markHardSkipped(_ id: String) {
        guard let ordinal = Self.ordinal(of: id) else { return }
        advanceMark(ordinal)
        removeDeferred(ordinal)
    }

    /// Records a deferral (no matching runtime, disconnected session, blocked
    /// configuration, or a submit that didn't take) so the ordinal stays
    /// retryable past the mark. Returns true when the capped ledger evicted its
    /// oldest entry to make room.
    @discardableResult
    mutating func markDeferred(_ id: String) -> Bool {
        guard let ordinal = Self.ordinal(of: id), !deferredOrdinals.contains(ordinal) else {
            return false
        }
        deferredOrdinals.append(ordinal)
        var evicted = false
        if deferredOrdinals.count > Self.deferredCap {
            deferredOrdinals.removeFirst(deferredOrdinals.count - Self.deferredCap)
            evicted = true
        }
        persistDeferred()
        return evicted
    }

    /// A freshly fetched document is the whole directive universe: a ledger entry
    /// whose ordinal no longer appears in it can never apply, so it is dropped.
    mutating func pruneDeferred(keeping observed: Set<Int>) {
        let kept = deferredOrdinals.filter(observed.contains)
        guard kept.count != deferredOrdinals.count else { return }
        deferredOrdinals = kept
        persistDeferred()
    }

    private mutating func advanceMark(_ ordinal: Int) {
        guard ordinal > lastAppliedOrdinal else { return }
        lastAppliedOrdinal = ordinal
        defaults.set(ordinal, forKey: RemoteSupervisionConfig.lastAppliedOrdinalKey)
    }

    private mutating func removeDeferred(_ ordinal: Int) {
        guard let index = deferredOrdinals.firstIndex(of: ordinal) else { return }
        deferredOrdinals.remove(at: index)
        persistDeferred()
    }

    private mutating func persistDeferred() {
        if let data = try? JSONEncoder().encode(deferredOrdinals) {
            defaults.set(String(decoding: data, as: UTF8.self),
                         forKey: RemoteSupervisionConfig.deferredOrdinalsKey)
        }
    }
}

/// Pure pacing decision for failure audit lines: once per window per distinct
/// error string, so a dead bucket writes one line per 5 minutes, not one per poll.
struct RemoteFailureAuditThrottle {
    static let interval: TimeInterval = 5 * 60

    private var lastAuditAt: [String: Date] = [:]

    mutating func shouldAudit(_ message: String, now: Date) -> Bool {
        if let last = lastAuditAt[message], now.timeIntervalSince(last) < Self.interval {
            return false
        }
        lastAuditAt[message] = now
        return true
    }
}

/// Pure pacing decision for status PUTs: at most one per window, trailing-edge — a
/// suppressed request marks `pending`, and the channel schedules a flush for the
/// end of the window so the fresh state goes up even if no later poll asks.
struct RemoteStatusPutThrottle {
    static let interval: TimeInterval = 15

    private(set) var lastSentAt: Date?
    private(set) var pending = false

    mutating func shouldSend(now: Date, interval: TimeInterval = Self.interval) -> Bool {
        if let last = lastSentAt, now.timeIntervalSince(last) < interval {
            pending = true
            return false
        }
        lastSentAt = now
        pending = false
        return true
    }

    /// Seconds until the current window closes and a pending PUT may go out; nil
    /// when nothing is pending.
    func remainingWindow(now: Date, interval: TimeInterval = Self.interval) -> TimeInterval? {
        guard pending, let last = lastSentAt else { return nil }
        return max(0, interval - now.timeIntervalSince(last))
    }
}

/// Pure classification of a directive GET's outcome. 304 against the stored ETag
/// means the document hasn't changed — done, no parse, no application pass.
enum RemoteFetchDisposition: Equatable {
    case notModified
    case apply(etag: String?)
    case failure(String)

    static func classify(statusCode: Int, etag: String?) -> RemoteFetchDisposition {
        if statusCode == 304 { return .notModified }
        guard (200..<300).contains(statusCode) else { return .failure("HTTP \(statusCode)") }
        return .apply(etag: etag)
    }
}

/// Polls the directive URL and applies what it finds; uplinks a redacted status
/// document after every poll cycle and turn. Owned by `SessionManager` and driven
/// like the watchdog: the loop only exists while the app is active AND the channel
/// is enabled — a disabled install never runs a timer.
@MainActor
final class AgentDirectiveChannel {
    /// A live runtime plus the one fact about it the runtime doesn't expose: whether
    /// its session is connected. Supplied by `SessionManager`, active server first,
    /// so a "*" directive lands where the user is.
    struct Target {
        let runtime: AgentRuntime
        let sessionConnected: Bool
    }

    static let pollIntervalSeconds = 30
    static let requestTimeout: TimeInterval = 10
    /// The one directive kind this build understands; anything else is skipped with
    /// a single audit line and left unapplied for a future build (forward compat).
    static let userMessageKind = "user_message"
    /// Input bounds. The supervisor writes the document, but the bucket is remote
    /// input all the same: a body cap keeps a hostile object from buffering hundreds
    /// of MB on the MainActor, a per-document directive cap bounds the apply loop,
    /// and a text cap bounds what can ever reach a transcript (and the model bill).
    nonisolated static let maxBodyBytes = 1_048_576
    static let maxDirectivesPerDocument = 100
    static let maxDirectiveTextLength = 8000
    static let auditedSkipsCap = 100

    /// Injected transport, so tests never touch the network.
    var fetch: (URLRequest) async throws -> (Data, URLResponse)
    var put: (URLRequest) async throws -> URLResponse
    var liveTargets: () -> [Target] = { [] }
    /// Audit sink for channel-level lines (poll/PUT failures, skipped directives) —
    /// wired to the lifecycle recorder so they reach the mirror even with no live
    /// runtime to carry them. Per-directive "applied" lines go through the target
    /// runtime's own trail instead.
    var audit: (String) -> Void = { _ in }

    private var isActive = false
    private var pollTask: Task<Void, Never>?
    private var pollInFlight = false
    /// A poll requested while another is in flight (turn finish landing mid-cycle)
    /// is coalesced into exactly one follow-up poll, never dropped.
    private var pendingPoll = false
    /// In-memory on purpose: a relaunch refetches once, which is cheaper than one
    /// more piece of durable state to keep coherent with the applied set.
    private var etag: String?
    /// The last successfully parsed document, kept so a 304 still runs a full
    /// application pass: a deferred directive (no runtime, disconnected session)
    /// must be retried on every poll even though the bytes haven't changed — the
    /// applied set makes the re-run cheap.
    private var cachedDocument: RemoteDirectiveDocument?
    private var failureThrottle = RemoteFailureAuditThrottle()
    private var putThrottle = RemoteStatusPutThrottle()
    /// Test seam for the PUT window; production never changes it.
    var statusPutWindow: TimeInterval = RemoteStatusPutThrottle.interval
    /// The scheduled trailing-edge flush for a throttle-suppressed PUT. Cancelled on
    /// stop: the flush fires only while the app stays active — a state change in the
    /// final seconds before backgrounding is uplinked if the window closes first,
    /// and otherwise rides the next foreground poll (no network after resign-active).
    private var putFlushTask: Task<Void, Never>?
    private var applied: AppliedDirectiveStore
    /// Skip audits are once per directive id per launch — "skip with one audit
    /// line" must not become one line per poll. Ordered and capped so a flood of
    /// unique bogus ids can't grow it without bound (oldest evicted).
    private var auditedSkips: [String] = []
    /// The oversized-document truncation audits once per launch, like a skip.
    private var auditedDirectiveOverflow = false
    /// The first deferred-ledger eviction audits once per launch, like a skip.
    private var auditedLedgerEviction = false
    private var lastFailureText: String?
    /// The directive URL the in-memory `etag`/`cachedDocument` belong to; a change
    /// invalidates both (the cache key is semantically (URL, ETag)).
    private var lastDirectiveURL: String
    /// When this channel last asked the control plane to re-vend supervision URLs, so
    /// a persistently-dead endpoint (or two 403s in one poll cycle) can't hammer
    /// `/presign`. A presigned refresh vends BOTH URLs at once, so one call per short
    /// window covers a GET-then-PUT failure pair.
    private var lastPresignRefreshAt: Date?
    static let presignRefreshCooldown: TimeInterval = 30
    private var configObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            // Streaming, not `URLSession.data`: the body cap must bound memory, so
            // one byte past it the transfer is cancelled instead of buffered whole.
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if response.expectedContentLength > Int64(AgentDirectiveChannel.maxBodyBytes) {
                // An honest oversize Content-Length never reads the body at all;
                // the poll's expectedContentLength check turns this into a failure.
                bytes.task.cancel()
                return (Data(), response)
            }
            let data = try await AgentDirectiveChannel.accumulateBody(bytes) {
                bytes.task.cancel()
            }
            return (data, response)
        },
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return response
        }
    ) {
        self.fetch = fetch
        self.put = put
        self.applied = AppliedDirectiveStore(defaults: defaults)
        self.lastDirectiveURL = RemoteSupervisionConfig.directiveURL
        configObserver = NotificationCenter.default.addObserver(
            forName: RemoteSupervisionConfig.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, which is the MainActor's executor.
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    // MARK: - Lifecycle

    func appDidBecomeActive() {
        isActive = true
        startLoop()
        pollNow()
    }

    func appDidResignActive() {
        isActive = false
        stopLoop()
    }

    /// A finished turn is the moment a directive→response→directive cycle wants to
    /// continue; poll immediately (the cycle's uplink rides the poll). `pollNow`'s
    /// active gate keeps a turn ending inside the background grace window from
    /// firing network I/O.
    func agentTurnFinished() {
        // The runtime is deterministically idle on this exact MainActor stack.
        // Apply queued work from the cached document BEFORE paying fetch latency:
        // an agent chaining heartbeat and user turns has idle gaps of a few
        // seconds, and a poll that fetches first loses that race every time —
        // observed in the field as directives starving behind a busy agent.
        if isActive, RemoteSupervisionConfig.isEnabled, let cached = cachedDocument {
            applyDirectives(cached)
        }
        pollNow()
    }

    #if DEBUG
    /// Test seam: tests drive `pollOnce` directly and need the active gate open
    /// without `appDidBecomeActive` spawning loop tasks and an immediate poll.
    func setActiveForTesting(_ active: Bool) {
        isActive = active
    }
    #endif

    private func configurationChanged() {
        // A new directive URL is a new document identity: the stored ETag and
        // cached document belong to the old URL and must neither revalidate
        // (If-None-Match) nor apply (304 replaying the old cache) against it.
        let directiveURL = RemoteSupervisionConfig.directiveURL
        if directiveURL != lastDirectiveURL {
            lastDirectiveURL = directiveURL
            etag = nil
            cachedDocument = nil
        }
        if RemoteSupervisionConfig.isEnabled, isActive {
            startLoop()
            pollNow()
        } else {
            stopLoop()
        }
    }

    private func startLoop() {
        guard pollTask == nil, isActive, RemoteSupervisionConfig.isEnabled else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // No strong self across the sleep, mirroring the heartbeat loop: a
                // discarded channel's loop must die with it.
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                guard let self, !Task.isCancelled, self.isActive,
                      RemoteSupervisionConfig.isEnabled else { return }
                await self.pollOnce()
            }
        }
    }

    private func stopLoop() {
        pollTask?.cancel()
        pollTask = nil
        putFlushTask?.cancel()
        putFlushTask = nil
        pendingPoll = false
    }

    private func pollNow() {
        // Active-gated so an out-of-band ask (a turn finishing during the iOS
        // background grace window) never fires network I/O from a backgrounded app.
        guard isActive, RemoteSupervisionConfig.isEnabled else { return }
        Task { await pollOnce() }
    }

    // MARK: - Poll

    func pollOnce() async {
        guard RemoteSupervisionConfig.isEnabled else { return }
        guard !pollInFlight else {
            // Coalesce, don't drop: the in-flight poll finishes and runs exactly
            // one follow-up, so a turn-finish ask can't be lost to a 30s tick.
            pendingPoll = true
            return
        }
        pollInFlight = true
        defer { pollInFlight = false }
        repeat {
            pendingPoll = false
            await performPoll()
        } while pendingPoll
    }

    /// Accumulates a streamed response body up to `cap` bytes. One byte past the
    /// cap it stops reading and invokes `cancel` (which tears down the transfer),
    /// so a hostile multi-hundred-MB object costs at most cap+1 bytes of buffering;
    /// the returned oversize count then fails the poll's body-size check. Generic
    /// over the byte sequence and parameterized on the cap purely as a test seam.
    nonisolated static func accumulateBody<Bytes: AsyncSequence>(
        _ bytes: Bytes, cap: Int = maxBodyBytes, cancel: () -> Void
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > cap {
                cancel()
                break
            }
        }
        return data
    }

    private func performPoll() async {
        // No directive URL yet, but an enabled channel with a configured control plane
        // can vend one on demand instead of idling — the manual paste becomes a
        // fallback, not a prerequisite.
        if RemoteSupervisionConfig.directiveURL.isEmpty,
           RemoteSupervisionConfig.isEnabled, CloudControlPlaneConfig.isConfigured {
            _ = await refreshSupervisionURLsIfAllowed()
        }

        var attemptedRefresh = false
        while true {
            let urlString = RemoteSupervisionConfig.directiveURL
            guard !urlString.isEmpty, let url = URL(string: urlString) else {
                if !urlString.isEmpty {
                    registerFailure("[s3] poll failed: invalid directive URL")
                }
                break
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeout
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            do {
                let (data, response) = try await fetch(request)
                // The user may have disabled the channel (or backgrounded the app)
                // while the fetch was in flight; a fetched document must not be
                // applied past that decision.
                guard RemoteSupervisionConfig.isEnabled, isActive else { break }
                let http = response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 200
                // An expired presigned URL reads as 403 (401 defensively): re-vend once
                // and retry with the fresh URL before recording a failure.
                if (statusCode == 403 || statusCode == 401), !attemptedRefresh,
                   await refreshSupervisionURLsIfAllowed() {
                    attemptedRefresh = true
                    continue
                }
                switch RemoteFetchDisposition.classify(
                    statusCode: statusCode,
                    etag: http?.value(forHTTPHeaderField: "ETag")
                ) {
                case .notModified:
                    // Unchanged bytes, but not necessarily nothing to do: re-run
                    // the cached document so directives deferred on an earlier
                    // pass (busy runtime, disconnected session) get their retry.
                    if let cachedDocument {
                        applyDirectives(cachedDocument)
                    }
                    recordPollOutcome("not modified")
                case .apply(let newETag):
                    if data.count > Self.maxBodyBytes
                        || response.expectedContentLength > Int64(Self.maxBodyBytes) {
                        registerFailure("[s3] poll failed: body too large")
                        recordPollOutcome("failed: body too large")
                    } else if let document = RemoteDirectiveDocument.parse(data) {
                        // Adopted only on a successful parse, so a garbled body is
                        // refetched next poll instead of being 304-pinned.
                        etag = newETag ?? etag
                        cachedDocument = document
                        // A fresh document defines what can still apply: ledger
                        // entries whose ordinal it no longer carries are dropped.
                        applied.pruneDeferred(keeping: Set(
                            document.directives.compactMap { AppliedDirectiveStore.ordinal(of: $0.id) }
                        ))
                        applyDirectives(document)
                        recordPollOutcome("ok (\(document.directives.count) directive(s))")
                    } else {
                        registerFailure("[s3] poll failed: unparseable directive document")
                        recordPollOutcome("failed: unparseable directive document")
                    }
                case .failure(let reason):
                    registerFailure("[s3] poll failed: \(reason)")
                    recordPollOutcome("failed: \(reason)")
                }
            } catch {
                let reason = Self.shortError(error)
                registerFailure("[s3] poll failed: \(reason)")
                recordPollOutcome("failed: \(reason)")
            }
            break
        }

        await uplinkStatus()
    }

    /// Re-vends the device-wide supervision URLs through the control plane and stores
    /// them (silently — same object, fresh credentials). Cooldown-gated so a dead
    /// endpoint, or a GET and PUT failing in the same cycle, can't hammer `/presign`;
    /// returns true only when fresh URLs actually landed, i.e. a retry is worthwhile.
    /// A no-op with no control plane configured, which keeps the reactive path inert
    /// on installs that only ever paste URLs by hand.
    private func refreshSupervisionURLsIfAllowed(now: Date = Date()) async -> Bool {
        guard CloudControlPlaneConfig.isConfigured else { return false }
        if let last = lastPresignRefreshAt,
           now.timeIntervalSince(last) < Self.presignRefreshCooldown {
            // Just re-vended (typically earlier in this same poll cycle); the stored
            // URLs are already the freshest the control plane will give us.
            return false
        }
        lastPresignRefreshAt = now
        let before = RemoteSupervisionConfig.directiveURL
        guard await PresignedURLService.refreshSupervisionURLs() else { return false }
        // Same S3 object, new signature: keep the ETag and cached document, just point
        // the cache key at the new URL so a later user paste still reads as a change.
        let after = RemoteSupervisionConfig.directiveURL
        if after != before { lastDirectiveURL = after }
        return true
    }

    // MARK: - Application

    func applyDirectives(_ document: RemoteDirectiveDocument) {
        if document.directives.count > Self.maxDirectivesPerDocument, !auditedDirectiveOverflow {
            auditedDirectiveOverflow = true
            audit("[s3] directive document truncated: processing first "
                + "\(Self.maxDirectivesPerDocument) of \(document.directives.count)")
        }
        // Replay classification uses the mark as it stood when this pass began:
        // an apply earlier in THIS pass must not reclassify a directive that
        // simply appears later in the array (see isBelowHighWaterMark(_:mark:)).
        let markAtPassStart = applied.lastAppliedOrdinal
        for directive in document.directives.prefix(Self.maxDirectivesPerDocument) {
            guard !applied.contains(directive.id) else { continue }
            guard !applied.isBelowHighWaterMark(directive.id, mark: markAtPassStart) else {
                // Applied before its id fell off the capped set — a replay after a
                // relaunch or document rewrite, never re-injected. A deferred
                // (never-applied) ordinal can't land here: it sits in the ledger
                // until it applies, hard-skips, or is pruned from the document.
                auditSkipOnce(directive.id, "below high-water mark")
                continue
            }
            guard directive.kind == Self.userMessageKind else {
                auditSkipOnce(directive.id, "unknown kind \"\(directive.kind)\"")
                applied.markHardSkipped(directive.id)
                continue
            }
            let text = (directive.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                auditSkipOnce(directive.id, "empty text")
                applied.markHardSkipped(directive.id)
                continue
            }
            guard text.count <= Self.maxDirectiveTextLength else {
                auditSkipOnce(directive.id, "text exceeds \(Self.maxDirectiveTextLength) characters")
                applied.markHardSkipped(directive.id)
                continue
            }
            // No live matching runtime, a disconnected session, or a blocked
            // configuration defer — retried next poll, never marked applied. A BUSY
            // runtime no longer defers: submit queues the prompt, the runtime's
            // FIFO queue guarantees execution order (later directives for the same
            // agent queue behind earlier ones in this same pass), and queued counts
            // as applied. The ledger keeps a deferred ordinal retryable even after
            // higher ordinals advance the high-water mark.
            guard let target = liveTargets().first(where: {
                directive.matches(agentNamed: $0.runtime.agent.name)
            }),
                target.sessionConnected,
                target.runtime.configurationBlocker == nil
            else {
                recordDeferral(directive.id)
                continue
            }

            if directive.armMonitor == true {
                // Monitor-tool semantics, .tool provenance — the exact path the
                // model's own monitor call takes, including the manual-mode refusal.
                // An omitted interval passes 0, which the tool resolves to the
                // agent's own configured heartbeat (its stock default if unset) —
                // the user's stepper stays the authoritative knob.
                let interval = directive.intervalSeconds.map { min(max($0, 15), 600) } ?? 0
                _ = target.runtime.executeMonitor(
                    action: "start",
                    intervalSeconds: interval,
                    rawArguments: "{\"action\":\"start\",\"interval_seconds\":\(interval)}"
                )
            }
            // The SAME path a typed message takes: submit clears suppression, sets
            // state, runs the turn, and its send_input calls still pass through
            // manual-mode approval and the destructive-command heuristic. `.queued`
            // is as good as `.started` — the queue runs it, in order, before any
            // heartbeat — so both mark applied; only an outright rejection defers.
            switch target.runtime.submit(text) {
            case .started, .queued:
                applied.markApplied(directive.id)
                target.runtime.recordSupervisionNotice("[s3] applied directive \(directive.id)")
            case .rejected:
                recordDeferral(directive.id)
            }
        }
    }

    /// Ledger bookkeeping for a deferred directive; the capped ledger's first
    /// eviction audits once per launch so silent loss is at least visible.
    private func recordDeferral(_ id: String) {
        guard applied.markDeferred(id) else { return }
        guard !auditedLedgerEviction else { return }
        auditedLedgerEviction = true
        audit("[s3] deferred ledger full: evicted oldest ordinal")
    }

    private func auditSkipOnce(_ id: String, _ reason: String) {
        guard !auditedSkips.contains(id) else { return }
        auditedSkips.append(id)
        if auditedSkips.count > Self.auditedSkipsCap {
            auditedSkips.removeFirst(auditedSkips.count - Self.auditedSkipsCap)
        }
        audit("[s3] skipped directive \(id): \(reason)")
    }

    // MARK: - Status uplink

    private func uplinkStatus(now: Date = Date()) async {
        // `isActive` too, not just enabled: the success path's post-fetch guard
        // already covers apply, but a failed GET's catch branch and the trailing
        // flush task both land here — neither may PUT after resign-active.
        guard RemoteSupervisionConfig.isEnabled, isActive,
              !RemoteSupervisionConfig.statusURL.isEmpty,
              URL(string: RemoteSupervisionConfig.statusURL) != nil else { return }
        guard putThrottle.shouldSend(now: now, interval: statusPutWindow) else {
            scheduleTrailingFlush(now: now)
            return
        }
        // A send carries the freshest state, so any scheduled flush is stale.
        putFlushTask?.cancel()
        putFlushTask = nil

        let body = Data(statusBody(now: now).utf8)
        var attemptedRefresh = false
        while true {
            guard let url = URL(string: RemoteSupervisionConfig.statusURL) else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeout
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let response = try await put(request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // An expired presigned URL reads as 403: re-vend once and retry.
                    if (http.statusCode == 403 || http.statusCode == 401), !attemptedRefresh,
                       await refreshSupervisionURLsIfAllowed() {
                        attemptedRefresh = true
                        continue
                    }
                    registerFailure("[s3] put failed: HTTP \(http.statusCode)")
                }
            } catch {
                registerFailure("[s3] put failed: \(Self.shortError(error))")
            }
            break
        }
    }

    /// Trailing edge of the PUT throttle: one task per window, firing when the
    /// window closes so a suppressed status change still goes up without waiting
    /// for the next poll cycle. Cancelled by `stopLoop` — see `putFlushTask`.
    private func scheduleTrailingFlush(now: Date) {
        guard putFlushTask == nil,
              let delay = putThrottle.remainingWindow(now: now, interval: statusPutWindow)
        else { return }
        putFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard let self, !Task.isCancelled, self.isActive,
                  RemoteSupervisionConfig.isEnabled else { return }
            self.putFlushTask = nil
            await self.uplinkStatus()
        }
    }

    /// The serialized status document, redacted whole. Per-field redaction already
    /// covers the assistant preview; running `MemoryRedactor` over the final JSON is
    /// defense in depth against any field that starts carrying terminal-derived text.
    func statusBody(now: Date = Date()) -> String {
        let target = liveTargets().first
        let runtime = target?.runtime
        let iso = ISO8601DateFormatter()

        var lastError: String?
        if case .failed(let message)? = runtime?.state {
            lastError = Self.sanitizeFailureText(message)
        } else {
            lastError = lastFailureText
        }
        let preview = runtime?.transcript.messages
            .last(where: { $0.role == .assistant && !$0.text.isEmpty })
            .map { String(MemoryRedactor.redact($0.text).prefix(200)) }
        let lastTurnAt = runtime?.transcript.messages
            .last(where: { $0.role == .user || $0.role == .assistant })?
            .timestamp

        let object: [String: Any] = [
            "schema": 1,
            "device": Self.deviceName,
            "device_id8": DeviceIdentity.short,
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "agent": runtime?.agent.name as Any? ?? NSNull(),
            "state": runtime.map { Self.stateLabel($0.state) } as Any? ?? NSNull(),
            "mode": runtime?.mode.rawValue as Any? ?? NSNull(),
            "monitoring_armed": runtime?.isMonitoring as Any? ?? NSNull(),
            "arm_source": runtime?.monitoringArmSource.rawValue as Any? ?? NSNull(),
            "suppressed": runtime?.monitoringSuppressed as Any? ?? NSNull(),
            "last_applied_id": applied.lastAppliedID as Any? ?? NSNull(),
            "last_turn_at": lastTurnAt.map(iso.string(from:)) as Any? ?? NSNull(),
            "last_assistant_preview": preview as Any? ?? NSNull(),
            "last_error": lastError as Any? ?? NSNull(),
            "updated_at": iso.string(from: now),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return MemoryRedactor.redact(String(decoding: data, as: UTF8.self))
    }

    static func stateLabel(_ state: AgentRuntime.RunState) -> String {
        switch state {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .awaitingApproval: return "awaitingApproval"
        case .failed: return "failed"
        }
    }

    // MARK: - Bookkeeping

    private func registerFailure(_ message: String) {
        lastFailureText = message
        guard failureThrottle.shouldAudit(message, now: Date()) else { return }
        audit(message)
    }

    /// Feeds the editor's "last poll" line. Status text only — the URLs themselves
    /// never land in defaults values that views might render or exports collect.
    private func recordPollOutcome(_ status: String) {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: RemoteSupervisionConfig.lastPollAtKey)
        defaults.set(status, forKey: RemoteSupervisionConfig.lastPollStatusKey)
        NotificationCenter.default.post(
            name: RemoteSupervisionConfig.pollOutcomeNotification, object: nil
        )
    }

    private static func shortError(_ error: Error) -> String {
        sanitizeFailureText(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    /// Failure text can embed the failing URL (some NSURLError userInfo does), and a
    /// presigned URL's query string IS the credential. Strip the configured URLs and
    /// any presigned-signature token before the text reaches an audit line or the
    /// uplinked status document, then apply the display cap.
    static func sanitizeFailureText(_ text: String) -> String {
        var result = text
        for url in [RemoteSupervisionConfig.directiveURL, RemoteSupervisionConfig.statusURL]
            where !url.isEmpty {
            result = result.replacingOccurrences(of: url, with: "[url]")
        }
        result = result.replacingOccurrences(
            of: #"X-Amz-[A-Za-z-]+=[^&\s]*"#,
            with: "[redacted]",
            options: .regularExpression
        )
        return result.count > 120 ? String(result.prefix(120)) + "…" : result
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        UIDevice.current.name
        #endif
    }
}

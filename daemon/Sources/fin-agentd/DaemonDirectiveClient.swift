import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One remote instruction, decoded from the supervisor's directive document. The wire
/// schema is the app's `RemoteDirective` (fin/Agent/AgentDirectiveChannel.swift) —
/// duplicated minimally here because those types compile into the app target only, and
/// FinAgentCore deliberately stays free of the supervision channel. Tolerant by
/// construction: unknown fields are ignored, `agent` defaults to the "*" wildcard, and
/// the optional monitor fields may be absent.
struct DaemonRemoteDirective: Decodable, Equatable {
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
struct DaemonDirectiveDocument: Decodable {
    let version: Int
    let issuedAt: String?
    let directives: [DaemonRemoteDirective]

    private struct TolerantElement: Decodable {
        let value: DaemonRemoteDirective?
        init(from decoder: Decoder) throws {
            value = try? DaemonRemoteDirective(from: decoder)
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

    static func parse(_ data: Data) -> DaemonDirectiveDocument? {
        try? JSONDecoder().decode(DaemonDirectiveDocument.self, from: data)
    }
}

/// What the daemon knows about itself when a status uplink goes out.
struct DaemonStatusSnapshot {
    var state: String
    var lastTurnAt: Date?
    var lastAssistantPreview: String?
    /// The most recent turn failure, if any — the status document's `last_error`.
    var lastError: String?
}

/// One polled document: its URL, ETag, last good parse, and whether the most recent
/// refresh succeeded. Two of these are polled on the same tick — the supervisor's
/// directive channel and the app's inbox — and everything downstream is shared,
/// including the applied-id ledger.
private struct PolledDocument {
    let url: String
    /// Audit prefix for this source's failures; the directive channel's strings predate
    /// the inbox and stay unchanged.
    let failurePrefix: String
    /// How the first-run audit lines name this source.
    let seedNoun: SeedNoun
    var etag: String?
    var cached: DaemonDirectiveDocument?
    /// False after a hard failure, so a source that just failed contributes nothing this
    /// pass instead of replaying a stale cache. The other source is unaffected.
    var isFresh = false
    /// First run only: true after a read that found NO object at the URL — HTTP 404,
    /// and only that (`DaemonDirectiveClient.absentStatus`). Reset by every read, and
    /// only ever set while `seedPending`: after the seed a 404 is a poll failure again,
    /// exactly as before.
    var absent = false
    /// True while this source's first-run high-water hasn't been drawn yet — see
    /// `seedLedgerIfFirstRun`. Each slot draws its own, independently.
    var seedPending = false

    struct SeedNoun {
        /// "no supervision directive document yet" / "no inbox document yet"
        let absent: String
        /// Formats the seeded-count line.
        let seeded: (Int) -> String
    }
}

/// The daemon's consumer of the S3 remote-supervision channel: polls the directive URL
/// (ETag-aware, body-capped) and the optional app-written inbox URL, hands matching
/// `user_message` entries to the daemon to inject between turns, dedupes applied ids in a
/// JSON state file next to the audit log, and PUTs a small status document after each
/// poll and turn.
///
/// Deliberately simpler than the app's `AgentDirectiveChannel`: one agent, one loop, no
/// deferral ledger — a directive the daemon can't apply yet simply stays unapplied and is
/// returned again on the next poll.
@MainActor
final class DaemonDirectiveClient {
    /// Same input bounds as the app's channel: the bucket is remote input all the same.
    static let maxBodyBytes = 1_048_576
    static let maxDirectiveTextLength = 8000
    static let appliedIDsCap = 500
    static let requestTimeout: TimeInterval = 10
    static let failureAuditWindow: TimeInterval = 5 * 60
    static let userMessageKind = "user_message"
    /// Reported in the status document so a supervisor can tell which harness features
    /// (stayResident, cloud transcript, inbox, push notify) this agent has.
    static let daemonVersion = "1.4.1"
    /// The ONE status that means "no such object" on a first-run read. S3 answers 404
    /// for a missing key when the signer may `s3:ListBucket` — the control plane's and
    /// the operator's signers hold it for exactly that reason (control-plane commit
    /// 59222fa, `SeeMissingAgentObjects`).
    ///
    /// 403 is deliberately NOT absent, at first run or ever. S3 answers 403 for a
    /// missing key when the signer lacks ListBucket — but also for an expired presigned
    /// URL, a signature mismatch, an expired token, a revoked or wrong access key, and
    /// a denied bucket policy; and the body's `<Code>` can't split them, because
    /// `AccessDenied` is what both a missing key without ListBucket and a denied read
    /// say, so no parse is attempted. Reading 403 as absent would let a resident install
    /// that starts with stale URLs complete its seed EMPTY and persist a ledger; the
    /// operator re-mints the URLs, restarts in the same state directory, and — no
    /// longer a first run — every unapplied directive and the whole inbox backlog
    /// replay, one model turn each. So a 403 is always a poll failure that leaves the
    /// seed pending, exactly as under 1.4.0. The cost: a signer without ListBucket sees
    /// its seed deferred until the document exists, which is the safe direction —
    /// nothing is stamped history on the strength of a status that may mean "denied".
    static let absentStatus = 404

    #if !canImport(Darwin)
    /// Linux only: the default fetch's buffered read runs through this session, whose
    /// resource timeout bounds the TOTAL transfer time — `URLRequest.timeoutInterval`
    /// alone is an idle timer, which a slow-drip body never trips.
    static let linuxBufferedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    #endif

    /// Injected transport, so tests never touch the network.
    var fetch: (URLRequest) async throws -> (Data, URLResponse)
    var put: (URLRequest) async throws -> URLResponse
    let audit: (String) -> Void

    let directiveURL: String
    let statusURL: String?
    /// The app-written second channel, same schema as directives. nil = inbox off.
    let inboxURL: String?
    let agentName: String
    let pollSeconds: Int
    /// Short host identifier echoed in the status document, matching the app's mirror
    /// file naming (`DeviceIdentity.short`).
    let deviceToken8: String
    private let stateFilePath: String

    private var directiveDocument: PolledDocument
    private var inboxDocument: PolledDocument?
    /// Ids this daemon applied (or hard-skipped) itself, oldest first, capped at
    /// `appliedIDsCap` with the oldest evicted.
    private(set) var appliedIDs: [String]
    /// The first-run high-water of the DIRECTIVE document: every id in it, in document
    /// order, the first time a fresh box read it. Kept apart from `appliedIDs` and never
    /// capped — the document can hold more than `appliedIDsCap` entries, and a seeded id
    /// evicted from the cap would replay, which is the very thing the seed exists to
    /// stop. Written once by `seedLedgerIfFirstRun`, then only ever read.
    private(set) var seededIDs: [String] {
        didSet { rebuildSeededLookup() }
    }
    /// The inbox's own first-run high-water, kept apart so the status document's
    /// `last_applied_id` can keep reporting the directive mark: inbox ids are opaque
    /// (`m-<uuid>`) and mean nothing to a supervisor reading that field.
    private(set) var seededInboxIDs: [String] {
        didSet { rebuildSeededLookup() }
    }
    private var seededLookup: Set<String>
    /// Skip audits are once per directive id, so a permanently bad entry writes one
    /// line, not one per poll.
    private var auditedSkips: Set<String> = []
    /// Failure audits are once per 5 minutes per distinct error string, so a dead
    /// bucket writes one line per window, not one per poll.
    private var lastFailureAuditAt: [String: Date] = [:]
    private var lastPollAt: Date?

    /// - Parameters:
    ///   - inboxResetAtLaunch: Whether whatever launched this daemon emptied the inbox
    ///     document first — the control plane's `POST /workers` does, right before the
    ///     instance launch. True exempts the inbox from the first-run seed (anything in
    ///     it by the first read arrived while the worker booted and must apply); false,
    ///     the default and the resident-install posture, seeds the inbox's backlog as
    ///     history like the directive document's.
    ///   - hasRunHereBefore: Evidence from outside the ledger that the daemon has run on
    ///     this box — the daemon passes whether its audit log already existed at launch.
    ///     A 1.3.0 daemon wrote the ledger only on its first apply, so a missing ledger
    ///     alone can't tell a fresh box from a 1.3.0 box that never applied anything;
    ///     seeding the latter would swallow the next directive as history. The verdict
    ///     is written as an empty, non-pending ledger, so the next launch reads it back
    ///     instead of re-deriving it from the audit log's existence. And because a
    ///     first run writes its own (pending) ledger at init, before any document is
    ///     read, this rule can only fire on a genuine 1.3.0 box: a 1.4.x first run
    ///     leaves a ledger behind even when every read failed.
    ///   - fetch: The transport; nil (the default) is the real one — streaming and
    ///     body-capped on Darwin, buffered under a total-time timeout on Linux.
    init(
        directiveURL: String,
        statusURL: String?,
        inboxURL: String? = nil,
        inboxResetAtLaunch: Bool = false,
        agentName: String,
        pollSeconds: Int,
        deviceToken8: String = DaemonConfig.defaultDeviceToken8,
        stateFilePath: String,
        hasRunHereBefore: Bool = false,
        audit: @escaping (String) -> Void = { _ in },
        fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return response
        }
    ) {
        self.directiveURL = directiveURL
        self.statusURL = statusURL
        self.inboxURL = inboxURL
        self.agentName = agentName
        self.pollSeconds = max(5, pollSeconds)
        self.deviceToken8 = deviceToken8
        self.stateFilePath = stateFilePath
        self.directiveDocument = PolledDocument(
            url: directiveURL,
            failurePrefix: "[s3] poll failed",
            seedNoun: .init(
                absent: "no supervision directive document yet",
                seeded: { "\($0) historical directive(s) in the supervision doc marked applied, not replayed" }
            )
        )
        self.inboxDocument = inboxURL.map {
            PolledDocument(
                url: $0,
                failurePrefix: "[s3] inbox poll failed",
                seedNoun: .init(
                    absent: "no inbox document yet",
                    seeded: { "\($0) message(s) already in the inbox marked applied, not replayed" }
                )
            )
        }
        self.audit = audit
        self.fetch = fetch ?? { request in
            #if canImport(Darwin)
            // Streaming, not `URLSession.data`: the body cap must bound memory, so a
            // hostile multi-hundred-MB (or slow-drip) object is cancelled one byte
            // past the cap instead of buffered whole — the same accumulate pattern as
            // the app's `AgentDirectiveChannel`. The oversize count then fails the
            // poll's body-size check.
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if response.expectedContentLength > Int64(DaemonDirectiveClient.maxBodyBytes) {
                // An honest oversize Content-Length never reads the body at all.
                bytes.task.cancel()
                return (Data(), response)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > DaemonDirectiveClient.maxBodyBytes {
                    bytes.task.cancel()
                    break
                }
            }
            return (data, response)
            #else
            // corelibs Foundation has no `URLSession.bytes`; the buffered read stays,
            // bounded by this session's total-time resource timeout so a slow-drip
            // body dies on the clock, with the poll's post-read size check intact.
            return try await DaemonDirectiveClient.linuxBufferedSession.data(for: request)
            #endif
        }
        self.put = put
        switch Self.loadLedger(from: stateFilePath) {
        case .loaded(let ledger):
            self.appliedIDs = ledger.applied
            self.seededIDs = ledger.seeded
            self.seededInboxIDs = ledger.inboxSeeded
            self.seededLookup = Set(ledger.seeded).union(ledger.inboxSeeded)
            // A ledger persisted while a first run was still waiting for a document (an
            // inbox message applied, then a restart) resumes the wait — it is not a
            // "has run before", or the whole shared document would replay the moment
            // the directive URL recovers. Each slot resumes its own.
            self.directiveDocument.seedPending = ledger.seedPending
            if ledger.seedPending {
                audit("[s3] first run: resumed with the directive seed still pending")
            }
            if inboxDocument != nil, ledger.inboxSeedPending {
                self.inboxDocument?.seedPending = true
                audit("[s3] first run: resumed with the inbox seed still pending")
            }
        case .missing where hasRunHereBefore:
            // No ledger, but the box has run this daemon: a 1.3.0 daemon that never
            // applied a directive left no ledger behind, only its audit log. Not a
            // first run — every unapplied directive is delivered, as 1.3.0 would have.
            // The verdict is written down as an empty, non-pending ledger, so the next
            // launch reads "has run here" from the file instead of re-deriving it from
            // the audit log's existence every time.
            self.appliedIDs = []
            self.seededIDs = []
            self.seededInboxIDs = []
            self.seededLookup = []
            audit("[s3] no directive ledger, but the audit log predates this launch — not a first run, nothing seeded")
            persistLedger()
        case .missing:
            // A box this daemon has never run on: the shared supervision document is
            // history to it, not instructions — and so is the inbox's backlog, unless
            // the launcher emptied the inbox first. Seeded on the first fresh fetch.
            //
            // The pending verdict is written down NOW, before any document is read.
            // A first run leaves the audit log behind whatever its reads did, and a
            // restart must not be judged by that alone: a resident install whose
            // presigned URLs are stale (403 on every read, so no seed ever lands),
            // restarted with re-minted URLs in the same state directory, would read
            // "audit log, no ledger" — the 1.3.0-upgrade rule above — and deliver the
            // whole backlog, the exact replay the seed exists to prevent. With this
            // file on disk the next launch is `.loaded` with the seeds still pending
            // and resumes the wait; the upgrade rule can then only fire on a genuine
            // 1.3.0 box. A write that fails is audited (throttled, like every ledger
            // write), and that next launch is judged by the audit log after all.
            self.appliedIDs = []
            self.seededIDs = []
            self.seededInboxIDs = []
            self.seededLookup = []
            self.directiveDocument.seedPending = true
            self.inboxDocument?.seedPending = !inboxResetAtLaunch
            persistLedger(failurePrefix: "[s3] first run: could not persist the pending ledger")
        case .corrupt:
            // Starting with an empty dedupe set means already-applied directives may
            // replay; the supervisor must be able to see why. Not a first run — the
            // daemon HAS run here — so nothing is seeded and the replay is visible.
            self.appliedIDs = []
            self.seededIDs = []
            self.seededInboxIDs = []
            self.seededLookup = []
            audit("[s3] state file unreadable — dedupe reset")
        }
    }

    private func rebuildSeededLookup() {
        seededLookup = Set(seededIDs).union(seededInboxIDs)
    }

    /// Whether enough time has passed since the last poll attempt.
    var pollIsDue: Bool {
        guard let lastPollAt else { return true }
        return Date().timeIntervalSince(lastPollAt) >= TimeInterval(pollSeconds)
    }

    /// True while any slot still owes its first-run seed.
    var isFirstRun: Bool {
        directiveDocument.seedPending || inboxDocument?.seedPending == true
    }

    // MARK: - Polling

    /// One GET against the directive URL, plus one against the inbox URL when
    /// configured. Returns the not-yet-applied entries that match this agent: directives
    /// first, then inbox messages, each in its own document order. A source whose fetch
    /// or parse failed contributes nothing this pass, after an audited failure; the other
    /// source is unaffected.
    func poll() async -> [DaemonRemoteDirective] {
        lastPollAt = Date()
        directiveDocument = await refreshed(directiveDocument)
        if let inbox = inboxDocument { inboxDocument = await refreshed(inbox) }
        seedLedgerIfFirstRun()
        return pendingDirectives()
    }

    /// The launch-time half of the first run: reads each still-unseeded document once,
    /// right now, so the high-water is drawn at LAUNCH — before the SSH connect, the
    /// readiness probes and the first task turn, which together can run for minutes,
    /// during which every directive an operator wrote would otherwise be stamped
    /// history. The daemon calls this before it even opens SSH. No-op unless this is a
    /// first run. A fetch that fails here audits once (beyond the throttled failure
    /// line) and leaves that slot's seed pending for the poll loop; the bucket never
    /// stops the daemon starting. Not a poll: the loop's first poll still runs on
    /// schedule, and its conditional GET rides the ETag this fetch recorded.
    func primeFirstRunSeed() async {
        guard isFirstRun else { return }
        if directiveDocument.seedPending {
            directiveDocument = await refreshed(directiveDocument)
        }
        if let inbox = inboxDocument, inbox.seedPending {
            inboxDocument = await refreshed(inbox)
        }
        seedLedgerIfFirstRun()
        if directiveDocument.seedPending {
            audit("[s3] first run: directive document not read at launch — seed deferred to the next poll")
        }
        if inboxDocument?.seedPending == true {
            audit("[s3] first run: inbox document not read at launch — seed deferred to the next poll")
        }
    }

    /// First run only: the first document actually read from a slot becomes that slot's
    /// high-water mark. Every id in it — matching this agent or not, well-formed or not
    /// — is recorded as seeded without being injected, because on a fresh box (a new
    /// cloud worker, a new install) the shared directive document is the supervisor's
    /// whole history and the inbox is the phone's, and replaying either burns a model
    /// turn re-answering every week-old prompt. The control plane can empty the
    /// per-agent inbox at launch (and a config with `inboxResetAtLaunch` says it did,
    /// which exempts the inbox here) but cannot empty the directive document, which
    /// every agent shares — so the daemon draws that line itself.
    ///
    /// A slot whose object does not exist yet (`absent` — HTTP 404, nothing else) has no
    /// history: its seed completes empty, so the first entry written afterwards is
    /// delivered rather than becoming the "first successful read" and getting seeded. A
    /// failed or unparseable read — a 403 included, whatever S3 meant by it — leaves the
    /// seed pending for the next poll, and in that window `matching(in:)` returns
    /// nothing for the slot anyway. Persisting even an empty seed creates the ledger
    /// file, so an in-place restart is no longer a first run — which is exactly why a
    /// status that may mean "denied" must never complete a seed.
    private func seedLedgerIfFirstRun() {
        var persist = false
        if directiveDocument.seedPending,
           let resolution = Self.seedResolution(of: directiveDocument) {
            directiveDocument.seedPending = false
            persist = true
            switch resolution {
            case .absent:
                audit("[s3] first run: \(directiveDocument.seedNoun.absent) (HTTP \(Self.absentStatus)) — nothing to seed")
            case .document(let ids):
                seededIDs = ids
                if !ids.isEmpty { audit("[s3] first run: \(directiveDocument.seedNoun.seeded(ids.count))") }
            }
        }
        if let inbox = inboxDocument, inbox.seedPending,
           let resolution = Self.seedResolution(of: inbox) {
            inboxDocument?.seedPending = false
            persist = true
            switch resolution {
            case .absent:
                audit("[s3] first run: \(inbox.seedNoun.absent) (HTTP \(Self.absentStatus)) — nothing to seed")
            case .document(let ids):
                seededInboxIDs = ids
                if !ids.isEmpty { audit("[s3] first run: \(inbox.seedNoun.seeded(ids.count))") }
            }
        }
        if persist {
            persistLedger(failurePrefix: "[s3] first run: could not persist the seed")
        }
    }

    private enum SeedResolution {
        /// HTTP 404 at first run: no object, no history.
        case absent
        case document([String])
    }

    /// What a slot's most recent read says for its seed: nil when it said nothing usable
    /// (failed, unparseable, or a 304 with no cached body — a caching proxy can answer
    /// that even to an unconditional first GET).
    private static func seedResolution(of slot: PolledDocument) -> SeedResolution? {
        if slot.absent { return .absent }
        guard slot.isFresh, let cached = slot.cached else { return nil }
        var seen = Set<String>()
        return .document(cached.directives.map(\.id).filter { seen.insert($0).inserted })
    }

    /// One conditional GET, returning the slot with its ETag and cached parse updated.
    private func refreshed(_ slot: PolledDocument) async -> PolledDocument {
        var document = slot
        document.isFresh = false
        document.absent = false
        guard let url = URL(string: document.url), !document.url.isEmpty else {
            registerFailure("\(document.failurePrefix): invalid URL")
            return document
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        if let etag = document.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await fetch(request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            if status == 304 {
                // Unchanged bytes, but not necessarily nothing to do: an entry the
                // daemon couldn't apply on an earlier pass gets its retry here.
                document.isFresh = true
                return document
            }
            guard (200..<300).contains(status) else {
                if document.seedPending, status == Self.absentStatus {
                    // First run, and no object at this URL: not a failure — there is
                    // no history here. `seedLedgerIfFirstRun` completes the seed
                    // empty. After the seed the same status is a poll failure again.
                    // 404 ONLY: a 403 falls through to the failure below and keeps
                    // the seed pending, because it may mean "denied" — see
                    // `absentStatus`.
                    document.absent = true
                    return document
                }
                registerFailure("\(document.failurePrefix): HTTP \(status)")
                return document
            }
            guard data.count <= Self.maxBodyBytes,
                  response.expectedContentLength <= Int64(Self.maxBodyBytes) else {
                registerFailure("\(document.failurePrefix): body too large")
                return document
            }
            guard let parsed = DaemonDirectiveDocument.parse(data) else {
                registerFailure("\(document.failurePrefix): unparseable directive document")
                return document
            }
            // Adopted only on a successful parse, so a garbled body is refetched next
            // poll instead of being 304-pinned.
            document.etag = http?.value(forHTTPHeaderField: "ETag") ?? document.etag
            document.cached = parsed
            document.isFresh = true
        } catch {
            registerFailure("\(document.failurePrefix): \(Self.shortError(error))")
        }
        return document
    }

    /// Both cached documents' matching, not-yet-applied `user_message` entries, in
    /// directives-then-inbox order. Structurally bad entries (wrong kind, empty or
    /// oversized text) are marked applied with one audit line so they never surface
    /// again.
    private func pendingDirectives() -> [DaemonRemoteDirective] {
        var pending = matching(in: directiveDocument)
        if let inboxDocument { pending += matching(in: inboxDocument) }
        return pending
    }

    /// One document's contribution. Ids are matched as opaque strings — the app writes
    /// arbitrary inbox ids ("m-<uuid>"), so nothing here may assume the supervisor's
    /// monotonic "d-N" shape.
    private func matching(in document: PolledDocument) -> [DaemonRemoteDirective] {
        guard document.isFresh, let cached = document.cached else { return [] }
        var pending: [DaemonRemoteDirective] = []
        for directive in cached.directives {
            guard !isApplied(directive.id) else { continue }
            guard directive.matches(agentNamed: agentName) else { continue }
            guard directive.kind == Self.userMessageKind else {
                skip(directive.id, "unknown kind \"\(directive.kind)\"")
                continue
            }
            let text = (directive.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                skip(directive.id, "empty text")
                continue
            }
            guard text.count <= Self.maxDirectiveTextLength else {
                skip(directive.id, "text exceeds \(Self.maxDirectiveTextLength) characters")
                continue
            }
            pending.append(directive)
        }
        return pending
    }

    /// Applied by this daemon, or in a first-run seed — either way, never injected.
    private func isApplied(_ id: String) -> Bool {
        seededLookup.contains(id) || appliedIDs.contains(id)
    }

    /// Called by the daemon the moment it injects a directive's text into the engine.
    func markApplied(_ id: String) {
        appliedIDs.append(id)
        capAppliedIDs()
        persistLedger()
        audit("[s3] applied directive \(id)")
    }

    private func skip(_ id: String, _ reason: String) {
        appliedIDs.append(id)
        capAppliedIDs()
        persistLedger()
        guard !auditedSkips.contains(id) else { return }
        auditedSkips.insert(id)
        audit("[s3] skipped directive \(id): \(reason)")
    }

    // MARK: - Status uplink

    /// PUTs the daemon's status document. Failures audit (throttled) and are otherwise
    /// swallowed — a dead status bucket must never take down the agent.
    func putStatus(_ snapshot: DaemonStatusSnapshot, now: Date = Date()) async {
        guard let statusURL, !statusURL.isEmpty, let url = URL(string: statusURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(statusBody(snapshot, now: now).utf8)
        do {
            let response = try await put(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                registerFailure("[s3] put failed: HTTP \(http.statusCode)")
            }
        } catch {
            registerFailure("[s3] put failed: \(Self.shortError(error))")
        }
    }

    /// The serialized status document — the daemon's slice of the app's status schema.
    func statusBody(_ snapshot: DaemonStatusSnapshot, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        let preview = snapshot.lastAssistantPreview.map { String($0.prefix(200)) }
        let object: [String: Any] = [
            "schema": 1,
            "device": "fin-agentd",
            "device_id8": deviceToken8,
            "daemon_version": Self.daemonVersion,
            "agent": agentName,
            "state": snapshot.state,
            // After a first-run seed and before any real apply, the LAST id in the
            // directive document as seeded — the high-water mark when the supervisor
            // appends, which is the document's contract; the seed keeps document
            // order and never sorts. The inbox seed is deliberately not consulted:
            // its ids are opaque, and this field is the supervisor's mark.
            "last_applied_id": (appliedIDs.last ?? seededIDs.last) as Any? ?? NSNull(),
            "last_turn_at": snapshot.lastTurnAt.map(iso.string(from:)) as Any? ?? NSNull(),
            "last_assistant_preview": preview as Any? ?? NSNull(),
            "last_error": snapshot.lastError as Any? ?? NSNull(),
            "updated_at": iso.string(from: now),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Bookkeeping

    private func registerFailure(_ message: String) {
        let now = Date()
        if let last = lastFailureAuditAt[message],
           now.timeIntervalSince(last) < Self.failureAuditWindow {
            return
        }
        lastFailureAuditAt[message] = now
        audit(message)
    }

    private static func shortError(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return String(text.prefix(200))
    }

    // MARK: - Ledger persistence

    /// The on-disk ledger. 1.3.0 wrote a bare `[String]` of applied ids (still loaded);
    /// since 1.4.0 the file is this object, because the first-run seed needs things a
    /// capped array can't hold: the seeded ids themselves, uncapped (`seededIDs`), and
    /// whether a first run is still waiting for its directive document, so a restart in
    /// that window — systemd's `Restart=always` after a failed-turn exit, stale
    /// presigned URLs re-minted by the operator — resumes the wait instead of replaying
    /// the whole document once the directive URL recovers. Since 1.4.1 the first run
    /// writes the file with that flag set at init, before any document is read, so the
    /// restart always finds it; 1.4.1 also adds the inbox's own pair. Every key is
    /// optional on read, each defaulting to "nothing": a file with
    /// only `applied` keeps its applied ids instead of counting as corrupt and
    /// resetting dedupe — the same forward tolerance the directive document has.
    struct LedgerFile: Codable, Equatable {
        var applied: [String]
        var seeded: [String]
        var seedPending: Bool
        var inboxSeeded: [String]
        var inboxSeedPending: Bool

        enum CodingKeys: String, CodingKey {
            case applied, seeded
            case seedPending = "seed_pending"
            case inboxSeeded = "inbox_seeded"
            case inboxSeedPending = "inbox_seed_pending"
        }

        init(applied: [String] = [], seeded: [String] = [], seedPending: Bool = false,
             inboxSeeded: [String] = [], inboxSeedPending: Bool = false) {
            self.applied = applied
            self.seeded = seeded
            self.seedPending = seedPending
            self.inboxSeeded = inboxSeeded
            self.inboxSeedPending = inboxSeedPending
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            applied = try container.decodeIfPresent([String].self, forKey: .applied) ?? []
            seeded = try container.decodeIfPresent([String].self, forKey: .seeded) ?? []
            seedPending = try container.decodeIfPresent(Bool.self, forKey: .seedPending) ?? false
            inboxSeeded = try container.decodeIfPresent([String].self, forKey: .inboxSeeded) ?? []
            inboxSeedPending = try container.decodeIfPresent(Bool.self, forKey: .inboxSeedPending) ?? false
        }
    }

    /// The three ways the ledger file can come back at init, kept distinct on purpose:
    /// `missing` is a first run: the init writes the ledger with its seeds pending, and
    /// `seedLedgerIfFirstRun` completes them — unless the daemon has other evidence it
    /// ran here (`hasRunHereBefore`), in which case the init writes an empty ledger so
    /// that verdict is on disk from then on; `loaded` — even
    /// an empty `[]` — means the daemon has run here before and every unapplied
    /// directive is delivered (unless the file itself says a seed is still pending);
    /// `corrupt` is a reset worth one audit line (the init writes it), because it can
    /// replay directives the previous run already applied.
    private enum LedgerLoad {
        case missing
        case corrupt
        case loaded(LedgerFile)
    }

    private static func loadLedger(from path: String) -> LedgerLoad {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        // Present but unreadable (permissions, a directory at the path) is not a first
        // run: the daemon has run here, so it keeps today's behavior and says why.
        guard let data = FileManager.default.contents(atPath: path) else { return .corrupt }
        let decoder = JSONDecoder()
        if let ids = try? decoder.decode([String].self, from: data) {
            return .loaded(LedgerFile(applied: Array(ids.suffix(appliedIDsCap))))
        }
        guard var ledger = try? decoder.decode(LedgerFile.self, from: data) else { return .corrupt }
        ledger.applied = Array(ledger.applied.suffix(appliedIDsCap))
        return .loaded(ledger)
    }

    private func capAppliedIDs() {
        if appliedIDs.count > Self.appliedIDsCap {
            appliedIDs.removeFirst(appliedIDs.count - Self.appliedIDsCap)
        }
    }

    /// Writes the ledger atomically. A write that fails is audited under `failurePrefix`
    /// (throttled like any failure, so an unwritable state directory writes one line
    /// per window, not one per apply) rather than swallowed: since the first-run seed,
    /// a ledger that silently never lands turns the next launch into a first run again,
    /// which seeds — and drops — whatever was written in between.
    private func persistLedger(failurePrefix: String = "[s3] ledger write failed") {
        let ledger = LedgerFile(
            applied: appliedIDs,
            seeded: seededIDs,
            seedPending: directiveDocument.seedPending,
            inboxSeeded: seededInboxIDs,
            inboxSeedPending: inboxDocument?.seedPending ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(ledger).write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
        } catch {
            registerFailure("\(failurePrefix) — \(Self.shortError(error))")
        }
    }
}

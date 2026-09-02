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
    var etag: String?
    var cached: DaemonDirectiveDocument?
    /// False after a hard failure, so a source that just failed contributes nothing this
    /// pass instead of replaying a stale cache. The other source is unaffected.
    var isFresh = false
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
    /// (stayResident, cloud transcript, inbox) this agent has.
    static let daemonVersion = "1.1.0"

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
    private(set) var appliedIDs: [String]
    /// Skip audits are once per directive id, so a permanently bad entry writes one
    /// line, not one per poll.
    private var auditedSkips: Set<String> = []
    /// Failure audits are once per 5 minutes per distinct error string, so a dead
    /// bucket writes one line per window, not one per poll.
    private var lastFailureAuditAt: [String: Date] = [:]
    private var lastPollAt: Date?

    init(
        directiveURL: String,
        statusURL: String?,
        inboxURL: String? = nil,
        agentName: String,
        pollSeconds: Int,
        deviceToken8: String = DaemonConfig.defaultDeviceToken8,
        stateFilePath: String,
        audit: @escaping (String) -> Void = { _ in },
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
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
        },
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
            url: directiveURL, failurePrefix: "[s3] poll failed"
        )
        self.inboxDocument = inboxURL.map {
            PolledDocument(url: $0, failurePrefix: "[s3] inbox poll failed")
        }
        self.audit = audit
        self.fetch = fetch
        self.put = put
        let loaded = Self.loadAppliedIDs(from: stateFilePath)
        self.appliedIDs = loaded.ids
        if loaded.corrupt {
            // Starting with an empty dedupe set means already-applied directives may
            // replay; the supervisor must be able to see why.
            audit("[s3] state file unreadable — dedupe reset")
        }
    }

    /// Whether enough time has passed since the last poll attempt.
    var pollIsDue: Bool {
        guard let lastPollAt else { return true }
        return Date().timeIntervalSince(lastPollAt) >= TimeInterval(pollSeconds)
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
        return pendingDirectives()
    }

    /// One conditional GET, returning the slot with its ETag and cached parse updated.
    private func refreshed(_ slot: PolledDocument) async -> PolledDocument {
        var document = slot
        document.isFresh = false
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
            guard !appliedIDs.contains(directive.id) else { continue }
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

    /// Called by the daemon the moment it injects a directive's text into the engine.
    func markApplied(_ id: String) {
        appliedIDs.append(id)
        if appliedIDs.count > Self.appliedIDsCap {
            appliedIDs.removeFirst(appliedIDs.count - Self.appliedIDsCap)
        }
        persistAppliedIDs()
        audit("[s3] applied directive \(id)")
    }

    private func skip(_ id: String, _ reason: String) {
        appliedIDs.append(id)
        if appliedIDs.count > Self.appliedIDsCap {
            appliedIDs.removeFirst(appliedIDs.count - Self.appliedIDsCap)
        }
        persistAppliedIDs()
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
            "last_applied_id": appliedIDs.last as Any? ?? NSNull(),
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

    // MARK: - Applied-id persistence

    /// A missing file is the normal first run; a present-but-unparseable file is a
    /// corrupt dedupe state worth one audit line (the init writes it), because the
    /// reset can replay directives the previous run already applied.
    private static func loadAppliedIDs(from path: String) -> (ids: [String], corrupt: Bool) {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ([], false)
        }
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return ([], true)
        }
        return (Array(ids.suffix(appliedIDsCap)), false)
    }

    private func persistAppliedIDs() {
        guard let data = try? JSONEncoder().encode(appliedIDs) else { return }
        try? data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
    }
}

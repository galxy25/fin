import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's cloud transcript: a rolling, redacted copy of the audit trail PUT to a
/// presigned URL so the iOS app can render a remote agent's timeline without filesystem
/// access to the box it runs on.
///
/// The line format is a wire contract, not a local choice. Lines are parsed by the app's
/// `AgentMirrorRecord.init(jsonlLine:)` (fin/Agent/AgentMirrorReader.swift), which reads
/// the JSONL the app itself writes via `AgentLogEntry.jsonlLine()` — so the keys,
/// snake_case casing, and fraction-free ISO8601 timestamp here must match that writer
/// byte for byte. `DaemonTranscriptUplinkTests` pins the reader's expectations.
///
/// Every text field passes through `MemoryRedactor` before it enters the ring: this data
/// leaves the machine, and it quotes the same raw terminal output that keeps the app's
/// own log store off CloudKit.
@MainActor
final class DaemonTranscriptUplink {
    /// The app's `AgentLogKind` raw values. A kind outside this set decodes as `.notice`
    /// in the app anyway; mapping it here keeps the intent visible in the document.
    /// `turnStarted`/`turnProgress` are the turn-visibility schema (see `record` below
    /// for `turnStarted`'s immediate, non-batched flush) — only `turnStarted` is
    /// actually emitted today (`AgentTurnEngine.submit`); `turnProgress` has no emitter
    /// yet anywhere, listed here only so the wire schema is already correct the day one
    /// is added.
    static let mirrorKinds: Set<String> = [
        "userMessage", "assistantMessage", "reasoning", "toolCall",
        "toolResult", "approval", "notice", "error",
        "turnStarted", "turnProgress",
    ]
    static let fallbackKind = "notice"
    /// The one kind whose mirror line must reach the app within seconds, not wait for
    /// the batched flush interval — `record` below flushes immediately whenever an
    /// event of this kind comes through.
    static let immediateFlushKind = "turnStarted"
    /// Stands in for `agentID` when the config omits it — the key stays present so the
    /// document shape never varies, and an all-zero id is obviously not a real agent.
    static let unsetAgentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let requestTimeout: TimeInterval = 10
    /// Same throttle as the directive client's: a dead bucket writes one audit line per
    /// window per distinct error, not one per flush.
    static let failureAuditWindow: TimeInterval = 5 * 60

    /// Plain ISO8601, no fractional seconds — `AgentMirrorRecord.timestampFormatter` is a
    /// default `ISO8601DateFormatter`, which rejects a fractional-seconds string.
    static let timestampFormatter = ISO8601DateFormatter()

    let putURL: String
    let flushSeconds: Int
    let maxLines: Int
    /// One id for this daemon process, so the app groups the whole run together.
    let runID: UUID
    let agentID: UUID
    let agentName: String
    let server: String
    let modelIdentifier: String
    let temperature: Double

    /// Injected transport, so tests never touch the network.
    var put: (URLRequest) async throws -> URLResponse
    /// Deliberately writes to the local audit trail only, never back into the ring: a
    /// transcript nobody can fetch is the one place a PUT failure cannot be reported.
    let audit: (String) -> Void

    private(set) var lines: [String] = []
    private var sequence = 0
    private(set) var isDirty = false
    private var lastFlushAt: Date?
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        putURL: String,
        flushSeconds: Int,
        maxLines: Int,
        runID: UUID = UUID(),
        agentID: UUID?,
        agentName: String,
        server: String,
        modelIdentifier: String,
        temperature: Double,
        audit: @escaping (String) -> Void = { _ in },
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return response
        }
    ) {
        self.putURL = putURL
        self.flushSeconds = max(1, flushSeconds)
        self.maxLines = max(1, maxLines)
        self.runID = runID
        self.agentID = agentID ?? Self.unsetAgentID
        self.agentName = agentName
        self.server = server
        self.modelIdentifier = modelIdentifier
        self.temperature = temperature
        self.audit = audit
        self.put = put
    }

    // MARK: - Ring

    /// Appends one audit event as a mirror line, evicting the oldest once the ring is
    /// full. Unencodable events are dropped rather than truncating the document.
    ///
    /// `turnStarted` additionally kicks an IMMEDIATE flush — its whole reason to exist
    /// is the app seeing "received" within seconds, not waiting out `flushSeconds` (which
    /// can be minutes) or the caller's own post-turn flush (which, by definition, hasn't
    /// happened yet — the turn just started). Stays a fire-and-forget `Task` rather than
    /// making `record` itself `async`: every other call site is a plain, synchronous
    /// notice, and this is the one kind that needs to jump the queue, not a reason to
    /// make the whole ring API asynchronous.
    func record(_ event: AgentAuditEvent) {
        sequence += 1
        guard let line = mirrorLine(for: event, sequence: sequence) else { return }
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        isDirty = true
        if event.kind == Self.immediateFlushKind {
            Task { [weak self] in
                await self?.flush()
            }
        }
    }

    /// The whole document: every retained line, newline-joined, exactly as PUT.
    var body: String {
        lines.joined(separator: "\n")
    }

    /// One mirror line. Internal so the format tests can assert on it without staging a
    /// flush.
    func mirrorLine(for event: AgentAuditEvent, sequence: Int) -> String? {
        var object: [String: Any] = [
            "id": UUID().uuidString,
            "run_id": runID.uuidString,
            "sequence": sequence,
            "timestamp": Self.timestampFormatter.string(from: event.timestamp),
            "agent_id": agentID.uuidString,
            "agent_name": agentName,
            "server": server,
            "kind": Self.mirrorKinds.contains(event.kind) ? event.kind : Self.fallbackKind,
            "text": MemoryRedactor.redact(event.text),
            "model": modelIdentifier,
            "temperature": temperature,
            "attempt": event.attempt,
            "retry_count": event.retryCount,
            "is_failure": event.isFailure,
        ]
        if let toolName = event.toolName { object["tool_name"] = toolName }
        if let toolArguments = event.toolArguments {
            object["tool_arguments"] = MemoryRedactor.redact(toolArguments)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Uplink

    /// Whether the periodic flush window has elapsed. The post-turn flush ignores this;
    /// it is the ceiling on mid-turn PUTs, not a floor on freshness.
    func flushIsDue(now: Date = Date()) -> Bool {
        guard isDirty else { return false }
        guard let lastFlushAt else { return true }
        return now.timeIntervalSince(lastFlushAt) >= TimeInterval(flushSeconds)
    }

    /// PUTs the whole document if anything changed since the last successful attempt.
    /// Failures audit (throttled) and are otherwise swallowed — a dead transcript bucket
    /// must never take down the agent.
    func flush(now: Date = Date()) async {
        guard isDirty, !putURL.isEmpty, let url = URL(string: putURL) else { return }
        // Cleared before the PUT: a failure is reported, not retried on the next tick,
        // because the next line to arrive re-dirties the ring and the whole document
        // goes up again anyway.
        isDirty = false
        lastFlushAt = now
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        do {
            let response = try await put(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                registerFailure("[transcript] put failed: HTTP \(http.statusCode)")
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[transcript] put failed: \(text.prefix(200))")
        }
    }

    /// The periodic path: flushes only once the window has elapsed.
    func flushIfDue(now: Date = Date()) async {
        guard flushIsDue(now: now) else { return }
        await flush(now: now)
    }

    private func registerFailure(_ message: String) {
        let now = Date()
        if let last = lastFailureAuditAt[message],
           now.timeIntervalSince(last) < Self.failureAuditWindow {
            return
        }
        lastFailureAuditAt[message] = now
        audit(message)
    }
}

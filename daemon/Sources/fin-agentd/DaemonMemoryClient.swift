import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's memory sync: `remember` POSTs one entry to the control plane's `/memory`
/// route (upsert-by-id — same bearer-token relay `DaemonNotifyClient`/
/// `DaemonTranscriptUplink` use, no presigned URL), `recall` GETs the agent's whole
/// document and searches it client-side. Both the daemon and the app read/write this
/// SAME S3 document (`scripts/cloud-agent/control-plane/lambda.py`'s `put_memory_entry`/
/// `get_memory`), so a fact learned in either place stays in sync — the "collection of
/// journals, atomically written" source of truth.
///
/// The search itself mirrors the app's own `MemoryStore.searchMemories` exactly: a plain
/// case-insensitive substring match across title/content/tags, most-recent-first, capped
/// — so `recall` behaves the same whether the conversation is running on-device or here.
@MainActor
final class DaemonMemoryClient {
    static let requestTimeout: TimeInterval = 10
    /// Same throttle as this daemon's other control-plane clients: one audit line per
    /// window per distinct error, not one per call.
    static let failureAuditWindow: TimeInterval = 5 * 60
    /// Mirrors `MemoryStore.searchMemories`'s default limit.
    static let recallLimit = 5

    let endpointURL: String
    private let token: String
    let agentName: String
    let agentID: UUID?
    let originDeviceID8: String

    /// Injected transport, so tests never touch the network.
    var transport: (URLRequest) async throws -> (Data, URLResponse)
    let audit: (String) -> Void
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        endpointURL: String,
        token: String,
        agentName: String,
        agentID: UUID?,
        originDeviceID8: String,
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpointURL = endpointURL
        self.token = token
        self.agentName = agentName
        self.agentID = agentID
        self.originDeviceID8 = originDeviceID8
        self.audit = audit
        self.transport = transport
    }

    private func request(path: String, method: String) -> URLRequest? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        return request
    }

    /// POST /memory — one entry, upserted by a freshly minted id. `tags` is passed
    /// through verbatim (empty/nil omitted, matching the route's own optional-field
    /// shape). Returns `.saved` only on a confirmed 2xx; every other outcome is
    /// `.failed`, matching `onNotify`'s "report what actually happened" discipline.
    func remember(title: String, content: String, tags: String?) async -> AgentRememberOutcome {
        guard var httpRequest = request(path: "/memory", method: "POST") else {
            return .failed("control plane URL is not configured")
        }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let now = ISO8601DateFormatter().string(from: Date())
        var object: [String: Any] = [
            "agent": agentName,
            "id": "m-\(UUID().uuidString)",
            "kind": "episodic",
            "title": title,
            "content": content,
            "createdAt": now,
            "updatedAt": now,
            "originDevice8": originDeviceID8,
        ]
        if let agentID { object["agentId"] = agentID.uuidString }
        let trimmedTags = tags?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTags.isEmpty { object["tags"] = trimmedTags }
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            return .failed("could not encode the memory entry")
        }
        httpRequest.httpBody = body
        do {
            let (_, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[memory] remember failed: HTTP \(status)")
                return .failed("control plane returned HTTP \(status)")
            }
            return .saved
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] remember failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// GET /memory?agent= — fetches the whole document, then filters/sorts/caps
    /// exactly as `MemoryStore.searchMemories` does app-side: case-insensitive
    /// substring match across title/content/tags when `query` is non-empty, else
    /// most-recent-first, capped at `recallLimit`.
    func recall(query: String) async -> AgentRecallOutcome {
        guard let httpRequest = request(
            path: "/memory?agent=\(agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? agentName)",
            method: "GET"
        ) else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[memory] recall failed: HTTP \(status)")
                return .failed("control plane returned HTTP \(status)")
            }
            return .found(Self.search(document: data, query: query))
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] recall failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// The pure half of `recall`: parse `{"entries": [...]}`, filter, sort, cap.
    /// Internal so it's directly testable without staging a network round trip.
    static func search(document data: Data, query: String) -> [AgentRecallHit] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]]
        else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = entries.filter { entry in
            guard !trimmedQuery.isEmpty else { return true }
            let title = entry["title"] as? String ?? ""
            let content = entry["content"] as? String ?? ""
            let tags = entry["tags"] as? String ?? ""
            return title.localizedCaseInsensitiveContains(trimmedQuery)
                || content.localizedCaseInsensitiveContains(trimmedQuery)
                || tags.localizedCaseInsensitiveContains(trimmedQuery)
        }
        let sorted = matching.sorted { lhs, rhs in
            ((lhs["updatedAt"] as? String) ?? "") > ((rhs["updatedAt"] as? String) ?? "")
        }
        return sorted.prefix(recallLimit).map { entry in
            AgentRecallHit(
                title: entry["title"] as? String ?? "",
                content: entry["content"] as? String ?? ""
            )
        }
    }

    // MARK: - Compaction: episodic entries since a cutoff

    /// GET /memory?agent=&since= — every entry updated at or after `since` (nil = the
    /// whole document), newest first, capped at `limit`. Distinct from `recall`: this
    /// has no keyword filter and no hardcoded cap, since `DaemonMemoryConsolidator`
    /// wants "what's new since the profile was last written," not a search result.
    func episodicEntriesSince(_ since: Date?, limit: Int) async -> AgentRecallOutcome {
        var path = "/memory?agent=\(agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? agentName)"
        if let since {
            let stamp = ISO8601DateFormatter().string(from: since)
            path += "&since=\(stamp.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stamp)"
        }
        guard let httpRequest = request(path: path, method: "GET") else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[memory] episodic-since fetch failed: HTTP \(status)")
                return .failed("control plane returned HTTP \(status)")
            }
            return .found(Self.entriesSince(document: data, limit: limit))
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] episodic-since fetch failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// The pure half of `episodicEntriesSince`: parse `{"entries": [...]}`, sort newest
    /// first, cap. The server already filtered by `since`; this only sorts/caps.
    static func entriesSince(document data: Data, limit: Int) -> [AgentRecallHit] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]]
        else { return [] }
        let sorted = entries.sorted { lhs, rhs in
            ((lhs["updatedAt"] as? String) ?? "") > ((rhs["updatedAt"] as? String) ?? "")
        }
        return sorted.prefix(max(0, limit)).map { entry in
            AgentRecallHit(
                title: entry["title"] as? String ?? "",
                content: entry["content"] as? String ?? ""
            )
        }
    }

    // MARK: - Compaction: the shared cumulative profile

    struct ProfileDocument: Equatable {
        var content: String
        var updatedAt: Date?
    }

    enum ProfileReadOutcome: Equatable {
        case found(ProfileDocument)
        case failed(String)
    }

    enum ProfileWriteOutcome: Equatable {
        case saved
        case failed(String)
    }

    /// GET /memory/profile — the single, cross-agent cumulative summary; absent is
    /// `.found` with empty content, not a failure (nothing consolidated yet).
    func readProfile() async -> ProfileReadOutcome {
        guard let httpRequest = request(path: "/memory/profile", method: "GET") else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[memory] profile read failed: HTTP \(status)")
                return .failed("control plane returned HTTP \(status)")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failed("the control plane's response was not the expected shape")
            }
            let updatedAt = (object["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return .found(ProfileDocument(content: object["content"] as? String ?? "", updatedAt: updatedAt))
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] profile read failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// PUT /memory/profile — wholesale replace.
    func writeProfile(_ content: String) async -> ProfileWriteOutcome {
        guard var httpRequest = request(path: "/memory/profile", method: "PUT") else {
            return .failed("control plane URL is not configured")
        }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": content]) else {
            return .failed("could not encode the profile")
        }
        httpRequest.httpBody = body
        do {
            let (_, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[memory] profile write failed: HTTP \(status)")
                return .failed("control plane returned HTTP \(status)")
            }
            return .saved
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] profile write failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    // MARK: - Compaction: the claim lock

    enum LockOutcome: Equatable {
        case claimed
        /// Another holder has the lock and it isn't stale yet.
        case locked(holder: String)
        case failed(String)
    }

    /// PUT /memory/profile/lock — atomic claim, or a stale-lock reclaim, or word of who
    /// currently holds it. `holder` should uniquely identify this daemon process
    /// (`originDeviceID8` is what every other control-plane call here already uses).
    func claimProfileLock(holder: String) async -> LockOutcome {
        guard var httpRequest = request(path: "/memory/profile/lock", method: "PUT") else {
            return .failed("control plane URL is not configured")
        }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["holder": holder]) else {
            return .failed("could not encode the lock claim")
        }
        httpRequest.httpBody = body
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse else {
                registerFailure("[memory] lock claim failed: no HTTP response")
                return .failed("no response from the control plane")
            }
            if http.statusCode == 409 {
                let currentHolder = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                return .locked(holder: currentHolder ?? "another runner")
            }
            guard (200..<300).contains(http.statusCode) else {
                registerFailure("[memory] lock claim failed: HTTP \(http.statusCode)")
                return .failed("control plane returned HTTP \(http.statusCode)")
            }
            return .claimed
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[memory] lock claim failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// DELETE /memory/profile/lock — unconditional; call after every claimed attempt,
    /// success or failure, so the next runner doesn't wait out the stale-reclaim TTL.
    func releaseProfileLock() async {
        guard let httpRequest = request(path: "/memory/profile/lock", method: "DELETE") else { return }
        _ = try? await transport(httpRequest)
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

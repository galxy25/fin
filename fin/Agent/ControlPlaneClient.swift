import Foundation

/// The app's one door to the control plane's bearer-token routes: sites,
/// messages, and the transport `CloudWorkerClient` and `CloudAgentChannel`
/// each used to hand-roll (base-URL trimming, the lowercase `authorization`
/// header, JSON bodies). Every method is total — it returns a value, never
/// throws — and no error string it produces carries the endpoint or the token.
///
/// `transport` is injectable so tests drive the response tables without a
/// server; the pure `decode…` halves are the seams the tests actually pin.
enum ControlPlaneClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    nonisolated(unsafe) static var transport: Transport = { try await URLSession.shared.data(for: $0) }

    static let requestTimeout: TimeInterval = 10

    enum Failure: Equatable, Error {
        case notConfigured
        case network
        case http(Int, String)
    }

    // MARK: - Request plumbing

    static func url(path: String, query: [String: String] = [:]) -> URL? {
        guard CloudControlPlaneConfig.isConfigured else { return nil }
        var base = CloudControlPlaneConfig.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    static func request(_ method: String, path: String, query: [String: String] = [:], body: [String: Any]? = nil) -> URLRequest? {
        guard let url = url(path: path, query: query) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// One round trip → (status, body) or `.network`. The HTTP status is left to
    /// the caller's decoder, since 404 and 409 mean different things per route.
    static func perform(_ request: URLRequest?) async -> Result<(Int, Data), Failure> {
        guard let request else { return .failure(.notConfigured) }
        guard let (data, response) = try? await transport(request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failure(.network) }
        return .success((status, data))
    }

    static func errorMessage(status: Int, body: Data) -> String {
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (fields?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return message ?? "HTTP \(status)"
    }

    static func decode<T: Decodable>(_ type: T.Type, status: Int, body: Data) -> Result<T, Failure> {
        guard (200...299).contains(status) else { return .failure(.http(status, errorMessage(status: status, body: body))) }
        guard let value = try? Self.decoder.decode(type, from: body) else { return .failure(.http(status, "unreadable response")) }
        return .success(value)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO8601: \(text)"))
            }
            return date
        }
        return decoder
    }()

    // MARK: - Sites

    struct SitesResponse: Decodable { let sites: [FinSite] }

    static func listSites(agent: String? = nil) async -> Result<[FinSite], Failure> {
        var query: [String: String] = [:]
        if let agent, !agent.isEmpty { query["agent"] = agent }
        return await perform(request("GET", path: "/sites", query: query))
            .flatMap { decode(SitesResponse.self, status: $0.0, body: $0.1) }
            .map(\.sites)
    }

    enum SiteCommand: String, CaseIterable { case restart, update, stop, drain }

    static func siteCommand(_ siteID: String, _ command: SiteCommand) async -> Result<Void, Failure> {
        await perform(request("POST", path: "/sites/\(siteID)/commands", body: ["kind": command.rawValue]))
            .flatMap { status, body in
                (200...299).contains(status) ? .success(()) : .failure(.http(status, errorMessage(status: status, body: body)))
            }
    }

    /// Where this session's two halves meet: the relay the control plane
    /// launched (or reused) for it. Delivered per session rather than
    /// configured, because the relay is an on-demand body whose address is new
    /// every time one is launched — and because both sides being told the same
    /// address by the same call is what makes it impossible for the app and
    /// the site to end up on different relays.
    struct RelayAddress: Decodable, Equatable {
        let relayHost: String
        let relayPort: Int
    }

    /// Wakes a site's daemon to attach a local PTY to `tmuxSession` and open its
    /// end of the terminal-relay WebSocket for `sessionId`, and returns the
    /// relay address to dial. Delivered on the site's next heartbeat
    /// (`SiteDirectory`'s ~20s cadence), not instantly — and the relay itself
    /// may still be booting when this returns, which is why the caller's
    /// "waking…" state covers both waits.
    static func openTerminalRelay(_ siteID: String, sessionId: String, tmuxSession: String) async -> Result<RelayAddress, Failure> {
        await perform(request("POST", path: "/sites/\(siteID)/commands", body: [
            "kind": "terminal-open",
            "args": ["sessionId": sessionId, "tmuxSession": tmuxSession],
        ]))
        .flatMap { decode(RelayAddress.self, status: $0.0, body: $0.1) }
    }

    static func deleteSite(_ siteID: String) async -> Result<Void, Failure> {
        await perform(request("DELETE", path: "/sites/\(siteID)"))
            .flatMap { status, body in
                (200...299).contains(status) ? .success(()) : .failure(.http(status, errorMessage(status: status, body: body)))
            }
    }

    // MARK: - Client telemetry

    /// A named, closed vocabulary of terminal-relay breadcrumbs (must match
    /// `CLIENT_EVENT_KINDS` in the control plane's `lambda.py`) — without this,
    /// a connect blocked by a client-side guard, a command the control plane
    /// never saw, and a socket that opened and died immediately all look
    /// identical from the operator's side: silence. Fire-and-forget: a failed
    /// telemetry post must never affect the relay it is reporting on, so this
    /// returns nothing and the caller does not await failure.
    enum ClientEventKind: String {
        case relayConnectBlocked = "relay_connect_blocked"
        case relayCommandQueued = "relay_command_queued"
        case relayCommandFailed = "relay_command_failed"
        case relayWSOpen = "relay_ws_open"
        case relayWSOpenFailed = "relay_ws_open_failed"
        case relayWSReceiveFailed = "relay_ws_receive_failed"
        case relayWSMessage = "relay_ws_message"
        case relayState = "relay_state"
        case relayClosed = "relay_closed"
    }

    static func logClientEvent(_ kind: ClientEventKind, detail: [String: Any] = [:]) {
        var body: [String: Any] = ["kind": kind.rawValue]
        if !detail.isEmpty { body["detail"] = detail }
        Task { _ = await perform(request("POST", path: "/client-events", body: body)) }
    }

    // MARK: - Account

    /// What `DELETE /account` reports it removed, so the app can tell the user
    /// what actually happened instead of a bare "done".
    struct AccountDeletion: Decodable, Equatable {
        struct Counts: Decodable, Equatable {
            let instancesTerminated: Int?
            let sites: Int?
            let messages: Int?
            let objects: Int?
            let sessions: Int?
        }
        let deleted: Counts
    }

    /// Erases the Fin account and everything it owns (App Store Guideline
    /// 5.1.1(v)). The server destroys every session as its last act, so the
    /// token this call authenticated with is dead on return — the caller MUST
    /// clear it locally (`CloudControlPlaneConfig.setToken("")`), which is
    /// also the right thing to do when the account is already gone.
    ///
    /// A 401 counts as success: it means no session remained to delete, so the
    /// account is not there to be deleted either. Anything else is reported,
    /// including the server's own 500 when a stage could not be swept — the
    /// user is told to contact support rather than shown a false "deleted".
    static func deleteAccount() async -> Result<AccountDeletion?, Failure> {
        await perform(request("DELETE", path: "/account")).flatMap { status, body in
            if (200...299).contains(status) {
                return .success(try? JSONDecoder().decode(AccountDeletion.self, from: body))
            }
            if status == 401 { return .success(nil) }
            return .failure(.http(status, errorMessage(status: status, body: body)))
        }
    }

    /// The sentence shown after a successful deletion. Pure so the wording is
    /// pinned by a test rather than only visible on a device.
    static func deletionSummary(_ deletion: AccountDeletion?) -> String {
        guard let counts = deletion?.deleted else {
            return "Your Fin account is gone. This device is signed out."
        }
        var parts: [String] = []
        if let value = counts.instancesTerminated, value > 0 {
            parts.append(value == 1 ? "1 cloud computer shut down" : "\(value) cloud computers shut down")
        }
        if let value = counts.sites, value > 0 {
            parts.append(value == 1 ? "1 computer unlinked" : "\(value) computers unlinked")
        }
        if let value = counts.objects, value > 0 {
            parts.append(value == 1 ? "1 stored file erased" : "\(value) stored files erased")
        }
        guard !parts.isEmpty else {
            return "Your Fin account is gone. This device is signed out."
        }
        return "Your Fin account is gone: " + parts.joined(separator: ", ")
            + ". Every device is signed out."
    }

    // MARK: - Messages

    /// The control plane's row, as `_public_message` renders it.
    struct Message: Decodable, Equatable, Identifiable {
        var id: String { messageId }
        let messageId: String
        let agent: String?
        let text: String?
        let source: String?
        let createdAt: Date?
        let state: String
        let routedBy: String?
        let pinSiteId: String?
        let targetSiteId: String?
        let targetSiteName: String?
        let clarifyCandidates: [String]?
        let claimedBy: String?
        let authorSiteId8: String?
        let appliedAt: Date?
        let answeredAt: Date?
        let replyPreview: String?
        let duplicate: Bool?
        /// docs/THREADS.md §2: the thread this row belongs to (a root's is its
        /// own `messageId`; the control plane fills it for pre-thread rows).
        let threadId: String?
        let pushedAt: Date?
        let claimedAt: Date?
        let appliedRunId: String?

        /// The thread the row belongs to, resolved the way the control plane
        /// resolves it: a row with no `threadId` is its own root.
        var resolvedThreadID: String { threadId ?? messageId }
    }

    struct MessageContext {
        var source = "app"
        var deviceID8 = DeviceIdentity.short
        var activeSessionNames: [String] = []
        var siteHint: String?
        /// Explicit thread membership (docs/THREADS.md §2): set when the user
        /// replies inside a thread view or from a notification whose payload
        /// carried `fin.threadId`. nil roots a new thread.
        var threadID: String?
    }

    /// Mint the id HERE, not in the transport: the pending row needs it to poll.
    static func newMessageID() -> String { "m-" + UUID().uuidString.lowercased() }

    /// The `POST /messages` body. Pure so the shape — `threadId` present only
    /// when the context names one — is pinned by a test without a transport.
    static func sendMessageBody(agent: String, text: String, messageID: String, context: MessageContext) -> [String: Any] {
        var ctx: [String: Any] = ["device_id8": context.deviceID8, "activeSessionNames": context.activeSessionNames]
        if let hint = context.siteHint { ctx["siteHint"] = hint }
        var body: [String: Any] = [
            "agent": agent, "text": text, "messageId": messageID, "source": context.source, "context": ctx,
        ]
        if let thread = context.threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !thread.isEmpty {
            body["threadId"] = thread
        }
        return body
    }

    static func sendMessage(agent: String, text: String, messageID: String, context: MessageContext = .init()) async -> Result<Message, Failure> {
        let body = sendMessageBody(agent: agent, text: text, messageID: messageID, context: context)
        return await perform(request("POST", path: "/messages", body: body))
            .flatMap { decode(Message.self, status: $0.0, body: $0.1) }
    }

    static func messageState(_ messageID: String) async -> Result<Message, Failure> {
        await perform(request("GET", path: "/messages/\(messageID)"))
            .flatMap { decode(Message.self, status: $0.0, body: $0.1) }
    }

    struct MessagesResponse: Decodable { let messages: [Message] }

    static func listMessages(agent: String) async -> Result<[Message], Failure> {
        await perform(request("GET", path: "/messages", query: ["agent": agent]))
            .flatMap { decode(MessagesResponse.self, status: $0.0, body: $0.1) }
            .map(\.messages)
    }

    // MARK: - Threads (docs/THREADS.md §3; README "Threads")

    /// `GET /threads/{id}`: the summary, its messages (public rows, oldest
    /// first) and its events (oldest first).
    struct ThreadDetail: Decodable {
        let thread: ThreadSummary
        let messages: [Message]
        let events: [ThreadEvent]

        enum CodingKeys: String, CodingKey { case thread, messages, events }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            thread = try c.decode(ThreadSummary.self, forKey: .thread)
            messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
            events = try c.decodeIfPresent([ThreadEvent].self, forKey: .events) ?? []
        }

        init(thread: ThreadSummary, messages: [Message], events: [ThreadEvent]) {
            self.thread = thread; self.messages = messages; self.events = events
        }
    }

    static func listThreads(agent: String, limit: Int = 50) async -> Result<[ThreadSummary], Failure> {
        await perform(request("GET", path: "/threads", query: ["agent": agent, "limit": String(limit)]))
            .flatMap { decode(ThreadListResponse.self, status: $0.0, body: $0.1) }
            .map(\.threads)
    }

    static func thread(id: String) async -> Result<ThreadDetail, Failure> {
        await perform(request("GET", path: "/threads/\(id)"))
            .flatMap { decode(ThreadDetail.self, status: $0.0, body: $0.1) }
    }

    static func threadEvents(id: String, after: Int = 0) async -> Result<[ThreadEvent], Failure> {
        await perform(request("GET", path: "/threads/\(id)/events", query: ["after": String(after)]))
            .flatMap { decode(ThreadEventsResponse.self, status: $0.0, body: $0.1) }
            .map(\.events)
    }
}

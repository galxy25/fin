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

    static func deleteSite(_ siteID: String) async -> Result<Void, Failure> {
        await perform(request("DELETE", path: "/sites/\(siteID)"))
            .flatMap { status, body in
                (200...299).contains(status) ? .success(()) : .failure(.http(status, errorMessage(status: status, body: body)))
            }
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

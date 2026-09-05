import Foundation

/// Vends short-lived presigned S3 URLs from the control plane's `POST /presign`
/// route, so the app can auto-refresh a cloud agent's transcript/inbox URLs and the
/// device's supervision directive/status URLs instead of the user pasting each one by
/// hand.
///
/// Same control plane, endpoint, and bearer token as `CloudWorkerClient`: one POST to
/// `CloudControlPlaneConfig.endpointURL + "/presign"`, authorized by
/// `authorization: Bearer <token>`. The vended URLs are capability grants with a ~1h
/// stated TTL that in practice die sooner — they are signed with the Lambda role's
/// temporary credentials, so they expire with those credentials regardless of the
/// stated `expiresAt`. Callers therefore re-request on demand (a 403 on use) rather
/// than trusting the expiry; the stored `expiresAt` is only an upper bound used to
/// skip a URL already known to be dead.
///
/// Stateless like `CloudWorkerClient`/`CloudAgentChannel`: no shared mutable state to
/// guard, so a caseless enum of static async funcs, not an actor or `@MainActor` type.
/// The URLSession calls are safe from any executor.
enum PresignedURLService {
    /// The presign kinds. Raw values are the exact tokens the endpoint's `kinds`
    /// request array accepts and that index its `urls` response object.
    enum Kind: String, CaseIterable {
        case transcript, inbox, status
        case supervisionDirective, supervisionStatus
    }

    /// A freshly vended set of URLs plus when the control plane says they expire. Only
    /// the requested/applicable kinds are non-nil; a capability the request did not ask
    /// for (or could not satisfy) stays nil.
    struct Grant: Equatable {
        var transcriptGet: String?
        var inboxGet: String?
        var inboxPut: String?
        var statusGet: String?
        var supervisionDirectiveGet: String?
        var supervisionStatusPut: String?
        var expiresAt: Date?
    }

    /// Never carries the endpoint or the token. A control-plane error body is untrusted
    /// input, so `server`'s text is scrubbed of any SigV4 signature and the token before
    /// it lands here — the same discipline `CloudWorkerClient` keeps for its `.failed`.
    enum Failure: Error, Equatable {
        case notConfigured
        case transport
        case http(Int)
        case server(String)
        case malformedResponse
    }

    static func vend(agent: String?, kinds: [Kind] = Kind.allCases) async -> Result<Grant, Failure> {
        guard CloudControlPlaneConfig.isConfigured else { return .failure(.notConfigured) }
        var base = CloudControlPlaneConfig.endpointURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/presign") else { return .failure(.transport) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Parallels the launch POST's generous timeout: presigning is quick, but the
        // Lambda cold-starts, and a slow sign must not read as a failure.
        request.timeoutInterval = 15
        var payload: [String: Any] = ["kinds": kinds.map(\.rawValue)]
        if let agent = agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
            payload["agent"] = agent
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure(.transport)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            if let message, !message.isEmpty { return .failure(.server(scrub(message))) }
            return .failure(.http(http.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return .failure(.malformedResponse)
        }

        let urls = decoded.urls
        var grant = Grant()
        grant.transcriptGet = urls?.transcriptGet
        grant.inboxGet = urls?.inboxGet
        grant.inboxPut = urls?.inboxPut
        grant.statusGet = urls?.statusGet
        grant.supervisionDirectiveGet = urls?.supervisionDirectiveGet
        grant.supervisionStatusPut = urls?.supervisionStatusPut
        grant.expiresAt = decoded.expiresAt.flatMap(Self.parseISO)
        return .success(grant)
    }

    // MARK: - Store-back refreshers

    /// Vends and stores a cloud agent's transcript + inbox URLs. Returns true when the
    /// URLs were refreshed. Safe to call speculatively (e.g. when the stored URL is
    /// missing or expired); a no-op with no control plane configured.
    @discardableResult
    static func refreshCloudAgentURLs(agentID: UUID, agentName: String) async -> Bool {
        switch await vend(agent: agentName, kinds: [.transcript, .inbox]) {
        case .success(let grant):
            CloudAgentConfig.applyPresigned(
                transcriptGet: grant.transcriptGet,
                inboxGet: grant.inboxGet,
                inboxPut: grant.inboxPut,
                expiresAt: grant.expiresAt,
                agentID: agentID
            )
            return true
        case .failure:
            return false
        }
    }

    /// Vends and stores the device-wide supervision directive (GET) + status (PUT)
    /// URLs. Returns true when the URLs were refreshed. The store is deliberately
    /// silent (no config-changed notification): a presigned refresh points at the same
    /// directive/status object, just with fresh credentials, so the directive channel's
    /// in-memory ETag stays valid and no poller restart is warranted.
    @discardableResult
    static func refreshSupervisionURLs() async -> Bool {
        switch await vend(agent: nil, kinds: [.supervisionDirective, .supervisionStatus]) {
        case .success(let grant):
            RemoteSupervisionConfig.applyPresigned(
                directiveGet: grant.supervisionDirectiveGet,
                statusPut: grant.supervisionStatusPut,
                expiresAt: grant.expiresAt
            )
            return true
        case .failure:
            return false
        }
    }

    // MARK: - Wire types

    private struct Response: Decodable {
        struct URLs: Decodable {
            let transcriptGet: String?
            let inboxGet: String?
            let inboxPut: String?
            let statusGet: String?
            let supervisionDirectiveGet: String?
            let supervisionStatusPut: String?
        }
        let expiresAt: String?
        let ttlSeconds: Int?
        let urls: URLs?
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    // MARK: - Helpers

    private static func parseISO(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// Strips any SigV4 signature parameter and the bearer token from an error string,
    /// then truncates — a presigned URL's query is itself a credential, and the token
    /// must never echo back. Mirrors the Lambda's `_scrub` and
    /// `AgentDirectiveChannel.sanitizeFailureText`.
    private static func scrub(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"X-Amz-[A-Za-z-]+=[^&\s]*"#,
            with: "[redacted]",
            options: .regularExpression
        )
        let token = CloudControlPlaneConfig.token
        if !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "[token]")
        }
        return result.count > 200 ? String(result.prefix(200)) + "…" : result
    }
}

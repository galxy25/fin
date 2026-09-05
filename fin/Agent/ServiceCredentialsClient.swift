import Foundation

/// Client for the control plane's service-credential store (`PUT/GET/DELETE
/// /secrets`), where the user provisions the third-party credentials a cloud
/// worker uses while driving a task — a Gmail app password, an App Store
/// Connect key.
///
/// WRITE-ONLY is the store's design, not a UI courtesy: no control-plane route
/// ever returns a secret value, and the Lambda's role holds no
/// `secretsmanager:GetSecretValue` at all, so a value physically cannot come
/// back through this client. The client keeps the matching discipline:
///   - The only type that ever holds a credential value is the PUT body, which
///     is built, sent, and discarded inside one call. `Metadata` — the only
///     decoded credential shape — has no field that could carry one (a test
///     pins that).
///   - Nothing here logs, at any level. A credential field must never reach a
///     log line, and the cheapest guarantee is a file with no logger in it.
///   - Error text surfaced to the UI carries field NAMES at most (the Lambda
///     keeps the same rule) and is scrubbed of the bearer token, mirroring
///     `PresignedURLService.scrub`.
///
/// Same control plane, endpoint, and bearer token as `CloudWorkerClient` and
/// `PresignedURLService`; stateless like both, so a caseless enum of static
/// funcs. Requests are built and responses mapped by pure static functions so
/// every branch is testable without a server.
enum ServiceCredentialsClient {
    /// The reserved scope every worker can read. The alternative is an agent's
    /// display name, which the Lambda lowercases to its key slug.
    static let sharedScope = "shared"

    /// The contract's credential shapes, in order of preference (revocable,
    /// purpose-minted shapes first — the settings footer explains why). Stored
    /// server-side as a tag, so listing never touches values.
    enum SecretKind: String, CaseIterable, Identifiable {
        case appPassword = "app-password"
        case oauth
        case apiKey = "api-key"
        case password

        var id: String { rawValue }

        var label: String {
            switch self {
            case .appPassword: return "App password"
            case .oauth: return "OAuth token"
            case .apiKey: return "API key"
            case .password: return "Password"
            }
        }
    }

    /// One row of `GET /secrets`. Metadata only, by construction: no property
    /// here can hold a credential value or username, and none may ever be
    /// added — `ServiceCredentialsTests` asserts the absence by reflection.
    struct Metadata: Decodable, Equatable, Identifiable {
        let service: String
        let agentScope: String
        let kind: String
        /// The user's own reminder text (the PUT's `note`, stored as the Secrets
        /// Manager Description). Optional: a credential stored without one has
        /// no label to show.
        let label: String?
        let lastUpdated: String?
        /// Day granularity ("2026-09-04") from Secrets Manager's
        /// LastAccessedDate — the "a worker actually read this" signal.
        let lastAccessed: String?
        /// ISO timestamp while a DELETE's 7-day recovery window is running;
        /// absent otherwise.
        let deletionScheduled: String?

        var id: String { agentScope + "/" + service }

        var lastUpdatedDate: Date? { lastUpdated.flatMap(parseISO) }
        var deletionDate: Date? { deletionScheduled.flatMap(parseISO) }

        /// Rotation nudge threshold. There is no rotation Lambda on purpose —
        /// AWS cannot rotate third-party credentials — so a staleness badge on
        /// the list is the user's only prompt to re-enter a fresh one.
        static let staleAfterDays = 180

        func isStale(asOf now: Date = Date()) -> Bool {
            guard let updated = lastUpdatedDate else { return false }
            return now.timeIntervalSince(updated) > TimeInterval(Self.staleAfterDays) * 86_400
        }
    }

    /// `PUT /secrets/{service}`'s 200/201 body — the store's acknowledgement,
    /// echoed metadata only, never the value and never the ARN.
    struct PutAck: Decodable, Equatable {
        let service: String
        let agentScope: String
        let kind: String
        let lastUpdated: String?
    }

    /// `DELETE /secrets/{service}`'s 200 body. `deletionDate` ends the 7-day
    /// recovery window; a re-PUT before then restores and replaces the secret.
    struct DeletionAck: Decodable, Equatable {
        let service: String
        let agentScope: String
        let deletionDate: String?
    }

    /// Never carries the endpoint, the token, or any credential field value.
    /// `server`'s text is the Lambda's own error message (field names at
    /// most), scrubbed of the token before it lands here.
    enum Failure: Error, Equatable {
        case notConfigured
        case transport
        case unauthorized
        case server(String)
        case http(Int)
        case malformedResponse

        /// What the settings UI shows. Plain sentences, no URLs, no tokens.
        var userMessage: String {
            switch self {
            case .notConfigured:
                return "The control plane isn't configured — paste its URL and "
                    + "token in a cloud agent's Hosting section first."
            case .transport:
                return "Network error — the control plane could not be reached."
            case .unauthorized:
                return "control plane token rejected — paste a current token in "
                    + "the Hosting section."
            case .server(let message):
                return message
            case .http(let status):
                return "control plane error (HTTP \(status))"
            case .malformedResponse:
                return "The control plane's response was unreadable."
            }
        }
    }

    /// The contract's service-name rule, verbatim: `[a-z0-9][a-z0-9-]{0,39}`.
    /// Checked client-side so the Add form can validate as the user types
    /// instead of round-tripping for a 400.
    static func isValidServiceName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
    }

    // MARK: - Calls

    /// Stores or rotates one credential. The value and username live only in
    /// this call's frame: into the body, onto the wire, gone on return.
    static func storeSecret(
        service: String,
        agentScope: String,
        kind: SecretKind,
        value: String,
        username: String?,
        note: String?
    ) async -> Result<PutAck, Failure> {
        guard let url = endpointURL(path: "/secrets/\(service)") else {
            return .failure(.notConfigured)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = putBody(
            agentScope: agentScope, kind: kind, value: value, username: username, note: note
        )
        let (status, data) = await send(request)
        return putOutcome(status: status, body: data)
    }

    /// Every stored credential's metadata — and only metadata; the route has
    /// nothing else to give.
    static func listSecrets() async -> Result<[Metadata], Failure> {
        guard let url = endpointURL(path: "/secrets") else {
            return .failure(.notConfigured)
        }
        let (status, data) = await send(authorizedRequest(url: url))
        return listOutcome(status: status, body: data)
    }

    /// Schedules deletion with the store's 7-day recovery window (never a
    /// force-delete). Idempotent server-side: deleting an already-scheduled
    /// credential answers the same 200.
    static func deleteSecret(
        service: String, agentScope: String
    ) async -> Result<DeletionAck, Failure> {
        guard let url = endpointURL(
            path: "/secrets/\(service)",
            query: [URLQueryItem(name: "agentScope", value: agentScope)]
        ) else {
            return .failure(.notConfigured)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "DELETE"
        let (status, data) = await send(request)
        return deleteOutcome(status: status, body: data)
    }

    // MARK: - Wire shape (pure, tested)

    /// The PUT body, contract-exact: `{"agentScope", "kind", "value",
    /// "username"?, "note"?}`. Optional fields are OMITTED when blank rather
    /// than sent empty — the Lambda rejects an empty username, and an absent
    /// key is the contract's "this credential has no username". `note` becomes
    /// the row's `label` in `GET /secrets`; it is Secrets Manager Description
    /// metadata, NOT encrypted like the value — the UI warns accordingly.
    static func putBody(
        agentScope: String,
        kind: SecretKind,
        value: String,
        username: String?,
        note: String?
    ) -> Data? {
        var object: [String: Any] = [
            "agentScope": agentScope,
            "kind": kind.rawValue,
            "value": value,
        ]
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedUsername.isEmpty { object["username"] = trimmedUsername }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNote.isEmpty { object["note"] = trimmedNote }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func putOutcome(status: Int?, body: Data?) -> Result<PutAck, Failure> {
        successData(status: status, body: body).flatMap { data in
            (try? JSONDecoder().decode(PutAck.self, from: data))
                .map(Result.success) ?? .failure(.malformedResponse)
        }
    }

    static func listOutcome(status: Int?, body: Data?) -> Result<[Metadata], Failure> {
        successData(status: status, body: body).flatMap { data in
            (try? JSONDecoder().decode(ListResponse.self, from: data))
                .map { .success($0.secrets ?? []) } ?? .failure(.malformedResponse)
        }
    }

    static func deleteOutcome(status: Int?, body: Data?) -> Result<DeletionAck, Failure> {
        successData(status: status, body: body).flatMap { data in
            (try? JSONDecoder().decode(DeletionAck.self, from: data))
                .map(Result.success) ?? .failure(.malformedResponse)
        }
    }

    /// The shared status table: 2xx passes the body through, everything else
    /// maps to a `Failure`. A non-2xx body's `error` field is the Lambda's own
    /// message — field names at most, never values — but still untrusted text,
    /// so it is scrubbed before surfacing.
    private static func successData(status: Int?, body: Data?) -> Result<Data, Failure> {
        guard let status else { return .failure(.transport) }
        if (200..<300).contains(status) { return .success(body ?? Data()) }
        if status == 401 { return .failure(.unauthorized) }
        let message = body.flatMap { try? JSONDecoder().decode(ErrorBody.self, from: $0) }?.error
        if let message, !message.isEmpty { return .failure(.server(scrub(message))) }
        return .failure(.http(status))
    }

    private struct ListResponse: Decodable {
        let secrets: [Metadata]?
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    // MARK: - Transport

    private static func endpointURL(path: String, query: [URLQueryItem] = []) -> URL? {
        guard CloudControlPlaneConfig.isConfigured else { return nil }
        var base = CloudControlPlaneConfig.endpointURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    private static func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization"
        )
        // The Lambda cold-starts; a slow store must not read as a failure
        // (same allowance as the launch and presign POSTs).
        request.timeoutInterval = 15
        return request
    }

    private static func send(_ request: URLRequest) async -> (Int?, Data?) {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (nil, nil)
        }
        return ((response as? HTTPURLResponse)?.statusCode, data)
    }

    /// Bearer-token scrub for error text, mirroring `PresignedURLService`:
    /// the token must never echo back through an error message, and 200
    /// characters is plenty for any legitimate Lambda validation error.
    private static func scrub(_ text: String) -> String {
        var result = text
        let token = CloudControlPlaneConfig.token
        if !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "[token]")
        }
        return result.count > 200 ? String(result.prefix(200)) + "…" : result
    }
}

private func parseISO(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
}

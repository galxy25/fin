import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The write half of cross-site inbox cooperation: multiple sites (this Mac's resident
/// daemon, a hand-launched or auto-woken cloud worker) can all be alive and polling the
/// SAME agent's inbox at once, and each site's own "already answered this" ledger lives
/// only on its own disk — invisible to every other site. Without a lock, two sites could
/// both answer the same message. `fin/inbox/{agent}.lock` (control-plane
/// `PUT`/`DELETE /inbox/{agent}/lock`) is the same claim-with-staleness-reclaim primitive
/// `DaemonMemoryClient`'s profile lock already proves out, scoped per agent instead of
/// account-wide. Entirely mechanical — a `holder` is just an id string a site writes
/// about itself; nothing here ever asks a model anything.
@MainActor
final class DaemonInboxLockClient {
    static let requestTimeout: TimeInterval = 10
    static let failureAuditWindow: TimeInterval = 5 * 60

    let endpointURL: String
    private let token: String
    let agentName: String

    var transport: (URLRequest) async throws -> (Data, URLResponse)
    let audit: (String) -> Void
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        endpointURL: String,
        token: String,
        agentName: String,
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpointURL = endpointURL
        self.token = token
        self.agentName = agentName
        self.audit = audit
        self.transport = transport
    }

    private func request(method: String) -> URLRequest? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let encodedAgent = agentName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentName
        guard !base.isEmpty, let url = URL(string: base + "/inbox/\(encodedAgent)/lock") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        return request
    }

    enum LockOutcome: Equatable {
        case claimed
        /// Another holder has the lock and it isn't stale yet — the caller should
        /// leave this agent's inbox alone this tick and let that holder drive.
        case locked(holder: String)
        case failed(String)
    }

    /// PUT /inbox/{agent}/lock — atomic claim, a stale-lock reclaim, or word of who
    /// currently holds it. `holder` should uniquely identify this daemon process.
    func claim(holder: String) async -> LockOutcome {
        guard var httpRequest = request(method: "PUT") else {
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
                registerFailure("[inbox] lock claim failed: no HTTP response")
                return .failed("no response from the control plane")
            }
            if http.statusCode == 409 {
                let currentHolder = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                return .locked(holder: currentHolder ?? "another site")
            }
            guard (200..<300).contains(http.statusCode) else {
                registerFailure("[inbox] lock claim failed: HTTP \(http.statusCode)")
                return .failed("control plane returned HTTP \(http.statusCode)")
            }
            return .claimed
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[inbox] lock claim failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    /// DELETE /inbox/{agent}/lock — unconditional; call after every claimed turn,
    /// success or failure, so the next site doesn't wait out the stale-reclaim TTL.
    func release() async {
        guard let httpRequest = request(method: "DELETE") else { return }
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

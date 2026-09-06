import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's push-notification path: one POST to the control plane's `/notify`
/// route, which fans the alert out over APNs to every device token the app has
/// registered (`PUT /device-tokens`). This is how a headless harness reaches a
/// human — the app's own cross-device pushes ride CloudKit signals, but a daemon
/// has no CloudKit, so the control plane relays instead.
///
/// Configured by the optional `controlPlane` config block; a config without one
/// leaves the daemon exactly as silent as before. The bearer token authenticates
/// every control-plane route, so it must never reach a log line — audit strings
/// here carry a status code or a short error at most, mirroring
/// `DaemonDirectiveClient`'s discipline for its presigned URLs.
///
/// The message crosses Apple's servers on its way to a lock screen, so it passes
/// through `MemoryRedactor` first — the same leaves-the-machine rule as the
/// cloud transcript — and is capped: a push is a summary, not a transcript.
@MainActor
final class DaemonNotifyClient {
    static let requestTimeout: TimeInterval = 10
    /// Same throttle as the directive client's: an unreachable control plane
    /// writes one audit line per window per distinct error, not one per event.
    static let failureAuditWindow: TimeInterval = 5 * 60
    /// APNs truncates long alerts anyway; the cap keeps the payload predictable.
    static let maxMessageLength = 500

    let endpointURL: String
    private let token: String
    let agentName: String
    /// Injected transport, so tests never touch the network.
    var post: (URLRequest) async throws -> URLResponse
    let audit: (String) -> Void
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        endpointURL: String,
        token: String,
        agentName: String,
        audit: @escaping (String) -> Void = { _ in },
        post: @escaping (URLRequest) async throws -> URLResponse = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return response
        }
    ) {
        self.endpointURL = endpointURL
        self.token = token
        self.agentName = agentName
        self.audit = audit
        self.post = post
    }

    // MARK: - Wire shape (pure, tested)

    /// The daemon's event names mapped to alert titles a lock screen can carry
    /// on its own; anything unrecognized falls back to the agent's name.
    static func title(event: String, agentName: String) -> String {
        switch event {
        case "request-input": return "\(agentName) needs input"
        case "task-complete": return "\(agentName): task complete"
        default: return agentName
        }
    }

    /// Redacted and capped alert text — this string leaves the machine.
    static func alertBody(_ message: String) -> String {
        let redacted = MemoryRedactor.redact(message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard redacted.count > maxMessageLength else { return redacted }
        return String(redacted.prefix(maxMessageLength)) + "…"
    }

    /// The `/notify` contract: `{"agent", "body", "title"}`.
    static func requestBody(title: String, body: String, agentName: String) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: ["title": title, "body": body, "agent": agentName],
            options: [.sortedKeys]
        )
    }

    // MARK: - Send

    /// POSTs one event. Failures audit (throttled) and are otherwise swallowed —
    /// a dead control plane must never take down the agent.
    func send(event: String, message: String) async {
        await deliver(
            title: Self.title(event: event, agentName: agentName),
            body: Self.alertBody(message)
        )
    }

    /// A model-authored push: the `notify` tool supplies its OWN title, so this bypasses
    /// the `event`→title table `send(event:)` uses and pushes the given headline verbatim
    /// (still redacted + capped, since it still leaves the machine). An empty title falls
    /// back to the agent's name so a lock screen always has something to show. Same
    /// swallow-and-throttle failure discipline as `send(event:)`.
    func sendDirect(title: String, body: String) async {
        let redactedTitle = MemoryRedactor.redact(title)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await deliver(
            title: redactedTitle.isEmpty ? agentName : redactedTitle,
            body: Self.alertBody(body)
        )
    }

    /// Shared POST for both `send(event:)` and `sendDirect`: the title and body are
    /// already resolved and redacted by the caller. (Named `deliver`, not `post`, so it
    /// doesn't shadow the injected `post` transport this ultimately calls.)
    private func deliver(title: String, body: String) async {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/notify") else {
            registerFailure("[notify] control plane URL is not a valid URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.requestBody(
            title: title,
            body: body,
            agentName: agentName
        )
        do {
            let response = try await post(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                registerFailure("[notify] post failed: HTTP \(http.statusCode)")
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[notify] post failed: \(text.prefix(200))")
        }
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

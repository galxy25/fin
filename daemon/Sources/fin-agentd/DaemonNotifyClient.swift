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
    /// The Agent record this push is about, when the daemon has been paired to
    /// one (`config.agentID`) — lets a tap deep-link straight to the
    /// conversation instead of just opening the app. Nil for an unpaired
    /// daemon: the push still lands, it just can't route a tap anywhere.
    let agentID: UUID?
    /// This Mac's own `DeviceIdentity.short`-equivalent (`config.deviceToken8`)
    /// — the push's true origin. Without it, a tap would default to treating
    /// the RECEIVING device as the origin (the local-banner assumption), which
    /// is wrong for every device but this one.
    let originDeviceID8: String
    /// Injected transport, so tests never touch the network.
    var post: (URLRequest) async throws -> URLResponse
    let audit: (String) -> Void
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        endpointURL: String,
        token: String,
        agentName: String,
        agentID: UUID? = nil,
        originDeviceID8: String = "",
        audit: @escaping (String) -> Void = { _ in },
        post: @escaping (URLRequest) async throws -> URLResponse = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return response
        }
    ) {
        self.endpointURL = endpointURL
        self.token = token
        self.agentName = agentName
        self.agentID = agentID
        self.originDeviceID8 = originDeviceID8
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
        case "agent-stalled": return "\(agentName) is stuck"
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

    /// The `/notify` contract: `{"agent", "body", "title", "event"}` required, plus
    /// `"agentID"`/`"originDeviceID8"` when the daemon has them — the Lambda
    /// forwards those into the APNs payload's `fin` dict so a tap on the
    /// resulting push can deep-link (see `AgentNotificationService`), instead
    /// of just opening the app cold — and `"messageId"` when the push reports on
    /// a claimed control-plane message, so the Lambda pushes that message's
    /// reply once (the daemon's task-complete push and the answered ack's push
    /// dedupe on it, design §3.7.3). `event` (`request-input` / `task-complete` /
    /// `agent-stalled` / `notify`) picks the APNs category and interruption level
    /// (`fin.input` + time-sensitive for the two "needs you" events). `"threadId"`
    /// names the thread (docs/THREADS.md §2) the push belongs to — the one the
    /// message turn in flight is stamped with — so the Lambda records `notify.sent`
    /// on it and the APNs `thread-id` groups the Lock Screen by request. Optional
    /// keys are omitted (not sent as null) when absent.
    static func requestBody(
        title: String, body: String, agentName: String, event: String = "notify",
        agentID: UUID? = nil, originDeviceID8: String = "", messageID: String? = nil,
        threadID: String? = nil
    ) -> Data? {
        var object: [String: Any] = ["title": title, "body": body, "agent": agentName, "event": event]
        if let agentID {
            object["agentID"] = agentID.uuidString
        }
        if !originDeviceID8.isEmpty {
            object["originDeviceID8"] = originDeviceID8
        }
        if let messageID, !messageID.isEmpty {
            object["messageId"] = messageID
        }
        if let threadID, !threadID.isEmpty {
            object["threadId"] = threadID
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Send

    /// POSTs one event. Failures audit (throttled) and are otherwise swallowed —
    /// a dead control plane must never take down the agent. Returns whether the post
    /// actually succeeded, so a caller that needs the real outcome (not just "handed
    /// off") can report it honestly instead of assuming delivery.
    /// `messageID` names the control-plane message this push reports on (the
    /// task-complete push for a claimed message); nil for everything else. `threadID`
    /// is that message's thread, when the daemon knows it.
    @discardableResult
    func send(event: String, message: String, messageID: String? = nil, threadID: String? = nil) async -> Bool {
        await deliver(
            title: Self.title(event: event, agentName: agentName),
            body: Self.alertBody(message),
            event: event,
            messageID: messageID,
            threadID: threadID
        )
    }

    /// A model-authored push: the `notify` tool supplies its OWN title, so this bypasses
    /// the `event`→title table `send(event:)` uses and pushes the given headline verbatim
    /// (still redacted + capped, since it still leaves the machine). An empty title falls
    /// back to the agent's name so a lock screen always has something to show. Same
    /// swallow-and-throttle failure discipline, and the same real-outcome return, as
    /// `send(event:)`.
    @discardableResult
    func sendDirect(title: String, body: String, threadID: String? = nil) async -> Bool {
        let redactedTitle = MemoryRedactor.redact(title)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await deliver(
            title: redactedTitle.isEmpty ? agentName : redactedTitle,
            body: Self.alertBody(body),
            event: "notify",
            threadID: threadID
        )
    }

    /// Shared POST for both `send(event:)` and `sendDirect`: the title and body are
    /// already resolved and redacted by the caller. (Named `deliver`, not `post`, so it
    /// doesn't shadow the injected `post` transport this ultimately calls.) Returns true
    /// only on a confirmed 2xx response — every other outcome (bad URL, transport error,
    /// non-2xx) is false, audited, and swallowed.
    @discardableResult
    private func deliver(
        title: String, body: String, event: String, messageID: String? = nil, threadID: String? = nil
    ) async -> Bool {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/notify") else {
            registerFailure("[notify] control plane URL is not a valid URL")
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.requestBody(
            title: title,
            body: body,
            agentName: agentName,
            event: event,
            agentID: agentID,
            originDeviceID8: originDeviceID8,
            messageID: messageID,
            threadID: threadID
        )
        do {
            let response = try await post(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                registerFailure("[notify] post failed: HTTP \(http.statusCode)")
                return false
            }
            return true
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[notify] post failed: \(text.prefix(200))")
            return false
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

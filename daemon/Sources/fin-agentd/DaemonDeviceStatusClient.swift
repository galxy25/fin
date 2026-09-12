import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET /devices/status — every device's last-known supervision status for this
/// account, so `DaemonMemoryConsolidator` can fold "what is happening on my other
/// devices right now" into the cumulative-profile compaction prompt. Same bearer-token
/// relay `DaemonMemoryClient`/`DaemonArtifactClient` use, no presigned URL.
@MainActor
final class DaemonDeviceStatusClient {
    static let requestTimeout: TimeInterval = 10
    static let failureAuditWindow: TimeInterval = 5 * 60

    private let endpointURL: String
    private let token: String
    var transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    let audit: (String) -> Void
    private var lastFailureAuditAt: Date?

    init(endpointURL: String, token: String, audit: @escaping (String) -> Void = { _ in }) {
        self.endpointURL = endpointURL
        self.token = token
        self.audit = audit
    }

    struct DeviceStatus: Decodable, Equatable {
        let device: String?
        let device_id8: String?
        let agent: String?
        let state: String?
        let last_turn_at: String?
        let updated_at: String?
    }
    private struct Response: Decodable { let devices: [DeviceStatus]? }

    private func request() -> URLRequest? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/devices/status") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.timeoutInterval = Self.requestTimeout
        return req
    }

    /// Every OTHER device's status (`excludingDeviceID8` — this daemon's own row),
    /// dropping anything stale past `maxAge` (default 2h: spans an overnight laptop
    /// sleep, but a decommissioned Mac doesn't haunt the profile forever). Never
    /// throws — a transport failure, malformed body, or empty result all return [],
    /// the same "empty is a safe no-op" contract `sessionActivityNotesProvider`
    /// follows, so a caller can await this unconditionally every compaction pass.
    func otherDevices(
        excludingDeviceID8: String, maxAge: TimeInterval = 2 * 60 * 60, now: Date = Date()
    ) async -> [DeviceStatus] {
        guard let req = request() else { return [] }
        guard let (data, response) = try? await transport(req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else {
            registerFailure("[devices] status fetch failed")
            return []
        }
        let iso = ISO8601DateFormatter()
        return (decoded.devices ?? []).filter { d in
            guard d.device_id8 != excludingDeviceID8 else { return false }
            guard let raw = d.updated_at, let updated = iso.date(from: raw) else { return false }
            return now.timeIntervalSince(updated) <= maxAge
        }
    }

    /// Exact relative-time bucketing both call sites (this file's formatter and, if
    /// wired, `AgentRuntime.swift`'s app-side compaction) must implement identically —
    /// see DaemonMemoryConsolidator's `crossDeviceStatusProvider` doc comment.
    static func relativeTimeLabel(iso: String?, now: Date) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "unknown" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    /// One formatted line per device, exact text: "<device> — <state>, working on
    /// <agent>, last seen <relative time>". Missing fields fall back to "device-<id8>",
    /// "unknown", "no agent" respectively, so a partial status document never crashes
    /// or produces an empty line.
    static func formatLine(_ d: DeviceStatus, now: Date) -> String {
        let device = d.device ?? "device-\(d.device_id8 ?? "????????")"
        let state = d.state ?? "unknown"
        let agent = d.agent ?? "no agent"
        let seen = relativeTimeLabel(iso: d.updated_at, now: now)
        return "\(device) — \(state), working on \(agent), last seen \(seen)"
    }

    private func registerFailure(_ message: String) {
        let now = Date()
        if let last = lastFailureAuditAt, now.timeIntervalSince(last) < Self.failureAuditWindow { return }
        lastFailureAuditAt = now
        audit(message)
    }
}

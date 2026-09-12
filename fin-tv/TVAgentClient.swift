// Agent mode on the Apple TV: the same conversation the iPhone's remote console
// shows, read from the control plane's transcript chunks and written through
// POST /messages — with the session token Sign in with Apple earned this TV
// (TVCloudAccount). Deliberately small: no iCloud mirror files, no local runtime.
import Foundation
import SwiftUI

@MainActor
final class TVAgentClient: ObservableObject {
    struct Pending: Identifiable, Equatable {
        let id: String
        let text: String
        var state: String
        let createdAt: Date
    }

    @Published private(set) var turns: [TranscriptTurns.Turn] = []
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var isSending = false

    let agentName: String
    private let endpoint: () -> String
    private let token: () -> String
    private var pollTask: Task<Void, Never>?
    static let pollSeconds: UInt64 = 10

    init(agentName: String, endpoint: @escaping () -> String, token: @escaping () -> String) {
        self.agentName = agentName
        self.endpoint = endpoint
        self.token = token
    }

    var isConfigured: Bool { !endpoint().isEmpty && !token().isEmpty }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func request(_ method: String, path: String, body: [String: Any]? = nil) -> URLRequest? {
        let base = KeyVaultClient.normalizedBase(endpoint())
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Latest hour merged with the previous one (same window the iPhone shows),
    /// `.notice` lines dropped, grouped into turns. Pending rows retire once a
    /// user line carrying their message id appears.
    func refresh() async {
        guard isConfigured,
              let encoded = agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return }
        guard let first = await fetchChunk(path: "/transcript-chunks?agent=\(encoded)") else { return }
        var groups = [first.records]
        if let hour = first.chunkHour, let index = first.hours.firstIndex(of: hour), index > 0,
           let previousHour = first.hours[index - 1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let previous = await fetchChunk(path: "/transcript-chunks?agent=\(encoded)&hour=\(previousHour)") {
            groups.append(previous.records)
        }
        let records = MirrorRecords.merge(groups).filter { $0.kind != .notice }
        turns = TranscriptTurns.turns(from: records)
        let applied = Set(records.compactMap(\.inReplyTo))
        pending.removeAll { applied.contains($0.id) }
        lastRefreshAt = Date()
        lastError = nil
        await refreshPendingStates()
    }

    private struct Chunk {
        let hours: [String]
        let chunkHour: String?
        let records: [AgentMirrorRecord]
    }

    private func fetchChunk(path: String) async -> Chunk? {
        guard let request = request("GET", path: path) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                lastError = "Transcript fetch failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                return nil
            }
            let chunk = object["chunk"] as? [String: Any]
            let lines = (chunk?["lines"] as? [String]) ?? []
            return Chunk(
                hours: (object["hours"] as? [String]) ?? [],
                chunkHour: chunk?["hour"] as? String,
                records: MirrorRecords.parseLines(lines.joined(separator: "\n"))
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Send one message to the agent; the pending row shows until the site
    /// applies it and the transcript carries the line.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConfigured else { return }
        let id = "m-" + UUID().uuidString.lowercased()
        pending.append(Pending(id: id, text: trimmed, state: "sending", createdAt: Date()))
        isSending = true
        defer { isSending = false }
        let body: [String: Any] = [
            "agent": agentName, "text": trimmed, "messageId": id, "source": "app",
            "context": ["device_id8": DeviceIdentity.short, "activeSessionNames": []],
        ]
        guard let request = request("POST", path: "/messages", body: body) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (200..<300).contains(status) {
                update(id, state: (object?["state"] as? String) ?? "queued")
            } else {
                update(id, state: "failed")
                lastError = (object?["error"] as? String) ?? "Send failed (HTTP \(status))."
            }
        } catch {
            update(id, state: "failed")
            lastError = error.localizedDescription
        }
    }

    private func update(_ id: String, state: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].state = state
    }

    private func refreshPendingStates() async {
        for row in pending where row.state != "failed" {
            guard let request = request("GET", path: "/messages/\(row.id)") else { continue }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let state = object["state"] as? String
            else { continue }
            update(row.id, state: state)
        }
    }
}

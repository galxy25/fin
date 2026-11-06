import AppIntents
import Foundation

/// docs/XANADU.md "Siri": one Fin thread as Siri sees it — the parameter of
/// Ask / Tell / Share ("…in the deploy thread"), what Xanadu publishes as its
/// onscreen context ("reply to this", "what did Fin say?"), and, on 27.3, a
/// snippet. Its properties carry what Siri needs to answer about the thread
/// without opening it: title, status, the last reply and a short recent
/// transcript. A value snapshot; the id is the thread id (its root message id).
struct FinThreadEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Fin Thread",
        numericFormat: "\(placeholder: .int) Fin threads"
    )
    static let defaultQuery = FinThreadQuery()

    let id: String
    @Property(title: "Agent")
    var agentName: String
    @Property(title: "Title")
    var title: String
    @Property(title: "Status")
    var status: String
    @Property(title: "Last Reply")
    var lastReply: String?
    @Property(title: "Recent Transcript")
    var recentTranscript: String?

    init(id: String, agentName: String, title: String, status: String, lastReply: String? = nil, recentTranscript: String? = nil) {
        self.id = id
        self.agentName = agentName
        self.title = title
        self.status = status
        self.lastReply = lastReply
        self.recentTranscript = recentTranscript
    }

    init(summary: ThreadSummary, agentName: String, detail: ControlPlaneClient.ThreadDetail? = nil) {
        self.init(
            id: summary.threadId,
            agentName: summary.agent ?? agentName,
            title: summary.displayTitle,
            status: summary.status.chip.label,
            lastReply: detail.flatMap { Self.lastReply(in: $0.messages) },
            recentTranscript: detail.flatMap { Self.recentTranscript(from: $0.messages) }
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(status)",
            image: .init(systemName: "bubble.left.and.text.bubble.right")
        )
    }

    /// Fin's newest answer in a thread's rows. Pure.
    static func lastReply(in messages: [ControlPlaneClient.Message]) -> String? {
        messages
            .filter { ($0.replyPreview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
            .max { ($0.answeredAt ?? $0.createdAt ?? .distantPast) < ($1.answeredAt ?? $1.createdAt ?? .distantPast) }?
            .replyPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last few exchanges as plain lines ("You: …" / "Fin: …"), newest
    /// last, capped so Siri gets context rather than a novel. Pure.
    static func recentTranscript(from messages: [ControlPlaneClient.Message], exchanges: Int = 4, limit: Int = 1500) -> String? {
        var lines: [String] = []
        for message in messages.suffix(exchanges) {
            let files = message.attachments ?? []
            var said = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !files.isEmpty {
                let names = files.map(\.name).joined(separator: ", ")
                said = said.isEmpty ? "[files: \(names)]" : "\(said) [files: \(names)]"
            }
            if !said.isEmpty { lines.append((message.source == "agent" ? "Fin: " : "You: ") + said) }
            if let reply = message.replyPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
                lines.append("Fin: " + reply)
            }
        }
        return transcriptText(lines, limit: limit)
    }

    /// Joins lines and keeps the NEWEST `limit` characters. Pure.
    static func transcriptText(_ lines: [String], limit: Int = 1500) -> String? {
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        guard joined.count > limit else { return joined }
        return "…" + String(joined.suffix(limit))
    }
}

/// Threads come from the control plane (`GET /threads`), for the user's
/// primary agent — the same one a voice message goes to.
struct FinThreadQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FinThreadEntity] {
        guard CloudControlPlaneConfig.isConfigured else { return [] }
        let agent = FinThreadDirectory.primaryAgentName() ?? "Fin"
        var found: [FinThreadEntity] = []
        for id in identifiers {
            if case .success(let detail) = await ControlPlaneClient.thread(id: id) {
                found.append(FinThreadEntity(summary: detail.thread, agentName: agent, detail: detail))
            } else {
                // Unreachable right now: still resolve, so a thread Siri was
                // handed keeps working as a parameter (the send carries its id).
                found.append(FinThreadEntity(id: id, agentName: agent, title: "Fin thread", status: "unknown"))
            }
        }
        return found
    }

    @MainActor
    func suggestedEntities() async throws -> [FinThreadEntity] {
        await FinThreadDirectory.threads()
    }

    @MainActor
    func entities(matching string: String) async throws -> [FinThreadEntity] {
        FinThreadDirectory.matching(string, in: await FinThreadDirectory.threads())
    }
}

enum FinThreadDirectory {
    /// The agent a voice message would go to (`FinVoiceIntentCore`'s rule).
    @MainActor
    static func primaryAgentName() -> String? {
        let agents = FinVoiceIntentCore.candidateAgents(container: FinSharedState.modelContainer)
        return FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: agents.map(\.name)).map { agents[$0].name }
    }

    /// The primary agent's threads, the current one first, newest after.
    @MainActor
    static func threads() async -> [FinThreadEntity] {
        guard CloudControlPlaneConfig.isConfigured, let agent = primaryAgentName() else { return [] }
        guard case .success(let list) = await ControlPlaneClient.listThreads(agent: agent, limit: 30) else { return [] }
        let current = XanaduCurrentThread.get(agent: agent)
        let ordered = ThreadSelection.sorted(list)
        let first = ordered.filter { $0.threadId == current }
        let rest = ordered.filter { $0.threadId != current }
        return (first + rest).map { FinThreadEntity(summary: $0, agentName: agent) }
    }

    /// Every word of the spoken name must appear in the title. Pure.
    static func matching(_ spoken: String, in threads: [FinThreadEntity]) -> [FinThreadEntity] {
        let ignored: Set<String> = ["the", "my", "thread", "conversation", "about", "a"]
        let words = spoken.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignored.contains($0) }
        guard !words.isEmpty else { return threads }
        return threads.filter { thread in
            let title = thread.title.lowercased()
            return words.allSatisfy { title.contains($0) }
        }
    }
}

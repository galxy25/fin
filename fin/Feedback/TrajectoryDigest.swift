import Foundation

/// Metadata-only summary of one finished agent conversation, derived entirely
/// from the already-redacted local audit trail (`AgentLogEntry`). Deliberately
/// carries NO message text and NO terminal output, not even redacted: every
/// field is a count, a duration, or an enum-shaped identifier. The struct's
/// shape IS the privacy guarantee — there is nowhere to put content.
struct TrajectoryDigest: Codable, Equatable {
    /// The first run's ID, stable across re-derivations — the wire-side dedup key.
    let conversationID: String
    /// Distinct runs containing conversational traffic (a user message or an
    /// assistant answer) — lifecycle-notice runs don't count.
    let turns: Int
    /// Tool-call counts keyed by tool name — names only, never arguments.
    let toolCallCounts: [String: Int]
    /// First entry to last entry, wall clock.
    let durationSeconds: Int
    /// "completed" when the final conversational run got its assistant answer and
    /// didn't end on a failure; "interrupted" otherwise.
    let outcome: String
    /// Total character count of user + assistant message text — a length, not the text.
    let transcriptChars: Int
    /// Most recent non-empty model identifier seen in the conversation.
    let model: String
    /// `AgentHostingMode` raw value for the owning agent.
    let hostingMode: String

    /// The contract's `payload` object, via Codable so field names stay honest.
    func payloadObject() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Pure derivation from the audit trail — no store access, no runtime access, so
/// the whole thing is testable on transient (never-inserted) entries.
enum TrajectoryDigestBuilder {
    /// A quiet gap this long between entries splits two conversations. Matches how
    /// people actually use the console: turns arrive seconds-to-minutes apart while
    /// a conversation is alive.
    static let conversationGapSeconds: TimeInterval = 30 * 60

    /// Splits one agent's timestamp-sorted trail into conversation groups at
    /// quiet gaps. Groups with no user message at all (pure lifecycle notices)
    /// are dropped — they aren't conversations.
    static func conversationGroups(entries: [AgentLogEntry]) -> [[AgentLogEntry]] {
        let sorted = entries.sorted {
            $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp
        }
        var groups: [[AgentLogEntry]] = []
        var current: [AgentLogEntry] = []
        for entry in sorted {
            if let last = current.last,
               entry.timestamp.timeIntervalSince(last.timestamp) > conversationGapSeconds {
                groups.append(current)
                current = []
            }
            current.append(entry)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.filter { group in
            group.contains { $0.kind == .userMessage }
        }
    }

    /// Whether a group contains a real (non-heartbeat) user message. Heartbeat-only
    /// monitoring sessions are digestible activity but don't count as conversations
    /// for the feedback prompt gate.
    static func hasDirectUserTraffic(_ group: [AgentLogEntry]) -> Bool {
        group.contains { $0.kind == .userMessage && !$0.text.hasPrefix("[heartbeat]") }
    }

    /// Digests one conversation group. Returns nil for groups that carry no
    /// conversational traffic (nothing worth reporting).
    static func digest(entries: [AgentLogEntry], hostingMode: String) -> TrajectoryDigest? {
        let sorted = entries.sorted {
            $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp
        }
        let conversational = sorted.filter {
            $0.kind == .userMessage || $0.kind == .assistantMessage
        }
        guard let first = sorted.first, let last = sorted.last,
              conversational.contains(where: { $0.kind == .userMessage })
        else { return nil }

        var toolCallCounts: [String: Int] = [:]
        for entry in sorted where entry.kind == .toolCall {
            let name = entry.toolName ?? "unknown"
            toolCallCounts[name, default: 0] += 1
        }

        // Runs carrying conversational traffic, in order of first appearance —
        // the last one decides the outcome.
        var runOrder: [UUID] = []
        for entry in conversational where !runOrder.contains(entry.runID) {
            runOrder.append(entry.runID)
        }

        var outcome = "interrupted"
        if let finalRun = runOrder.last {
            let finalRunEntries = sorted.filter { $0.runID == finalRun }
            let answered = finalRunEntries.contains { $0.kind == .assistantMessage }
            let endedBadly = finalRunEntries.last.map { $0.isFailure || $0.kind == .error } ?? false
            if answered && !endedBadly { outcome = "completed" }
        }

        let model = sorted.reversed()
            .first { !$0.modelIdentifier.isEmpty }?.modelIdentifier ?? ""

        return TrajectoryDigest(
            conversationID: runOrder.first?.uuidString ?? first.runID.uuidString,
            turns: runOrder.count,
            toolCallCounts: toolCallCounts,
            durationSeconds: Int(last.timestamp.timeIntervalSince(first.timestamp).rounded()),
            outcome: outcome,
            transcriptChars: conversational.reduce(0) { $0 + $1.text.count },
            model: model,
            hostingMode: hostingMode
        )
    }
}

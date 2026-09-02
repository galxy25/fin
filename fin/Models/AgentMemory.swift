import Foundation
import SwiftData

/// What a memory record represents.
enum MemoryKind: String, Codable, CaseIterable {
    /// One conversation's digest — what was asked and answered, plus anything the agent
    /// was explicitly told to remember.
    case episodic
    /// The single user-level profile distilled from episodic memories over time: tasks,
    /// goals, preferences, styles, tastes. Exactly one of these should exist.
    case cumulative
}

/// Long-term memory for the terminal agent, synced across devices like the agents
/// themselves — a conversation digested on the Mac should inform the phone.
///
/// Accepted trade-off: memory content derives from terminal output and model replies —
/// the same material that keeps `AgentLogEntry` local-only. Cross-device memory is the
/// feature's point, so this model syncs anyway; every write is scrubbed by
/// `MemoryRedactor` first, but a secret that doesn't match a known shape can still
/// reach CloudKit. The risk is residual, not zero.
///
/// Every property carries a default and none are unique — required for the
/// CloudKit-mirrored store this model lives in (see `FinApp.init`).
@Model
final class AgentMemory {
    var id: UUID = UUID()
    var kindRaw: String = MemoryKind.episodic.rawValue
    /// Nil for the cumulative profile — it is user-level, not per-agent.
    var agentID: UUID?
    /// The runtime's conversation identity. Nil for the cumulative profile.
    var conversationID: UUID?
    var title: String = ""
    var content: String = ""
    /// Comma-separated metadata tags.
    var tags: String = ""
    var startedAt: Date = Date()
    /// Set once the conversation ends (cleared or torn down).
    var stoppedAt: Date?
    /// Set once this episodic record has been folded into the cumulative profile;
    /// nil marks it as a consolidation candidate. Always nil for the profile itself.
    var consolidatedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .episodic }
        set { kindRaw = newValue.rawValue }
    }

    init(
        kind: MemoryKind,
        agentID: UUID? = nil,
        conversationID: UUID? = nil,
        title: String = "",
        content: String = "",
        tags: String = "",
        startedAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.agentID = agentID
        self.conversationID = conversationID
        self.title = title
        self.content = content
        self.tags = tags
        self.startedAt = startedAt
        self.stoppedAt = nil
        self.consolidatedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

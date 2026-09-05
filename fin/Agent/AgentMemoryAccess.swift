import Foundation

/// One search hit, decoupled from the model type so the runtime stays SwiftData-free.
struct AgentMemoryHit {
    var id: UUID
    var title: String
    var content: String
    var tags: String
    var updatedAt: Date
}

/// Memory operations handed to `AgentRuntime` as closures, mirroring how `onAgentLog`
/// keeps the runtime free of SwiftData. `FinApp` wires these to a `MemoryStore`.
struct AgentMemoryAccess {
    /// Creates or updates (by conversationID) the conversation's episodic record.
    /// Returns false when the store rejected the save, so callers can report honestly.
    var saveEpisodic: (_ conversationID: UUID, _ agentID: UUID?, _ title: String, _ content: String, _ tags: String) -> Bool
    var markConversationStopped: (_ conversationID: UUID) -> Void
    /// Substring match against title/content/tags, newest first; empty query = most
    /// recent. This is the metadata/recency search and the fallback lane for
    /// `semanticSearch` below.
    var searchMemories: (_ query: String, _ limit: Int) -> [AgentMemoryHit]
    /// Vector/hybrid recall scoped to the agent's semantic index (PROTOTYPE,
    /// vector-recall branch). nil result = the vector path is unavailable or errored;
    /// the runtime then falls back to `searchMemories`, as it also does on an empty
    /// result — so wiring this can only improve recall, never lose it. Optional and
    /// defaulted so existing constructions (and `.noop`) stay keyword-only.
    var semanticSearch: (@MainActor (_ agentID: UUID, _ query: String, _ limit: Int) async -> [AgentMemoryHit]?)? = nil
    /// Why `semanticSearch` last returned nil ("platform gate", "empty index",
    /// "rebuild in progress", "error <desc>"), read immediately after a nil result.
    /// Feeds the runtime's once-per-session vector-lane audit line; optional and
    /// defaulted so existing constructions (and `.noop`) stay unchanged.
    var vectorLaneDiagnostic: (() -> String?)? = nil
    /// The session-routing registry, nil when none exists — nil (the default) keeps
    /// the routing prompt section out of the system prompt entirely, so agents
    /// without a registry see zero change. Optional and defaulted so existing
    /// constructions (and `.noop`) stay registry-free.
    var readRoutingRegistry: (() -> RegistryDocument?)? = nil
    /// The user profile, empty if none exists yet.
    var readCumulative: () -> String
    var writeCumulative: (_ content: String) -> Bool
    /// Episodic records not yet folded into the profile (`consolidatedAt == nil`),
    /// newest first.
    var consolidationCandidates: (_ limit: Int) -> [AgentMemoryHit]
    /// Stamps `consolidatedAt` — called only after a successful profile write, so a
    /// failed consolidation loses nothing.
    var markConsolidated: (_ ids: [UUID]) -> Void
    /// The agent's newest episodic record whose conversation never ended, so a
    /// relaunch can adopt it instead of fragmenting the conversation per launch.
    var latestOpenConversation: (_ agentID: UUID) -> (id: UUID, title: String, digest: String)?

    static let noop = AgentMemoryAccess(
        saveEpisodic: { _, _, _, _, _ in true },
        markConversationStopped: { _ in },
        searchMemories: { _, _ in [] },
        readCumulative: { "" },
        writeCumulative: { _ in true },
        consolidationCandidates: { _ in [] },
        markConsolidated: { _ in },
        latestOpenConversation: { _ in nil }
    )
}

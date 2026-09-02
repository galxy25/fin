import Foundation
import SwiftData

/// Concrete implementation behind `AgentMemoryAccess` — the only place agent memory
/// touches SwiftData. Lives outside `FinApp.init` so tests can exercise it against an
/// in-memory container. Not actor-annotated for the same reason the `onAgentLog`
/// closure isn't: every caller (the main-actor `AgentRuntime`) already runs on main,
/// and annotating would make the plain closure types in `AgentMemoryAccess` illegal.
final class MemoryStore {
    private let context: ModelContext
    /// Optional semantic index (PROTOTYPE, vector-recall branch). Nil on OS versions
    /// without the on-device embedder — every write path below treats indexing as
    /// fire-and-forget, so an index failure can never break a memory write.
    private let indexer: (any AgentMemoryIndexing)?

    /// Why the vector lane most recently declined to serve ("platform gate",
    /// "empty index", "rebuild in progress", "error <desc>"); nil after a recall
    /// the vector lane handled. Feeds the runtime's once-per-session
    /// "[recall] vector lane unavailable — <reason>" audit line — the silent
    /// keyword fallback hid a broken index in the field for hours.
    private(set) var lastVectorLaneReason: String?

    init(context: ModelContext, indexer: (any AgentMemoryIndexing)? = nil) {
        self.context = context
        self.indexer = indexer
    }

    /// Strong captures on purpose: the store holds no reference back to these closures,
    /// and whoever installs the access is what keeps the store alive.
    var access: AgentMemoryAccess {
        AgentMemoryAccess(
            saveEpisodic: { self.saveEpisodic(conversationID: $0, agentID: $1, title: $2, content: $3, tags: $4) },
            markConversationStopped: { self.markConversationStopped(conversationID: $0) },
            searchMemories: { self.searchMemories(query: $0, limit: $1) },
            semanticSearch: { await self.semanticRecall(agentID: $0, query: $1, limit: $2) },
            vectorLaneDiagnostic: { self.lastVectorLaneReason },
            readCumulative: { self.readCumulative() },
            writeCumulative: { self.writeCumulative(content: $0) },
            consolidationCandidates: { self.consolidationCandidates(limit: $0) },
            markConsolidated: { self.markConsolidated(ids: $0) },
            latestOpenConversation: { self.latestOpenConversation(agentID: $0) }
        )
    }

    /// Every write is scrubbed here — the single choke point in front of the
    /// CloudKit-synced store — so no caller can forget the redaction pass.
    @discardableResult
    func saveEpisodic(conversationID: UUID, agentID: UUID?, title: String, content: String, tags: String) -> Bool {
        let safeTitle = MemoryRedactor.redact(title)
        let safeContent = MemoryRedactor.redact(content)
        let record: AgentMemory
        if let existing = episodicRecord(for: conversationID) {
            existing.title = safeTitle
            existing.content = safeContent
            existing.tags = tags
            existing.updatedAt = Date()
            record = existing
        } else {
            record = AgentMemory(
                kind: .episodic,
                agentID: agentID,
                conversationID: conversationID,
                title: safeTitle,
                content: safeContent,
                tags: tags
            )
            context.insert(record)
        }
        let saved = (try? context.save()) != nil
        if saved {
            indexer?.noteUpsert(
                agentID: record.agentID,
                memoryID: record.id,
                text: Self.indexableText(title: safeTitle, content: safeContent, tags: tags)
            )
        }
        return saved
    }

    func markConversationStopped(conversationID: UUID) {
        guard let record = episodicRecord(for: conversationID) else { return }
        record.stoppedAt = Date()
        try? context.save()
    }

    /// Substring metadata search over episodic memories, newest first. The cumulative
    /// profile is excluded — it is already injected into the system prompt wholesale.
    /// Vector search is the intended eventual replacement for this.
    func searchMemories(query: String, limit: Int) -> [AgentMemoryHit] {
        let kind = MemoryKind.episodic.rawValue
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\AgentMemory.updatedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else { return [] }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = needle.isEmpty
            ? records
            : records.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.content.localizedCaseInsensitiveContains(needle)
                    || $0.tags.localizedCaseInsensitiveContains(needle)
            }
        return matches.prefix(max(0, limit)).map(hit)
    }

    /// Vector/hybrid recall over the agent's semantic index, mapped back to live
    /// SwiftData records so callers see exactly the same `AgentMemoryHit` shape as
    /// keyword search. Returns nil when no indexer is wired (platform gate) or the
    /// index errored — the runtime falls back to `searchMemories`. Scoped per agent
    /// (each agent has its own store); cross-agent and legacy nil-agent records stay
    /// reachable through the keyword fallback.
    ///
    /// `@MainActor` because the SwiftData fetches on either side of the index hop
    /// must stay on the context's actor; the class itself is deliberately
    /// unannotated (see the type comment).
    @MainActor
    func semanticRecall(agentID: UUID, query: String, limit: Int) async -> [AgentMemoryHit]? {
        guard let indexer else {
            lastVectorLaneReason = "platform gate"
            return nil
        }
        // Current truth for the lazy self-heal: the index rebuilds itself when its
        // sidecar diverges from these records (first search of a session only).
        let records = episodicRecords(agentID: agentID)
        let expected = records.map {
            IndexableMemory(id: $0.id, text: Self.indexableText(title: $0.title, content: $0.content, tags: $0.tags))
        }
        switch await indexer.search(agentID: agentID, query: query, limit: limit, expected: expected) {
        case .unavailable(let reason):
            lastVectorLaneReason = reason
            return nil
        case .hits(let vectorHits):
            lastVectorLaneReason = nil
            // Re-materialize from SwiftData rather than trusting index snippets: frames
            // can lag an update, but the record is always current. A hit whose record
            // vanished mid-search drops out here.
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return vectorHits.compactMap { byID[$0.memoryID].map(hit) }
        }
    }

    /// What the semantic index sees for one memory: title + tags + content. Callers
    /// pass already-redacted values — the index must never store what SwiftData wouldn't.
    static func indexableText(title: String, content: String, tags: String) -> String {
        [title, tags, content].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The agent's episodic records shaped for the vector index — what the
    /// launch-time consistency pass treats as SwiftData truth for that agent.
    func indexableEpisodicRecords(agentID: UUID) -> [IndexableMemory] {
        episodicRecords(agentID: agentID).map {
            IndexableMemory(id: $0.id, text: Self.indexableText(title: $0.title, content: $0.content, tags: $0.tags))
        }
    }

    private func episodicRecords(agentID: UUID) -> [AgentMemory] {
        let kind = MemoryKind.episodic.rawValue
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { $0.kindRaw == kind && $0.agentID == agentID },
            sortBy: [SortDescriptor(\AgentMemory.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Episodic records not yet distilled into the profile, newest first. Per-record
    /// markers instead of a timestamp window, so a failed consolidation attempt (or
    /// cross-device sync latency) never permanently excludes a record.
    func consolidationCandidates(limit: Int) -> [AgentMemoryHit] {
        let kind = MemoryKind.episodic.rawValue
        var descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> {
                $0.kindRaw == kind && $0.consolidatedAt == nil
            },
            sortBy: [SortDescriptor(\AgentMemory.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        guard let records = try? context.fetch(descriptor) else { return [] }
        return records.map(hit)
    }

    func markConsolidated(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { ids.contains($0.id) }
        )
        guard let records = try? context.fetch(descriptor) else { return }
        let now = Date()
        for record in records { record.consolidatedAt = now }
        try? context.save()
    }

    /// The agent's newest episodic record whose conversation never ended — what a
    /// relaunched runtime adopts so one conversation stays one record.
    func latestOpenConversation(agentID: UUID) -> (id: UUID, title: String, digest: String)? {
        let kind = MemoryKind.episodic.rawValue
        var descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> {
                $0.kindRaw == kind && $0.agentID == agentID && $0.stoppedAt == nil
            },
            sortBy: [SortDescriptor(\AgentMemory.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first,
              let conversationID = record.conversationID else { return nil }
        return (conversationID, record.title, record.content)
    }

    func readCumulative() -> String {
        cumulativeRecord()?.content ?? ""
    }

    /// Deliberately not indexed for semantic search: the profile is excluded from
    /// `searchMemories` too (it is injected into the system prompt wholesale), and
    /// indexing it would change the recall tool's model-facing contract.
    @discardableResult
    func writeCumulative(content: String) -> Bool {
        let record = fetchOrCreateCumulative()
        record.content = MemoryRedactor.redact(content)
        record.updatedAt = Date()
        return (try? context.save()) != nil
    }

    func fetchOrCreateCumulative() -> AgentMemory {
        if let existing = cumulativeRecord() { return existing }
        let record = AgentMemory(kind: .cumulative, title: "User profile", tags: "profile")
        context.insert(record)
        try? context.save()
        return record
    }

    private func episodicRecord(for conversationID: UUID) -> AgentMemory? {
        let kind = MemoryKind.episodic.rawValue
        var descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> {
                $0.kindRaw == kind && $0.conversationID == conversationID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func cumulativeRecord() -> AgentMemory? {
        let kind = MemoryKind.cumulative.rawValue
        // No fetchLimit: if sync ever races two profiles into existence, converging on
        // the oldest keeps every device rewriting the same record from then on.
        let descriptor = FetchDescriptor<AgentMemory>(
            predicate: #Predicate<AgentMemory> { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\AgentMemory.createdAt, order: .forward)]
        )
        guard let records = try? context.fetch(descriptor),
              let canonical = records.first else { return nil }
        // Sync races can create duplicates; fold their distinct content into the
        // canonical (oldest) record, newest last, and delete the extras.
        if records.count > 1 {
            for extra in records.dropFirst() {
                let content = extra.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty, !canonical.content.contains(content) {
                    canonical.content = canonical.content.isEmpty
                        ? content
                        : canonical.content + "\n" + content
                }
                // Invariant: every local `context.delete` of an AgentMemory pairs
                // with a noteRemoval, so no deletion leaves index residue behind.
                // (Cumulative records are never indexed, so today this is a no-op —
                // the pairing is kept so future delete paths copy the right shape.)
                indexer?.noteRemoval(agentID: extra.agentID, memoryID: extra.id)
                context.delete(extra)
            }
            canonical.updatedAt = Date()
            try? context.save()
        }
        return canonical
    }

    private func hit(_ record: AgentMemory) -> AgentMemoryHit {
        AgentMemoryHit(
            id: record.id,
            title: record.title,
            content: record.content,
            tags: record.tags,
            updatedAt: record.updatedAt
        )
    }
}

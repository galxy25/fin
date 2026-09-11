import Foundation

// Semantic-recall seam. A vector/hybrid index (Wax-backed on-device, then a cloud
// index behind the control plane API) has lived behind this interface before —
// keyword search alone ranked query "wrapper verification" below an unrelated
// recency-first memory instead of the memory literally titled "wrapper
// verification". The Wax-backed implementation was removed 2026-09-11: it dragged
// in ~all of Wax's broker/MCP-server code just for its embedded vector store (Fin
// only ever called `Wax.Memory.save/search/stats/flush/close`), and that unused
// code broke the macOS Release build (MetalANNS's Float16 API under a newer
// Xcode) while ALSO already being broken for iOS (an unguarded Foundation.Process
// reference in the broker). Semantic recall is being rebuilt on the cloud control
// plane (`scripts/cloud-agent/control-plane`) instead, since that infra already
// exists. Until then `indexer` is always nil and every agent runs keyword-only
// recall, exactly like the pre-Wax app.

/// One search hit from the vector index: which SwiftData memory matched, the text
/// the index stored for it (possibly stale — callers should re-materialize from
/// SwiftData), and the index's rank score (a rank key, not a probability).
struct VectorRecallHit: Sendable {
    let memoryID: UUID
    let snippet: String
    let score: Double?
}

/// One memory as the index should see it: identity plus the text worth embedding
/// (title + tags + content, already redacted by `MemoryStore`).
struct IndexableMemory: Sendable {
    let id: UUID
    let text: String
}

/// What the vector lane did with a search: either it ran (possibly finding nothing),
/// or it was unavailable for a stated reason. The reason string feeds the
/// once-per-session "[recall] vector lane unavailable — <reason>" audit line, which
/// exists because the silent keyword fallback hid a broken index in the field for
/// hours. Reason vocabulary: "empty index", "rebuild in progress", "error <desc>"
/// (plus "platform gate", produced above this seam where no indexer is wired).
enum VectorSearchResult: Sendable {
    case hits([VectorRecallHit])
    case unavailable(reason: String)
}

/// The seam `MemoryStore` holds instead of a concrete index — currently always nil
/// (see the file header), so every agent runs keyword-only recall. A future
/// cloud-backed indexer plugs in here without `MemoryStore` or `AgentRuntime`
/// changing at all.
protocol AgentMemoryIndexing: Sendable {
    /// Fire-and-forget: returns immediately, indexes in the background. An indexing
    /// failure must never break a memory write — errors are logged and dropped.
    /// Memories with `agentID == nil` are not indexed at all (there is no agent whose
    /// recall could ever search them); the keyword fallback still finds such records.
    func noteUpsert(agentID: UUID?, memoryID: UUID, text: String)
    /// Fire-and-forget tombstone; the frame is physically dropped at the next rebuild.
    /// Call this alongside EVERY local deletion of an `AgentMemory` record — a
    /// `context.delete` without it leaves the record's plaintext in the index file
    /// until a consistency pass notices the divergence.
    func noteRemoval(agentID: UUID?, memoryID: UUID)
    /// Vector/hybrid search over the agent's index. `expected` is the agent's current
    /// SwiftData truth, used for the once-per-session lazy self-heal (rebuild on
    /// divergence). `.unavailable` means the caller should fall back to keyword
    /// search; `.hits([])` means the index ran and found nothing (callers also fall
    /// back, so recall never regresses).
    func search(agentID: UUID, query: String, limit: Int, expected: [IndexableMemory]) async -> VectorSearchResult
}

/// Front door for "this agent is gone — take its vector index files with it". UI
/// deletion paths call this unconditionally; it is currently always a no-op (see
/// the file header) until some future concrete indexer installs a destroyer.
@MainActor
enum AgentMemoryIndexRegistry {
    /// Fire-and-forget, like the indexer's note* calls: agent deletion must never
    /// block the UI on index file IO.
    static var destroyIndex: (UUID) -> Void = { _ in }
    /// Audit sink for index-level events that should reach the agent log machinery
    /// (and, behind the mirror gate, iCloud — so they are remotely debuggable).
    /// `FinApp` wires it to `SessionManager.recordLifecycleEvent`; a no-op elsewhere.
    static var audit: (_ agentID: UUID, _ line: String) -> Void = { _, _ in }
}


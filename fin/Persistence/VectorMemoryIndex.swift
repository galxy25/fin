import CryptoKit
import Foundation
import os
#if canImport(Wax)
import Wax
#endif

// PROTOTYPE (vector-recall branch): semantic recall on Wax. Scoped to prove that
// vector/hybrid search fixes the relevance failure keyword recall showed in the
// field (query "wrapper verification" ranking an unrelated recency-first memory
// above the memory literally titled "wrapper verification").

/// One search hit from the vector index: which SwiftData memory matched, the text
/// Wax stored for it (possibly stale — callers should re-materialize from
/// SwiftData), and Wax's rank score (a rank key, not a probability).
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

/// The seam `MemoryStore` holds instead of a concrete index, so the store compiles
/// and runs on OS versions where the Wax embedder does not exist (iOS 17): the
/// concrete `VectorMemoryIndexManager` is availability-gated, and a nil indexer
/// simply means "keyword search only".
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

/// Non-availability-gated front door for "this agent is gone — take its vector index
/// files with it". UI deletion paths call this unconditionally; it is a no-op until
/// `FinApp.init` installs a destroyer (Wax platforms only), so visionOS and iOS 17
/// compile and run it as nothing.
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

// Wax is destination-filtered out of the visionOS build (its broker code cannot
// compile there — see project.yml), so everything below the seam vanishes with it;
// visionOS runs keyword-only recall through the nil-indexer path.
#if canImport(Wax)

/// Owns one `VectorMemoryIndex` per agent. Memories saved without an agent are not
/// indexed at all — no agent's recall could ever search them, and an unsearchable
/// store would be a write-only plaintext file with no erasure path.
///
/// The fire-and-forget note* calls are executed strictly in spawn order per agent
/// (a chained tail Task, appended synchronously under a lock at call time), so an
/// upsert can never overtake the removal of the same memory; `search` and the
/// consistency pass await the agent's current tail before comparing state.
@available(iOS 18.0, macOS 15.0, *)
actor VectorMemoryIndexManager: AgentMemoryIndexing {
    private let directory: URL
    private let embedding: Wax.Memory.EmbeddingSource
    private var indexes: [UUID: VectorMemoryIndex] = [:]
    private let queues = OrderedNoteQueues()

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fin/VectorMemory", isDirectory: true)
    }

    init(
        directory: URL = VectorMemoryIndexManager.defaultDirectory,
        embedding: Wax.Memory.EmbeddingSource = VectorMemoryIndex.defaultEmbedding
    ) {
        self.directory = directory
        self.embedding = embedding
    }

    private func index(for agentID: UUID) -> VectorMemoryIndex {
        if let existing = indexes[agentID] { return existing }
        let created = VectorMemoryIndex(agentID: agentID, directory: directory, embedding: embedding)
        indexes[agentID] = created
        return created
    }

    nonisolated func noteUpsert(agentID: UUID?, memoryID: UUID, text: String) {
        guard let agentID else {
            VectorMemoryIndex.logger.debug("not indexing agent-less memory \(memoryID)")
            return
        }
        queues.append(agentID: agentID) {
            await self.index(for: agentID).upsert(memoryID: memoryID, text: text)
        }
    }

    nonisolated func noteRemoval(agentID: UUID?, memoryID: UUID) {
        guard let agentID else { return } // never indexed (see noteUpsert) — nothing to remove
        queues.append(agentID: agentID) {
            await self.index(for: agentID).remove(memoryID: memoryID)
        }
    }

    /// How long a recall will wait for in-flight consistency work (typically the
    /// launch pass's full rebuild) before serving the keyword fallback instead. A
    /// first-ever rebuild on-device can run minutes (CoreML model compile inside the
    /// store open); a recall tool call must not hang the agent's turn on that.
    static let searchConsistencyTimeout: TimeInterval = 30

    func search(agentID: UUID, query: String, limit: Int, expected: [IndexableMemory]) async -> VectorSearchResult {
        let index = index(for: agentID)
        // An already-running check/rebuild first, BEFORE the note-tail wait: notes
        // themselves wait out consistency work, so waiting the tail while a rebuild
        // runs would chain this recall behind it unboundedly.
        guard await index.waitForConsistencyWorkBounded(timeout: Self.searchConsistencyTimeout) else {
            return .unavailable(reason: "rebuild in progress")
        }
        // Let already-spawned notes land, so the consistency check compares settled
        // state — otherwise a save an instant before the session's first recall
        // reads as divergence and triggers a spurious full rebuild.
        await queues.waitForTail(agentID: agentID)
        // Bounded wait: joins (never duplicates) any in-flight consistency check.
        // The live defect's first symptom was a recall racing the launch pass's
        // rebuild and searching a half-built store; now it either waits for the
        // settled state or honestly reports why it can't serve.
        let settled = await index.ensureConsistentBounded(
            with: expected, timeout: Self.searchConsistencyTimeout
        )
        guard settled else { return .unavailable(reason: "rebuild in progress") }
        guard await index.indexedCount > 0 else { return .unavailable(reason: "empty index") }
        do {
            return .hits(try await index.search(query: query, limit: limit))
        } catch {
            VectorMemoryIndex.logger.error("vector search failed: \(String(describing: error))")
            return .unavailable(reason: "error \(String(describing: error))")
        }
    }

    /// Launch-time consistency pass for one agent: remote (CloudKit-synced) deletions
    /// have no per-record hook, so `FinApp` runs this in the background shortly after
    /// launch with each agent's current SwiftData truth. Cheap when nothing changed
    /// (digest-map compare plus a `stats()` call); a full rebuild only on divergence.
    /// Deliberately does NOT consume the index's once-per-session search-path check,
    /// so a deletion synced in after this pass is still caught at first recall.
    func ensureConsistent(agentID: UUID, expected: [IndexableMemory]) async {
        await queues.waitForTail(agentID: agentID)
        await index(for: agentID).verifyConsistency(with: expected)
    }

    /// Deletes an agent's index outright: waits out pending notes, closes the store
    /// (Wax's lock is an untimed `flock` — never delete an open store), then removes
    /// the `.wax` file, its sidecar, and any WAL-style siblings.
    func destroyIndex(agentID: UUID) async {
        await queues.waitForTail(agentID: agentID)
        if let index = indexes.removeValue(forKey: agentID) {
            // An in-flight consistency rebuild would recreate the files right
            // after this removal — wait it out before deleting anything.
            await index.waitForConsistencyWork()
            await index.close()
        }
        Self.removeIndexFiles(agentID: agentID, directory: directory)
    }

    /// Removes index files whose agent no longer exists — agents deleted on another
    /// device (their local `destroyIndex` hook never fired here) and legacy stores
    /// from builds that indexed agent-less memories. Run by the launch pass.
    func pruneOrphanedIndexes(keeping agentIDs: Set<UUID>) async {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var orphans: Set<UUID> = []
        for file in files {
            let name = file.lastPathComponent
            guard let dot = name.firstIndex(of: "."),
                  let id = UUID(uuidString: String(name[..<dot])),
                  !agentIDs.contains(id)
            else { continue }
            orphans.insert(id)
        }
        for id in orphans {
            VectorMemoryIndex.logger.notice("pruning vector index for missing agent \(id)")
            await destroyIndex(agentID: id)
        }
    }

    private static func removeIndexFiles(agentID: UUID, directory: URL) {
        let fileManager = FileManager.default
        let prefix = "\(agentID.uuidString)."
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Test seam: waits until every fire-and-forget note spawned so far has landed.
    func waitForPendingWrites() async {
        await queues.waitForAllTails()
    }

    /// Releases every store's file lock. Required before another manager instance
    /// may touch the same directory (Wax's store lock is an untimed `flock`; a
    /// second open of a still-open store blocks forever). Waits out pending notes
    /// first so a late note can't reopen a just-closed store.
    func closeAll() async {
        await queues.waitForAllTails()
        for index in indexes.values {
            await index.waitForConsistencyWork()
            await index.close()
        }
        indexes.removeAll()
    }

    /// Test seam: the underlying per-agent index, for state assertions.
    func indexForTesting(agentID: UUID) -> VectorMemoryIndex {
        index(for: agentID)
    }

    /// The per-agent FIFO behind the fire-and-forget notes. Independent `Task {}`s
    /// carry no ordering guarantee — an earlier upsert could overtake the removal of
    /// the same memory and resurrect it in the sidecar — so each note chains onto the
    /// agent's previous tail, and the chaining happens *synchronously under the lock
    /// at call time*, making spawn order == execution order per agent.
    private final class OrderedNoteQueues: @unchecked Sendable {
        private let lock = NSLock()
        private var tails: [UUID: Task<Void, Never>] = [:]

        func append(agentID: UUID, _ op: @escaping @Sendable () async -> Void) {
            lock.withLock {
                let previous = tails[agentID]
                tails[agentID] = Task {
                    await previous?.value
                    await op()
                }
            }
        }

        func waitForTail(agentID: UUID) async {
            let tail = lock.withLock { tails[agentID] }
            await tail?.value
        }

        func waitForAllTails() async {
            let snapshot = lock.withLock { Array(tails.values) }
            for tail in snapshot { await tail.value }
        }
    }
}

/// One agent's semantic memory index: a single-file Wax store at
/// `Application Support/fin/VectorMemory/<agentID>.wax` plus a JSON sidecar
/// tracking what this app believes is indexed (`memoryID -> content digest`).
///
/// Wax's real API (verified against the pinned 0.1.27 sources) shapes three decisions here:
/// - `save(_:metadata:)` accepts metadata and `search` returns it per item, so each
///   frame carries its SwiftData UUID under `fin-memory-id` — no text-embedding hack.
/// - `delete(frameID:)` exists but `save` never returns the frame ID, so a specific
///   memory cannot be deleted directly. Updates therefore append a fresh frame
///   (search dedupes by memory ID, best rank wins) and removals tombstone in the
///   sidecar; both are physically compacted by `rebuild(from:)`.
/// - `stats()` exposes `frameCount`, which backs the cheap self-heal divergence
///   check alongside the sidecar.
///
/// Deleted-content erasure SLA (honest version): a removal first *tombstones* —
/// search stops returning the memory immediately, but its plaintext frames stay in
/// the `.wax` file until the next rebuild physically drops them. Rebuilds happen at
/// the launch-time consistency pass and at the session's first recall for the agent,
/// so a locally deleted memory's bytes are erased from disk by the next launch at
/// the latest. Remote (CloudKit-synced) deletions have no per-record hook at all and
/// rely entirely on those divergence-triggered rebuilds — same bound: gone from
/// search once the record leaves SwiftData, gone from disk by the next launch.
/// Deleting an *agent* bypasses all of this: `destroyIndex` removes its files outright.
@available(iOS 18.0, macOS 15.0, *)
actor VectorMemoryIndex {
    static let logger = Logger(subsystem: "dev.levischoen.fin", category: "VectorMemory")

    /// GPU-first on purpose, three Wax 0.1.27 facts driving it (all verified):
    /// - `.automatic` and the default compute order compile the model for the Neural
    ///   Engine *inside the store open* — ~10 minutes on a first launch (CoreML's
    ///   compile cache is keyed to the app bundle), during which every open-awaiting
    ///   caller stalls. The GPU plan of the same model compiles in seconds.
    /// - The bundled fp16 model overflows to non-finite values on plain CPU, so
    ///   `cpuOnly` is not a usable fallback (upstream shipped a finite model only in
    ///   0.1.33, which no longer compiles for iOS — see project.yml).
    /// - `.builtIn` (unlike `.automatic`) surfaces a broken setup as a thrown error
    ///   instead of silently degrading to text-only; our openIfNeeded logs and the
    ///   recall path falls back to keyword search.
    static let defaultEmbedding = Wax.Memory.EmbeddingSource.builtIn(
        .miniLM,
        BuiltInEmbeddingProviderOptions(computeUnitsOrder: [.cpuAndGPU, .cpuAndNeuralEngine, .all])
    )
    private static let metadataKey = "fin-memory-id"
    /// Stale frames accumulate one per content update (see `upsert`); past this many,
    /// the next session's consistency check compacts even without divergence.
    private static let staleFrameCompactionThreshold = 64

    private let agentID: UUID
    private let directory: URL
    private let storeURL: URL
    private let stateURL: URL
    private let embedding: Wax.Memory.EmbeddingSource
    /// Memoized open. A plain `var store: Wax.Memory?` would race under actor
    /// reentrancy: two concurrent callers both see nil across the init's suspension
    /// (the embedder can compile for minutes) and start two `Wax.Memory` inits on the
    /// same file — and Wax's store lock is an *untimed* blocking `flock`, so the
    /// second init deadlocks an IO thread forever. Publishing the Task before the
    /// first await makes every later caller await the same open.
    private var openAttempt: (id: UUID, task: Task<Wax.Memory, Error>)?
    private var state: State
    private var checkedConsistency = false
    /// Serializes consistency checks (and the rebuilds they trigger): each check
    /// chains onto the previous one, exactly like the note queue. Without this,
    /// the launch pass and the session's first recall — which FinApp runs
    /// concurrently — both read the same diverged sidecar under actor reentrancy
    /// and run DUPLICATE full rebuilds, each closing and deleting the store out
    /// from under the other (observed live: io("session is closed") save failures,
    /// SQLite unlinked-while-open complaints, and recalls served off a half-built
    /// store).
    private var consistencyChain: Task<Void, Never>?
    /// How many chained checks have not finished yet; 0 means settled state.
    private var activeConsistencyChecks = 0

    private struct State: Codable {
        /// memoryID -> digest of the last text indexed for it.
        var indexed: [String: String] = [:]
        /// Removed memoryIDs whose frames still exist until the next rebuild.
        var tombstones: Set<String> = []
        /// Frames superseded by updates/removals, awaiting compaction.
        var staleFrames: Int = 0
        /// The store's frame count recorded after the last successful write, so an
        /// interrupted rebuild (iOS suspension/kill mid-loop) is detected next
        /// session even when the digest map alone still matches SwiftData truth.
        /// Optional: absent in sidecars written by earlier builds.
        var frameCount: UInt64?
    }

    init(agentID: UUID, directory: URL, embedding: Wax.Memory.EmbeddingSource = VectorMemoryIndex.defaultEmbedding) {
        self.agentID = agentID
        self.directory = directory
        self.storeURL = directory.appendingPathComponent("\(agentID.uuidString).wax")
        self.stateURL = directory.appendingPathComponent("\(agentID.uuidString).state.json")
        self.embedding = embedding
        self.state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
    }

    // MARK: - Writes

    /// Indexes (or re-indexes) one memory. Unchanged content is a no-op, so the
    /// per-turn episodic re-save doesn't grow the store; changed content appends a
    /// fresh frame and counts the superseded one as stale.
    func upsert(memoryID: UUID, text: String) async {
        // Never interleave with an in-flight rebuild: a save racing the rebuild's
        // close/delete/reopen lands in a store that is about to be destroyed.
        await waitForConsistencyWork()
        let key = memoryID.uuidString
        let digest = Self.digest(text)
        if state.indexed[key] == digest { return }
        do {
            let store = try await openIfNeeded()
            try await store.save(text, metadata: [Self.metadataKey: key])
            if state.indexed[key] != nil { state.staleFrames += 1 }
            state.indexed[key] = digest
            state.tombstones.remove(key)
            state.frameCount = await store.stats().frameCount
            persistState()
        } catch {
            Self.logger.error("vector upsert failed for \(key): \(String(describing: error))")
        }
    }

    /// Tombstones a memory: search stops returning it immediately; its frames are
    /// physically dropped at the next rebuild (Wax deletes only by frame ID, which
    /// `save` never exposes — see the type comment). Removing a memory that was
    /// never indexed is a strict no-op — no tombstone, no stale-frame bump — so it
    /// cannot force an unnecessary rebuild.
    func remove(memoryID: UUID) async {
        await waitForConsistencyWork()
        let key = memoryID.uuidString
        guard state.indexed.removeValue(forKey: key) != nil else { return }
        state.tombstones.insert(key)
        state.staleFrames += 1
        persistState()
    }

    // MARK: - Search

    /// Hybrid (FTS5 + vector when the embedder is attached) search, deduped to one
    /// hit per memory. Over-fetches because multiple frames can carry the same
    /// memory ID after updates.
    func search(query: String, limit: Int) async throws -> [VectorRecallHit] {
        guard limit > 0, !state.indexed.isEmpty else { return [] }
        let store = try await openIfNeeded()
        var options = Wax.Memory.SearchOptions()
        options.topK = max(limit * 4, 16)
        let results = try await store.search(query, options: options)
        var seen = Set<String>()
        var hits: [VectorRecallHit] = []
        for item in results.items {
            guard let key = item.metadata[Self.metadataKey],
                  let id = UUID(uuidString: key),
                  state.indexed[key] != nil, // filters tombstoned and foreign frames
                  seen.insert(key).inserted
            else { continue }
            hits.append(VectorRecallHit(memoryID: id, snippet: item.text, score: Double(item.score)))
            if hits.count >= limit { break }
        }
        return hits
    }

    // MARK: - Self-heal

    /// Search-path variant of `verifyConsistency`: once per session (per actor
    /// lifetime), so recall's hot path pays for at most one check. The launch-time
    /// pass calls `verifyConsistency` directly and deliberately does not consume
    /// this guard — a deletion synced in between launch and the first recall is
    /// still caught here.
    func ensureConsistent(with expected: [IndexableMemory]) async {
        guard !checkedConsistency else { return }
        checkedConsistency = true
        await verifyConsistency(with: expected)
    }

    /// The search path's entry: joins (never duplicates) any in-flight consistency
    /// work and waits at most `timeout` for the settled state. Returns false when
    /// the work is still running past the deadline — the caller serves the keyword
    /// fallback with reason "rebuild in progress" instead of hanging the recall on
    /// a rebuild that can take minutes on a cold device.
    func ensureConsistentBounded(with expected: [IndexableMemory], timeout: TimeInterval) async -> Bool {
        if !checkedConsistency {
            checkedConsistency = true
            _ = enqueueConsistencyCheck(expected)
        }
        return await waitForConsistencyWorkBounded(timeout: timeout)
    }

    /// Bounded companion to `waitForConsistencyWork`: true once no consistency
    /// check is in flight, false when the deadline passes first.
    func waitForConsistencyWorkBounded(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while activeConsistencyChecks > 0 {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Compares the sidecar against SwiftData truth and rebuilds on divergence —
    /// which covers records deleted or edited outside this process (CloudKit sync),
    /// a wiped or corrupt store file, pending tombstones, and stale-frame buildup.
    /// (0.1.27 predates `backfillUnembedded` / `framesWithoutVectors`, so frames
    /// saved before the embedder attached are healed by rebuild rather than backfill.)
    ///
    /// Strictly serialized: concurrent callers (the launch pass and the first
    /// recall) chain rather than interleave, so the second check re-evaluates
    /// against the FIRST check's completed rebuild and finds nothing to do —
    /// at most one rebuild per session unless memories actually changed after it.
    func verifyConsistency(with expected: [IndexableMemory]) async {
        await enqueueConsistencyCheck(expected).value
    }

    /// Waits until no consistency check (or rebuild) is in flight. Writers and
    /// teardown paths call this so they never operate on a store mid-rebuild.
    func waitForConsistencyWork() async {
        while activeConsistencyChecks > 0 {
            if let chain = consistencyChain {
                await chain.value
            } else {
                break
            }
        }
    }

    private func enqueueConsistencyCheck(_ expected: [IndexableMemory]) -> Task<Void, Never> {
        activeConsistencyChecks += 1
        let previous = consistencyChain
        let task = Task {
            await previous?.value
            await self.performConsistencyCheck(with: expected)
            await self.finishConsistencyCheck()
        }
        consistencyChain = task
        return task
    }

    private func finishConsistencyCheck() {
        activeConsistencyChecks -= 1
    }

    private func performConsistencyCheck(with expected: [IndexableMemory]) async {
        // Recovery for already-damaged stores first: duplicate rebuilds and per-turn
        // re-appends accumulate frames Wax can never drop (no per-document delete),
        // so recreation IS compaction — past a sanity bound relative to memory
        // count, destroy the files and rebuild fresh no matter what the ledger
        // says. Measured on the frames region beyond the WAL ring, NOT the raw
        // file size: Wax 0.1.27 embeds a 256MiB WAL in every open store file (a
        // healthy open store "weighs" ~256MB on disk until its close-time
        // compaction, which an iOS kill skips), so raw size would flag healthy
        // stores and loop rebuilds forever.
        if let frameBytes = Self.frameRegionBytes(at: storeURL), frameBytes > Self.bloatBound(memoryCount: expected.count) {
            let pretty = ByteCountFormatter.string(fromByteCount: Int64(frameBytes), countStyle: .file)
            Self.logger.notice("vector store bloated (\(pretty)) for \(self.agentID); rebuilding fresh")
            await rebuild(from: expected)
            let line = "[memory-index] store bloated (\(pretty)) — rebuilt fresh (\(expected.count) memories)"
            let id = agentID
            Task { @MainActor in AgentMemoryIndexRegistry.audit(id, line) }
            return
        }
        let expectedMap = Dictionary(
            expected.map { ($0.id.uuidString, Self.digest($0.text)) },
            uniquingKeysWith: { first, _ in first }
        )
        var needsRebuild = expectedMap != state.indexed
            || !state.tombstones.isEmpty
            || state.staleFrames > Self.staleFrameCompactionThreshold
        if !needsRebuild, !state.indexed.isEmpty, let store = try? await openIfNeeded() {
            let stats = await store.stats()
            // The recorded post-write frame count (exact) catches a rebuild that an
            // iOS suspension killed mid-loop; the indexed-count floor is the weaker
            // legacy check for sidecars written before frameCount existed.
            let expectedFrames = state.frameCount ?? UInt64(state.indexed.count)
            if stats.frameCount < expectedFrames {
                needsRebuild = true // store lost frames the sidecar believes exist
            }
        }
        if needsRebuild {
            Self.logger.notice("vector index diverged from SwiftData for \(self.agentID); rebuilding")
            await rebuild(from: expected)
        }
    }

    /// The frames-region sanity bound: a healthy store for `memoryCount` memories
    /// (few-KB digests plus embeddings) sits well under 100KB per memory even with
    /// the per-update stale frames the compaction threshold tolerates; the 20MB
    /// floor keeps small stores from tripping on fixed overhead.
    static func bloatBound(memoryCount: Int) -> Int {
        max(20 * 1024 * 1024, memoryCount * 100 * 1024)
    }

    /// Bytes the .wax file holds beyond its fixed header + WAL ring — the region
    /// frames (TOC, footer, payloads) actually grow in. Parsed straight off the
    /// header (verified against Wax 0.1.27's `WaxHeaderPage`: magic "WAX1",
    /// wal_offset u64 LE at byte 32, wal_size u64 LE at byte 40). nil when the file
    /// doesn't exist; a file whose header doesn't parse is measured raw — it is
    /// unreadable garbage, and recreating it over the bound is the right recovery
    /// for that too.
    static func frameRegionBytes(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = attributes[.size] as? Int
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return total }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 48), header.count == 48,
              header.prefix(4) == Data([0x57, 0x41, 0x58, 0x31]) // "WAX1"
        else { return total }
        func readUInt64(at offset: Int) -> UInt64 {
            header.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
            }
        }
        let dataStart = readUInt64(at: 32) &+ readUInt64(at: 40)
        guard dataStart > 0, dataStart < UInt64(Int.max) else { return total }
        return max(0, total - Int(dataStart))
    }

    /// Drops the store file and re-indexes from scratch — the one place tombstoned
    /// and stale frames are physically removed. Only ever invoked from within the
    /// consistency chain (or directly by tests), so two rebuilds can never interleave.
    func rebuild(from records: [IndexableMemory]) async {
        rebuildCount += 1
        await close()
        let fileManager = FileManager.default
        // The .wax store is single-file, but remove by prefix in case Wax keeps
        // WAL-style siblings next to it.
        let prefix = "\(agentID.uuidString).wax"
        if let siblings = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in siblings where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
        guard let store = try? await openIfNeeded() else {
            // The old store is gone and a fresh one would not open: nothing is
            // indexed, and the ledger must say so or search would trust entries
            // that no longer have a store behind them.
            state = State()
            persistState()
            return
        }
        // Build the replacement ledger off to the side; `state` keeps the previous
        // fully-landed truth until the rebuild completes. An interruption (process
        // kill, iOS suspension mid-loop) therefore never persists an empty or
        // partial ledger — the failure mode that left the field device with a
        // 277-byte sidecar it re-rebuilt against on every consistency check. The
        // stale on-disk ledger an interruption leaves behind is caught next session
        // by the frameCount comparison above.
        var rebuilt = State()
        for record in records {
            let key = record.id.uuidString
            do {
                try await store.save(record.text, metadata: [Self.metadataKey: key])
                rebuilt.indexed[key] = Self.digest(record.text)
            } catch {
                Self.logger.error("vector rebuild skipped \(key): \(String(describing: error))")
            }
        }
        try? await store.flush()
        rebuilt.frameCount = await store.stats().frameCount
        state = rebuilt
        persistState()
    }

    /// Test seam: full rebuilds performed by this actor instance (one actor ==
    /// one session, so a lifecycle test can assert the per-session rebuild budget).
    private(set) var rebuildCount = 0

    /// Test seam: how many distinct memories the sidecar believes are indexed.
    var indexedCount: Int { state.indexed.count }

    /// Test seam: whether the sidecar has any entry for this memory.
    func isIndexed(memoryID: UUID) -> Bool { state.indexed[memoryID.uuidString] != nil }

    /// Test seam: whether the sidecar records exactly `text` as this memory's
    /// currently indexed content (digest comparison — ordering assertions).
    func hasIndexed(memoryID: UUID, text: String) -> Bool {
        state.indexed[memoryID.uuidString] == Self.digest(text)
    }

    /// Test seams for the removal bookkeeping.
    var tombstoneCount: Int { state.tombstones.count }
    var staleFrameCount: Int { state.staleFrames }

    // MARK: - Plumbing

    /// WAL ring capacity for stores this app creates. Wax 0.1.27's `Memory` facade
    /// hardwires its 256MiB default WAL into every NEW store file — which is why the
    /// field device's vector store "weighed" 256.2MB for a few dozen memories: the
    /// file's logical size is header + WAL + frames from the very first save, and
    /// the app never performs the clean close that would compact it. Wax opens an
    /// existing file with whatever wal_size its header declares, so pre-creating
    /// the file right-sizes it: 8MiB caps the resting file at ~8MB while leaving
    /// orders of magnitude of headroom over the largest single memory text.
    static let newStoreWALSize: UInt64 = 8 * 1024 * 1024

    private func openIfNeeded() async throws -> Wax.Memory {
        if let openAttempt { return try await openAttempt.task.value }
        let id = UUID()
        let task = Task { [storeURL, directory, embedding] () throws -> Wax.Memory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: storeURL.path) {
                // Seed the file with a right-sized WAL (see newStoreWALSize), then
                // let the Memory facade adopt it as an existing store.
                let seed = try await FrameStore.create(at: storeURL, walSize: Self.newStoreWALSize)
                try await seed.close()
            }
            var config = Wax.Memory.Config.default
            config.embedding = embedding
            return try await Wax.Memory(at: storeURL, config: config)
        }
        openAttempt = (id, task)
        do {
            return try await task.value
        } catch {
            // A failed open must not poison the index for the session — the next
            // caller retries from scratch. The id guard keeps a stale failure from
            // wiping a newer attempt that a retry already started.
            if openAttempt?.id == id { openAttempt = nil }
            throw error
        }
    }

    /// Releases the store's file lock. Wax's lock is an untimed `flock` on the .wax
    /// file, so anything that will reopen this store through another instance (tests
    /// spanning "sessions", a future teardown path) must close the old one first.
    func close() async {
        guard let openAttempt else { return }
        self.openAttempt = nil
        if let store = try? await openAttempt.task.value {
            try? await store.close()
        }
    }

    private func persistState() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Self.logger.error("vector sidecar write failed: \(String(describing: error))")
        }
    }

    /// Stable across launches (unlike `hashValue`), cheap, and collision-safe enough
    /// for change detection: the first 8 bytes of SHA-256 over the indexed text.
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

#endif // canImport(Wax)

import SwiftData
import XCTest
@testable import fin

// PROTOTYPE (vector-recall branch): exercises the Wax-backed semantic index and the
// recall tool's vector-first/keyword-fallback lane selection.

// MARK: - Runtime lane selection (no Wax required — runs on all platforms)

/// The recall tool's contract: semantic lane first when wired and the query is
/// non-empty; keyword lane on nil (gate off), error, empty results, or empty query.
/// These use stub closures, so they run everywhere — including visionOS, where the
/// vector path doesn't exist at all.
final class RecallLaneSelectionTests: XCTestCase {

    @MainActor
    private func makeRuntime(access: AgentMemoryAccess) -> AgentRuntime {
        AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible,
                         endpointURL: "http://[invalid/v1", modelIdentifier: "m"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
    }

    private static func hit(_ title: String, content: String = "c") -> AgentMemoryHit {
        AgentMemoryHit(id: UUID(), title: title, content: content, tags: "", updatedAt: Date())
    }

    @MainActor
    func testRecallFallsBackToKeywordWhenVectorGateIsOff() async {
        var access = AgentMemoryAccess.noop
        access.semanticSearch = nil // the platform gate / visionOS shape
        access.searchMemories = { _, _ in [Self.hit("keyword hit")] }

        let result = await makeRuntime(access: access)
            .executeRecall(query: "wrapper verification", rawArguments: "{}")
        XCTAssertTrue(result.contains("keyword hit"))
    }

    @MainActor
    func testRecallPrefersVectorHitsAndSkipsKeywordSearch() async {
        var keywordSearched = false
        var access = AgentMemoryAccess.noop
        access.semanticSearch = { _, _, _ in [Self.hit("vector hit")] }
        access.searchMemories = { _, _ in
            keywordSearched = true
            return [Self.hit("keyword hit")]
        }

        let result = await makeRuntime(access: access)
            .executeRecall(query: "wrapper verification", rawArguments: "{}")
        XCTAssertTrue(result.contains("vector hit"))
        XCTAssertFalse(keywordSearched, "a non-empty vector result must not also run keyword search")
    }

    @MainActor
    func testRecallFallsBackWhenVectorReturnsEmptyOrNil() async {
        for vectorResult in [[AgentMemoryHit]?.none, [AgentMemoryHit]?.some([])] {
            var access = AgentMemoryAccess.noop
            access.semanticSearch = { _, _, _ in vectorResult }
            access.searchMemories = { _, _ in [Self.hit("keyword hit")] }

            let result = await makeRuntime(access: access)
                .executeRecall(query: "anything", rawArguments: "{}")
            XCTAssertTrue(result.contains("keyword hit"))
        }
    }

    @MainActor
    private func makeRuntimeCapturingLog(access: AgentMemoryAccess, into lines: NSMutableArray) -> AgentRuntime {
        AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible,
                         endpointURL: "http://[invalid/v1", modelIdentifier: "m"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { record in if record.kind == .notice { lines.add(record.text) } },
            memory: access
        )
    }

    /// The vector lane's health must be visible in the audit trail exactly once per
    /// session: "served <n> hits" on the first successful vector recall, never again.
    @MainActor
    func testFirstVectorRecallAuditsServedHitsOnce() async {
        let lines = NSMutableArray()
        var access = AgentMemoryAccess.noop
        access.semanticSearch = { _, _, _ in [Self.hit("vector hit"), Self.hit("second")] }
        let runtime = makeRuntimeCapturingLog(access: access, into: lines)

        _ = await runtime.executeRecall(query: "wrapper verification", rawArguments: "{}")
        _ = await runtime.executeRecall(query: "wrapper verification", rawArguments: "{}")

        let audits = lines.compactMap { $0 as? String }.filter { $0.hasPrefix("[recall] vector lane") }
        XCTAssertEqual(audits, ["[recall] vector lane served 2 hits"],
                       "exactly one served-audit per session, got \(audits)")
    }

    /// The silent fallback that hid the field defect: the FIRST fallback must audit
    /// its reason (from the diagnostic closure), and only once per session.
    @MainActor
    func testFirstVectorFallbackAuditsReasonOnce() async {
        let lines = NSMutableArray()
        var access = AgentMemoryAccess.noop
        access.semanticSearch = { _, _, _ in nil }
        access.vectorLaneDiagnostic = { "rebuild in progress" }
        access.searchMemories = { _, _ in [Self.hit("keyword hit")] }
        let runtime = makeRuntimeCapturingLog(access: access, into: lines)

        _ = await runtime.executeRecall(query: "anything", rawArguments: "{}")
        _ = await runtime.executeRecall(query: "anything", rawArguments: "{}")

        let audits = lines.compactMap { $0 as? String }.filter { $0.hasPrefix("[recall] vector lane") }
        XCTAssertEqual(audits, ["[recall] vector lane unavailable — rebuild in progress"])
    }

    /// No indexer wired at all (visionOS / iOS 17) reads as the platform gate.
    @MainActor
    func testPlatformGateFallbackAuditsPlatformGate() async {
        let lines = NSMutableArray()
        var access = AgentMemoryAccess.noop
        access.semanticSearch = nil
        access.searchMemories = { _, _ in [Self.hit("keyword hit")] }
        let runtime = makeRuntimeCapturingLog(access: access, into: lines)

        _ = await runtime.executeRecall(query: "anything", rawArguments: "{}")

        let audits = lines.compactMap { $0 as? String }.filter { $0.hasPrefix("[recall] vector lane") }
        XCTAssertEqual(audits, ["[recall] vector lane unavailable — platform gate"])
    }

    /// A vector lane that ran and simply found nothing is AVAILABLE — no unavailable
    /// audit — and an empty query never touches the lane, so no audit either.
    @MainActor
    func testNoMatchAndEmptyQueryProduceNoLaneAudit() async {
        let lines = NSMutableArray()
        var access = AgentMemoryAccess.noop
        access.semanticSearch = { _, _, _ in [] }
        access.searchMemories = { _, _ in [Self.hit("keyword hit")] }
        let runtime = makeRuntimeCapturingLog(access: access, into: lines)

        _ = await runtime.executeRecall(query: "anything", rawArguments: "{}")
        _ = await runtime.executeRecall(query: "", rawArguments: "{}")

        let audits = lines.compactMap { $0 as? String }.filter { $0.hasPrefix("[recall] vector lane") }
        XCTAssertEqual(audits, [], "ran-but-no-match is not 'unavailable'; got \(audits)")
    }

    @MainActor
    func testEmptyQueryKeepsMostRecentBehaviorAndNeverRunsVector() async {
        var semanticSearched = false
        var access = AgentMemoryAccess.noop
        access.semanticSearch = { _, _, _ in
            semanticSearched = true
            return [Self.hit("vector hit")]
        }
        access.searchMemories = { query, _ in
            XCTAssertEqual(query, "")
            return [Self.hit("most recent")]
        }

        let result = await makeRuntime(access: access)
            .executeRecall(query: "", rawArguments: "{}")
        XCTAssertTrue(result.contains("most recent"))
        XCTAssertFalse(semanticSearched, "empty query must keep the keyword lane's recency behavior")
    }
}

// MARK: - Wax-backed index (iOS 18 / macOS 15+, not built on visionOS)

#if canImport(Wax)
import Wax

@available(iOS 18.0, macOS 15.0, *)
final class VectorMemoryIndexTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("Wax's built-in embedder needs iOS 18 / macOS 15")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorMemoryIndexTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// `.builtIn(.miniLM)` on purpose: `.automatic` can serve text-only results while
    /// the embedder compiles, which would let these tests pass without ever proving
    /// the vector lane. A construction failure here should fail, not skip — this
    /// machine is expected to have the embedder. GPU compute because at Wax 0.1.27
    /// the other units are unusable in tests: the default order compiles the model
    /// for the Neural Engine first — 10+ minutes per fresh build (CoreML's compile
    /// cache is keyed to the bundle) — and the bundled fp16 model overflows to
    /// non-finite values on plain CPU (upstream shipped a finite model only in
    /// 0.1.33, which no longer compiles for iOS).
    static let testEmbedding = Wax.Memory.EmbeddingSource.builtIn(
        .miniLM, BuiltInEmbeddingProviderOptions(computeUnitsOrder: [.cpuAndGPU])
    )

    private func makeIndex(agentID: UUID = UUID()) -> VectorMemoryIndex {
        VectorMemoryIndex(agentID: agentID, directory: directory, embedding: Self.testEmbedding)
    }

    /// The field failure this branch exists to fix: keyword recall ranked the agent's
    /// "mission" memory above the memory literally titled "wrapper verification" for
    /// the query "wrapper verification". The vector index must rank B first.
    func testFieldFailureRegressionWrapperVerificationRanksFirst() async throws {
        let index = makeIndex()
        let missionID = UUID()
        let wrapperID = UUID()
        await index.upsert(memoryID: missionID, text: MemoryStore.indexableText(
            title: "mission",
            content: "Ask claude in the terminal session how you can help it accomplish its mission and follow its directions using logging via icloud as a back channel",
            tags: ""
        ))
        await index.upsert(memoryID: wrapperID, text: MemoryStore.indexableText(
            title: "wrapper verification",
            content: "Step 1 of the wrapper verification protocol completed.",
            tags: ""
        ))

        let hits = try await index.search(query: "wrapper verification", limit: 5)
        XCTAssertEqual(hits.first?.memoryID, wrapperID,
                       "the memory titled 'wrapper verification' must outrank the mission memory")
    }

    func testMemoryIDRoundTripsThroughWaxMetadata() async throws {
        let index = makeIndex()
        let memoryID = UUID()
        let text = MemoryStore.indexableText(
            title: "deploy pipeline", content: "set up CI on the mac mini", tags: "work"
        )
        await index.upsert(memoryID: memoryID, text: text)

        let hits = try await index.search(query: "continuous integration setup", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.memoryID, memoryID)
        // The ID travels as Wax metadata, never inside the text — nothing to strip.
        XCTAssertEqual(hits.first?.snippet, text)
        XCTAssertFalse(hits.first?.snippet.contains(memoryID.uuidString) ?? true)
    }

    func testRemoveTombstonesUntilRebuildCompacts() async throws {
        let index = makeIndex()
        let keepID = UUID()
        let dropID = UUID()
        await index.upsert(memoryID: keepID, text: "groceries\nbuy oat milk and coffee beans")
        await index.upsert(memoryID: dropID, text: "server move\nmigrate the blog to the new VPS")

        await index.remove(memoryID: dropID)
        let hits = try await index.search(query: "migrate the blog to the new VPS", limit: 5)
        XCTAssertFalse(hits.contains { $0.memoryID == dropID },
                       "a removed memory must stop matching immediately (tombstone)")

        // Rebuild physically drops the tombstoned frames.
        await index.rebuild(from: [IndexableMemory(id: keepID, text: "groceries\nbuy oat milk and coffee beans")])
        let afterRebuild = try await index.search(query: "migrate the blog to the new VPS", limit: 5)
        XCTAssertFalse(afterRebuild.contains { $0.memoryID == dropID })
        let count = await index.indexedCount
        XCTAssertEqual(count, 1)
    }

    /// A record deleted outside the index (CloudKit sync, another device) is healed
    /// on the first search of the next session: the sidecar diverges from SwiftData
    /// truth and the index rebuilds without it.
    func testSelfHealRebuildDropsRecordsDeletedElsewhere() async throws {
        let agentID = UUID()
        let keptID = UUID()
        let deletedID = UUID()
        let keptText = "status\nthe nightly backup finished cleanly"
        let first = makeIndex(agentID: agentID)
        await first.upsert(memoryID: keptID, text: keptText)
        await first.upsert(memoryID: deletedID, text: "secrets\nrotate the signing certificate")
        // Wax's store lock is an untimed flock — release it before the "next session"
        // opens the same file, exactly as a real relaunch would.
        await first.close()

        // Fresh actor = fresh session; SwiftData truth no longer contains deletedID.
        let second = makeIndex(agentID: agentID)
        await second.ensureConsistent(with: [IndexableMemory(id: keptID, text: keptText)])

        let hits = try await second.search(query: "rotate the signing certificate", limit: 5)
        XCTAssertFalse(hits.contains { $0.memoryID == deletedID })
        let count = await second.indexedCount
        XCTAssertEqual(count, 1)
    }

    /// Removing a memory the index never saw must not fabricate a tombstone or a
    /// stale-frame — either would force a pointless full rebuild next session.
    func testRemoveOfNeverIndexedMemoryIsNoOp() async throws {
        let index = makeIndex()
        let realID = UUID()
        await index.upsert(memoryID: realID, text: "groceries\nbuy oat milk and coffee beans")

        await index.remove(memoryID: UUID()) // never indexed

        let tombstones = await index.tombstoneCount
        let stale = await index.staleFrameCount
        let indexed = await index.indexedCount
        XCTAssertEqual(tombstones, 0)
        XCTAssertEqual(stale, 0)
        XCTAssertEqual(indexed, 1)
    }

    /// BLOAT RECOVERY: the field device's end state was a 256MB append-only .wax for
    /// a few dozen memories. Past the sanity bound, the consistency check must
    /// destroy and rebuild the store outright — Wax has no per-document delete, so
    /// recreation IS compaction — and audit the recovery so it is remotely visible.
    func testBloatedStoreIsDestroyedAndRebuiltFresh() async throws {
        let agentID = UUID()
        let keptID = UUID()
        let keptText = "groceries\nbuy oat milk and coffee beans"
        let first = makeIndex(agentID: agentID)
        await first.upsert(memoryID: keptID, text: keptText)
        await first.close()

        // Damage: inflate the store past the sanity bound, as months of duplicate
        // appends did in the field.
        let waxURL = directory.appendingPathComponent("\(agentID.uuidString).wax")
        let handle = try FileHandle(forWritingTo: waxURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: VectorMemoryIndex.bloatBound(memoryCount: 1) + 1))
        try handle.close()

        let audited = NSMutableArray()
        await MainActor.run { AgentMemoryIndexRegistry.audit = { _, line in audited.add(line) } }

        let second = makeIndex(agentID: agentID)
        await second.verifyConsistency(with: [IndexableMemory(id: keptID, text: keptText)])

        let rebuilds = await second.rebuildCount
        XCTAssertEqual(rebuilds, 1, "a bloated store must be rebuilt fresh exactly once")
        // Frames region, not raw size: an OPEN store legitimately carries its whole
        // WAL ring in the file; only bytes beyond it are frame bloat.
        let frameBytes = try XCTUnwrap(VectorMemoryIndex.frameRegionBytes(at: waxURL))
        XCTAssertLessThan(frameBytes, 1024 * 1024,
                          "recreation is compaction: the fresh frames region must be small, got \(frameBytes) bytes")
        let hits = try await second.search(query: "buy oat milk and coffee beans", limit: 5)
        XCTAssertEqual(hits.first?.memoryID, keptID, "the rebuilt store must still serve its memories")
        // The recreated file also sheds Wax's 256MiB default WAL (the bulk of the
        // field device's 256.2MB): our right-sized WAL bounds the whole file.
        let rawSize = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: waxURL.path)[.size] as? Int
        )
        XCTAssertLessThan(rawSize, 20 * 1024 * 1024,
                          "a rebuilt store must not weigh 256MB+ on disk again, got \(rawSize) bytes")

        // The audit hook fires through a MainActor hop; give it a beat.
        for _ in 0..<40 where audited.count == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let lines = audited.compactMap { $0 as? String }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasPrefix("[memory-index] store bloated (") == true,
                      "unexpected audit line: \(lines)")
        XCTAssertTrue(lines.first?.hasSuffix("— rebuilt fresh (1 memories)") == true,
                      "unexpected audit line: \(lines)")

        await MainActor.run { AgentMemoryIndexRegistry.audit = { _, _ in } }
        await second.close()
    }

    /// The erasure SLA's rebuild half, verified at the byte level: after remove +
    /// rebuild, the removed memory's plaintext is physically gone from the .wax file,
    /// not merely hidden from search.
    func testLocalRemovalErasesContentFromDiskAtRebuild() async throws {
        let agentID = UUID()
        let index = makeIndex(agentID: agentID)
        let keptID = UUID()
        let doomedID = UUID()
        let keptText = "groceries\nbuy oat milk and coffee beans"
        let doomedMarker = "tell-no-one-9981"
        await index.upsert(memoryID: keptID, text: keptText)
        await index.upsert(memoryID: doomedID, text: "credentials\nthe staging vault passphrase is \(doomedMarker)")

        await index.remove(memoryID: doomedID)
        let hits = try await index.search(query: "staging vault passphrase", limit: 5)
        XCTAssertFalse(hits.contains { $0.memoryID == doomedID },
                       "a removed memory must stop matching immediately (tombstone)")

        await index.rebuild(from: [IndexableMemory(id: keptID, text: keptText)])
        await index.close()

        let bytes = try Data(contentsOf: directory.appendingPathComponent("\(agentID.uuidString).wax"))
        // Prove the byte probe works before trusting its absence result: the kept
        // text must be findable as plaintext (if a future Wax version compresses
        // frames, this assertion flags the probe as vacuous instead of green-washing).
        XCTAssertNotNil(bytes.range(of: Data(keptText.utf8)),
                        "kept content should be visible in the store file — byte probe is broken otherwise")
        XCTAssertNil(bytes.range(of: Data(doomedMarker.utf8)),
                     "rebuild must physically erase removed content from the .wax file")
    }
}

/// Manager-level behavior: per-agent ordered note execution, index destruction, the
/// orphan sweep, and the nil-agent skip.
@available(iOS 18.0, macOS 15.0, *)
final class VectorMemoryIndexManagerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("Wax's built-in embedder needs iOS 18 / macOS 15")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorMemoryIndexManagerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeManager() -> VectorMemoryIndexManager {
        VectorMemoryIndexManager(directory: directory, embedding: VectorMemoryIndexTests.testEmbedding)
    }

    /// Spawn order must be execution order: an upsert immediately followed by a
    /// removal of the same memory lands removed. With independent Tasks this was a
    /// race (the upsert could overtake the removal and resurrect the memory).
    func testUpsertThenRemoveInSpawnOrderLandsRemoved() async throws {
        let manager = makeManager()
        let agentID = UUID()
        let memoryID = UUID()

        manager.noteUpsert(agentID: agentID, memoryID: memoryID, text: "ephemeral\ndelete me right away")
        manager.noteRemoval(agentID: agentID, memoryID: memoryID) // same spawn instant, no await between
        await manager.waitForPendingWrites()

        let index = await manager.indexForTesting(agentID: agentID)
        let indexed = await index.isIndexed(memoryID: memoryID)
        XCTAssertFalse(indexed, "the later-spawned removal must win over the earlier upsert")
        let hits = try await index.search(query: "delete me right away", limit: 5)
        XCTAssertFalse(hits.contains { $0.memoryID == memoryID })
        await manager.closeAll()
    }

    /// Two upserts of the same memory in spawn order: the sidecar must end on the
    /// newest content's digest, or the next consistency check reads a phantom
    /// divergence and rebuilds for nothing.
    func testInterleavedUpsertsKeepNewestDigest() async throws {
        let manager = makeManager()
        let agentID = UUID()
        let memoryID = UUID()
        let v1 = "status\nthe deploy is still running"
        let v2 = "status\nthe deploy finished and the health checks are green"

        manager.noteUpsert(agentID: agentID, memoryID: memoryID, text: v1)
        manager.noteUpsert(agentID: agentID, memoryID: memoryID, text: v2)
        await manager.waitForPendingWrites()

        let index = await manager.indexForTesting(agentID: agentID)
        let newestWins = await index.hasIndexed(memoryID: memoryID, text: v2)
        XCTAssertTrue(newestWins, "the sidecar must record the last-spawned upsert's digest")
        await manager.closeAll()
    }

    /// Agent deletion: destroyIndex closes the store (Wax's untimed flock — never
    /// delete an open store) and removes both the .wax file and the sidecar, and the
    /// path is immediately reusable by a fresh manager.
    func testDestroyIndexRemovesFilesAfterClosingStore() async throws {
        let manager = makeManager()
        let agentID = UUID()
        manager.noteUpsert(agentID: agentID, memoryID: UUID(), text: "server move\nmigrate the blog to the new VPS")
        await manager.waitForPendingWrites()

        let waxURL = directory.appendingPathComponent("\(agentID.uuidString).wax")
        let stateURL = directory.appendingPathComponent("\(agentID.uuidString).state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: waxURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        await manager.destroyIndex(agentID: agentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: waxURL.path), "agent deletion must remove the .wax store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path), "agent deletion must remove the sidecar")

        // The flock was released before removal: a fresh manager can open the same
        // path right away (a leaked lock would hang this open forever) and starts empty.
        let next = makeManager()
        let freshID = UUID()
        let freshText = "fresh start\nnothing left from before"
        next.noteUpsert(agentID: agentID, memoryID: freshID, text: freshText)
        await next.waitForPendingWrites()
        let result = await next.search(agentID: agentID, query: "migrate the blog to the new VPS", limit: 5,
                                       expected: [IndexableMemory(id: freshID, text: freshText)])
        guard case .hits(let hits) = result else {
            return XCTFail("vector lane should be available after reuse, got \(result)")
        }
        XCTAssertFalse(hits.contains { $0.snippet.contains("migrate the blog") })
        await next.closeAll()
        await manager.closeAll()
    }

    /// Memories without an agent are skipped outright — no sentinel store, no
    /// write-only plaintext file that nothing can ever search or heal.
    func testNilAgentMemoriesAreNeverIndexed() async throws {
        let manager = makeManager()
        manager.noteUpsert(agentID: nil, memoryID: UUID(), text: "orphan\nno agent owns this")
        manager.noteRemoval(agentID: nil, memoryID: UUID())
        await manager.waitForPendingWrites()

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "nil-agent notes must create no index files, got \(contents)")
        await manager.closeAll()
    }

    /// The launch sweep: index files whose agent is gone (deleted on another device)
    /// are removed; a surviving agent's files are untouched.
    func testPruneOrphanedIndexesRemovesUnknownAgentsFiles() async throws {
        let manager = makeManager()
        let keptAgent = UUID()
        let goneAgent = UUID()
        manager.noteUpsert(agentID: keptAgent, memoryID: UUID(), text: "groceries\nbuy oat milk")
        manager.noteUpsert(agentID: goneAgent, memoryID: UUID(), text: "secrets\nrotate the signing certificate")
        await manager.waitForPendingWrites()

        await manager.pruneOrphanedIndexes(keeping: [keptAgent])

        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        XCTAssertTrue(names.contains("\(keptAgent.uuidString).wax"))
        XCTAssertFalse(names.contains("\(goneAgent.uuidString).wax"),
                       "a deleted agent's store must not survive the sweep")
        XCTAssertFalse(names.contains("\(goneAgent.uuidString).state.json"))
        await manager.closeAll()
    }
}

/// End-to-end through `MemoryStore`: a saved memory becomes semantically searchable,
/// and one deleted from SwiftData is rebuilt away on the next session's first search.
@available(iOS 18.0, macOS 15.0, *)
final class MemoryStoreVectorIntegrationTests: XCTestCase {

    private var container: ModelContainer?
    private var directory: URL!

    override func setUpWithError() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("Wax's built-in embedder needs iOS 18 / macOS 15")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryStoreVectorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private func makeStore() throws -> (MemoryStore, VectorMemoryIndexManager, ModelContext) {
        // cloudKitDatabase must be .none: tests run inside the app host, whose real
        // CloudKit-mirrored store a second .automatic container tears down (crash).
        let container = try self.container ?? ModelContainer(
            for: AgentMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        let manager = VectorMemoryIndexManager(
            directory: directory,
            embedding: VectorMemoryIndexTests.testEmbedding
        )
        return (
            MemoryStore(context: container.mainContext, indexer: manager),
            manager,
            container.mainContext
        )
    }

    @MainActor
    func testSavedMemoryBecomesSearchableAndDeletedOneIsRebuiltAway() async throws {
        let (store, manager, context) = try makeStore()
        let agentID = UUID()
        let keptConversation = UUID()
        let doomedConversation = UUID()

        store.saveEpisodic(conversationID: keptConversation, agentID: agentID,
                           title: "wrapper verification",
                           content: "Step 1 of the wrapper verification protocol completed.",
                           tags: "auto")
        store.saveEpisodic(conversationID: doomedConversation, agentID: agentID,
                           title: "mission",
                           content: "Ask claude in the terminal session how you can help it accomplish its mission and follow its directions using logging via icloud as a back channel",
                           tags: "auto")
        await manager.waitForPendingWrites()

        // Saved → searchable, and the field-failure query ranks the right record first.
        let recalled = await store.semanticRecall(agentID: agentID, query: "wrapper verification", limit: 5)
        let hits = try XCTUnwrap(recalled)
        XCTAssertEqual(hits.first?.title, "wrapper verification")

        // Delete one record from SwiftData (as sync would) …
        let doomed = try context.fetch(FetchDescriptor<AgentMemory>())
            .filter { $0.conversationID == doomedConversation }
        doomed.forEach(context.delete)
        try context.save()

        // … and a fresh session (fresh manager over the same on-disk index) self-heals
        // on its first search: the deleted record is rebuilt away. The old manager
        // must release its untimed flock first, as a real app exit would.
        await manager.closeAll()
        let (nextSessionStore, _, _) = try makeStore()
        let healedRecall = await nextSessionStore.semanticRecall(
            agentID: agentID, query: "accomplish its mission icloud back channel", limit: 5
        )
        let healed = try XCTUnwrap(healedRecall)
        XCTAssertFalse(healed.contains { $0.title == "mission" },
                       "a record deleted from SwiftData must not survive the self-heal rebuild")
    }

    /// The launch-time consistency pass (FinApp's post-launch task) heals a record
    /// deleted out-of-band — CloudKit sync from another device — WITHOUT waiting for
    /// the agent's first recall: the pass alone rebuilds the index.
    @MainActor
    func testLaunchConsistencyPassRebuildsAfterOutOfBandDelete() async throws {
        let (store, manager, context) = try makeStore()
        let agentID = UUID()
        let keptConversation = UUID()
        let doomedConversation = UUID()

        store.saveEpisodic(conversationID: keptConversation, agentID: agentID,
                           title: "status", content: "the nightly backup finished cleanly", tags: "auto")
        store.saveEpisodic(conversationID: doomedConversation, agentID: agentID,
                           title: "secrets", content: "rotate the signing certificate", tags: "auto")
        await manager.waitForPendingWrites()

        // Out-of-band delete, exactly as a CloudKit import would apply it.
        let doomed = try context.fetch(FetchDescriptor<AgentMemory>())
            .filter { $0.conversationID == doomedConversation }
        doomed.forEach(context.delete)
        try context.save()

        // "Next launch": a fresh manager over the same files runs the launch pass.
        await manager.closeAll()
        let (nextStore, nextManager, _) = try makeStore()
        await nextManager.ensureConsistent(
            agentID: agentID,
            expected: nextStore.indexableEpisodicRecords(agentID: agentID)
        )

        // The pass itself rebuilt — no recall has happened yet.
        let index = await nextManager.indexForTesting(agentID: agentID)
        let count = await index.indexedCount
        XCTAssertEqual(count, 1, "the launch pass must rebuild the diverged index on its own")
        let hits = try await index.search(query: "rotate the signing certificate", limit: 5)
        XCTAssertFalse(hits.contains { $0.snippet.contains("signing certificate") },
                       "deleted content must be gone after the launch pass, before any recall")
        await nextManager.closeAll()
    }

    /// LIVE FIELD DEFECT reproduction (iPad, 2026-08): a fresh install whose SwiftData
    /// already holds an agent's memories (CloudKit sync) but whose vector index is
    /// empty. The real launch flow runs the consistency pass as a background Task that
    /// recalls do NOT wait for (FinApp's `Task { … ensureConsistent … }`), so the
    /// session's first recall races the in-flight full rebuild. The field store showed
    /// the end state of getting this wrong: a 256MB append-only .wax next to a 277-byte
    /// sidecar, and every recall silently falling back to keyword ranking.
    ///
    /// Invariants under test, in failure-message order:
    /// 1. Exactly ONE full rebuild in total — not one per check, not one per session.
    /// 2. After session 1 the sidecar ledger contains ALL N digests.
    /// 3. The .wax file does not grow across a second session that changed nothing.
    /// 4. The field-failure ranking regression holds at every recall of the lifecycle.
    @MainActor
    func testFreshInstallLifecycleRebuildsOnceAndKeepsStoreStable() async throws {
        let (seedStore, _, context) = try makeStore()
        _ = seedStore // records are seeded directly; the store just owns the container shape
        let agentID = UUID()

        // N memories that arrived via sync — the index never saw a noteUpsert for them.
        var texts: [UUID: String] = [:]
        let wrapperID = UUID()
        let seeds: [(UUID, String, String)] = [
            (wrapperID, "wrapper verification", "Step 1 of the wrapper verification protocol completed."),
            (UUID(), "mission", "Ask claude in the terminal session how you can help it accomplish its mission and follow its directions using logging via icloud as a back channel"),
            (UUID(), "groceries", "buy oat milk and coffee beans before the weekend"),
            (UUID(), "server move", "migrate the blog to the new VPS and update DNS"),
            (UUID(), "deploy pipeline", "set up CI on the mac mini with signing keys"),
            (UUID(), "status", "the nightly backup finished cleanly at 3am"),
            (UUID(), "reading list", "finish the chapter on distributed consensus"),
            (UUID(), "travel", "book the train to Portland for the conference"),
            (UUID(), "health", "morning runs three times a week, knee is holding up"),
            (UUID(), "budget", "the hosting bill doubled after the traffic spike"),
            (UUID(), "family", "call grandma on Sunday about the photo album"),
            (UUID(), "ideas", "prototype a pocket dj app that mixes ambient loops"),
        ]
        for (id, title, content) in seeds {
            let record = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(),
                                     title: title, content: content, tags: "auto")
            record.id = id
            context.insert(record)
            texts[id] = MemoryStore.indexableText(title: title, content: content, tags: "auto")
        }
        try context.save()
        let memoryCount = seeds.count

        // ---- SESSION 1 ----
        let (store1, manager1, _) = try makeStore()
        let expected1 = store1.indexableEpisodicRecords(agentID: agentID)
        XCTAssertEqual(expected1.count, memoryCount)

        // The launch pass exactly as FinApp spawns it: a Task nobody awaits before
        // the first recall arrives.
        let launchPass = Task { await manager1.ensureConsistent(agentID: agentID, expected: expected1) }
        let firstRecall = await store1.semanticRecall(agentID: agentID, query: "wrapper verification", limit: 5)
        await launchPass.value

        // Same process: another consistency check (foreground tick shape) + recall.
        await manager1.ensureConsistent(agentID: agentID, expected: store1.indexableEpisodicRecords(agentID: agentID))
        let secondRecall = await store1.semanticRecall(agentID: agentID, query: "wrapper verification", limit: 5)

        let session1Rebuilds = await manager1.indexForTesting(agentID: agentID).rebuildCount
        await manager1.closeAll()

        let waxURL = directory.appendingPathComponent("\(agentID.uuidString).wax")
        let stateURL = directory.appendingPathComponent("\(agentID.uuidString).state.json")
        let sizeAfterSession1 = (try FileManager.default.attributesOfItem(atPath: waxURL.path)[.size] as? Int) ?? 0

        // 2. The sidecar ledger must hold ALL N digests after the rebuild.
        struct SidecarState: Decodable { var indexed: [String: String] }
        let sidecar = try JSONDecoder().decode(SidecarState.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(sidecar.indexed.count, memoryCount,
                       "sidecar ledger incomplete after session 1: \(sidecar.indexed.count)/\(memoryCount) digests — a consistency check next session will re-rebuild forever")

        // ---- SESSION 2: fresh manager over the same files, nothing changed ----
        let (store2, manager2, _) = try makeStore()
        let launchPass2 = Task { await manager2.ensureConsistent(agentID: agentID, expected: store2.indexableEpisodicRecords(agentID: agentID)) }
        let thirdRecall = await store2.semanticRecall(agentID: agentID, query: "wrapper verification", limit: 5)
        await launchPass2.value
        let session2Rebuilds = await manager2.indexForTesting(agentID: agentID).rebuildCount
        await manager2.closeAll()
        let sizeAfterSession2 = (try FileManager.default.attributesOfItem(atPath: waxURL.path)[.size] as? Int) ?? 0

        // 1. Exactly one full rebuild across the entire lifecycle.
        XCTAssertEqual(session1Rebuilds + session2Rebuilds, 1,
                       "expected exactly ONE full rebuild total; session 1 ran \(session1Rebuilds), session 2 ran \(session2Rebuilds) — duplicate rebuilds are the append-only bloat engine")

        // 3. No growth across an unchanged second session (small tolerance for
        //    store-header/commit bookkeeping, never for re-appended frames)…
        XCTAssertLessThanOrEqual(sizeAfterSession2, sizeAfterSession1 + 16_384,
                                 ".wax grew across an unchanged session: \(sizeAfterSession1) -> \(sizeAfterSession2) bytes")
        //    …and the resting file is right-sized: the field device's store weighed
        //    256.2MB because every store carried Wax's 256MiB default WAL ring.
        XCTAssertLessThan(sizeAfterSession1, 20 * 1024 * 1024,
                          "a fresh store must not carry a 256MiB WAL, got \(sizeAfterSession1) bytes")

        // 4. The ranking regression holds at every recall in the lifecycle.
        XCTAssertEqual(try XCTUnwrap(firstRecall).first?.title, "wrapper verification",
                       "first recall (racing the launch pass) lost the field-failure ranking")
        XCTAssertEqual(try XCTUnwrap(secondRecall).first?.title, "wrapper verification",
                       "second recall (settled index) lost the field-failure ranking")
        XCTAssertEqual(try XCTUnwrap(thirdRecall).first?.title, "wrapper verification",
                       "session-2 recall lost the field-failure ranking")
    }

    @MainActor
    func testSemanticRecallIsNilWithoutAnIndexer() async throws {
        let container = try ModelContainer(
            for: AgentMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        let store = MemoryStore(context: container.mainContext) // gate off
        let result = await store.semanticRecall(agentID: UUID(), query: "anything", limit: 5)
        XCTAssertNil(result, "no indexer must read as 'vector path unavailable', not 'no matches'")
    }
}
#endif // canImport(Wax)

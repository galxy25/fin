import XCTest
import SwiftData
@testable import fin

/// Exercises `MemoryStore` — the concrete implementation behind the memory closures
/// `FinApp` injects into the runtime — against an in-memory container.
final class AgentMemoryTests: XCTestCase {

    /// Held on the test case: a context whose container has been deallocated traps on
    /// the first insert, and a returned-but-unused local can be released early.
    private var container: ModelContainer?

    @MainActor
    private func makeStore() throws -> (MemoryStore, ModelContext) {
        // cloudKitDatabase must be .none: tests run inside the app host, whose real
        // CloudKit-mirrored store a second .automatic container tears down (crash).
        let container = try ModelContainer(
            for: AgentMemory.self,
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
        self.container = container
        return (MemoryStore(context: container.mainContext), container.mainContext)
    }

    @MainActor
    func testSaveEpisodicCreatesThenUpdatesByConversationID() throws {
        let (store, context) = try makeStore()
        let conversationID = UUID()
        let agentID = UUID()

        store.saveEpisodic(conversationID: conversationID, agentID: agentID,
                           title: "First question", content: "Q: hi / A: hello", tags: "auto")
        let created = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
        let originalStartedAt = created.startedAt

        store.saveEpisodic(conversationID: conversationID, agentID: agentID,
                           title: "First question", content: "Q: hi / A: hello\nQ: more / A: sure",
                           tags: "auto,conversation")

        let all = try context.fetch(FetchDescriptor<AgentMemory>())
        XCTAssertEqual(all.count, 1)
        let updated = try XCTUnwrap(all.first)
        XCTAssertEqual(updated.content, "Q: hi / A: hello\nQ: more / A: sure")
        XCTAssertEqual(updated.tags, "auto,conversation")
        XCTAssertEqual(updated.startedAt, originalStartedAt)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, originalStartedAt)
    }

    @MainActor
    func testMarkConversationStoppedSetsStoppedAt() throws {
        let (store, context) = try makeStore()
        let conversationID = UUID()

        store.saveEpisodic(conversationID: conversationID, agentID: UUID(),
                           title: "t", content: "c", tags: "")
        store.markConversationStopped(conversationID: conversationID)

        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
        XCTAssertNotNil(record.stoppedAt)
    }

    @MainActor
    func testSearchMatchesSubstringsCaseInsensitivelyAcrossFields() throws {
        let (store, _) = try makeStore()
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "Deploy pipeline", content: "set up CI", tags: "work")
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "Groceries", content: "the DEPLOY word appears here", tags: "home")
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "Music", content: "playlist ideas", tags: "deployment,fun")
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "Unrelated", content: "nothing here", tags: "misc")

        let hits = store.searchMemories(query: "deploy", limit: 10)
        XCTAssertEqual(hits.count, 3)
        XCTAssertFalse(hits.contains { $0.title == "Unrelated" })
    }

    @MainActor
    func testSearchOrdersByRecencyAndHonorsLimit() throws {
        let (store, context) = try makeStore()
        let old = AgentMemory(kind: .episodic, conversationID: UUID(), title: "old", content: "x")
        old.updatedAt = Date(timeIntervalSinceNow: -300)
        let middle = AgentMemory(kind: .episodic, conversationID: UUID(), title: "middle", content: "x")
        middle.updatedAt = Date(timeIntervalSinceNow: -150)
        let newest = AgentMemory(kind: .episodic, conversationID: UUID(), title: "newest", content: "x")
        context.insert(old)
        context.insert(middle)
        context.insert(newest)
        try context.save()

        // Empty query = most recent first.
        let hits = store.searchMemories(query: "", limit: 2)
        XCTAssertEqual(hits.map(\.title), ["newest", "middle"])
    }

    @MainActor
    func testSearchExcludesTheCumulativeProfile() throws {
        let (store, _) = try makeStore()
        store.writeCumulative(content: "likes terse answers")
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "terse", content: "terse chat", tags: "")

        let hits = store.searchMemories(query: "terse", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.title, "terse")
    }

    // MARK: - Redaction

    func testRedactorDropsPEMBlocksAndMasksKeyMaterial() {
        let text = """
        before
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2g
        -----END OPENSSH PRIVATE KEY-----
        after
        """
        let redacted = MemoryRedactor.redact(text)
        XCTAssertFalse(redacted.contains("PRIVATE KEY"))
        XCTAssertFalse(redacted.contains("b3BlbnNzaC1rZXktdjEA"))
        XCTAssertTrue(redacted.contains("before"))
        XCTAssertTrue(redacted.contains("after"))
    }

    func testRedactorMasksTokenShapes() {
        // AWS access key ID.
        XCTAssertFalse(
            MemoryRedactor.redact("the key is AKIAIOSFODNN7EXAMPLE ok")
                .contains("AKIAIOSFODNN7EXAMPLE")
        )
        // 32+ char hex run.
        XCTAssertFalse(
            MemoryRedactor.redact("sha: deadbeefdeadbeefdeadbeefdeadbeef123")
                .contains("deadbeef")
        )
        // 40+ char base64 run.
        let blob = String(repeating: "Qx", count: 25)
        XCTAssertFalse(MemoryRedactor.redact("data \(blob) end").contains(blob))
    }

    func testRedactorMasksCredentialAssignmentsKeepingTheKey() {
        let exported = MemoryRedactor.redact("export MY_API_KEY=sk-abc123")
        XCTAssertFalse(exported.contains("sk-abc123"))
        XCTAssertTrue(exported.contains("MY_API_KEY"))

        let yaml = MemoryRedactor.redact("password: hunter2")
        XCTAssertFalse(yaml.contains("hunter2"))
        XCTAssertTrue(yaml.contains("password"))

        XCTAssertFalse(
            MemoryRedactor.redact("GITHUB_TOKEN=\"ghp_short\"").contains("ghp_short")
        )
    }

    /// Tool arguments reach the redactor as raw JSON, where the key's closing quote
    /// sits between key and colon — that quote must not defeat the credential mask.
    func testRedactorMasksJSONQuotedCredentialKeys() {
        let password = MemoryRedactor.redact(#"{"password": "hunter2"}"#)
        XCTAssertFalse(password.contains("hunter2"))
        XCTAssertTrue(password.contains("password"))

        let apiKey = MemoryRedactor.redact(#"{"apiKey": "sk-abc123"}"#)
        XCTAssertFalse(apiKey.contains("sk-abc123"))
        XCTAssertTrue(apiKey.contains("apiKey"))

        // Compact form, no space after the colon.
        XCTAssertFalse(
            MemoryRedactor.redact(#"{"api_token":"tok_9y8x"}"#).contains("tok_9y8x")
        )
    }

    func testRedactorLeavesOrdinaryProseAlone() {
        let text = "Q: how do I deploy / A: run ./scripts/deploy.sh and check the logs"
        XCTAssertEqual(MemoryRedactor.redact(text), text)
    }

    @MainActor
    func testStoreRedactsEveryWritePath() throws {
        let (store, context) = try makeStore()
        store.saveEpisodic(conversationID: UUID(), agentID: nil,
                           title: "setup", content: "ran export API_KEY=sk-lm-9999", tags: "")
        let episodic = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
        XCTAssertFalse(episodic.content.contains("sk-lm-9999"))

        store.writeCumulative(content: "uses AKIAIOSFODNN7EXAMPLE for deploys")
        XCTAssertFalse(store.readCumulative().contains("AKIAIOSFODNN7EXAMPLE"))
    }

    // MARK: - Cumulative duplicates

    @MainActor
    func testDuplicateCumulativeRecordsMergeIntoOldestAndExtrasAreDeleted() throws {
        let (store, context) = try makeStore()
        let older = AgentMemory(kind: .cumulative, title: "User profile",
                                content: "old profile", tags: "profile")
        older.createdAt = Date(timeIntervalSinceNow: -100)
        let newer = AgentMemory(kind: .cumulative, title: "User profile",
                                content: "newer detail", tags: "profile")
        context.insert(older)
        context.insert(newer)
        try context.save()

        // Any read converges: distinct content merged newest-last into the oldest record.
        let merged = store.readCumulative()
        XCTAssertEqual(merged, "old profile\nnewer detail")

        let kind = MemoryKind.cumulative.rawValue
        let all = try context.fetch(
            FetchDescriptor<AgentMemory>(predicate: #Predicate { $0.kindRaw == kind })
        )
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, older.id)
    }

    // MARK: - Consolidation markers

    @MainActor
    func testConsolidationCandidatesAreUnconsolidatedNewestFirst() throws {
        let (store, context) = try makeStore()
        let done = AgentMemory(kind: .episodic, conversationID: UUID(), title: "done", content: "x")
        done.consolidatedAt = Date()
        let old = AgentMemory(kind: .episodic, conversationID: UUID(), title: "old", content: "x")
        old.updatedAt = Date(timeIntervalSinceNow: -300)
        let fresh = AgentMemory(kind: .episodic, conversationID: UUID(), title: "fresh", content: "x")
        context.insert(done)
        context.insert(old)
        context.insert(fresh)
        try context.save()

        let candidates = store.consolidationCandidates(limit: 10)
        XCTAssertEqual(candidates.map(\.title), ["fresh", "old"])
        XCTAssertEqual(store.consolidationCandidates(limit: 1).map(\.title), ["fresh"])

        // Stamping removes exactly the stamped records from future selection — an
        // attempt that never stamps (a failure) loses nothing.
        store.markConsolidated(ids: [fresh.id])
        XCTAssertEqual(store.consolidationCandidates(limit: 10).map(\.title), ["old"])

        store.markConsolidated(ids: [old.id])
        XCTAssertTrue(store.consolidationCandidates(limit: 10).isEmpty)
    }

    // MARK: - Open conversation adoption

    @MainActor
    func testLatestOpenConversationSkipsStoppedRecordsAndOtherAgents() throws {
        let (store, context) = try makeStore()
        let agentID = UUID()

        let stopped = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(),
                                  title: "stopped", content: "a")
        stopped.stoppedAt = Date()
        let olderOpen = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(),
                                    title: "older open", content: "b")
        olderOpen.updatedAt = Date(timeIntervalSinceNow: -300)
        let newestOpen = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(),
                                     title: "newest open", content: "Q: hi / A: hello")
        let otherAgent = AgentMemory(kind: .episodic, agentID: UUID(), conversationID: UUID(),
                                     title: "other agent", content: "c")
        for record in [stopped, olderOpen, newestOpen, otherAgent] { context.insert(record) }
        try context.save()

        let open = try XCTUnwrap(store.latestOpenConversation(agentID: agentID))
        XCTAssertEqual(open.id, newestOpen.conversationID)
        XCTAssertEqual(open.title, "newest open")
        XCTAssertEqual(open.digest, "Q: hi / A: hello")

        XCTAssertNil(store.latestOpenConversation(agentID: UUID()))
    }

    @MainActor
    func testCumulativeReadWriteIsASingleton() throws {
        let (store, context) = try makeStore()
        XCTAssertEqual(store.readCumulative(), "")

        store.writeCumulative(content: "goal: ship fin")
        XCTAssertEqual(store.readCumulative(), "goal: ship fin")

        store.writeCumulative(content: "goal: ship fin; prefers fish shell")
        XCTAssertEqual(store.readCumulative(), "goal: ship fin; prefers fish shell")

        let kind = MemoryKind.cumulative.rawValue
        let all = try context.fetch(
            FetchDescriptor<AgentMemory>(predicate: #Predicate { $0.kindRaw == kind })
        )
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.conversationID)
        XCTAssertNil(all.first?.agentID)
    }
}

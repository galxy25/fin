import XCTest
@testable import fin

// Runtime lane selection for the recall tool: semantic lane first when wired and
// the query is non-empty; keyword lane on nil (no indexer wired — currently every
// platform, since the Wax-backed on-device index was removed 2026-09-11; see
// VectorMemoryIndex.swift), error, empty results, or empty query. These use stub
// closures against the AgentMemoryIndexing seam, so they exercise the same lane
// logic a future cloud-backed indexer will run through.

/// The recall tool's contract: semantic lane first when wired and the query is
/// non-empty; keyword lane on nil (gate off), error, empty results, or empty query.
/// These use stub closures, so they run everywhere — including platforms with no
/// indexer wired at all.
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
        access.semanticSearch = nil // the platform gate / no-indexer shape
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

    /// No indexer wired at all reads as the platform gate.
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

import XCTest
@testable import FinAgentCore

final class GoalsLedgerSyncTests: XCTestCase {
    private func goal(_ id: String, state: GoalState = .open, priority: Int = 2, next: String? = nil,
                      updates: [(String, UpdateKind, String)] = [], tags: [String] = []) -> Goal {
        Goal(id: id, title: id, state: state, priority: priority, why: nil, nextAction: next, blockedOn: nil,
             tags: tags, source: nil, createdAt: "2026-09-01T00:00:00Z",
             updates: updates.map { Update(at: $0.0, kind: $0.1, text: $0.2) })
    }

    func testDecodeRemoteToleratesANullDocument() {
        let remote = GoalsLedgerSync.decodeRemote(Data(#"{"version":0,"document":null}"#.utf8))
        XCTAssertEqual(remote?.version, 0)
        XCTAssertNil(remote?.document)
    }

    func testUnionsGoalsAndUpdatesAcrossSides() {
        var local = LedgerDocument(); local.goals = [goal("a", updates: [("2026-09-02T00:00:00Z", .progress, "did x")]), goal("only-local")]
        var remote = LedgerDocument(); remote.goals = [goal("a", updates: [("2026-09-03T00:00:00Z", .progress, "did y")]), goal("only-remote")]
        let merged = GoalsLedgerSync.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(Set(merged.goals.map(\.id)), ["a", "only-local", "only-remote"])
        let a = merged.goals.first { $0.id == "a" }!
        XCTAssertEqual(a.updates.map(\.text), ["did x", "did y"])
    }

    func testScalarsComeFromTheSideWithTheLaterUpdate() {
        var local = LedgerDocument(); local.goals = [goal("a", priority: 1, next: "old next", updates: [("2026-09-02T00:00:00Z", .progress, "x")])]
        var remote = LedgerDocument(); remote.goals = [goal("a", priority: 3, next: "new next", updates: [("2026-09-05T00:00:00Z", .progress, "y")])]
        let merged = GoalsLedgerSync.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(merged.goals[0].priority, 3)
        XCTAssertEqual(merged.goals[0].nextAction, "new next")
    }

    func testDoneIsStickyAndTagsUnion() {
        var local = LedgerDocument(); local.goals = [goal("a", state: .done, updates: [("2026-09-02T00:00:00Z", .close, "closed")], tags: ["x"])]
        var remote = LedgerDocument(); remote.goals = [goal("a", state: .active, updates: [("2026-09-06T00:00:00Z", .progress, "still going")], tags: ["y"])]
        let merged = GoalsLedgerSync.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(merged.goals[0].state, .done, "a close on either side closes the goal — there are no deletes")
        XCTAssertEqual(Set(merged.goals[0].tags), ["x", "y"])
    }

    func testDuplicateUpdatesCollapse() {
        let u: (String, UpdateKind, String) = ("2026-09-02T00:00:00Z", .progress, "same")
        var local = LedgerDocument(); local.goals = [goal("a", updates: [u])]
        var remote = LedgerDocument(); remote.goals = [goal("a", updates: [u])]
        XCTAssertEqual(GoalsLedgerSync.merge(base: nil, local: local, remote: remote).goals[0].updates.count, 1)
    }

    func testFingerprintIgnoresUpdatedAt() {
        var a = LedgerDocument(); a.goals = [goal("g")]; a.updatedAt = "2026-09-01T00:00:00Z"
        var b = a; b.updatedAt = "2026-09-09T00:00:00Z"
        XCTAssertEqual(GoalsLedgerSync.fingerprint(a), GoalsLedgerSync.fingerprint(b))
        b.goals[0].priority = 9
        XCTAssertNotEqual(GoalsLedgerSync.fingerprint(a), GoalsLedgerSync.fingerprint(b))
    }
}

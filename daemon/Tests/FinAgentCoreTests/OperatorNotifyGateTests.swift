import XCTest
@testable import FinAgentCore

/// `OperatorNotifyGate`/`OperatorNotifyMarker` — the dwell that turns "an operator
/// Claude Code session is blocked on Levi" into a time-sensitive push, without
/// trusting the local model's own sense of time (see the type's doc comment).
final class OperatorNotifyGateTests: XCTestCase {
    private func request(
        id: String = "g1", question: String = "Ship it?", createdAt: Date,
        notifyAfter: Date, notifiedAt: Date? = nil, threadID: String? = nil
    ) -> OperatorNotifyRequest {
        OperatorNotifyRequest(
            id: id, question: question, createdAt: createdAt, notifyAfter: notifyAfter,
            notifiedAt: notifiedAt, threadID: threadID
        )
    }

    // MARK: - due

    func testNotDueBeforeItsOwnDwell() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(createdAt: now.addingTimeInterval(-60), notifyAfter: now.addingTimeInterval(60)),
        ])
        XCTAssertTrue(OperatorNotifyGate.due(in: state, now: now).isEmpty)
    }

    func testDueOncePastItsOwnDwellBoundaryInclusive() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(createdAt: now.addingTimeInterval(-600), notifyAfter: now),
        ])
        XCTAssertEqual(OperatorNotifyGate.due(in: state, now: now).map(\.id), ["g1"])
    }

    func testAlreadyNotifiedIsNeverDueAgain() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(createdAt: now.addingTimeInterval(-600), notifyAfter: now.addingTimeInterval(-300), notifiedAt: now.addingTimeInterval(-100)),
        ])
        XCTAssertTrue(OperatorNotifyGate.due(in: state, now: now).isEmpty)
    }

    /// Two operator sessions, or two questions in one session, can be outstanding
    /// at once — each fires independently on its own schedule.
    func testMultipleIndependentWatchesEachFireOnTheirOwnSchedule() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(id: "urgent", createdAt: now.addingTimeInterval(-120), notifyAfter: now.addingTimeInterval(-1)),
            request(id: "patient", createdAt: now.addingTimeInterval(-120), notifyAfter: now.addingTimeInterval(600)),
        ])
        XCTAssertEqual(OperatorNotifyGate.due(in: state, now: now).map(\.id), ["urgent"])
    }

    // MARK: - notified / cleared

    func testNotifiedStampsOnlyTheMatchingRequest() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(id: "a", createdAt: now, notifyAfter: now),
            request(id: "b", createdAt: now, notifyAfter: now),
        ])
        let updated = OperatorNotifyGate.notified(state, id: "a", at: now)
        XCTAssertEqual(updated.requests.first { $0.id == "a" }?.notifiedAt, now)
        XCTAssertNil(updated.requests.first { $0.id == "b" }?.notifiedAt)
        XCTAssertTrue(OperatorNotifyGate.due(in: updated, now: now.addingTimeInterval(1)).map(\.id) == ["b"])
    }

    func testClearedRemovesTheRequestEntirely() {
        let now = Date()
        let state = OperatorNotifyState(requests: [request(id: "answered-already", createdAt: now, notifyAfter: now)])
        let cleared = OperatorNotifyGate.cleared(state, id: "answered-already")
        XCTAssertTrue(cleared.requests.isEmpty)
    }

    func testClearingAnUnknownIDIsANoOp() {
        let now = Date()
        let state = OperatorNotifyState(requests: [request(createdAt: now, notifyAfter: now)])
        XCTAssertEqual(OperatorNotifyGate.cleared(state, id: "not-here"), state)
    }

    // MARK: - pruning

    func testPrunesWatchesOlderThanMaxAgeRegardlessOfNotifiedState() {
        let now = Date()
        let state = OperatorNotifyState(requests: [
            request(id: "stale-unfired", createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60), notifyAfter: now.addingTimeInterval(-2 * 24 * 60 * 60)),
            request(id: "fresh", createdAt: now.addingTimeInterval(-60), notifyAfter: now.addingTimeInterval(60)),
        ])
        let pruned = OperatorNotifyGate.prunedOfStale(state, now: now, maxAge: 24 * 60 * 60)
        XCTAssertEqual(pruned.requests.map(\.id), ["fresh"])
    }

    // MARK: - Marker (file round trip)

    func testMarkerRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("operator-notify.json").path

        XCTAssertEqual(OperatorNotifyMarker.state(at: path), OperatorNotifyState(), "a missing file reads as empty, not an error")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = OperatorNotifyState(requests: [
            request(id: "g1", question: "Deploy Lambda + ship TestFlight now?", createdAt: now, notifyAfter: now.addingTimeInterval(600), threadID: "m-thread-1"),
        ])
        OperatorNotifyMarker.write(state, at: path)
        let reloaded = OperatorNotifyMarker.state(at: path)
        XCTAssertEqual(reloaded.requests.first?.id, "g1")
        XCTAssertEqual(reloaded.requests.first?.question, "Deploy Lambda + ship TestFlight now?")
        XCTAssertEqual(reloaded.requests.first?.threadID, "m-thread-1")
        let notifyAfter = try XCTUnwrap(reloaded.requests.first?.notifyAfter)
        XCTAssertEqual(notifyAfter.timeIntervalSince1970, now.addingTimeInterval(600).timeIntervalSince1970, accuracy: 1)
    }

    func testCorruptFileReadsAsEmptyRatherThanCrashing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("operator-notify.json").path
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(OperatorNotifyMarker.state(at: path), OperatorNotifyState())
    }
}

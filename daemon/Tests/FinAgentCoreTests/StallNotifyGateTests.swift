import XCTest
@testable import FinAgentCore

/// `StallNotifyGate`/`StallNotifyMarker` — the cooldown on the daemon's own
/// "agent-stalled" push, added after a live incident (2026-09-09/10) where a launchd
/// `KeepAlive` restart loop re-paged every ~17 minutes for two hours, twice, because
/// `consecutiveFailures` resets on every process restart with no memory of the last
/// push.
final class StallNotifyGateTests: XCTestCase {

    // MARK: - shouldNotify

    func testNotifiesWhenNeverNotifiedBefore() {
        XCTAssertTrue(StallNotifyGate.shouldNotify(lastNotifiedAt: nil, now: Date()))
    }

    func testDoesNotNotifyWithinTheCooldown() {
        let now = Date()
        let lastNotifiedAt = now.addingTimeInterval(-10 * 60)
        XCTAssertFalse(StallNotifyGate.shouldNotify(lastNotifiedAt: lastNotifiedAt, now: now, cooldown: 30 * 60))
    }

    func testNotifiesAgainOnceTheCooldownElapses() {
        let now = Date()
        let lastNotifiedAt = now.addingTimeInterval(-31 * 60)
        XCTAssertTrue(StallNotifyGate.shouldNotify(lastNotifiedAt: lastNotifiedAt, now: now, cooldown: 30 * 60))
    }

    func testCooldownBoundaryIsInclusive() {
        let now = Date()
        let lastNotifiedAt = now.addingTimeInterval(-30 * 60)
        XCTAssertTrue(StallNotifyGate.shouldNotify(lastNotifiedAt: lastNotifiedAt, now: now, cooldown: 30 * 60))
    }

    /// The exact shape of the live incident: a restart every ~17 minutes, well inside
    /// the 30-minute default cooldown, must collapse to roughly one push per two
    /// cooldown windows rather than one push per restart.
    func testCollapsesA17MinuteCrashLoopToOnePushPerCooldownWindow() {
        var lastNotifiedAt: Date? = nil
        var pushCount = 0
        var now = Date()
        for _ in 0..<7 {
            if StallNotifyGate.shouldNotify(lastNotifiedAt: lastNotifiedAt, now: now) {
                pushCount += 1
                lastNotifiedAt = now
            }
            now = now.addingTimeInterval(17 * 60)
        }
        XCTAssertLessThan(pushCount, 7, "seven restarts must not produce seven pushes")
        XCTAssertGreaterThan(pushCount, 0, "a still-stuck daemon must still page eventually")
    }

    // MARK: - StallNotifyMarker persistence

    private func withTempMarkerPath(_ body: (String) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StallNotifyGateTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("stall-notify.json").path)
    }

    func testMarkerReturnsNilWhenTheFileDoesNotExist() {
        withTempMarkerPath { path in
            XCTAssertNil(StallNotifyMarker.lastNotifiedAt(at: path))
        }
    }

    func testMarkerReturnsNilOnCorruptContent() throws {
        try withTempMarkerPath { path in
            try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertNil(StallNotifyMarker.lastNotifiedAt(at: path))
        }
    }

    func testMarkerRoundTripsThroughDisk() {
        withTempMarkerPath { path in
            let now = Date()
            StallNotifyMarker.recordNotified(at: path, now: now)
            let readBack = StallNotifyMarker.lastNotifiedAt(at: path)
            XCTAssertNotNil(readBack)
            // ISO 8601 round-trips to whole seconds.
            XCTAssertEqual(readBack!.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1.0)
        }
    }

    func testMarkerSurvivesAcrossASimulatedProcessRestart() {
        // consecutiveFailures is a local var and resets on restart; the marker is the
        // one thing that must NOT reset — this is the actual bug being fixed.
        withTempMarkerPath { path in
            let firstStallAt = Date()
            StallNotifyMarker.recordNotified(at: path, now: firstStallAt)

            // Simulate a fresh process (new local state, same marker file on disk).
            let restartedProcessNow = firstStallAt.addingTimeInterval(5 * 60)
            let carriedOverLastNotifiedAt = StallNotifyMarker.lastNotifiedAt(at: path)
            XCTAssertFalse(
                StallNotifyGate.shouldNotify(lastNotifiedAt: carriedOverLastNotifiedAt, now: restartedProcessNow),
                "a restart 5 minutes after the last push must not immediately re-page"
            )
        }
    }
}

/// The backoff added after 2026-09-12/13: 12 pages in one night, one per flat
/// 30-minute window, for two failures. Repeats of the same failure must back off;
/// a different failure is news; a good turn closes the incident with one note.
final class StallNotifyBackoffTests: XCTestCase {
    private let modelDown = "Endpoint returned HTTP 400 — {\"error\": {\"message\": \"Failed to load model\"}}"
    private let emptyAnswer = "The model stopped without producing an answer."

    func testFirstStallPagesImmediately() {
        XCTAssertTrue(StallNotifyGate.shouldNotify(state: nil, failure: modelDown, now: Date()))
    }

    func testRepeatCooldownDoublesAndCaps() {
        XCTAssertEqual(StallNotifyGate.repeatCooldown(pageCount: 1), 30 * 60)
        XCTAssertEqual(StallNotifyGate.repeatCooldown(pageCount: 2), 60 * 60)
        XCTAssertEqual(StallNotifyGate.repeatCooldown(pageCount: 3), 120 * 60)
        XCTAssertEqual(StallNotifyGate.repeatCooldown(pageCount: 4), 240 * 60)
        XCTAssertEqual(StallNotifyGate.repeatCooldown(pageCount: 9), 240 * 60, "capped at four hours")
    }

    /// The live shape: a restart every ~6 minutes for three hours on the same error.
    /// The flat gate paged 6 times; the backoff pages twice (t=0, t=30m), then waits an
    /// hour, then two — 3 pages in 3 hours.
    func testThreeHourCrashLoopOnOneFailurePagesThreeTimes() {
        var state: StallNotifyState? = nil
        var pages: [Int] = []
        let start = Date()
        var minute = 0
        while minute <= 180 {
            let now = start.addingTimeInterval(TimeInterval(minute * 60))
            if StallNotifyGate.shouldNotify(state: state, failure: modelDown, now: now) {
                pages.append(minute)
                state = StallNotifyGate.statePaged(after: state, failure: modelDown, now: now)
            }
            minute += 6
        }
        XCTAssertEqual(pages, [0, 30, 90], "got \(pages)")
        XCTAssertEqual(state?.pageCount, 3)
    }

    func testADifferentFailurePagesAfterTheBaseCooldownAndResetsTheBackoff() {
        let start = Date()
        var state = StallNotifyGate.statePaged(after: nil, failure: modelDown, now: start)
        state = StallNotifyGate.statePaged(after: state, failure: modelDown, now: start.addingTimeInterval(30 * 60))
        XCTAssertEqual(state.pageCount, 2)
        // 40 minutes later the error changes: inside the repeat's 1-hour window, but
        // past the base 30 — a new problem is worth a page.
        let changed = start.addingTimeInterval(70 * 60)
        XCTAssertFalse(StallNotifyGate.shouldNotify(state: state, failure: modelDown, now: changed))
        XCTAssertTrue(StallNotifyGate.shouldNotify(state: state, failure: emptyAnswer, now: changed))
        let fresh = StallNotifyGate.statePaged(after: state, failure: emptyAnswer, now: changed)
        XCTAssertEqual(fresh.pageCount, 1, "a new failure starts its own backoff")
    }

    func testAFlipToADifferentFailureInsideTheBaseWindowDoesNotPage() {
        // The 2026-09-13 loop had one HTTP 500 amid the 400s, ten minutes after a page.
        let start = Date()
        let state = StallNotifyGate.statePaged(after: nil, failure: modelDown, now: start)
        XCTAssertFalse(StallNotifyGate.shouldNotify(state: state, failure: emptyAnswer, now: start.addingTimeInterval(10 * 60)))
    }

    func testFailureKeyIgnoresWhitespaceAndCase() {
        XCTAssertEqual(
            StallNotifyGate.failureKey("HTTP 400 —  {\n  \"error\": 1 }"),
            StallNotifyGate.failureKey("http 400 — { \"error\": 1 }")
        )
        XCTAssertNotEqual(StallNotifyGate.failureKey("HTTP 400"), StallNotifyGate.failureKey("HTTP 500"))
    }

    func testRecoveryClosesTheIncidentExactlyOnce() {
        let now = Date()
        let paged = StallNotifyGate.statePaged(after: nil, failure: modelDown, now: now)
        let recovered = StallNotifyGate.stateRecovered(from: paged, now: now.addingTimeInterval(60))
        XCTAssertEqual(recovered?.active, false)
        XCTAssertNil(StallNotifyGate.stateRecovered(from: recovered, now: now.addingTimeInterval(120)),
                     "a second good turn must not send a second recovery note")
        XCTAssertNil(StallNotifyGate.stateRecovered(from: nil, now: now), "no incident, no note")
        // The next stall after a recovery starts fresh, even for the same failure.
        let again = StallNotifyGate.statePaged(after: recovered, failure: modelDown, now: now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(again.pageCount, 1)
    }

    func testMarkerReadsThePreBackoffFileAsOnePageStillActive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StallBackoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("m.json").path
        try Data("{\"lastNotifiedAt\":\"2026-09-13T14:36:47Z\"}".utf8).write(to: URL(fileURLWithPath: path))
        let state = try XCTUnwrap(StallNotifyMarker.state(at: path))
        XCTAssertEqual(state.pageCount, 1)
        XCTAssertTrue(state.active)
        XCTAssertNil(state.failureKey)
        // Round trip of the new shape.
        StallNotifyMarker.write(StallNotifyGate.statePaged(after: state, failure: "x", now: Date()), at: path)
        XCTAssertEqual(StallNotifyMarker.state(at: path)?.failureKey, "x")
    }
}

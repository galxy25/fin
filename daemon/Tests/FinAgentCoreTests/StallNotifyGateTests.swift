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

/// The dwell added 2026-09-21 (docs/NOTIFICATION-NOISE-AUDIT.md item 2): a give-up-worthy
/// streak (>=5 consecutive failures) must keep failing, unresolved, for 30 minutes before
/// it pages — most give-up episodes in the audited week self-healed well inside that
/// window (max observed page-to-recovery gap: 15.8 minutes).
final class StallNotifyDwellTests: XCTestCase {
    private let modelDown = "Endpoint returned HTTP 400 — {\"error\": {\"message\": \"Failed to load model\"}}"
    private let emptyAnswer = "The model stopped without producing an answer."

    func testAFreshStreakHasNotDwelledYet() {
        let now = Date()
        let pending = StallNotifyGate.statePending(after: nil, failure: modelDown, now: now)
        XCTAssertFalse(StallNotifyGate.pendingHasDwelled(state: pending, failure: modelDown, now: now))
        XCTAssertFalse(StallNotifyGate.pendingHasDwelled(
            state: pending, failure: modelDown, now: now.addingTimeInterval(29 * 60)))
    }

    func testTheStreakDwellsAfterThirtyMinutesUnresolved() {
        let start = Date()
        let pending = StallNotifyGate.statePending(after: nil, failure: modelDown, now: start)
        XCTAssertTrue(StallNotifyGate.pendingHasDwelled(
            state: pending, failure: modelDown, now: start.addingTimeInterval(30 * 60)))
    }

    /// The live shape this whole mechanism exists for: a daemon crash-looping every ~90
    /// seconds, restarting between every failure, must still accumulate the dwell and
    /// page once it has genuinely been broken for 30 minutes — an in-memory dwell would
    /// page never.
    func testACrashLoopEveryNinetySecondsStillAccumulatesTheDwellAcrossRestarts() {
        var state: StallNotifyState? = nil
        var now = Date()
        let end = now.addingTimeInterval(35 * 60)
        var dwelled = false
        while now < end {
            // Every iteration simulates a fresh process: state is read from "disk"
            // (the persisted `state`), never carried over as an in-memory local.
            state = StallNotifyGate.statePending(after: state, failure: modelDown, now: now)
            if StallNotifyGate.pendingHasDwelled(state: state, failure: modelDown, now: now) {
                dwelled = true
                break
            }
            now = now.addingTimeInterval(90)
        }
        XCTAssertTrue(dwelled, "30 unbroken minutes of the same failure, even across restarts, must eventually page")
    }

    func testADifferentFailureRestartsTheDwellClock() {
        let start = Date()
        var state = StallNotifyGate.statePending(after: nil, failure: modelDown, now: start)
        state = StallNotifyGate.statePending(after: state, failure: modelDown, now: start.addingTimeInterval(20 * 60))
        // A different failure at minute 25: must not inherit the modelDown clock.
        let switched = start.addingTimeInterval(25 * 60)
        state = StallNotifyGate.statePending(after: state, failure: emptyAnswer, now: switched)
        XCTAssertFalse(StallNotifyGate.pendingHasDwelled(state: state, failure: emptyAnswer, now: switched.addingTimeInterval(20 * 60)))
        XCTAssertTrue(StallNotifyGate.pendingHasDwelled(state: state, failure: emptyAnswer, now: switched.addingTimeInterval(30 * 60)))
    }

    /// The reviewer-flagged risk: a single interleaved success amid a mostly-failing
    /// streak must not silently cancel the dwell, or a brain that flaps 80% failures
    /// could go forever without paging.
    func testASingleInterleavedSuccessDoesNotCancelThePendingStreak() {
        let start = Date()
        var state: StallNotifyState? = StallNotifyGate.statePending(after: nil, failure: modelDown, now: start)
        // One success ten minutes in.
        state = StallNotifyGate.statePendingSucceeded(after: state)
        XCTAssertNotNil(state?.pendingSince, "one success must not be enough to cancel the streak")
        // The failures resume — still the same problem — and the ORIGINAL pendingSince
        // must survive, not restart, so the 30-minute clock is not reset by the blip.
        state = StallNotifyGate.statePending(after: state, failure: modelDown, now: start.addingTimeInterval(20 * 60))
        XCTAssertTrue(StallNotifyGate.pendingHasDwelled(state: state, failure: modelDown, now: start.addingTimeInterval(30 * 60)))
    }

    func testTwoConsecutiveSuccessesCancelThePendingStreak() {
        let start = Date()
        var state: StallNotifyState? = StallNotifyGate.statePending(after: nil, failure: modelDown, now: start)
        state = StallNotifyGate.statePendingSucceeded(after: state)
        state = StallNotifyGate.statePendingSucceeded(after: state)
        XCTAssertNil(state?.pendingSince, "two successes in a row is real recovery")
        XCTAssertFalse(StallNotifyGate.pendingHasDwelled(
            state: state, failure: modelDown, now: start.addingTimeInterval(31 * 60)))
    }

    func testStatePendingSucceededIsANoOpWhenNothingIsPending() {
        XCTAssertNil(StallNotifyGate.statePendingSucceeded(after: nil))
        let notPending = StallNotifyGate.statePaged(after: nil, failure: modelDown, now: Date())
        XCTAssertEqual(StallNotifyGate.statePendingSucceeded(after: notPending), notPending)
    }

    /// Paging must not erase the dwell bookkeeping — a restart right after the page,
    /// with the SAME failure recurring, must not have to dwell another 30 minutes
    /// before the (already-running) backoff schedule can page again.
    func testPagingCarriesThePendingClockForward() {
        let start = Date()
        let pending = StallNotifyGate.statePending(after: nil, failure: modelDown, now: start)
        let dwelledAt = start.addingTimeInterval(30 * 60)
        let paged = StallNotifyGate.statePaged(after: pending, failure: modelDown, now: dwelledAt)
        XCTAssertEqual(paged.pendingSince, start, "the original streak start must survive the page")
        XCTAssertEqual(paged.pendingFailureKey, StallNotifyGate.failureKey(modelDown))
    }

    /// End-to-end shape: the crash loop that motivated this fix (restarts every ~17
    /// minutes, per `testCollapsesA17MinuteCrashLoopToOnePushPerCooldownWindow` above)
    /// must still page — later than before, but not never — and once paged, further
    /// repeats use the existing exponential backoff rather than another 30-minute dwell.
    func testTheOriginalCrashLoopStillPagesJustLater() {
        var state: StallNotifyState? = nil
        var pages: [Int] = []
        let start = Date()
        var minute = 0
        while minute <= 180 {
            let now = start.addingTimeInterval(TimeInterval(minute * 60))
            state = StallNotifyGate.statePending(after: state, failure: modelDown, now: now)
            if StallNotifyGate.pendingHasDwelled(state: state, failure: modelDown, now: now),
               StallNotifyGate.shouldNotify(state: state, failure: modelDown, now: now) {
                pages.append(minute)
                state = StallNotifyGate.statePaged(after: state, failure: modelDown, now: now)
            }
            minute += 17
        }
        XCTAssertEqual(pages.first, 34, "first page only once dwelled past 30 min, at the next 17-min restart tick")
        XCTAssertLessThan(pages.count, 7, "still far fewer pages than one per restart")
        XCTAssertGreaterThan(pages.count, 0, "a genuinely stuck daemon still must page eventually")
    }
}

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

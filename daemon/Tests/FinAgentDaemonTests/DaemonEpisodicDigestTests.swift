import XCTest
@testable import FinAgentDaemon

/// `Daemon.appendedDigest` — the pure growth step behind automatic per-turn episodic
/// recording (`recordTurnInEpisodicMemory`), which keeps a cloud-hosted agent's memory
/// flowing from ordinary conversation the same way a locally-hosted one's does, without
/// depending on the model remembering to call the `remember` tool itself.
final class DaemonEpisodicDigestTests: XCTestCase {

    func testFirstLineHasNoLeadingNewline() {
        let digest = Daemon.appendedDigest("", userMessage: "what's the status?", answer: "all green")
        XCTAssertEqual(digest, "Q: what's the status? / A: all green")
    }

    func testSubsequentLinesAppendWithANewline() {
        let first = Daemon.appendedDigest("", userMessage: "q1", answer: "a1")
        let second = Daemon.appendedDigest(first, userMessage: "q2", answer: "a2")
        XCTAssertEqual(second, "Q: q1 / A: a1\nQ: q2 / A: a2")
    }

    func testLongUserMessageAndAnswerAreTruncated() {
        let longMessage = String(repeating: "a", count: 500)
        let longAnswer = String(repeating: "b", count: 500)
        let digest = Daemon.appendedDigest("", userMessage: longMessage, answer: longAnswer)
        XCTAssertTrue(digest.contains("…"), "both halves must be capped, not sent whole")
        XCTAssertLessThan(digest.count, 600)
    }

    func testOldestWholeLinesDropFirstOnceOverTheCap() {
        var digest = ""
        for index in 1...1000 {
            digest = Daemon.appendedDigest(digest, userMessage: "q\(index)", answer: "a\(index)")
        }
        XCTAssertLessThanOrEqual(digest.count, Daemon.maxDigestCharacters)
        XCTAssertFalse(digest.contains("Q: q1 /"), "the oldest line must have been dropped")
        XCTAssertTrue(digest.contains("q1000"), "the newest line must survive")
    }

    func testNewlinesInsideAMessageAreFlattened() {
        let digest = Daemon.appendedDigest("", userMessage: "line one\nline two", answer: "ok")
        XCTAssertFalse(digest.contains("line one\nline two"), "an embedded newline would look like a second digest line")
        XCTAssertTrue(digest.contains("line one line two"))
    }
}

/// `Daemon.nextNoOpenGoalsSince` — the pure state transition behind the control
/// plane's cost-savings sweep signal: a timer that starts the moment the goals ledger
/// goes empty and holds steady across further heartbeats (never refreshed by mere
/// reflection the way `last_turn_at` is), so an idle worker with nothing left to
/// pursue actually accumulates idle time instead of looking perpetually "active."
final class DaemonNoOpenGoalsSinceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_756_999_000)

    func testGoalsOpenClearsTheTimer() {
        XCTAssertNil(Daemon.nextNoOpenGoalsSince(hasOpenGoals: true, previous: earlier, now: now))
    }

    func testGoalsFirstGoingEmptyStartsTheTimerAtNow() {
        XCTAssertEqual(Daemon.nextNoOpenGoalsSince(hasOpenGoals: false, previous: nil, now: now), now)
    }

    func testGoalsStayingEmptyHoldsTheExistingTimerSteady() {
        XCTAssertEqual(Daemon.nextNoOpenGoalsSince(hasOpenGoals: false, previous: earlier, now: now), earlier,
                       "a heartbeat with nothing to do must not push the timer forward")
    }

    func testUnknownGoalsStateLeavesWhateverTimerAlreadyExistedUntouched() {
        XCTAssertEqual(Daemon.nextNoOpenGoalsSince(hasOpenGoals: nil, previous: earlier, now: now), earlier)
        XCTAssertNil(Daemon.nextNoOpenGoalsSince(hasOpenGoals: nil, previous: nil, now: now))
    }
}

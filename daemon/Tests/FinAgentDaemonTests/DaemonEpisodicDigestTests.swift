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

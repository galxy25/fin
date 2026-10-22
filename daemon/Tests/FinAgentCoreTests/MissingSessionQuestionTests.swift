import XCTest
@testable import FinAgentCore

final class MissingSessionQuestionTests: XCTestCase {
    private let ledger = LedgerDocument(goals: [
        Goal(id: "g-kio-rebase", title: "Rebase data-anamoly-reporter-agent", state: .active),
        Goal(id: "g-old", title: "Ship old-thing-worker", state: .done),
    ])
    private let live = ["main", "avycie-api", "avycie-web"]

    func testTheNeoQuestionBlocksItsGoalInstead() {
        let verdict = MissingSessionQuestion.verdict(
            question: "I can't find tmux session data-anamoly-reporter-agent. Which session should I rebase?",
            ledger: ledger, liveSessions: live
        )
        XCTAssertEqual(verdict, .init(goalID: "g-kio-rebase", session: "data-anamoly-reporter-agent"))
    }

    func testARunningSessionIsStillAskedAbout() {
        let withIt = live + ["data-anamoly-reporter-agent"]
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Session data-anamoly-reporter-agent has conflicts — keep theirs or ours?",
            ledger: ledger, liveSessions: withIt
        ))
    }

    func testNoPaneScanProvesNothing() {
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Can't find session data-anamoly-reporter-agent?", ledger: ledger, liveSessions: []
        ))
    }

    func testNamesOnlyDoneGoalsOrNoGoalAreAsked() {
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Can't find session old-thing-worker, restart it?", ledger: ledger, liveSessions: live
        ))
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Can't find session some-other-name, start it?", ledger: ledger, liveSessions: live
        ))
    }

    func testAQuestionThatIsNotAboutASessionIsAsked() {
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Should data-anamoly-reporter-agent rebase onto main or develop?",
            ledger: ledger, liveSessions: live
        ))
    }

    func testTheGoalIdIsNotMistakenForASession() {
        XCTAssertNil(MissingSessionQuestion.verdict(
            question: "Is g-kio-rebase still wanted, given its session is fine?",
            ledger: ledger, liveSessions: live
        ))
    }
}

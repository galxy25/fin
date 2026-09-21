import XCTest
@testable import FinAgentCore

/// The 2026-09-16 Blackstreet incident's signature: a real reply from the model,
/// not a decision blob, that claims it never saw the user's message. Purely a
/// telemetry marker (Daemon.swift logs it, never retries on it) — these tests
/// pin the phrase match so it doesn't silently drift.
final class MissingMessageConfusionGuardTests: XCTestCase {
    func testTheLiveIncidentTextIsFlagged() {
        XCTAssertTrue(AgentTurnLogic.looksLikeMissingMessageConfusion(
            "I don't see a message from you in our current turn. Could you please let me know what you'd like me to work on?"
        ))
    }

    func testOtherPhrasingsOfTheSameConfusionAreFlagged() {
        XCTAssertTrue(AgentTurnLogic.looksLikeMissingMessageConfusion("I do not see a message from you yet."))
        XCTAssertTrue(AgentTurnLogic.looksLikeMissingMessageConfusion("I haven't received a message to act on."))
        XCTAssertTrue(AgentTurnLogic.looksLikeMissingMessageConfusion("Sorry, I didn't receive a message — what would you like me to work on?"))
    }

    func testRealAnswersAreNotFlagged() {
        XCTAssertFalse(AgentTurnLogic.looksLikeMissingMessageConfusion("Dropped it — the Blackstreet rip is no longer on the ledger."))
        XCTAssertFalse(AgentTurnLogic.looksLikeMissingMessageConfusion("The PDF was uploaded at 10:36 AM."))
        XCTAssertFalse(AgentTurnLogic.looksLikeMissingMessageConfusion(""))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(AgentTurnLogic.looksLikeMissingMessageConfusion("I DON'T SEE A MESSAGE FROM YOU."))
    }
}

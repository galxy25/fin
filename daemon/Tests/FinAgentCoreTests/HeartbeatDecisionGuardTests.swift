import XCTest
@testable import FinAgentCore

final class HeartbeatDecisionGuardTests: XCTestCase {
    func testDecisionBlobsAreRecognizedFencedOrBare() {
        XCTAssertTrue(AgentTurnLogic.looksLikeHeartbeatDecision(#"{"decision": "idle", "reason": "nothing"}"#))
        XCTAssertTrue(AgentTurnLogic.looksLikeHeartbeatDecision("```json\n{\"decision\": \"drive\", \"goal_id\": \"g1\"}\n```\n\nI'm driving."))
        XCTAssertTrue(AgentTurnLogic.looksLikeHeartbeatDecision("  \n{\"decision\":\"report\"}"))
    }

    func testRealAnswersAreNotFlagged() {
        XCTAssertFalse(AgentTurnLogic.looksLikeHeartbeatDecision("The PDF was uploaded at 10:36 AM."))
        XCTAssertFalse(AgentTurnLogic.looksLikeHeartbeatDecision("Yes — the decision was made yesterday; TestFlight has CarPlay."))
        XCTAssertFalse(AgentTurnLogic.looksLikeHeartbeatDecision("{\"ok\": true}"), "JSON without a decision key is not the tick contract")
        XCTAssertFalse(AgentTurnLogic.looksLikeHeartbeatDecision(""))
    }

    func testRetryPromptRestatesTheRequestAndForbidsJSON() {
        let prompt = AgentTurnLogic.decisionRetryPrompt(request: "Is CarPlay in TestFlight?")
        XCTAssertTrue(prompt.contains("Is CarPlay in TestFlight?"))
        XCTAssertTrue(prompt.contains("Never emit JSON"))
        XCTAssertTrue(prompt.contains("no heartbeat right now"))
    }
}

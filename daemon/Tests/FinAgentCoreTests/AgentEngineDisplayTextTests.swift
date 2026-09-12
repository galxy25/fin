import XCTest
@testable import FinAgentCore

/// `submit(_:displayText:)`: the model is sent the wrapped prompt, the audit trail
/// (and so the cloud transcript) records the user's exact words.
final class AgentEngineDisplayTextTests: XCTestCase {
    func testTheAuditTrailRecordsTheDisplayTextNotTheWrappedPrompt() async {
        var recorded: [AgentAuditEvent] = []
        let engine = await AgentTurnEngine(
            configuration: AgentEngineConfiguration(endpointURL: "http://127.0.0.1:1", modelIdentifier: "stub"),
            session: RecordingStubSession(),
            audit: { recorded.append($0) }
        )
        _ = await engine.submit("PREAMBLE: do it now\n\nMessage from the user:\nsend the grant", displayText: "send the grant")
        let user = recorded.first { $0.kind == "userMessage" }
        XCTAssertEqual(user?.text, "send the grant")
        let lastUser = await engine.transcript.messages.last { $0.role == .user }
        XCTAssertEqual(lastUser?.text.hasPrefix("PREAMBLE"), true, "the model still sees the wrapped prompt")
    }
}

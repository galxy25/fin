import XCTest
@testable import FinAgentCore

/// 2026-10-07: with the 10k history budget live, every heartbeat tick on qwen failed
/// with "No user query found in messages" — the trim had dropped the turn's own user
/// message. The engine must always send the message it is answering.
@MainActor
final class HistoryBudgetEngineTests: XCTestCase {
    func testEveryRequestStillCarriesTheCurrentUserMessage() async {
        let engine = AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1", modelIdentifier: "stub",
                contextWindowTokens: 42_000, maxOutputTokens: 640,
                systemPrompt: String(repeating: "s", count: 2_000),
                historyTokenBudget: 1_000
            ),
            session: RecordingStubSession(),
            audit: { _ in }
        )
        for index in 0..<8 {
            let text = "tick \(index) " + String(repeating: "x", count: 1_200)
            _ = await engine.submit(text)
            XCTAssertTrue(
                engine.transcript.wireMessages.contains { $0.role == .user && $0.text == text },
                "turn \(index) lost its own user message: \(engine.transcript.wireMessages.map(\.role))"
            )
        }
    }
}

import XCTest
@testable import FinAgentCore

/// The structured `target` on the pane-relaying tool calls (docs/THREADS.md §2): the
/// audit event for `send_session` / `read_session` names the validated pane target
/// as a field, so the cloud transcript's `target` — and the control plane's
/// `relay.sent` / `relay.read` thread events — never parse it out of the prose.
/// The prose itself is unchanged; it is what the app's log view shows.
@MainActor
final class AgentEngineRelayTargetTests: XCTestCase {

    private func makeEngine(audit: @escaping (AgentAuditEvent) -> Void) -> AgentTurnEngine {
        AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1", // never reached on these paths
                modelIdentifier: "stub"
            ),
            session: RecordingStubSession(),
            audit: audit
        )
    }

    private func call(_ name: String, _ arguments: String) -> AgentToolCall {
        AgentToolCall(id: "t1", name: name, arguments: arguments)
    }

    func testSendSessionToolCallCarriesTheValidatedTarget() async {
        var events: [AgentAuditEvent] = []
        let engine = makeEngine { events.append($0) }
        engine.onSendSession = { _, _, _ in .sent(after: .notWaited) }

        _ = await engine.execute(call(
            AgentToolSpec.sendSession.name, #"{"session": "main:2.0", "text": "run the tests"}"#
        ))

        let toolCall = events.first { $0.kind == "toolCall" && $0.toolName == "send_session" }
        XCTAssertEqual(toolCall?.target, "main:2.0")
        XCTAssertEqual(toolCall?.text, "send_session: main:2.0 (13 chars)", "the prose is unchanged")
        // The prose parser the follow-up goals use still agrees with the field.
        XCTAssertEqual(GoalsTick.sendSessionTarget(fromAuditText: toolCall?.text ?? ""), toolCall?.target)
    }

    func testReadSessionToolCallCarriesTheTargetOnlyWhenItNamesAPane() async {
        var events: [AgentAuditEvent] = []
        let engine = makeEngine { events.append($0) }
        engine.onReadSession = { _, _ in .text("$ ls") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:2.0", "lines": 20}"#))
        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{}"#))

        let reads = events.filter { $0.kind == "toolCall" && $0.toolName == "read_session" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[0].target, "main:2.0")
        XCTAssertEqual(reads[0].text, "read_session: main:2.0 (20 lines)")
        XCTAssertNil(reads[1].target, "a session listing addresses no pane")
        XCTAssertEqual(reads[1].text, "read_session: list sessions")
    }

    func testARejectedTargetRecordsNoTarget() async {
        var events: [AgentAuditEvent] = []
        let engine = makeEngine { events.append($0) }
        engine.onSendSession = { _, _, _ in .sent(after: .notWaited) }

        _ = await engine.execute(call(AgentToolSpec.sendSession.name, #"{"session": "main", "text": "hi"}"#))

        XCTAssertTrue(events.allSatisfy { $0.target == nil }, "a bare name is refused before any relay")
        XCTAssertTrue(events.contains { $0.kind == "error" && $0.toolName == "send_session" })
    }

    func testEveryOtherEventHasNoTarget() {
        let event = AgentAuditEvent(kind: "toolCall", text: "read_terminal (40 lines)", toolName: "read_terminal")
        XCTAssertNil(event.target)
    }
}

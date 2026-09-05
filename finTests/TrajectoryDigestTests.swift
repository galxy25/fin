import XCTest
@testable import fin

/// Digest-builder correctness on a synthetic audit trail: turn/tool counting,
/// duration, outcome classification, quiet-gap conversation splitting — and the
/// invariant the whole feature rests on: a digest payload carries counts only,
/// never message text or terminal output. All entries are transient (never
/// inserted), the same trick `AgentLogMirror.line(for:)` relies on.
final class TrajectoryDigestTests: XCTestCase {

    private let agentID = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        _ kind: AgentLogKind,
        text: String,
        runID: UUID,
        sequence: Int,
        at offset: TimeInterval,
        toolName: String? = nil,
        toolArguments: String? = nil,
        model: String = "qwen-32b",
        isFailure: Bool = false
    ) -> AgentLogEntry {
        let made = AgentLogEntry(record: AgentLogRecord(
            agentID: agentID,
            agentName: "Fin",
            serverName: "box",
            runID: runID,
            sequence: sequence,
            kind: kind,
            text: text,
            toolName: toolName,
            toolArguments: toolArguments,
            modelIdentifier: model,
            isFailure: isFailure
        ))
        made.timestamp = base.addingTimeInterval(offset)
        return made
    }

    /// Two-run conversation: a question answered after two tool calls, then a
    /// follow-up answered directly.
    private func completedConversation() -> (entries: [AgentLogEntry], firstRun: UUID) {
        let run1 = UUID()
        let run2 = UUID()
        return ([
            entry(.userMessage, text: "why did the build fail?", runID: run1, sequence: 1, at: 0),
            entry(.toolCall, text: "readTerminal", runID: run1, sequence: 2, at: 2,
                  toolName: "readTerminal", toolArguments: "{}"),
            entry(.toolResult, text: "error: missing semicolon", runID: run1, sequence: 3, at: 3),
            entry(.toolCall, text: "readTerminal", runID: run1, sequence: 4, at: 5,
                  toolName: "readTerminal", toolArguments: "{}"),
            entry(.toolResult, text: "line 42", runID: run1, sequence: 5, at: 6),
            entry(.assistantMessage, text: "Missing semicolon on line 42.", runID: run1, sequence: 6, at: 8),
            entry(.userMessage, text: "fix it", runID: run2, sequence: 1, at: 20),
            entry(.toolCall, text: "sendInput", runID: run2, sequence: 2, at: 22,
                  toolName: "sendInput", toolArguments: #"{"input":"vim main.c"}"#),
            entry(.assistantMessage, text: "Done — fixed and rebuilt.", runID: run2, sequence: 3, at: 30),
        ], run1)
    }

    // MARK: - Digest correctness

    func testDigestCountsTurnsToolsDurationAndChars() throws {
        let (entries, firstRun) = completedConversation()
        let digest = try XCTUnwrap(
            TrajectoryDigestBuilder.digest(entries: entries.shuffled(), hostingMode: "local")
        )
        XCTAssertEqual(digest.conversationID, firstRun.uuidString)
        XCTAssertEqual(digest.turns, 2)
        XCTAssertEqual(digest.toolCallCounts, ["readTerminal": 2, "sendInput": 1])
        XCTAssertEqual(digest.durationSeconds, 30)
        XCTAssertEqual(digest.outcome, "completed")
        XCTAssertEqual(digest.model, "qwen-32b")
        XCTAssertEqual(digest.hostingMode, "local")
        // Chars of the four user/assistant messages only — tool results excluded.
        let expectedChars = "why did the build fail?".count
            + "Missing semicolon on line 42.".count
            + "fix it".count
            + "Done — fixed and rebuilt.".count
        XCTAssertEqual(digest.transcriptChars, expectedChars)
    }

    func testUnansweredFinalRunIsInterrupted() throws {
        var (entries, _) = completedConversation()
        // A trailing question the agent never answered.
        entries.append(entry(.userMessage, text: "and the tests?", runID: UUID(), sequence: 1, at: 40))
        let digest = try XCTUnwrap(
            TrajectoryDigestBuilder.digest(entries: entries, hostingMode: "local")
        )
        XCTAssertEqual(digest.outcome, "interrupted")
        XCTAssertEqual(digest.turns, 3)
    }

    func testFinalRunEndingInFailureIsInterrupted() throws {
        let run = UUID()
        let entries = [
            entry(.userMessage, text: "deploy", runID: run, sequence: 1, at: 0),
            entry(.assistantMessage, text: "Deploying…", runID: run, sequence: 2, at: 2),
            entry(.error, text: "model call failed", runID: run, sequence: 3, at: 4, isFailure: true),
        ]
        let digest = try XCTUnwrap(
            TrajectoryDigestBuilder.digest(entries: entries, hostingMode: "cloud")
        )
        XCTAssertEqual(digest.outcome, "interrupted")
        XCTAssertEqual(digest.hostingMode, "cloud")
    }

    func testNoUserTrafficProducesNoDigest() {
        let run = UUID()
        let entries = [
            entry(.notice, text: "[app] launched build 42", runID: run, sequence: 1, at: 0),
            entry(.notice, text: "[session] connected", runID: run, sequence: 2, at: 1),
        ]
        XCTAssertNil(TrajectoryDigestBuilder.digest(entries: entries, hostingMode: "local"))
    }

    // MARK: - The privacy invariant

    func testPayloadCarriesNoMessageTextOrToolArguments() throws {
        let (entries, _) = completedConversation()
        let digest = try XCTUnwrap(
            TrajectoryDigestBuilder.digest(entries: entries, hostingMode: "local")
        )
        let payload = try XCTUnwrap(digest.payloadObject())
        XCTAssertEqual(
            Set(payload.keys),
            ["conversationID", "turns", "toolCallCounts", "durationSeconds",
             "outcome", "transcriptChars", "model", "hostingMode"]
        )
        // Belt and braces: none of the conversation's actual words appear anywhere
        // in the serialized payload.
        let serialized = String(
            decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self
        )
        XCTAssertFalse(serialized.contains("semicolon"))
        XCTAssertFalse(serialized.contains("vim main.c"))
        XCTAssertFalse(serialized.contains("build fail"))
    }

    // MARK: - Conversation grouping

    func testQuietGapSplitsConversations() {
        let runA = UUID()
        let runB = UUID()
        let entries = [
            entry(.userMessage, text: "first", runID: runA, sequence: 1, at: 0),
            entry(.assistantMessage, text: "answer one", runID: runA, sequence: 2, at: 5),
            // 31 minutes later — past the 30-minute gap.
            entry(.userMessage, text: "second", runID: runB, sequence: 1, at: 5 + 31 * 60),
            entry(.assistantMessage, text: "answer two", runID: runB, sequence: 2, at: 10 + 31 * 60),
        ]
        let groups = TrajectoryDigestBuilder.conversationGroups(entries: entries)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].first?.runID, runA)
        XCTAssertEqual(groups[1].first?.runID, runB)
    }

    func testLifecycleOnlyGroupsAreDropped() {
        let entries = [
            entry(.notice, text: "[app] backgrounded", runID: UUID(), sequence: 1, at: 0),
            entry(.notice, text: "[app] foregrounded", runID: UUID(), sequence: 2, at: 3600 * 3),
        ]
        XCTAssertTrue(TrajectoryDigestBuilder.conversationGroups(entries: entries).isEmpty)
    }

    func testHeartbeatOnlyConversationHasNoDirectUserTraffic() {
        let run = UUID()
        let group = [
            entry(.userMessage, text: "[heartbeat] check the task", runID: run, sequence: 1, at: 0),
            entry(.assistantMessage, text: "still compiling", runID: run, sequence: 2, at: 4),
        ]
        XCTAssertFalse(TrajectoryDigestBuilder.hasDirectUserTraffic(group))
        // But a digest still exists — monitoring activity is real trajectory data.
        XCTAssertNotNil(TrajectoryDigestBuilder.digest(entries: group, hostingMode: "local"))
    }
}

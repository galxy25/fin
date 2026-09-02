import XCTest
@testable import FinAgentCore

/// Pure-logic coverage for the extracted core — ported from the app's
/// `AgentLogicTests`/`AgentIntentClassifierTests` essentials so the daemon package
/// stands on its own test feet.
final class AgentCoreLogicTests: XCTestCase {

    // MARK: - Destructive command heuristic

    func testFlagsRecognizablyDestructiveCommands() {
        let destructive = [
            "rm -rf /",
            "rm -rf ~/projects",
            "sudo rm -fr /var",
            "mkfs.ext4 /dev/sda1",
            "dd if=/dev/zero of=/dev/sda",
            "shutdown -h now",
            "reboot",
            "git push --force origin main",
            "git reset --hard HEAD~3",
            "DROP TABLE users;",
            "killall -9 sshd",
        ]
        for command in destructive {
            XCTAssertTrue(DestructiveCommandHeuristic.isDestructive(command), "expected flagged: \(command)")
        }
    }

    func testDoesNotFlagOrdinaryCommands() {
        let safe = [
            "ls -la",
            "cat /etc/hosts",
            "git status",
            "git push origin main",
            "grep -rf patterns.txt .",
            "echo 'formatting the report'",
        ]
        for command in safe {
            XCTAssertFalse(DestructiveCommandHeuristic.isDestructive(command), "expected NOT flagged: \(command)")
        }
    }

    // MARK: - submittable normalization

    func testSubmittableAlwaysEndsInExactlyOneCarriageReturn() {
        XCTAssertEqual(AgentTurnLogic.submittable("ls -la"), "ls -la\r")
        XCTAssertEqual(AgentTurnLogic.submittable("ls -la\n"), "ls -la\r")
        XCTAssertEqual(AgentTurnLogic.submittable("ls -la\r"), "ls -la\r")
        XCTAssertEqual(AgentTurnLogic.submittable("ls -la\r\n"), "ls -la\r")
        XCTAssertEqual(AgentTurnLogic.submittable("ls -la\n\n\n"), "ls -la\r")
    }

    func testSubmittablePreservesInteriorNewlines() {
        XCTAssertEqual(
            AgentTurnLogic.submittable("cat <<EOF\nhello\nEOF\n"),
            "cat <<EOF\nhello\nEOF\r"
        )
    }

    // MARK: - containsResponse

    func testEchoOfOwnInputIsNotAResponse() {
        let sent = "sleep 3; echo FIN_DELAYED_1"
        XCTAssertFalse(AgentTurnLogic.containsResponse(
            "[18:57:53] < \u{276F} sleep 3; echo FIN_DELAYED_1",
            beyond: sent
        ))
        XCTAssertFalse(AgentTurnLogic.containsResponse("", beyond: sent))
        XCTAssertFalse(AgentTurnLogic.containsResponse("\u{276F} ", beyond: sent))
    }

    func testActualCommandOutputIsAResponse() {
        let sent = "sleep 3; echo FIN_DELAYED_1"
        XCTAssertTrue(AgentTurnLogic.containsResponse(
            "[18:57:53] < \u{276F} sleep 3; echo FIN_DELAYED_1\nFIN_DELAYED_1",
            beyond: sent
        ))
        XCTAssertTrue(AgentTurnLogic.containsResponse(
            "[18:58:02] < It is 6:58 PM PDT.",
            beyond: "what time is it?"
        ))
    }

    func testMultiLineInputEchoIsNotAResponse() {
        let sent = "cat <<EOF\nhello world\nEOF"
        let echoOnly = "[19:00:01] < \u{276F} cat <<EOF\nhello world\nEOF"
        XCTAssertFalse(AgentTurnLogic.containsResponse(echoOnly, beyond: sent))
        XCTAssertTrue(AgentTurnLogic.containsResponse(
            echoOnly + "\nthe actual command output",
            beyond: sent
        ))
    }

    // MARK: - Transcript compaction

    func testCompactionLeavesShortTranscriptsAlone() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "You are a terminal agent.")
        transcript.append(AgentMessage(role: .user, text: "hello"))

        XCTAssertFalse(transcript.compactIfNeeded(budget: 10_000))
        XCTAssertEqual(transcript.droppedMessageCount, 0)
    }

    func testCompactionDropsOldTurnsAndPreservesSystemPrompt() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "SYSTEM")
        for index in 0..<40 {
            transcript.append(AgentMessage(role: .user, text: String(repeating: "x", count: 400) + "\(index)"))
            transcript.append(AgentMessage(role: .assistant, text: String(repeating: "y", count: 400)))
        }
        let before = transcript.estimatedTokenCount

        XCTAssertTrue(transcript.compactIfNeeded(budget: 1_000))

        XCTAssertLessThan(transcript.estimatedTokenCount, before)
        XCTAssertLessThanOrEqual(transcript.estimatedTokenCount, 1_000)
        XCTAssertGreaterThan(transcript.droppedMessageCount, 0)
        XCTAssertEqual(transcript.messages.first?.text, "SYSTEM", "system prompt must survive")
        XCTAssertEqual(transcript.messages.last?.role, .assistant)
    }

    func testCompactionRecordsASingleRunningNote() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "SYSTEM")
        for _ in 0..<30 {
            transcript.append(AgentMessage(role: .user, text: String(repeating: "z", count: 500)))
        }

        transcript.compactIfNeeded(budget: 800)
        transcript.append(AgentMessage(role: .user, text: String(repeating: "z", count: 3_000)))
        transcript.compactIfNeeded(budget: 800)

        let notes = transcript.messages.filter { $0.text.hasPrefix("[context trimmed]") }
        XCTAssertEqual(notes.count, 1, "repeated compaction should update one note, not stack them")
    }

    func testCompactionNeverLeavesAnOrphanedToolResultAtTheHead() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "SYSTEM")
        for index in 0..<25 {
            let call = AgentToolCall(id: "call\(index)", name: "read_terminal", arguments: "{}")
            transcript.append(AgentMessage(role: .user, text: String(repeating: "q", count: 300)))
            transcript.append(AgentMessage(role: .assistant, text: "", toolCalls: [call]))
            transcript.append(AgentMessage(role: .tool, text: String(repeating: "r", count: 300), toolCallID: call.id))
        }

        transcript.compactIfNeeded(budget: 900)

        let conversational = transcript.wireMessages.drop { $0.role == .system }
        XCTAssertNotEqual(conversational.first?.role, .tool)
    }

    // MARK: - Intent classifier

    func testClassifiesReadTerminalPhrasings() {
        let phrasings = [
            "What did that print?",
            "what was just echoed?",
            "is it done yet?",
            "What's the output?",
            "Show me the terminal",
            "what did the screen show?",
        ]
        for phrasing in phrasings {
            XCTAssertEqual(AgentIntentClassifier.classify(phrasing), .readTerminal, "expected .readTerminal for: \(phrasing)")
        }
    }

    func testClassifiesSendInputPhrasings() {
        let cases: [(String, String)] = [
            ("run git status", "git status"),
            ("please run git status", "git status"),
            ("can you type pwd", "pwd"),
            ("type pwd and hit enter", "pwd"),
            ("run `ls -la`", "ls -la"),
            ("execute \"echo hi\"", "echo hi"),
            ("run ls, then press enter", "ls"),
            ("Run this exact shell command in the terminal right now: echo hi", "echo hi"),
        ]
        for (message, expectedCommand) in cases {
            XCTAssertEqual(
                AgentIntentClassifier.classify(message), .sendInput(command: expectedCommand),
                "expected .sendInput(\(expectedCommand)) for: \(message)"
            )
        }
    }

    func testAmbiguousAndAdversarialPhrasings() {
        let ambiguous = [
            "What is 2 + 2?",
            "should I run rm -rf?",
            "why does printf need a newline",
            "I ran this earlier and it broke everything",
            "Yesterday you told me to run the tests",
            "",
            "   ",
            "run",
            "run ?",
        ]
        for message in ambiguous {
            XCTAssertEqual(AgentIntentClassifier.classify(message), .ambiguous, "expected .ambiguous for: \(message)")
        }
    }

    // MARK: - Tool call argument parsing

    func testParsesToolCallArguments() {
        let call = AgentToolCall(id: "1", name: "send_input", arguments: #"{"input": "ls -la\n"}"#)
        XCTAssertEqual(call.argument("input"), "ls -la\n")
        XCTAssertNil(call.argument("missing"))

        let numeric = AgentToolCall(id: "1", name: "read_terminal", arguments: #"{"lines": 80}"#)
        XCTAssertEqual(numeric.argument("lines").flatMap(Int.init), 80)

        let malformed = AgentToolCall(id: "1", name: "send_input", arguments: "not json at all")
        XCTAssertNil(malformed.argument("input"))
    }

    // MARK: - Endpoint URL handling

    func testRejectsEmptyEndpoint() async {
        let client = AgentEndpointClient(baseURL: "   ", model: "m", apiKey: nil, temperature: 0, maxOutputTokens: 16)
        do {
            _ = try await client.complete(messages: [], tools: [])
            XCTFail("expected badURL")
        } catch AgentEndpointError.badURL {
            // expected
        } catch {
            XCTFail("expected badURL, got \(error)")
        }
    }

    // MARK: - Engine refusal path (no network, no session traffic needed)

    /// The daemon-specific behavior worth locking down: with nobody to approve it, a
    /// destructive-looking send_input is refused before anything touches the wire.
    @MainActor
    func testEngineRefusesDestructiveCommandsUnattended() async {
        let session = RecordingStubSession()
        var audited: [AgentAuditEvent] = []
        let engine = AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1", // never reached on this path
                modelIdentifier: "stub"
            ),
            session: session,
            audit: { audited.append($0) }
        )

        // "run rm -rf /" classifies as a forced send_input; the refusal must happen
        // in the tool executor, before the session sees any input.
        _ = await engine.submit("run rm -rf /tmp/precious")

        XCTAssertTrue(session.sentInputs.isEmpty, "destructive input must never reach the session")
        let refusal = engine.transcript.messages.first { $0.role == .tool }
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.text.contains("REFUSED") ?? false, "got: \(refusal?.text ?? "nil")")
        XCTAssertTrue(audited.contains { $0.kind == "error" && $0.isFailure }, "refusal must land in the audit trail")
    }
}

/// Minimal in-memory conformer for engine tests that must not touch SSH.
@MainActor
final class RecordingStubSession: AgentSessionDriving {
    let eventLog = TerminalEventLog()
    var isSessionConnected = true
    private(set) var sentInputs: [String] = []

    func sendAgentInput(_ text: String) {
        sentInputs.append(text)
        eventLog.recordInput(Array(text.utf8))
    }
}

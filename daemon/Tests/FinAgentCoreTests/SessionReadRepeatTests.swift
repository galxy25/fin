import XCTest
@testable import FinAgentCore

/// The 2026-09-16 thread `m-b3bf22ae` in two halves, each now a deterministic gate:
///
/// 1. Asked what the Claude Code sessions were working on, the model read `main:0.0`
///    and `main:1.0`, then read BOTH AGAIN. The human cleared `main:1.0` in between,
///    so the duplicate returned a bare banner — and that is what the reply was built
///    from, throwing away the first capture's full account of the work.
/// 2. Asked to look at the machine, the model called `read_terminal` (its own control
///    shell), got Fin's own connect handshake, and — obeying framing that said "quote
///    values above verbatim" — pushed a wall of `FIN_ENV_580869=…` to the owner's phone.
@MainActor
final class SessionReadRepeatTests: XCTestCase {

    private func makeEngine(audit: @escaping (AgentAuditEvent) -> Void = { _ in }) -> AgentTurnEngine {
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

    // MARK: - The repeat read

    func testASecondReadOfTheSamePaneServesTheFirstCaptureAndNeverTouchesTmux() async {
        var captures = 0
        let engine = makeEngine()
        engine.onReadSession = { _, _ in
            captures += 1
            return .text(captures == 1 ? "the App Store work, in full" : "a bare cleared banner")
        }

        let first = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))
        let second = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))

        XCTAssertEqual(captures, 1, "the duplicate must not reach the runner at all")
        XCTAssertTrue(first.contains("the App Store work, in full"))
        XCTAssertTrue(
            second.contains("the App Store work, in full"),
            "the good evidence is served again — the cleared banner never appears"
        )
        XCTAssertFalse(second.contains("bare cleared banner"))
        XCTAssertTrue(second.hasPrefix("ALREADY READ THIS TURN."))
    }

    func testTheRepeatIsMatchedOnTheNameTheModelAskedForCaseAndSpaceInsensitively() async {
        var captures = 0
        let engine = makeEngine()
        engine.onReadSession = { _, _ in captures += 1; return .text("screen") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "Fin"}"#))
        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": " fin "}"#))

        XCTAssertEqual(captures, 1)
    }

    func testADifferentPaneIsStillRead() async {
        var read: [String?] = []
        let engine = makeEngine()
        engine.onReadSession = { name, _ in read.append(name); return .text("screen") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:0.0"}"#))
        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))

        XCTAssertEqual(read, ["main:0.0", "main:1.0"], "reading the NEXT pane is the whole job")
    }

    func testRepeatingTheSessionListingIsAlsoServedFromTheFirst() async {
        var captures = 0
        let engine = makeEngine()
        engine.onReadSession = { _, _ in captures += 1; return .text("main: 3 windows") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{}"#))
        let second = await engine.execute(call(AgentToolSpec.readSession.name, #"{}"#))

        XCTAssertEqual(captures, 1)
        XCTAssertTrue(second.contains("the session listing"))
    }

    func testTypingIntoAPaneInvalidatesEveryCaptureSoAReadAfterASendIsReal() async {
        var captures = 0
        let engine = makeEngine()
        engine.onReadSession = { _, _ in captures += 1; return .text("screen \(captures)") }
        engine.onSendSession = { _, _, _ in .sent(after: .notWaited) }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:2.0"}"#))
        _ = await engine.execute(call(
            AgentToolSpec.sendSession.name, #"{"session": "main:2.0", "text": "run the tests"}"#
        ))
        let after = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:2.0"}"#))

        XCTAssertEqual(captures, 2, "after keystrokes land, a re-read is the point")
        XCTAssertTrue(after.contains("screen 2"))
        XCTAssertFalse(after.hasPrefix("ALREADY READ THIS TURN."))
    }

    func testANewTurnStartsWithNothingRead() async {
        var captures = 0
        let engine = makeEngine()
        engine.onReadSession = { _, _ in captures += 1; return .text("screen") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))
        // submit() fails fast on an empty message, but only AFTER the per-turn reset it
        // shares with every real turn — which is exactly the seam under test.
        _ = await engine.submit("what is going on over there?")
        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))

        XCTAssertEqual(captures, 2, "a fresh turn must see the pane as it is now")
    }

    func testTheRepeatIsVisibleInTheAuditAsARepeat() async {
        var events: [AgentAuditEvent] = []
        let engine = makeEngine { events.append($0) }
        engine.onReadSession = { _, _ in .text("screen") }

        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))
        _ = await engine.execute(call(AgentToolSpec.readSession.name, #"{"session": "main:1.0"}"#))

        let reads = events.filter { $0.kind == "toolCall" && $0.toolName == "read_session" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads[1].text.contains("already read this turn"))
        XCTAssertEqual(reads[1].target, "main:1.0", "a repeat still names the pane it is about")
    }

    // MARK: - Fin's own handshake is not terminal content

    func testAHandshakeOnlyCaptureIsReportedAsAnIdleShellNotAsQuotableOutput() {
        // Verbatim from the live audit, run FB451F99, 16:13:08Z.
        let snapshot = """
        [04:00:11] > echo FIN_ENV_580869=$TMUX
        [04:00:11] < echo FIN_ENV_580869=$TMUX
        echo FIN_ENV_580869=$TMUX

        FIN_ENV_580869=/private/tmp/tmux-501/fin,25329,0
        ⏎                                        ⏎deepspacenine@Levis-iMac ~/f/l/fin (main)> 
        [04:00:13] < FIN_READY_306053
        deepspacenine@Levis-iMac ~/f/l/fin (main)> echo FIN_ENV_388250=$TMUX
        FIN_ENV_388250=/private/tmp/tmux-501/fin,25329,0
        deepspacenine@Levis-iMac ~/f/l/fin (main)> echo FIN_READY_893832
        FIN_READY_893832
        """

        let framed = AgentTurnLogic.frameTerminalResult(snapshot)

        XCTAssertEqual(framed, AgentTurnLogic.idleTerminalResult)
        XCTAssertFalse(framed.contains("FIN_ENV_580869"), "the owner's phone must never see this")
        XCTAssertFalse(framed.contains("FIN_READY"))
        XCTAssertFalse(framed.contains("authoritative"), "nothing here is worth quoting verbatim")
        XCTAssertTrue(framed.contains("read_session"), "it must name the tool that CAN answer")
    }

    func testRealOutputSurvivesWithOnlyTheHandshakeRemoved() {
        let snapshot = """
        [10:00:01] > echo FIN_READY_112233
        [10:00:01] < FIN_READY_112233
        [10:00:05] > swift test
        [10:00:09] < Executed 466 tests, with 0 failures
        """

        let framed = AgentTurnLogic.frameTerminalResult(snapshot)

        XCTAssertTrue(framed.contains("Executed 466 tests, with 0 failures"))
        XCTAssertTrue(framed.contains("swift test"))
        XCTAssertFalse(framed.contains("FIN_READY_112233"))
        XCTAssertTrue(framed.contains("authoritative"), "real output is still quotable")
    }

    func testALineThatMerelyMentionsATokenKeepsItsOtherWords() {
        // A grep or a log line ABOUT the handshake is real output someone asked for.
        let snapshot = "[10:00:05] < LocalTerminalSession.swift:412: let token = FIN_READY_112233 probe"
        let result = TerminalNoiseFilter.strip(snapshot)

        XCTAssertFalse(result.removedAll)
        XCTAssertEqual(result.text, snapshot)
    }

    func testAnEmptyTerminalStillReportsAsIdle() {
        XCTAssertEqual(AgentTurnLogic.frameTerminalResult(""), AgentTurnLogic.idleTerminalResult)
    }

    func testTheReadTerminalAuditSaysWhenItFilteredEverything() async {
        var events: [AgentAuditEvent] = []
        let session = RecordingStubSession()
        session.eventLog.recordInput(Array("echo FIN_READY_112233\n".utf8))
        session.eventLog.recordOutput(Array("FIN_READY_112233\n".utf8))
        let engine = AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1", modelIdentifier: "stub"
            ),
            session: session,
            audit: { events.append($0) }
        )

        _ = await engine.execute(call(AgentToolSpec.readTerminal.name, #"{}"#))

        let read = events.first { $0.kind == "toolCall" && $0.toolName == "read_terminal" }
        XCTAssertTrue(read?.text.contains("Fin's own handshake") ?? false, read?.text ?? "no event")
    }
}

/// An empty completion is a reasoning model that never started writing, not a refusal.
/// `7a9b955` measured the cure on gemma-4-12b (2045 of 2048 tokens spent on reasoning,
/// 0 characters of content) and the 2026-09-16 retest proved the old cure — a system
/// message asking it to answer — does not work: it returned empty a second time and the
/// turn failed. The retry is a prefill.
@MainActor
final class EmptyReplyPrefillTests: XCTestCase {

    /// A stub endpoint is out of reach here, so these assert on the pure pieces the
    /// engine composes: the prefill is content-free, and assembly never doubles it.
    func testThePrefillCommitsToNothingAboutTheAnswer() {
        let prefill = AgentTurnEngine.answerPrefill
        XCTAssertFalse(prefill.isEmpty)
        // It must fit a status report, a result, or bad news alike.
        for word in ["success", "done", "complete", "sorry", "error"] {
            XCTAssertFalse(
                prefill.localizedCaseInsensitiveContains(word),
                "\(prefill) presumes the answer"
            )
        }
    }

    func testTheProfileAssemblyRuleTheEngineMirrorsNeverDoublesThePrefill() {
        // The engine's assembledAnswer is private; this pins the shared rule it copies.
        XCTAssertEqual(
            ProfileCompaction.assembled(from: "**Current work**\n- a thing"),
            "**Current work**\n- a thing",
            "a model that restated the prefill must not get it twice"
        )
        XCTAssertTrue(
            ProfileCompaction.assembled(from: "a thing").hasPrefix(ProfileCompaction.assistantPrefill)
        )
    }
}

import XCTest
@testable import FinAgentCore

/// Dispatch-path coverage for the tools the shared roster advertises but the engine
/// forwards to its runner hooks (request_input, monitor) or answers honestly for
/// (remember, recall) — plus the split-Return send and the promoted TASK COMPLETE
/// detection. Pure logic: a stub session, no network, no model.
@MainActor
final class AgentEngineDispatchTests: XCTestCase {

    private func makeEngine(
        session: RecordingStubSession? = nil,
        audit: @escaping (AgentAuditEvent) -> Void = { _ in }
    ) -> AgentTurnEngine {
        let session = session ?? RecordingStubSession()
        return AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1", // never reached on these paths
                modelIdentifier: "stub"
            ),
            session: session,
            audit: audit
        )
    }

    private func call(_ name: String, _ arguments: String) -> AgentToolCall {
        AgentToolCall(id: "t1", name: name, arguments: arguments)
    }

    // MARK: - TASK COMPLETE detection (promoted from AgentRuntime)

    /// Suffix-anchored: the prompts contract on "end your reply with the exact phrase
    /// TASK COMPLETE", so a reply completes only when it ENDS with the token (after
    /// trimming trailing whitespace and punctuation). A mid-reply mention must not shut
    /// the daemon down — live-proven false positive: a model restating its instructions.
    func testContainsTaskCompleteMatchesTheExactPhraseAtTheEnd() {
        XCTAssertTrue(AgentTurnLogic.containsTaskComplete("All verified. TASK COMPLETE"))
        XCTAssertTrue(AgentTurnLogic.containsTaskComplete("TASK COMPLETE."))
        XCTAssertTrue(AgentTurnLogic.containsTaskComplete("**TASK COMPLETE**"))
        XCTAssertTrue(AgentTurnLogic.containsTaskComplete("Done. TASK COMPLETE \n"))
        // Embedded mentions counted under the old contains() semantics — the bug.
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete("TASK COMPLETE — see the log."))
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete("TASK COMPLETE is what I will say later"))
        // The live false positive that completed a task and shut the process down.
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete("I will only reply TASK COMPLETE when instructed..."))
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete("task complete"))
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete("The task is almost complete."))
        XCTAssertFalse(AgentTurnLogic.containsTaskComplete(""))
    }

    // MARK: - Split-Return send

    /// The paste-detection fix: the body and the Return must be two separate writes —
    /// a \r riding in the same stdin burst is treated by TUI input libraries as paste
    /// content (inserted, not submitted).
    func testSendInputSendsBodyThenReturnAsSeparateWrites() async {
        let session = RecordingStubSession()
        let engine = makeEngine(session: session)

        _ = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "echo hi\n", "await_output_seconds": 1}"#
        ))

        XCTAssertEqual(session.sentInputs, ["echo hi", "\r"],
                       "expected the typed body and a lone \\r, in that order")
    }

    // MARK: - remember / recall

    func testMemoryToolsAnswerHonestlyInsteadOfUnknownTool() async {
        var audited: [AgentAuditEvent] = []
        let engine = makeEngine(audit: { audited.append($0) })

        for name in [AgentToolSpec.remember.name, AgentToolSpec.recall.name] {
            let result = await engine.execute(call(name, "{}"))
            XCTAssertTrue(result.contains("unavailable in headless mode"), "got: \(result)")
            XCTAssertFalse(result.contains("unknown tool"),
                           "an advertised tool must never be answered as unknown")
        }
        XCTAssertEqual(audited.filter { $0.kind == "toolCall" }.count, 2,
                       "each memory call should still land in the audit trail")
    }

    // MARK: - request_input

    func testRequestInputFiresHookAndReturnsCannedAcknowledgment() async {
        var askedQuestions: [String] = []
        var audited: [AgentAuditEvent] = []
        let engine = makeEngine(audit: { audited.append($0) })
        engine.onRequestInput = { askedQuestions.append($0) }

        let result = await engine.execute(call(
            AgentToolSpec.requestInput.name,
            #"{"question": "Which branch should I deploy?"}"#
        ))

        XCTAssertEqual(askedQuestions, ["Which branch should I deploy?"])
        XCTAssertEqual(result, "The user has been notified. Their next message will answer your question.")
        XCTAssertTrue(audited.contains {
            $0.kind == "toolCall" && $0.text.contains("Which branch should I deploy?")
        }, "the question must be recorded in the audit log")
    }

    func testRequestInputRequiresAQuestion() async {
        let engine = makeEngine()
        engine.onRequestInput = { _ in XCTFail("hook must not fire for an empty question") }

        let result = await engine.execute(call(AgentToolSpec.requestInput.name, "{}"))
        XCTAssertTrue(result.contains("non-empty \"question\""), "got: \(result)")
    }

    func testRequestInputWithoutARunnerHookIsAnHonestError() async {
        let engine = makeEngine()
        let result = await engine.execute(call(
            AgentToolSpec.requestInput.name,
            #"{"question": "hello?"}"#
        ))
        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("not available"), "got: \(result)")
    }

    // MARK: - monitor

    func testMonitorStartClampsTheIntervalAndReportsTheEffectiveCadence() async {
        let engine = makeEngine()
        var received: [Int] = []
        engine.onMonitorStart = { requested in
            received.append(requested)
            return requested == 0 ? 60 : requested // runner keeps 60s when told "keep"
        }

        // Below the floor → clamped up to 15.
        var result = await engine.execute(call(
            AgentToolSpec.monitor.name, #"{"action": "start", "interval_seconds": "5"}"#
        ))
        XCTAssertTrue(result.contains("every 15s"), "got: \(result)")

        // Above the ceiling → clamped down to 600.
        result = await engine.execute(call(
            AgentToolSpec.monitor.name, #"{"action": "start", "interval_seconds": "10000"}"#
        ))
        XCTAssertTrue(result.contains("every 600s"), "got: \(result)")

        // Unset → 0 reaches the runner ("keep current"), whose answer is reported.
        result = await engine.execute(call(AgentToolSpec.monitor.name, #"{"action": "start"}"#))
        XCTAssertTrue(result.contains("every 60s"), "got: \(result)")

        XCTAssertEqual(received, [15, 600, 0])
    }

    func testMonitorStopFiresHookAndConfirms() async {
        let engine = makeEngine()
        var stopped = false
        engine.onMonitorStop = { stopped = true }

        let result = await engine.execute(call(AgentToolSpec.monitor.name, #"{"action": "stop"}"#))
        XCTAssertTrue(stopped)
        XCTAssertEqual(result, "Monitoring disarmed.")
    }

    func testMonitorRejectsUnknownActions() async {
        let engine = makeEngine()
        engine.onMonitorStart = { _ in XCTFail("must not arm"); return 0 }
        engine.onMonitorStop = { XCTFail("must not disarm") }

        let result = await engine.execute(call(AgentToolSpec.monitor.name, #"{"action": "pause"}"#))
        XCTAssertTrue(result.contains("\"start\" or \"stop\""), "got: \(result)")
    }

    func testMonitorWithoutRunnerHooksIsAnHonestError() async {
        let engine = makeEngine()
        for arguments in [#"{"action": "start"}"#, #"{"action": "stop"}"#] {
            let result = await engine.execute(call(AgentToolSpec.monitor.name, arguments))
            XCTAssertTrue(result.contains("not available"), "got: \(result)")
        }
    }

    // MARK: - notify (proactively-social push)

    /// The 7th tool must ride in the shared roster the engine advertises, with the
    /// {title, body} schema and both fields required — a drift here changes what every
    /// backend exposes to the model.
    func testNotifyToolIsAdvertisedInTheSharedRoster() {
        XCTAssertTrue(AgentToolSpec.all.contains { $0.name == "notify" },
                      "notify must be part of the advertised roster")
        XCTAssertTrue(AgentToolSpec.knownToolNames.contains("notify"))

        let properties = AgentToolSpec.notify.parameters["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["title"], "notify schema must expose a title property")
        XCTAssertNotNil(properties?["body"], "notify schema must expose a body property")
        let required = AgentToolSpec.notify.parameters["required"] as? [String]
        XCTAssertEqual(required.map(Set.init), Set(["title", "body"]),
                       "both title and body are required")
    }

    /// The happy path: the model chose to notify, so the runner's hook fires with the
    /// exact title and body, and the tool tells the model it was sent.
    func testNotifyFiresHookWithTitleAndBodyAndReportsSent() async {
        var pushes: [(title: String, body: String)] = []
        var audited: [AgentAuditEvent] = []
        let engine = makeEngine(audit: { audited.append($0) })
        engine.onNotify = { title, body in
            pushes.append((title, body))
            return true // a channel is configured
        }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "Deploy done", "body": "main is live on prod; smoke tests green."}"#
        ))

        XCTAssertEqual(pushes.count, 1)
        XCTAssertEqual(pushes.first?.title, "Deploy done")
        XCTAssertEqual(pushes.first?.body, "main is live on prod; smoke tests green.")
        XCTAssertEqual(result, "Sent to the owner.")
        XCTAssertTrue(audited.contains {
            $0.kind == "toolCall" && $0.text.contains("Deploy done")
        }, "the notification must be recorded in the audit trail")
    }

    /// A configured-but-unreachable channel (hook returns false) must be reported to the
    /// model honestly, not dressed up as a delivered push.
    func testNotifyReportsWhenNoChannelDelivered() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in false }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "FYI", "body": "halfway through the migration."}"#
        ))
        XCTAssertTrue(result.contains("not reached"), "got: \(result)")
        XCTAssertFalse(result.hasPrefix("Sent"), "an undelivered push must not claim success")
    }

    func testNotifyRequiresABody() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in XCTFail("hook must not fire for an empty body"); return true }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name, #"{"title": "hi"}"#
        ))
        XCTAssertTrue(result.contains("non-empty \"body\""), "got: \(result)")
    }

    /// Same honesty as the memory/monitor tools: an advertised tool with no runner wiring
    /// says so plainly rather than lying that the owner heard it.
    func testNotifyWithoutARunnerHookIsAnHonestError() async {
        let engine = makeEngine()
        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "hi", "body": "anyone there?"}"#
        ))
        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("not available"), "got: \(result)")
    }

    /// The heart of the delegate-to-the-model design: notifying is the MODEL's choice, so
    /// nothing the engine does on its own — reading the terminal, arming/stopping a
    /// monitor, asking for input — may fire the notify hook. Only a `notify` tool call
    /// does. If this ever regresses, a heartbeat tick could spam the owner.
    func testOtherToolsNeverAutoFireNotify() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in
            XCTFail("no tool other than notify itself may push to the owner")
            return true
        }
        engine.onRequestInput = { _ in }
        engine.onMonitorStart = { _ in 60 }
        engine.onMonitorStop = { }

        _ = await engine.execute(call(AgentToolSpec.readTerminal.name, "{}"))
        _ = await engine.execute(call(AgentToolSpec.requestInput.name, #"{"question": "which branch?"}"#))
        _ = await engine.execute(call(AgentToolSpec.monitor.name, #"{"action": "start"}"#))
        _ = await engine.execute(call(AgentToolSpec.monitor.name, #"{"action": "stop"}"#))
        // No XCTFail fired → nothing auto-notified.
    }
}

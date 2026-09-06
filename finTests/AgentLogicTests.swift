import XCTest
@testable import fin

/// Covers the agent's pure logic — the parts that decide what gets sent to a real shell,
/// and the parts that keep a conversation inside a model's context window. Both are
/// reachable without a live endpoint or SSH session, and both fail in ways that are
/// expensive rather than merely annoying (a destructive command typed unattended; a
/// request rejected mid-run for overflowing the window).
final class AgentLogicTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Self.scrubDurableWatchdogState()
    }

    override func tearDown() {
        Self.scrubDurableWatchdogState()
        super.tearDown()
    }

    /// Monitoring suppression and arm provenance are durable device-local state
    /// keyed per agent ID; scrubbing every key — and the shared store's in-memory
    /// mirrors, which would otherwise shadow the scrub — before and after keeps
    /// these tests hermetic and leaves nothing behind in the host app's defaults.
    private static func scrubDurableWatchdogState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("fin.watchdog.suppressedAt.")
                || key.hasPrefix("fin.watchdog.armSource.") {
            defaults.removeObject(forKey: key)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { MonitorSuppressionStore.shared.resetCachesForTesting() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { MonitorSuppressionStore.shared.resetCachesForTesting() }
            }
        }
    }

    /// Syntactically non-empty (so `isRunnable` passes and `configurationBlocker`
    /// is nil) but unparseable as a URL, so a turn fails fast with a non-retryable
    /// `badURL` — no network, no retry backoff, no timers.
    private static let unparseableEndpointURL = "http://[invalid/v1"

    /// Lets the dispatched fast-failing tasks these tests provoke run to completion.
    private func drainMainActorTasks() async {
        for _ in 0..<50 { await Task.yield() }
    }

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
            XCTAssertTrue(
                DestructiveCommandHeuristic.isDestructive(command),
                "expected to be flagged: \(command)"
            )
        }
    }

    func testDoesNotFlagOrdinaryCommands() {
        let safe = [
            "ls -la",
            "cat /etc/hosts",
            "git status",
            "git push origin main",
            "docker ps -a",
            "tail -f /var/log/syslog",
            "grep -rf patterns.txt .",   // -rf here is grep's flags, not rm's
            "systemctl status nginx",
            "echo 'formatting the report'",
        ]
        for command in safe {
            XCTAssertFalse(
                DestructiveCommandHeuristic.isDestructive(command),
                "expected NOT to be flagged: \(command)"
            )
        }
    }

    // MARK: - Tool call argument parsing

    func testParsesStringArgumentFromJSON() {
        let call = AgentToolCall(
            id: "1",
            name: "send_input",
            arguments: #"{"input": "ls -la\n"}"#
        )
        XCTAssertEqual(call.argument("input"), "ls -la\n")
        XCTAssertNil(call.argument("missing"))
    }

    func testParsesNumericArgumentAsString() {
        let call = AgentToolCall(id: "1", name: "read_terminal", arguments: #"{"lines": 80}"#)
        XCTAssertEqual(call.argument("lines").flatMap(Int.init), 80)
    }

    func testMalformedArgumentsYieldNilRatherThanCrashing() {
        let call = AgentToolCall(id: "1", name: "send_input", arguments: "not json at all")
        XCTAssertNil(call.argument("input"))
    }

    // MARK: - send_input submission normalization

    /// An approved send_input must land as a real Return keypress (`\r`) — models omit the
    /// trailing newline they were asked for, and even a supplied `\n` isn't what a Return
    /// keypress sends, so TUI apps (Claude Code, vim) leave the text typed but unsubmitted.
    func testSubmittableAlwaysEndsInExactlyOneCarriageReturn() {
        XCTAssertEqual(AgentRuntime.submittable("ls -la"), "ls -la\r")
        XCTAssertEqual(AgentRuntime.submittable("ls -la\n"), "ls -la\r")
        XCTAssertEqual(AgentRuntime.submittable("ls -la\r"), "ls -la\r")
        XCTAssertEqual(AgentRuntime.submittable("ls -la\r\n"), "ls -la\r")
        XCTAssertEqual(AgentRuntime.submittable("ls -la\n\n\n"), "ls -la\r")
    }

    func testSubmittablePreservesInteriorNewlines() {
        XCTAssertEqual(
            AgentRuntime.submittable("cat <<EOF\nhello\nEOF\n"),
            "cat <<EOF\nhello\nEOF\r"
        )
    }

    // MARK: - send_input response detection

    /// The PTY reflects typed keystrokes back as output instantly — the await must not
    /// mistake that echo for the command's actual response.
    func testEchoOfOwnInputIsNotAResponse() {
        let sent = "sleep 3; echo FIN_DELAYED_1"
        XCTAssertFalse(AgentRuntime.containsResponse(
            "[18:57:53] < \u{276F} sleep 3; echo FIN_DELAYED_1",
            beyond: sent
        ))
        XCTAssertFalse(AgentRuntime.containsResponse("", beyond: sent))
        // A bare prompt redraw (no alphanumeric content) isn't a response.
        XCTAssertFalse(AgentRuntime.containsResponse("\u{276F} ", beyond: sent))
    }

    func testActualCommandOutputIsAResponse() {
        let sent = "sleep 3; echo FIN_DELAYED_1"
        XCTAssertTrue(AgentRuntime.containsResponse(
            "[18:57:53] < \u{276F} sleep 3; echo FIN_DELAYED_1\nFIN_DELAYED_1",
            beyond: sent
        ))
        XCTAssertTrue(AgentRuntime.containsResponse(
            "[18:58:02] < It is 6:58 PM PDT.",
            beyond: "what time is it?"
        ))
    }

    /// A multi-line send (a heredoc, a pasted script) echoes as multiple lines, none of
    /// which contain the full sent text — the echo check must compare per sent line or
    /// the echo alone reads as a response and settles the await prematurely.
    func testMultiLineInputEchoIsNotAResponse() {
        let sent = "cat <<EOF\nhello world\nEOF"
        let echoOnly = "[19:00:01] < \u{276F} cat <<EOF\nhello world\nEOF"
        XCTAssertFalse(AgentRuntime.containsResponse(echoOnly, beyond: sent))
        XCTAssertTrue(AgentRuntime.containsResponse(
            echoOnly + "\nthe actual command output",
            beyond: sent
        ))
    }

    // MARK: - Heartbeat completion detection

    /// The heartbeat disarms only when the reply ENDS with the exact token — the prompts
    /// contract on "end your reply with TASK COMPLETE", so detection is suffix-anchored
    /// after trimming trailing whitespace and punctuation. A paraphrase, a lowercase
    /// echo, or a mid-reply mention must keep monitoring alive rather than silently
    /// ending it.
    func testTaskCompleteTokenIsDetectedExactly() {
        // Suffix-anchored completions, including common trailing decoration.
        XCTAssertTrue(AgentRuntime.containsTaskComplete("All checks passed. TASK COMPLETE"))
        XCTAssertTrue(AgentRuntime.containsTaskComplete("TASK COMPLETE"))
        XCTAssertTrue(AgentRuntime.containsTaskComplete("TASK COMPLETE."))
        XCTAssertTrue(AgentRuntime.containsTaskComplete("**TASK COMPLETE**"))
        XCTAssertTrue(AgentRuntime.containsTaskComplete("Done. TASK COMPLETE \n"))
        XCTAssertTrue(AgentRuntime.containsTaskComplete("Build verified. \"TASK COMPLETE!\""))
        // A mention that doesn't END the reply must not complete — this embedded form
        // counted under the old contains() semantics, which was the bug.
        XCTAssertFalse(AgentRuntime.containsTaskComplete("TASK COMPLETE — build succeeded and tests are green."))
        XCTAssertFalse(AgentRuntime.containsTaskComplete("TASK COMPLETE is what I will say later"))
        // The live-proven false positive: a reply that merely restates the contract
        // must not disarm the app's monitor (or shut the daemon down).
        XCTAssertFalse(AgentRuntime.containsTaskComplete("I will only reply TASK COMPLETE when instructed..."))
        XCTAssertFalse(AgentRuntime.containsTaskComplete("task complete"))
        XCTAssertFalse(AgentRuntime.containsTaskComplete("Task Complete"))
        XCTAssertFalse(AgentRuntime.containsTaskComplete("The task is nearly COMPLETE."))
        XCTAssertFalse(AgentRuntime.containsTaskComplete(""))
    }

    /// The prompt still contracts on the exact token — replacing the heartbeat text with
    /// the reflective version must not change the completion protocol.
    @MainActor
    func testReflectiveHeartbeatPromptKeepsTheCompletionContract() {
        XCTAssertTrue(AgentRuntime.heartbeatPrompt.hasPrefix("[heartbeat]"))
        XCTAssertTrue(AgentRuntime.heartbeatPrompt.contains("TASK COMPLETE"))
        XCTAssertTrue(AgentRuntime.heartbeatPrompt.contains("request_input"))
    }

    // MARK: - Monitoring auto-resume

    func testAutoResumeRequiresArmedAutoModeHeartbeatAndMatchingDeviceServer() {
        XCTAssertTrue(AgentRuntime.shouldAutoResume(
            monitoringArmed: true, mode: .auto, heartbeatSeconds: 30,
            deviceMatches: true, serverMatches: true
        ))
        XCTAssertFalse(AgentRuntime.shouldAutoResume(
            monitoringArmed: false, mode: .auto, heartbeatSeconds: 30,
            deviceMatches: true, serverMatches: true
        ))
        XCTAssertFalse(AgentRuntime.shouldAutoResume(
            monitoringArmed: true, mode: .manual, heartbeatSeconds: 30,
            deviceMatches: true, serverMatches: true
        ))
        XCTAssertFalse(AgentRuntime.shouldAutoResume(
            monitoringArmed: true, mode: .auto, heartbeatSeconds: 0,
            deviceMatches: true, serverMatches: true
        ))
        // The armed flag syncs across devices, but only the arming device may resume…
        XCTAssertFalse(AgentRuntime.shouldAutoResume(
            monitoringArmed: true, mode: .auto, heartbeatSeconds: 30,
            deviceMatches: false, serverMatches: true
        ))
        // …and only against the server the monitor was watching.
        XCTAssertFalse(AgentRuntime.shouldAutoResume(
            monitoringArmed: true, mode: .auto, heartbeatSeconds: 30,
            deviceMatches: true, serverMatches: false
        ))
    }

    /// The console toggle's start/stop is what writes the durable armed state — flag
    /// plus the device/server binding a resume is gated on — so a relaunch knows
    /// whether, where, and for which server a monitor was live when the process died.
    @MainActor
    func testHeartbeatTogglePersistsArmedStateOnAgent() {
        let agent = Agent(name: "Fin", defaultMode: .auto, heartbeatSeconds: 30)
        let serverID = UUID()
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: serverID),
            serverName: "box"
        )
        XCTAssertFalse(agent.monitoringArmed)

        runtime.isMonitoring = true
        XCTAssertTrue(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, DeviceIdentity.id)
        XCTAssertEqual(agent.monitoringServerID, serverID)
        runtime.isMonitoring = false
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, "")
        XCTAssertNil(agent.monitoringServerID)

        // Every teardown path disarms: leaving auto mode…
        runtime.isMonitoring = true
        runtime.mode = .manual
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertFalse(runtime.isMonitoring)

        // …and cancel.
        runtime.mode = .auto
        runtime.isMonitoring = true
        runtime.cancel()
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, "")
        XCTAssertNil(agent.monitoringServerID)
        XCTAssertFalse(runtime.isMonitoring)
    }

    /// Teardown of a replaced/discarded runtime suspends — the loop dies but the
    /// persisted armed state survives so a later runtime auto-resumes it. Only a
    /// user-intent stop clears the persisted state.
    @MainActor
    func testSuspendKeepsPersistedArmedStateAndStopClearsIt() {
        let agent = Agent(name: "Fin", defaultMode: .auto, heartbeatSeconds: 30)
        let serverID = UUID()
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: serverID),
            serverName: "box"
        )

        runtime.isMonitoring = true
        runtime.suspend()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertTrue(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, DeviceIdentity.id)
        XCTAssertEqual(agent.monitoringServerID, serverID)

        runtime.isMonitoring = true
        runtime.stopHeartbeat()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, "")
        XCTAssertNil(agent.monitoringServerID)
    }

    /// The edit sheet has no runtime, so its mode setter must disarm the persisted
    /// monitor itself when leaving auto — otherwise the armed flag strands true and a
    /// later flip back to auto resurrects a dead monitor.
    @MainActor
    func testEditingModeAwayFromAutoDisarmsPersistedMonitor() {
        let agent = Agent(name: "Fin", defaultMode: .auto, heartbeatSeconds: 30)
        agent.monitoringArmed = true
        agent.monitoringDeviceID = DeviceIdentity.id
        agent.monitoringServerID = UUID()

        agent.updateDefaultMode(.auto)
        XCTAssertTrue(agent.monitoringArmed)

        agent.updateDefaultMode(.manual)
        XCTAssertEqual(agent.defaultMode, .manual)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, "")
        XCTAssertNil(agent.monitoringServerID)
    }

    // MARK: - request_input tool spec

    func testRequestInputToolSpecIsRegistered() {
        XCTAssertTrue(AgentToolSpec.all.contains { $0.name == AgentToolSpec.requestInput.name })
        XCTAssertTrue(AgentToolSpec.knownToolNames.contains("request_input"))
        XCTAssertEqual(
            AgentToolSpec.requestInput.parameters["required"] as? [String],
            ["question"]
        )
    }

    func testMonitorToolSpecIsRegistered() {
        XCTAssertTrue(AgentToolSpec.all.contains { $0.name == AgentToolSpec.monitor.name })
        XCTAssertTrue(AgentToolSpec.knownToolNames.contains("monitor"))
        XCTAssertEqual(
            AgentToolSpec.monitor.parameters["required"] as? [String],
            ["action"]
        )
    }

    func testNotifyToolSpecIsRegistered() {
        XCTAssertTrue(AgentToolSpec.all.contains { $0.name == AgentToolSpec.notify.name })
        XCTAssertTrue(AgentToolSpec.knownToolNames.contains("notify"))
        XCTAssertEqual(
            (AgentToolSpec.notify.parameters["required"] as? [String]).map(Set.init),
            Set(["title", "body"])
        )
    }

    /// Fin's proactively-social persona rides in every composed system prompt (the app's
    /// notify tool always has a local-notification channel), and the guidance carries both
    /// halves of Levi's brief — social AND non-spammy.
    func testPersonaGuidanceIsPresentAndBalanced() {
        let guidance = AgentToolSpec.notifyPersonaGuidance
        XCTAssertTrue(guidance.contains("proactively social"))
        XCTAssertTrue(guidance.contains("notify tool"))
        XCTAssertTrue(guidance.lowercased().contains("never spam"))
        XCTAssertTrue(guidance.contains("heartbeat"), "must warn off firing on a heartbeat tick")
    }

    // MARK: - Consolidation guard

    func testConsolidationGuardRejectsGarbageProfiles() {
        // Too short to be a profile (refusals, "OK", fragments).
        XCTAssertFalse(AgentRuntime.acceptableConsolidatedProfile("short", replacing: ""))
        // Echo of the "(none)" placeholder the consolidation prompt itself injects.
        XCTAssertFalse(AgentRuntime.acceptableConsolidatedProfile(
            "Current profile: (none). The recent conversations contained nothing new to add.",
            replacing: ""
        ))
        // A degenerate repetition loop.
        XCTAssertFalse(AgentRuntime.acceptableConsolidatedProfile(
            String(repeating: "—", count: 60),
            replacing: ""
        ))
        // Shrinking a substantial profile by more than 70% is a bad reply, not a summary.
        let existing = String(repeating: "User is building Fin and prefers terse answers. ", count: 7) // ~336 chars
        let tinyReplacement = "User likes terse answers, ships from the terminal daily." // 56 < 30%
        XCTAssertFalse(AgentRuntime.acceptableConsolidatedProfile(tinyReplacement, replacing: existing))
    }

    func testConsolidationGuardAcceptsReasonableProfiles() {
        let fresh = "User is building Fin, an SSH terminal app; prefers terse answers and fish shell."
        XCTAssertTrue(AgentRuntime.acceptableConsolidatedProfile(fresh, replacing: ""))
        // A moderate shrink of a substantial profile is a legitimate distillation.
        let existing = String(repeating: "User is building Fin and prefers terse answers. ", count: 7)
        let distilled = String(repeating: "Building Fin; terse answers; fish shell; TestFlight beta. ", count: 3)
        XCTAssertTrue(AgentRuntime.acceptableConsolidatedProfile(distilled, replacing: existing))
    }

    // MARK: - Conversation adoption & mode write-back

    /// A relaunch with restored history must continue the same episodic record instead
    /// of fragmenting the conversation into one record per launch.
    @MainActor
    func testRuntimeAdoptsLatestOpenConversationWhenRestoringHistory() {
        let adopted = UUID()
        var access = AgentMemoryAccess.noop
        access.latestOpenConversation = { _ in (adopted, "earlier title", "Q: hi / A: hello") }

        let restored = AgentRuntime(
            agent: Agent(name: "Fin"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access,
            history: [AgentMessage(role: .user, text: "hi")]
        )
        XCTAssertEqual(restored.conversationID, adopted)

        // No restored history → a fresh conversation, not the open record.
        let fresh = AgentRuntime(
            agent: Agent(name: "Fin"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
        XCTAssertNotEqual(fresh.conversationID, adopted)

        // Clearing always mints a new identity, even after adoption.
        restored.clearConversation()
        XCTAssertNotEqual(restored.conversationID, adopted)
    }

    @MainActor
    func testConsoleModeChangeWritesBackToAgentDefaultMode() {
        let agent = Agent(name: "Fin", defaultMode: .manual)
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        XCTAssertEqual(runtime.mode, .manual)

        runtime.mode = .auto
        XCTAssertEqual(agent.defaultMode, .auto)
        runtime.mode = .manual
        XCTAssertEqual(agent.defaultMode, .manual)
    }

    // MARK: - Session routing prompt wiring

    /// The system prompt the runtime actually reset its transcript with — the composed
    /// prompt is private, but the transcript's system message is the same string and is
    /// what the model really sees.
    @MainActor
    private func systemPrompt(of runtime: AgentRuntime) -> String? {
        runtime.transcript.messages.first(where: { $0.role == .system })?.text
    }

    /// Bootstrap contract: with no registry file on disk, a runtime wired exactly like
    /// finApp wires it (readRoutingRegistry → loadIfPresent) composes a system prompt
    /// byte-identical to a runtime with no routing wired at all.
    @MainActor
    func testAbsentRoutingRegistryFileLeavesSystemPromptUnchanged() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-absent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(RegistryDocument.standardFileName)
        var access = AgentMemoryAccess.noop
        access.readRoutingRegistry = { RegistryDocument.loadIfPresent(at: missing) }

        let wired = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
        let unwired = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        XCTAssertEqual(systemPrompt(of: wired), "BASE PROMPT")
        XCTAssertEqual(systemPrompt(of: wired), systemPrompt(of: unwired))
    }

    /// A registry file on disk turns the routing section on, naming each registered
    /// session — and a file that appears after the runtime exists is picked up at the
    /// next conversation boundary (clearConversation), which is exactly the staleness
    /// window the finApp wiring documents.
    @MainActor
    func testRoutingRegistryFileEntersSystemPromptAtConversationBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RegistryDocument.standardFileName)

        var access = AgentMemoryAccess.noop
        access.readRoutingRegistry = { RegistryDocument.loadIfPresent(at: url) }
        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
        // No file at init → no routing section yet.
        XCTAssertEqual(systemPrompt(of: runtime), "BASE PROMPT")

        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin", cwd: "~/forges/levi/fin", tasks: ["fin", "widget"]),
            SessionRegistration(session: "pocketdj", tasks: ["dj", "audio engine"]),
        ])).write(to: url)

        runtime.clearConversation()
        let prompt = try XCTUnwrap(systemPrompt(of: runtime))
        // Routing is strictly additive: the base prompt survives untouched up front.
        XCTAssertTrue(prompt.hasPrefix("BASE PROMPT"))
        XCTAssertTrue(prompt.contains("Session routing:"))
        XCTAssertTrue(prompt.contains("fin"))
        XCTAssertTrue(prompt.contains("pocketdj"))
        XCTAssertTrue(prompt.contains("OFF-LIMITS"))
    }

    /// The path itself is part of the contract: docs tell users to drop the registry
    /// at Application Support/fin/routing-registry.json, so the URL the app actually
    /// reads (the one finApp hands to loadIfPresent) must resolve exactly there —
    /// same machine-scoped directory convention as VectorMemoryIndexManager, shared
    /// basename with fin-agentd.
    func testRoutingRegistryLocationFollowsAppSupportConvention() {
        XCTAssertTrue(
            RoutingRegistryLocation.fileURL.path
                .hasSuffix("/Application Support/fin/routing-registry.json")
        )
    }

    // MARK: - Goals ledger prompt wiring

    /// Bootstrap contract: with no ledger file on disk, a runtime wired exactly like
    /// finApp wires it (readGoalsLedger → loadIfPresent) composes a system prompt
    /// byte-identical to a runtime with no goals wired at all.
    @MainActor
    func testAbsentGoalsLedgerFileLeavesSystemPromptUnchanged() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-absent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(LedgerDocument.standardFileName)
        var access = AgentMemoryAccess.noop
        access.readGoalsLedger = { LedgerDocument.loadIfPresent(at: missing) }

        let wired = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
        let unwired = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        XCTAssertEqual(systemPrompt(of: wired), "BASE PROMPT")
        XCTAssertEqual(systemPrompt(of: wired), systemPrompt(of: unwired))
    }

    /// A ledger file on disk turns the mission section on, naming each goal — and a
    /// file that appears after the runtime exists is picked up at the next
    /// conversation boundary (clearConversation), the same staleness window as the
    /// routing registry. With both files present the mission renders AFTER the
    /// routing section, matching the daemon's order.
    @MainActor
    func testGoalsLedgerFileEntersSystemPromptAtConversationBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent(LedgerDocument.standardFileName)
        let registryURL = directory.appendingPathComponent(RegistryDocument.standardFileName)

        var access = AgentMemoryAccess.noop
        access.readGoalsLedger = { LedgerDocument.loadIfPresent(at: ledgerURL) }
        access.readRoutingRegistry = { RegistryDocument.loadIfPresent(at: registryURL) }
        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", systemPrompt: "BASE PROMPT"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            memory: access
        )
        // No files at init → no mission section yet.
        XCTAssertEqual(systemPrompt(of: runtime), "BASE PROMPT")

        try JSONEncoder().encode(LedgerDocument(goals: [
            Goal(id: "g-voice-intent", title: "Ship the voice intent flow", state: .active),
            Goal(id: "g-appstore-rejection", title: "Clear the App Store 2.1 rejection", state: .blocked),
        ])).write(to: ledgerURL)
        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin", tasks: ["fin", "widget"]),
        ])).write(to: registryURL)

        runtime.clearConversation()
        let prompt = try XCTUnwrap(systemPrompt(of: runtime))
        // Goals are strictly additive: the base prompt survives untouched up front.
        XCTAssertTrue(prompt.hasPrefix("BASE PROMPT"))
        XCTAssertTrue(prompt.contains("Mission ledger:"))
        XCTAssertTrue(prompt.contains("Ship the voice intent flow"))
        XCTAssertTrue(prompt.contains("Clear the App Store 2.1 rejection"))
        let routing = try XCTUnwrap(prompt.range(of: "Session routing:"))
        let mission = try XCTUnwrap(prompt.range(of: "Mission ledger:"))
        XCTAssertTrue(routing.lowerBound < mission.lowerBound)
    }

    /// The path itself is part of the contract: the app reads the ledger at
    /// Application Support/fin/goals-ledger.json — same directory convention as the
    /// routing registry, shared basename with fin-agentd.
    func testGoalsLedgerLocationFollowsAppSupportConvention() {
        XCTAssertTrue(
            GoalsLedgerLocation.fileURL.path
                .hasSuffix("/Application Support/fin/goals-ledger.json")
        )
    }

    /// The beat-text fork: no ledger (or an empty one) keeps the reflective heartbeat
    /// byte-identical; a ledger with goals swaps in the mission tick, which preserves
    /// the "[heartbeat]" prefix and the completion contract while carrying the goals.
    func testHeartbeatTextSwapsToMissionTickOnlyWhenLedgerPresent() {
        XCTAssertEqual(
            AgentRuntime.heartbeatPromptText(goals: nil),
            AgentRuntime.heartbeatPrompt
        )
        XCTAssertEqual(
            AgentRuntime.heartbeatPromptText(goals: LedgerDocument()),
            AgentRuntime.heartbeatPrompt
        )

        let tick = AgentRuntime.heartbeatPromptText(goals: LedgerDocument(goals: [
            Goal(id: "g-voice-intent", title: "Ship the voice intent flow", state: .active),
        ]))
        XCTAssertNotEqual(tick, AgentRuntime.heartbeatPrompt)
        XCTAssertTrue(tick.hasPrefix("[heartbeat]"))
        XCTAssertTrue(tick.contains("TASK COMPLETE"))
        XCTAssertTrue(tick.contains("request_input"))
        XCTAssertTrue(tick.contains("Ship the voice intent flow"))
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
        // The newest exchange is the one still in play and must never be trimmed away.
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

    /// A `tool` message references a call by id; most endpoints reject one whose matching
    /// assistant turn is no longer in the payload, so trimming must not strand it at the head.
    func testCompactionNeverLeavesAnOrphanedToolResultAtTheHead() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "SYSTEM")
        for index in 0..<25 {
            let call = AgentToolCall(id: "call\(index)", name: "read_terminal", arguments: "{}")
            transcript.append(AgentMessage(role: .user, text: String(repeating: "q", count: 300)))
            transcript.append(AgentMessage(role: .assistant, text: "", toolCalls: [call]))
            transcript.append(AgentMessage(
                role: .tool,
                text: String(repeating: "r", count: 300),
                toolCallID: call.id
            ))
        }

        transcript.compactIfNeeded(budget: 900)

        let conversational = transcript.wireMessages.drop { $0.role == .system }
        XCTAssertNotEqual(
            conversational.first?.role, .tool,
            "a tool result must not be the first non-system message after trimming"
        )
    }

    // MARK: - Endpoint URL handling

    func testAcceptsBaseAndFullCompletionURLs() async {
        // Both spellings are common in the wild; neither should be rejected outright.
        for base in ["http://100.64.0.1:1234/v1", "http://100.64.0.1:1234/v1/chat/completions"] {
            let client = AgentEndpointClient(
                baseURL: base,
                model: "m",
                apiKey: nil,
                temperature: 0,
                maxOutputTokens: 16
            )
            do {
                _ = try await client.complete(messages: [], tools: [])
                XCTFail("expected a transport failure against an unreachable host")
            } catch AgentEndpointError.badURL {
                XCTFail("\(base) should parse as a valid endpoint")
            } catch {
                // Any other error means the URL parsed and a request was attempted.
            }
        }
    }

    func testRejectsEmptyEndpoint() async {
        let client = AgentEndpointClient(
            baseURL: "   ",
            model: "m",
            apiKey: nil,
            temperature: 0,
            maxOutputTokens: 16
        )
        do {
            _ = try await client.complete(messages: [], tools: [])
            XCTFail("expected badURL")
        } catch AgentEndpointError.badURL {
            // expected
        } catch {
            XCTFail("expected badURL, got \(error)")
        }
    }

    // MARK: - Watchdog decisions

    /// A fixed "now" so every interval in these tables is exact, not racing the clock.
    private static let tickNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Defaults describe a healthy armed monitor mid-flight; each case overrides only
    /// what it is about. `idleSince` defaults past the arm delay so the arm cases
    /// exercise their own gates; `configurationBlockedCheck` lets N5's laziness
    /// tests observe whether the availability query ran at all.
    private func watchdogActions(
        armed: Bool = true,
        deviceMatches: Bool = true,
        serverMatches: Bool = true,
        mode: AgentMode = .auto,
        heartbeatSeconds: Int = 60,
        heartbeatRunning: Bool = true,
        autoResumePending: Bool = false,
        sessionConnected: Bool = true,
        conversationUnfinished: Bool = false,
        conversationStale: Bool = false,
        idleSince: Date? = AgentLogicTests.tickNow.addingTimeInterval(-61),
        suppressed: Bool = false,
        configurationBlocked: Bool = false,
        state: AgentWatchdog.StateKind = .idle,
        failedSince: Date? = nil,
        thinkingSince: Date? = nil,
        wedgeNoticePosted: Bool = false,
        lastHeartbeatAt: Date? = AgentLogicTests.tickNow.addingTimeInterval(-10),
        lastRecoveryAt: Date? = nil,
        recoveryFailures: Int = 0,
        now: Date = AgentLogicTests.tickNow,
        configurationBlockedCheck: (() -> Bool)? = nil
    ) -> [AgentWatchdog.Action] {
        AgentWatchdog.evaluate(
            armed: armed,
            deviceMatches: deviceMatches,
            serverMatches: serverMatches,
            mode: mode,
            heartbeatSeconds: heartbeatSeconds,
            heartbeatRunning: heartbeatRunning,
            autoResumePending: autoResumePending,
            sessionConnected: sessionConnected,
            conversationUnfinished: conversationUnfinished,
            conversationStale: conversationStale,
            idleSince: idleSince,
            suppressed: suppressed,
            state: state,
            failedSince: failedSince,
            thinkingSince: thinkingSince,
            wedgeNoticePosted: wedgeNoticePosted,
            lastHeartbeatAt: lastHeartbeatAt,
            lastRecoveryAt: lastRecoveryAt,
            recoveryFailures: recoveryFailures,
            now: now,
            configurationBlocked: configurationBlockedCheck ?? { configurationBlocked }
        )
    }

    func testWatchdogAllQuietDoesNothing() {
        XCTAssertEqual(watchdogActions(), [])
        // Never armed: nothing to resume, recover, or refire.
        XCTAssertEqual(watchdogActions(armed: false, heartbeatRunning: false), [])
        // Armed but no beat has fired yet: the running loop's first beat is pending,
        // not overdue.
        XCTAssertEqual(watchdogActions(lastHeartbeatAt: nil), [])
    }

    func testWatchdogResumesDiedLoop() {
        XCTAssertEqual(watchdogActions(heartbeatRunning: false), [.resumeMonitoring])
        // A pending auto-resume poll is already handling it.
        XCTAssertEqual(
            watchdogActions(heartbeatRunning: false, autoResumePending: true),
            []
        )
        // The armed flag syncs across devices; only the arming device may act.
        XCTAssertEqual(
            watchdogActions(deviceMatches: false, heartbeatRunning: false),
            []
        )
        XCTAssertEqual(
            watchdogActions(serverMatches: false, heartbeatRunning: false),
            []
        )
        // Manual mode or a disabled interval means monitoring must not run at all.
        XCTAssertEqual(watchdogActions(mode: .manual, heartbeatRunning: false), [])
        XCTAssertEqual(
            watchdogActions(heartbeatSeconds: 0, heartbeatRunning: false),
            []
        )
    }

    func testWatchdogRecoversPersistentFailureAfterDelay() {
        let stale = Self.tickNow.addingTimeInterval(-31)
        let fresh = Self.tickNow.addingTimeInterval(-10)
        XCTAssertEqual(
            watchdogActions(state: .failed, failedSince: stale),
            [.recoveryHeartbeat]
        )
        // Too fresh: the heartbeat loop's own next-beat retry gets first refusal.
        XCTAssertEqual(watchdogActions(state: .failed, failedSince: fresh), [])
    }

    func testWatchdogRateLimitsRecovery() {
        let stale = Self.tickNow.addingTimeInterval(-120)
        XCTAssertEqual(
            watchdogActions(
                state: .failed,
                failedSince: stale,
                lastRecoveryAt: Self.tickNow.addingTimeInterval(-30)
            ),
            [],
            "a hard-down endpoint must not be hammered every tick"
        )
        XCTAssertEqual(
            watchdogActions(
                state: .failed,
                failedSince: stale,
                lastRecoveryAt: Self.tickNow.addingTimeInterval(-61)
            ),
            [.recoveryHeartbeat]
        )
    }

    /// The cooldown is `max(60, heartbeatSeconds)`: a user who chose a slow heartbeat
    /// chose that cadence for model calls generally, so recovery must respect it
    /// instead of hammering every 60s regardless.
    func testWatchdogRecoveryCooldownScalesWithHeartbeatInterval() {
        XCTAssertEqual(AgentWatchdog.recoveryCooldown(heartbeatSeconds: 0), 60)
        XCTAssertEqual(AgentWatchdog.recoveryCooldown(heartbeatSeconds: 30), 60)
        XCTAssertEqual(AgentWatchdog.recoveryCooldown(heartbeatSeconds: 60), 60)
        XCTAssertEqual(AgentWatchdog.recoveryCooldown(heartbeatSeconds: 1800), 1800)

        let stale = Self.tickNow.addingTimeInterval(-7200)
        XCTAssertEqual(
            watchdogActions(
                heartbeatSeconds: 1800,
                state: .failed,
                failedSince: stale,
                lastRecoveryAt: Self.tickNow.addingTimeInterval(-600)
            ),
            [],
            "a 30-minute heartbeat means 30-minute recovery pacing"
        )
        XCTAssertEqual(
            watchdogActions(
                heartbeatSeconds: 1800,
                state: .failed,
                failedSince: stale,
                lastRecoveryAt: Self.tickNow.addingTimeInterval(-1801)
            ),
            [.recoveryHeartbeat]
        )
    }

    func testWatchdogPausesRecoveryAtTheFailureCap() {
        let stale = Self.tickNow.addingTimeInterval(-3600)
        XCTAssertEqual(
            watchdogActions(state: .failed, failedSince: stale, recoveryFailures: 4),
            [.recoveryHeartbeat]
        )
        XCTAssertEqual(
            watchdogActions(state: .failed, failedSince: stale, recoveryFailures: 5),
            [],
            "five straight failed recoveries pause auto-recovery until the user interacts"
        )
        XCTAssertEqual(AgentWatchdog.maxRecoveryFailures, 5)
    }

    func testWatchdogFiresOverdueBeatImmediately() {
        // Overdue means more than one full interval late: last fired > 2×interval ago.
        XCTAssertEqual(
            watchdogActions(lastHeartbeatAt: Self.tickNow.addingTimeInterval(-121)),
            [.overdueHeartbeat]
        )
        XCTAssertEqual(
            watchdogActions(lastHeartbeatAt: Self.tickNow.addingTimeInterval(-119)),
            []
        )
        // A dead loop is the resume action's problem, not a beat to fire blind.
        XCTAssertEqual(
            watchdogActions(
                heartbeatRunning: false,
                lastHeartbeatAt: Self.tickNow.addingTimeInterval(-121)
            ),
            [.resumeMonitoring]
        )
        // A busy runtime's in-flight turn is its own progress report.
        XCTAssertEqual(
            watchdogActions(
                state: .thinking,
                thinkingSince: Self.tickNow.addingTimeInterval(-5),
                lastHeartbeatAt: Self.tickNow.addingTimeInterval(-121)
            ),
            []
        )
    }

    func testWatchdogNoticesThinkingWedgeOncePerEpisode() {
        let wedged = Self.tickNow.addingTimeInterval(-601)
        XCTAssertEqual(
            watchdogActions(state: .thinking, thinkingSince: wedged),
            [.thinkingWedgeNotice]
        )
        XCTAssertEqual(
            watchdogActions(state: .thinking, thinkingSince: wedged, wedgeNoticePosted: true),
            [],
            "one notice per wedge episode"
        )
        XCTAssertEqual(
            watchdogActions(
                state: .thinking,
                thinkingSince: Self.tickNow.addingTimeInterval(-300)
            ),
            []
        )
        // Not gated on monitoring: a user-submitted turn can wedge too.
        XCTAssertEqual(
            watchdogActions(armed: false, state: .thinking, thinkingSince: wedged),
            [.thinkingWedgeNotice]
        )
    }

    /// The field-failure case: an auto-mode agent that never called its monitor tool
    /// sits idle mid-task — the tick arms the monitor for it.
    func testWatchdogArmsIdleUnfinishedConversation() {
        XCTAssertEqual(
            watchdogActions(armed: false, heartbeatRunning: false, conversationUnfinished: true),
            [.armIdleUnfinished]
        )
        // heartbeatSeconds is not a gate here: the runtime supplies the same 60s
        // default the monitor tool's start path picks.
        XCTAssertEqual(
            watchdogActions(
                armed: false,
                heartbeatSeconds: 0,
                heartbeatRunning: false,
                conversationUnfinished: true
            ),
            [.armIdleUnfinished]
        )
        // One failed recovery short of the cap still arms.
        XCTAssertEqual(
            watchdogActions(
                armed: false,
                heartbeatRunning: false,
                conversationUnfinished: true,
                recoveryFailures: 4
            ),
            [.armIdleUnfinished]
        )
    }

    /// Every gate suppresses the arm on its own against the firing baseline.
    func testWatchdogArmIdleUnfinishedSuppressedByEachGate() {
        // Already armed: the resume/overdue paths own it, self-arming never fires.
        XCTAssertEqual(watchdogActions(conversationUnfinished: true), [])
        XCTAssertFalse(
            watchdogActions(heartbeatRunning: false, conversationUnfinished: true)
                .contains(.armIdleUnfinished)
        )
        // Manual mode must never self-arm — no self-escalation out of approval mode.
        XCTAssertEqual(
            watchdogActions(
                armed: false, mode: .manual,
                heartbeatRunning: false, conversationUnfinished: true
            ),
            []
        )
        // Only a genuinely idle runtime is wedged; anything in flight is progress.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                state: .thinking, thinkingSince: Self.tickNow.addingTimeInterval(-5)
            ),
            []
        )
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                state: .awaitingApproval
            ),
            []
        )
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                state: .failed, failedSince: Self.tickNow.addingTimeInterval(-60)
            ),
            []
        )
        // A live loop or a pending resume poll is already handling it.
        XCTAssertEqual(
            watchdogActions(armed: false, heartbeatRunning: true, conversationUnfinished: true),
            []
        )
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                autoResumePending: true, conversationUnfinished: true
            ),
            []
        )
        // A heartbeat against a dead terminal only fails.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                sessionConnected: false, conversationUnfinished: true
            ),
            []
        )
        // Finished (or empty) conversation: nothing to unwedge.
        XCTAssertEqual(
            watchdogActions(armed: false, heartbeatRunning: false, conversationUnfinished: false),
            []
        )
        // A suppression stamped by any disarm is never fought — THE INVARIANT: the
        // watchdog may only auto-arm when the newest user-intent event postdates
        // the last disarm.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                conversationUnfinished: true, suppressed: true
            ),
            []
        )
        // A stale conversation is history, not work in flight.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                conversationUnfinished: true, conversationStale: true
            ),
            []
        )
        // A blocked configuration's beats are guaranteed no-ops; arming would only
        // leave a permanently armed loop that silently does nothing.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                conversationUnfinished: true, configurationBlocked: true
            ),
            []
        )
        // The recovery pause cap applies to self-arming too.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false,
                conversationUnfinished: true, recoveryFailures: 5
            ),
            []
        )
    }

    /// The arm waits out `idleArmDelay`: rapid back-and-forth chat (idle for
    /// seconds between turns) never self-arms; only a conversation idle-unfinished
    /// for a full minute gets the reflective check.
    func testWatchdogArmWaitsOutTheIdleDelay() {
        XCTAssertEqual(AgentWatchdog.idleArmDelay, 60)
        // Just answered — the user is right there.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                idleSince: Self.tickNow.addingTimeInterval(-5)
            ),
            []
        )
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                idleSince: Self.tickNow.addingTimeInterval(-59)
            ),
            []
        )
        // At and past the threshold the walked-away conversation arms.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                idleSince: Self.tickNow.addingTimeInterval(-60)
            ),
            [.armIdleUnfinished]
        )
        // No idle stamp at all (the runtime is mid-something) never arms.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                idleSince: nil
            ),
            []
        )
    }

    /// The configuration gate is a closure consulted only after every other arm
    /// gate passes — for on-device agents it queries FoundationModels availability,
    /// which the quiet 5s tick must never do.
    func testWatchdogConfigurationGateIsConsultedLazily() {
        var consulted = false
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                configurationBlockedCheck: { consulted = true; return false }
            ),
            [.armIdleUnfinished]
        )
        XCTAssertTrue(consulted, "an otherwise-armable tick does consult the gate")

        // All-quiet armed baseline: never consulted.
        XCTAssertEqual(
            watchdogActions(configurationBlockedCheck: {
                XCTFail("the all-quiet tick must not query availability")
                return false
            }),
            []
        )
        // Each cheaper gate rules the tick out first.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                suppressed: true,
                configurationBlockedCheck: {
                    XCTFail("a suppressed conversation must not query availability")
                    return false
                }
            ),
            []
        )
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                idleSince: Self.tickNow.addingTimeInterval(-5),
                configurationBlockedCheck: {
                    XCTFail("a freshly-idle conversation must not query availability")
                    return false
                }
            ),
            []
        )
        // And a blocked configuration still refuses the arm.
        XCTAssertEqual(
            watchdogActions(
                armed: false, heartbeatRunning: false, conversationUnfinished: true,
                configurationBlockedCheck: { true }
            ),
            []
        )
    }

    func testConsolidationDailyFloor() {
        let now = Self.tickNow
        // Never succeeded and memories are waiting: due.
        XCTAssertTrue(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil, lastAttemptAt: nil, isBusy: false, now: now,
            hasUnconsolidatedMemories: { true }
        ))
        XCTAssertTrue(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: now.addingTimeInterval(-25 * 60 * 60),
            lastAttemptAt: now.addingTimeInterval(-31 * 60),
            isBusy: false, now: now,
            hasUnconsolidatedMemories: { true }
        ))
        // Succeeded recently: the post-turn pacing path owns it.
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: now.addingTimeInterval(-23 * 60 * 60),
            lastAttemptAt: nil, isBusy: false, now: now,
            hasUnconsolidatedMemories: { true }
        ))
        // A recent attempt paces the floor too — dispatching would just no-op
        // against the machinery's own 30-minute stamp.
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil,
            lastAttemptAt: now.addingTimeInterval(-10 * 60),
            isBusy: false, now: now,
            hasUnconsolidatedMemories: { true }
        ))
        // Nothing unconsolidated: nothing to run.
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil, lastAttemptAt: nil, isBusy: false, now: now,
            hasUnconsolidatedMemories: { false }
        ))
        // Mid-turn: skip, retry next tick.
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil, lastAttemptAt: nil, isBusy: true, now: now,
            hasUnconsolidatedMemories: { true }
        ))
    }

    /// The memories check costs a SwiftData fetch, so the free checks must rule the
    /// tick out before it ever runs — the all-quiet 5s tick does zero I/O.
    func testConsolidationDailyFloorConsultsMemoriesLazily() {
        let now = Self.tickNow
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: now.addingTimeInterval(-60), lastAttemptAt: nil,
            isBusy: false, now: now,
            hasUnconsolidatedMemories: {
                XCTFail("a satisfied 24h stamp must skip the candidates fetch")
                return true
            }
        ))
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil, lastAttemptAt: now.addingTimeInterval(-60),
            isBusy: false, now: now,
            hasUnconsolidatedMemories: {
                XCTFail("a fresh pacing stamp must skip the candidates fetch")
                return true
            }
        ))
        XCTAssertFalse(AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: nil, lastAttemptAt: nil, isBusy: true, now: now,
            hasUnconsolidatedMemories: {
                XCTFail("a busy runtime must skip the candidates fetch")
                return true
            }
        ))
    }

    // MARK: - Background-action audit trail

    /// Every background workflow action lands in the audit log with a greppable
    /// prefix. The console toggle goes through its own mediator so the trail shows
    /// *who* armed the monitor — console, tool, or auto-resume.
    @MainActor
    func testConsoleToggleRecordsAuditEntries() {
        var records: [AgentLogRecord] = []
        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", defaultMode: .auto, heartbeatSeconds: 30),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { records.append($0) }
        )

        runtime.toggleMonitoringFromConsole()
        XCTAssertTrue(runtime.isMonitoring)
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[monitor] armed by console toggle"
        })

        runtime.toggleMonitoringFromConsole()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[monitor] disarmed by console toggle"
        })
    }

    /// A dead loop for an armed monitor is handed to the resume poll — and audited.
    @MainActor
    func testWatchdogRecordsResumingADeadMonitorLoop() {
        var records: [AgentLogRecord] = []
        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", defaultMode: .auto, heartbeatSeconds: 60),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { records.append($0) }
        )
        // Arm (persists the device/server binding), then kill the loop the way a
        // teardown does — armed state survives, loop dead, no resume poll running.
        runtime.isMonitoring = true
        runtime.suspendHeartbeat()

        runtime.watchdogTick()

        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[watchdog] resumed a dead monitor loop"
        })
        XCTAssertTrue(runtime.isAutoResumePending, "the tick hands the dead loop to the resume poll")
    }

    /// Five watchdog recovery turns failing in a row pause auto-recovery, with the
    /// audit trail carrying every attempt and the pause; user attention resets it.
    /// Driven through a configuration-blocked endpoint agent, so every "turn" fails
    /// immediately without a model call or a live session.
    @MainActor
    func testWatchdogRecoveryAuditsAttemptsAndPausesAfterFiveFailures() async {
        var records: [AgentLogRecord] = []
        let serverID = UUID()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible, // no endpoint URL → configurationBlocker
            defaultMode: .auto,
            heartbeatSeconds: 60
        )
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: serverID),
            serverName: "box",
            log: { records.append($0) }
        )
        // Persisted monitor state, as a live monitor would have written it.
        agent.monitoringArmed = true
        agent.monitoringDeviceID = DeviceIdentity.id
        agent.monitoringServerID = serverID

        runtime.submit("hi") // blocked → .failed, stamping failedSince
        guard case .failed = runtime.state else {
            return XCTFail("expected the blocked agent to fail the turn synchronously")
        }

        func recoveryRecords() -> [String] {
            records.map(\.text).filter { $0.hasPrefix("[watchdog] recovery heartbeat") }
        }

        var now = Date().addingTimeInterval(31)
        for attempt in 1...5 {
            runtime.watchdogTick(now: now)
            // The escalated turn runs in the runtime's own task; let it finish.
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(runtime.consecutiveRecoveryFailures, attempt)
            XCTAssertTrue(recoveryRecords().contains(
                "[watchdog] recovery heartbeat after failure (attempt \(attempt))"
            ))
            now = now.addingTimeInterval(90)
        }
        XCTAssertTrue(records.map(\.text).contains(
            "[watchdog] auto-recovery paused after 5 failed attempts"
        ))

        // Past the cap the watchdog stays quiet…
        runtime.watchdogTick(now: now)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recoveryRecords().count, 5)

        // …until user attention resets the budget.
        runtime.resetRecoveryBackoff()
        runtime.watchdogTick(now: now.addingTimeInterval(90))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recoveryRecords().count, 6)
        XCTAssertEqual(runtime.consecutiveRecoveryFailures, 1)
    }

    // MARK: - Idle-unfinished self-arm (runtime)

    /// `conversationUnfinished` is computed from the in-memory transcript alone: real
    /// conversation exists and the last real assistant reply didn't declare
    /// TASK COMPLETE. Notices and heartbeat rows never count as replies.
    @MainActor
    func testConversationUnfinishedComputation() {
        func makeRuntime(_ history: [AgentMessage]) -> AgentRuntime {
            AgentRuntime(
                agent: Agent(name: "Fin"),
                session: TerminalSession(serverID: UUID()),
                serverName: "box",
                history: history
            )
        }
        // Empty transcript: nothing in flight.
        XCTAssertFalse(makeRuntime([]).conversationUnfinished)
        // A trailing user message with no reply is unfinished work.
        XCTAssertTrue(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
        ]).conversationUnfinished)
        // A tool-call-only assistant turn is mid-loop, not an answer.
        XCTAssertTrue(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(
                role: .assistant,
                text: "",
                toolCalls: [AgentToolCall(id: "c1", name: "read_terminal", arguments: "{}")]
            ),
        ]).conversationUnfinished)
        // TASK COMPLETE finishes it — suffix-anchored, so trailing whitespace or
        // punctuation still completes…
        XCTAssertFalse(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "All green. TASK COMPLETE \n"),
        ]).conversationUnfinished)
        XCTAssertFalse(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "Deploy verified on both hosts. **TASK COMPLETE**"),
        ]).conversationUnfinished)
        // …but a mid-reply mention does not: the reply didn't END with the token.
        XCTAssertTrue(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "TASK COMPLETE — deploy verified on both hosts."),
        ]).conversationUnfinished)
        // A paraphrase is not the token.
        XCTAssertTrue(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "task complete"),
        ]).conversationUnfinished)
        // A trailing user message after a completed reply is a submitted turn's
        // job — submit dispatches it immediately — not the watchdog's.
        XCTAssertFalse(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "TASK COMPLETE"),
            AgentMessage(role: .user, text: "now watch the logs"),
        ]).conversationUnfinished)
        // A new assistant reply past a completion reopens the conversation.
        XCTAssertTrue(makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "TASK COMPLETE"),
            AgentMessage(role: .user, text: "now watch the logs"),
            AgentMessage(role: .assistant, text: "Tailing them now."),
        ]).conversationUnfinished)
        // Local notices after the completing reply don't flip it back — this is
        // what lets a finished heartbeat conversation converge instead of re-arming.
        let finished = makeRuntime([
            AgentMessage(role: .user, text: "watch the deploy"),
            AgentMessage(role: .assistant, text: "TASK COMPLETE"),
        ])
        finished.cancel() // appends the "Stopped." local notice
        XCTAssertFalse(finished.conversationUnfinished)
    }

    /// Every disarm path stamps a durable suppression; only genuine user intent
    /// lifts it — THE INVARIANT the watchdog's auto-arm rests on.
    @MainActor
    func testSuppressionSetByEveryDisarmPathAndLiftedByUserIntent() {
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible, // no endpoint URL → submits fail fast
            defaultMode: .auto,
            heartbeatSeconds: 30
        )
        let suppressionKey = AgentRuntime.monitoringSuppressionKey(for: agent.id)
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        func disarmViaConsole() {
            runtime.toggleMonitoringFromConsole() // on
            runtime.toggleMonitoringFromConsole() // off → suppressed
            XCTAssertTrue(runtime.monitoringSuppressed)
        }
        XCTAssertFalse(runtime.monitoringSuppressed)

        // The console's off-path sets it — durably; toggling back on lifts it.
        runtime.toggleMonitoringFromConsole()
        XCTAssertFalse(runtime.monitoringSuppressed)
        runtime.toggleMonitoringFromConsole()
        XCTAssertTrue(runtime.monitoringSuppressed)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: suppressionKey))
        runtime.toggleMonitoringFromConsole()
        XCTAssertFalse(runtime.monitoringSuppressed)
        XCTAssertNil(UserDefaults.standard.object(forKey: suppressionKey))
        runtime.toggleMonitoringFromConsole()

        // Approve and reject are user intent.
        XCTAssertTrue(runtime.monitoringSuppressed)
        runtime.approvePendingCall()
        XCTAssertFalse(runtime.monitoringSuppressed)
        disarmViaConsole()
        runtime.rejectPendingCall()
        XCTAssertFalse(runtime.monitoringSuppressed)

        // A mode change supersedes the disarm.
        disarmViaConsole()
        runtime.mode = .manual
        XCTAssertFalse(runtime.monitoringSuppressed)

        // So does a submit — suppression lifts even though the blocked turn fails.
        runtime.mode = .auto
        disarmViaConsole()
        runtime.submit("hi")
        XCTAssertFalse(runtime.monitoringSuppressed)

        // Stop is a disarm (the only reachable one for a never-configured agent).
        runtime.cancel()
        XCTAssertTrue(runtime.monitoringSuppressed)
        runtime.submit("hi again")
        XCTAssertFalse(runtime.monitoringSuppressed)

        // The model's own sanctioned monitor-stop is a disarm too.
        _ = runtime.executeMonitor(action: "start", intervalSeconds: 30, rawArguments: "{}")
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")
        XCTAssertTrue(runtime.monitoringSuppressed)
        runtime.submit("once more")
        XCTAssertFalse(runtime.monitoringSuppressed)

        // A TASK COMPLETE conclusion holds against re-arming.
        runtime.toggleMonitoringFromConsole()
        runtime.concludeMonitoredTaskComplete()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertTrue(runtime.monitoringSuppressed)

        // Foreground-shaped attention is NOT user intent: neither the recovery
        // reset nor a watchdog tick lifts it.
        runtime.resetRecoveryBackoff()
        XCTAssertTrue(runtime.monitoringSuppressed)
        runtime.watchdogTick(isExplicit: true)
        XCTAssertTrue(runtime.monitoringSuppressed)
    }

    /// `request_input` means the agent is blocked on the user: the watchdog must
    /// not re-arm over the question (a notification per beat, forever), but an
    /// armed loop the console or tool sanctioned keeps running.
    @MainActor
    func testRequestInputSuppressesReArmWithoutDisarmingTheLoop() {
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            defaultMode: .auto,
            heartbeatSeconds: 30
        )
        let runtime = AgentRuntime(
            agent: agent,
            session: TerminalSession(serverID: UUID()),
            serverName: "box"
        )
        runtime.toggleMonitoringFromConsole() // console-armed loop
        XCTAssertTrue(runtime.isMonitoring)

        _ = runtime.executeRequestInput(question: "Which branch?", rawArguments: "{}")

        XCTAssertTrue(runtime.monitoringSuppressed, "blocked on the user → no watchdog re-arm")
        XCTAssertTrue(runtime.isMonitoring, "the sanctioned loop must keep running")
        XCTAssertTrue(agent.monitoringArmed)

        // The user's answer lifts the suppression.
        runtime.cancel() // ends the loop so the submit isn't racing a beat
        runtime.submit("main")
        XCTAssertFalse(runtime.monitoringSuppressed)
    }

    /// The suppression key outlives the runtime: a replacement (relaunch, server
    /// reopen, or a sync-driven `agents.first` change) reads it back at init, so a
    /// disarmed conversation stays disarmed until the user acts.
    @MainActor
    func testSuppressionPersistsAcrossRuntimeReplacement() async {
        let serverID = UUID()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: 60
        )
        let suppressionKey = AgentRuntime.monitoringSuppressionKey(for: agent.id)
        let history = [AgentMessage(role: .user, text: "watch the deploy")]

        let firstSession = TerminalSession(serverID: serverID)
        firstSession.simulateConnectedStateForTesting()
        let first = AgentRuntime(
            agent: agent, session: firstSession, serverName: "box", history: history
        )
        XCTAssertFalse(first.monitoringSuppressed)
        first.toggleMonitoringFromConsole() // arm
        first.toggleMonitoringFromConsole() // explicit disarm → durable suppression
        XCTAssertNotNil(UserDefaults.standard.object(forKey: suppressionKey))
        first.suspend() // replaced-runtime teardown

        // Same agent ID, fresh runtime: the persisted key is adopted at init and
        // holds the arm gate shut despite an unfinished conversation, a connected
        // session, and a runnable configuration.
        let secondSession = TerminalSession(serverID: serverID)
        secondSession.simulateConnectedStateForTesting()
        let second = AgentRuntime(
            agent: agent, session: secondSession, serverName: "box", history: history
        )
        XCTAssertTrue(second.monitoringSuppressed)
        XCTAssertFalse(
            second.watchdogTick(now: Date().addingTimeInterval(61), isExplicit: true),
            "a disarmed conversation stays disarmed — past the idle delay, suppression is the refusing gate"
        )
        XCTAssertFalse(second.isMonitoring)

        // The user's next message lifts it — durably.
        second.submit("hi")
        XCTAssertFalse(second.monitoringSuppressed)
        XCTAssertNil(UserDefaults.standard.object(forKey: suppressionKey))
        await drainMainActorTasks() // let the fast-failing submitted turn finish
    }

    /// The live field failure: an idle auto-mode agent mid-task that never called its
    /// monitor tool. The tick arms the monitor with the tool's own 60s default,
    /// audits it, and fires an immediate first beat through `runTask` — claiming the
    /// pass's single dispatch slot even with the consolidation floor also due.
    @MainActor
    func testWatchdogArmsIdleUnfinishedAgentWithImmediateBeat() async {
        let defaults = UserDefaults.standard
        let successBefore = defaults.object(forKey: AgentRuntime.lastConsolidationSuccessKey)
        let pacingBefore = defaults.object(forKey: AgentRuntime.lastConsolidationKey)
        defer {
            if let successBefore {
                defaults.set(successBefore, forKey: AgentRuntime.lastConsolidationSuccessKey)
            } else {
                defaults.removeObject(forKey: AgentRuntime.lastConsolidationSuccessKey)
            }
            if let pacingBefore {
                defaults.set(pacingBefore, forKey: AgentRuntime.lastConsolidationKey)
            } else {
                defaults.removeObject(forKey: AgentRuntime.lastConsolidationKey)
            }
        }
        // The daily floor is simultaneously due; the arm+beat must win the slot.
        defaults.removeObject(forKey: AgentRuntime.lastConsolidationSuccessKey)
        defaults.set(Date().addingTimeInterval(-31 * 60), forKey: AgentRuntime.lastConsolidationKey)

        var records: [AgentLogRecord] = []
        var access = AgentMemoryAccess.noop
        access.consolidationCandidates = { _ in
            [AgentMemoryHit(id: UUID(), title: "t", content: "c", tags: "", updatedAt: Date())]
        }
        let serverID = UUID()
        let session = TerminalSession(serverID: serverID)
        session.simulateConnectedStateForTesting()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            // Runnable (the arm gate requires no configuration blocker) but the
            // URL never parses, so the beat fails fast with no model call.
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: 0 // unset → the arm must supply the monitor tool's 60s default
        )
        let runtime = AgentRuntime(
            agent: agent,
            session: session,
            serverName: "box",
            log: { records.append($0) },
            memory: access,
            history: [AgentMessage(role: .user, text: "watch the build")]
        )

        // Ticks inside the idle-arm delay stay quiet — a conversation the user
        // just left gets a minute of grace before the reflective check.
        XCTAssertFalse(runtime.watchdogTick(isExplicit: false))
        XCTAssertFalse(runtime.isMonitoring)

        let armNow = Date().addingTimeInterval(AgentWatchdog.idleArmDelay + 1)
        let dispatched = runtime.watchdogTick(now: armNow, isExplicit: true)

        XCTAssertTrue(dispatched, "an arm+beat claims the pass's dispatch slot")
        XCTAssertTrue(runtime.isMonitoring)
        // The arm never mutates the synced config: the 60s default lives on the
        // runtime as the episode's effective interval.
        XCTAssertEqual(agent.heartbeatSeconds, 0)
        XCTAssertEqual(runtime.effectiveHeartbeatSeconds, 60)
        XCTAssertEqual(runtime.currentHeartbeatInterval, 60)
        XCTAssertTrue(agent.monitoringArmed)
        XCTAssertEqual(agent.monitoringDeviceID, DeviceIdentity.id)
        XCTAssertEqual(agent.monitoringServerID, serverID)
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[watchdog] agent idle with unfinished work — arming monitor loop"
        })
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[watchdog] foreground check — arming monitor loop"
        })
        // SessionManager's pass contract: the floor only runs when the tick
        // dispatched nothing — one dispatch per tick, so it stays untriggered here.
        if !dispatched { runtime.consolidateIfDailyFloorDue() }
        XCTAssertFalse(records.contains { $0.text == "[consolidation] daily floor triggered" })

        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(
            runtime.lastHeartbeatFiredAt,
            "the first beat fires immediately, not one interval out"
        )
    }

    /// An armable fixture: auto mode, connected session, unfinished conversation,
    /// and a runnable-but-unparseable endpoint so every beat fails fast offline —
    /// no network, no retries, no timers.
    @MainActor
    private func makeArmableRuntime(
        heartbeatSeconds: Int = 60,
        history: [AgentMessage] = [AgentMessage(role: .user, text: "watch the build")],
        log: @escaping (AgentLogRecord) -> Void = { _ in }
    ) -> (runtime: AgentRuntime, agent: Agent) {
        let session = TerminalSession(serverID: UUID())
        session.simulateConnectedStateForTesting()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: heartbeatSeconds
        )
        let runtime = AgentRuntime(
            agent: agent, session: session, serverName: "box", log: log, history: history
        )
        return (runtime, agent)
    }

    /// Spins the main actor until `condition` holds (or a generous cap), so tests
    /// can wait out a dispatched fast-failing turn without wall-clock sleeps.
    @MainActor
    private func drainUntil(_ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < 2000 {
            await Task.yield()
            iterations += 1
        }
    }

    /// A misconfigured auto agent passes no arm gate: arming it would create a
    /// permanently armed loop whose every beat no-ops at the configuration guard.
    @MainActor
    func testConfigurationBlockedAgentNeverArms() {
        var records: [AgentLogRecord] = []
        let session = TerminalSession(serverID: UUID())
        session.simulateConnectedStateForTesting()
        let runtime = AgentRuntime(
            agent: Agent(
                name: "Fin",
                provider: .openAICompatible, // no endpoint URL → configurationBlocker
                defaultMode: .auto,
                heartbeatSeconds: 60
            ),
            session: session,
            serverName: "box",
            log: { records.append($0) },
            history: [AgentMessage(role: .user, text: "watch the build")]
        )

        // Past the idle delay, so the configuration gate is the one refusing.
        XCTAssertFalse(runtime.watchdogTick(now: Date().addingTimeInterval(61), isExplicit: true))
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(records.contains { $0.text.contains("arming monitor loop") })
    }

    /// A conversation whose newest real message predates the 24h window is history:
    /// the watchdog refuses to arm and says so once per runtime, on explicit ticks
    /// only — never per 5s tick.
    @MainActor
    func testStaleConversationDoesNotArmAndAuditsOnce() {
        var records: [AgentLogRecord] = []
        let (runtime, _) = makeArmableRuntime(
            history: [AgentMessage(
                role: .user,
                text: "watch the deploy",
                timestamp: Date().addingTimeInterval(-25 * 60 * 60)
            )],
            log: { records.append($0) }
        )
        func staleLines() -> Int {
            records.filter { $0.text == "[watchdog] conversation stale — not arming" }.count
        }

        // Past the idle delay, so staleness is the gate doing the refusing.
        let now = Date().addingTimeInterval(61)
        // The quiet tick refuses silently.
        XCTAssertFalse(runtime.watchdogTick(now: now))
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertEqual(staleLines(), 0)

        // The explicit tick audits the refusal — once per runtime, not per tick.
        XCTAssertFalse(runtime.watchdogTick(now: now, isExplicit: true))
        XCTAssertEqual(staleLines(), 1)
        XCTAssertFalse(runtime.watchdogTick(now: now, isExplicit: true))
        XCTAssertEqual(staleLines(), 1)
    }

    func testConversationStaleComputation() {
        // Threshold sanity: the constant the runtime's scan compares against.
        XCTAssertEqual(AgentWatchdog.conversationStaleAfter, 24 * 60 * 60)
    }

    /// The watchdog-armed no-progress budget: 10 beats, refreshed to 10 by any
    /// beat that calls send_input, exhausted by read/reply-only beats — ending in
    /// a durable disarm, an audit line, and no re-arm.
    @MainActor
    func testWatchdogArmedBeatBudgetLifecycle() async {
        var records: [AgentLogRecord] = []
        let (runtime, agent) = makeArmableRuntime(log: { records.append($0) })

        XCTAssertTrue(runtime.watchdogTick(now: Date().addingTimeInterval(61)))
        XCTAssertEqual(runtime.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget)
        // The immediate beat fails (unparseable endpoint); failed beats charge the
        // failed-beat cap, never the no-progress budget.
        await drainUntil { runtime.consecutiveFailedBeats == 1 }
        XCTAssertEqual(runtime.consecutiveFailedBeats, 1)
        XCTAssertEqual(runtime.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget)

        // Read/reply-only beats consume one each; success resets the failed streak.
        for beat in 1...3 {
            runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
            XCTAssertEqual(runtime.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget - beat)
        }
        XCTAssertEqual(runtime.consecutiveFailedBeats, 0)

        // A beat that acted on the terminal is real work: full budget back.
        runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: true)
        XCTAssertEqual(runtime.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget)

        // Exhaustion: durable disarm + suppression + audit + attention.
        for _ in 1...AgentWatchdog.watchdogArmBeatBudget {
            runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
        }
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertTrue(runtime.monitoringSuppressed)
        XCTAssertNotNil(UserDefaults.standard.object(
            forKey: AgentRuntime.monitoringSuppressionKey(for: agent.id)
        ))
        XCTAssertTrue(records.contains {
            $0.text == "[watchdog] auto-monitor made no progress after 10 beats — pausing"
        })
        XCTAssertFalse(runtime.watchdogTick(), "the suppressed conversation must not re-arm")
    }

    /// Console- and tool-armed episodes are sanctioned and carry no beat budget.
    @MainActor
    func testConsoleArmedEpisodesAreUnbudgeted() {
        let (runtime, agent) = makeArmableRuntime()
        runtime.toggleMonitoringFromConsole()
        XCTAssertTrue(runtime.isMonitoring)

        for _ in 1...(AgentWatchdog.watchdogArmBeatBudget * 2) {
            runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
        }
        XCTAssertTrue(runtime.isMonitoring, "a user-armed loop never pauses for lack of progress")
        XCTAssertTrue(agent.monitoringArmed)
        XCTAssertFalse(runtime.monitoringSuppressed)
    }

    /// The failed-beat cap is provenance-aware: a console-armed monitor is never
    /// disarmed by endpoint failures — at five straight it backs off to a 5-minute
    /// cadence (one notification, one audit line) and keeps retrying, and the
    /// first successful beat restores the normal cadence. A ~2-minute endpoint
    /// blip must never permanently stop an overnight user-armed monitor.
    @MainActor
    func testFailedBeatCapBacksOffUserArmedMonitorsInsteadOfDisarming() async {
        var records: [AgentLogRecord] = []
        let (runtime, agent) = makeArmableRuntime(heartbeatSeconds: 30, log: { records.append($0) })
        runtime.toggleMonitoringFromConsole()
        XCTAssertTrue(runtime.isMonitoring)

        func backoffLines() -> Int {
            records.filter {
                $0.text == "[watchdog] monitor backing off after 5 consecutive failed beats"
            }.count
        }

        for beat in 1...AgentWatchdog.maxRecoveryFailures {
            await runtime.runHeartbeatTurn()
            XCTAssertEqual(runtime.consecutiveFailedBeats, beat)
        }
        // Still armed, not suppressed — only slower.
        XCTAssertTrue(runtime.isMonitoring)
        XCTAssertTrue(agent.monitoringArmed)
        XCTAssertFalse(runtime.monitoringSuppressed)
        XCTAssertTrue(runtime.monitorBackoffActive)
        XCTAssertEqual(runtime.currentHeartbeatInterval, AgentWatchdog.failedBeatBackoffSeconds)
        XCTAssertEqual(backoffLines(), 1)

        // Further failures ride the backoff silently — no repeat audit/notification.
        await runtime.runHeartbeatTurn()
        XCTAssertEqual(runtime.consecutiveFailedBeats, AgentWatchdog.maxRecoveryFailures + 1)
        XCTAssertTrue(runtime.isMonitoring)
        XCTAssertEqual(backoffLines(), 1)

        // The first successful beat restores the cadence and resets the streak.
        runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
        XCTAssertFalse(runtime.monitorBackoffActive)
        XCTAssertEqual(runtime.currentHeartbeatInterval, 30)
        XCTAssertEqual(runtime.consecutiveFailedBeats, 0)
        XCTAssertTrue(runtime.isMonitoring)
        XCTAssertTrue(records.contains {
            $0.text == "[watchdog] monitor recovered — resuming normal cadence"
        })
    }

    /// N2: the beat budget's "real work" signal is delivery, not attempt — a send
    /// into a disconnected session, or one the user declined, must not refresh a
    /// watchdog-armed episode's budget.
    @MainActor
    func testSendInputRefreshSignalRequiresDeliveredBytes() async {
        // Disconnected session: the guard refuses before any bytes are written.
        let disconnected = AgentRuntime(
            agent: Agent(
                name: "Fin",
                provider: .openAICompatible,
                endpointURL: Self.unparseableEndpointURL,
                modelIdentifier: "m",
                defaultMode: .auto,
                heartbeatSeconds: 60
            ),
            session: TerminalSession(serverID: UUID()), // never connected
            serverName: "box"
        )
        let refused = await disconnected.executeSendInput(
            input: "echo hi\n", awaitOutputSeconds: 1, rawArguments: "{}"
        )
        XCTAssertTrue(refused.hasPrefix("Error: the terminal session is not connected"))
        XCTAssertFalse(
            disconnected.beatUsedSendInput,
            "an undeliverable send must not count as beat progress"
        )

        // Denied by the user: the approval path refuses before any bytes are written.
        let (denied, _) = makeArmableRuntime()
        let call = Task {
            await denied.executeSendInput(
                input: "rm -rf /tmp/x", awaitOutputSeconds: 1, rawArguments: "{}"
            )
        }
        await drainUntil { denied.pendingApproval != nil }
        denied.rejectPendingCall()
        let deniedResult = await call.value
        XCTAssertTrue(deniedResult.contains("declined"))
        XCTAssertFalse(
            denied.beatUsedSendInput,
            "a declined send must not count as beat progress"
        )

        // Delivered into a connected session: the signal stamps.
        let (delivered, _) = makeArmableRuntime()
        _ = await delivered.executeSendInput(
            input: "echo hi\n", awaitOutputSeconds: 1, rawArguments: "{}"
        )
        XCTAssertTrue(delivered.beatUsedSendInput, "a delivered send is real work")
    }

    /// N1: suppression is one truth per agent, not per runtime. The same agent
    /// open against two servers yields two runtimes; a Stop in one console must
    /// hold in the other instantly, and a submit in either lifts it for both.
    @MainActor
    func testSuppressionSyncsAcrossLiveRuntimesForTheSameAgent() async {
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: 60
        )
        let history = [AgentMessage(role: .user, text: "watch the deploy")]
        func makeRuntime() -> AgentRuntime {
            let session = TerminalSession(serverID: UUID())
            session.simulateConnectedStateForTesting()
            return AgentRuntime(agent: agent, session: session, serverName: "box", history: history)
        }
        let first = makeRuntime()
        let second = makeRuntime()

        // Stop in the first console — the strongest disarm — reaches the second.
        first.cancel()
        XCTAssertTrue(first.monitoringSuppressed)
        XCTAssertTrue(second.monitoringSuppressed, "Stop must hold across every live runtime")
        XCTAssertFalse(
            second.watchdogTick(now: Date().addingTimeInterval(61)),
            "the second runtime's tick must not re-arm the agent the user just stopped"
        )
        XCTAssertFalse(second.isMonitoring)

        // A submit in the second lifts it for the first too.
        second.submit("carry on")
        XCTAssertFalse(second.monitoringSuppressed)
        XCTAssertFalse(first.monitoringSuppressed, "user intent in either console lifts the shared suppression")
        await drainMainActorTasks() // let the fast-failing submitted turn finish
    }

    /// N1: two runtimes for the same agent in one synchronous watchdog pass cannot
    /// both arm — the first arm persists `agent.monitoringArmed` synchronously, so
    /// the second runtime's evaluate sees armed == true and stays out.
    @MainActor
    func testTwoRuntimesForOneAgentCannotBothArmInOnePass() async {
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: 60
        )
        let history = [AgentMessage(role: .user, text: "watch the deploy")]
        let sessionA = TerminalSession(serverID: UUID())
        sessionA.simulateConnectedStateForTesting()
        let sessionB = TerminalSession(serverID: UUID())
        sessionB.simulateConnectedStateForTesting()
        let first = AgentRuntime(agent: agent, session: sessionA, serverName: "a", history: history)
        let second = AgentRuntime(agent: agent, session: sessionB, serverName: "b", history: history)

        let now = Date().addingTimeInterval(61)
        XCTAssertTrue(first.watchdogTick(now: now))
        XCTAssertTrue(agent.monitoringArmed, "the first arm persists synchronously")
        XCTAssertFalse(
            second.watchdogTick(now: now),
            "the second runtime in the same pass must see armed == true and not double-arm"
        )
        XCTAssertFalse(second.isMonitoring)
        XCTAssertEqual(agent.monitoringServerID, sessionA.id, "the binding is not thrashed")
        await drainUntil { first.consecutiveFailedBeats == 1 } // drain the dispatched beat
    }

    /// N4: arm provenance persists per agent — a relaunched runtime resumes a
    /// watchdog-armed episode as watchdog-armed, with the episode interval and a
    /// fresh no-progress budget, instead of laundering it into an unbudgeted
    /// console arm. Disarm removes the record.
    @MainActor
    func testWatchdogArmProvenancePersistsAcrossRuntimeReplacement() async {
        let serverID = UUID()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            heartbeatSeconds: 0 // unset — the episode interval must carry the resume
        )
        let armSourceKey = MonitorSuppressionStore.armSourceKey(for: agent.id)
        let history = [AgentMessage(role: .user, text: "watch the deploy")]

        let firstSession = TerminalSession(serverID: serverID)
        firstSession.simulateConnectedStateForTesting()
        let first = AgentRuntime(agent: agent, session: firstSession, serverName: "box", history: history)
        XCTAssertTrue(first.watchdogTick(now: Date().addingTimeInterval(61)))
        XCTAssertEqual(UserDefaults.standard.string(forKey: armSourceKey), "watchdog")
        await drainUntil { first.consecutiveFailedBeats == 1 } // let the immediate beat fail
        // Spend part of the budget so the resume's fresh grant is observable.
        first.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
        XCTAssertEqual(first.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget - 1)
        first.suspend() // replaced-runtime teardown: keeps armed state and provenance
        XCTAssertEqual(UserDefaults.standard.string(forKey: armSourceKey), "watchdog")

        let secondSession = TerminalSession(serverID: serverID)
        secondSession.simulateConnectedStateForTesting()
        let second = AgentRuntime(agent: agent, session: secondSession, serverName: "box", history: history)
        await drainUntil { second.isMonitoring }
        XCTAssertTrue(second.isMonitoring, "the armed episode resumes despite heartbeatSeconds == 0")
        XCTAssertEqual(second.monitoringArmSource, .watchdog)
        XCTAssertEqual(
            second.watchdogBeatsRemaining, AgentWatchdog.watchdogArmBeatBudget,
            "a resumed watchdog episode keeps the budget bound, freshly granted"
        )
        XCTAssertEqual(second.effectiveHeartbeatSeconds, 60)
        XCTAssertEqual(agent.heartbeatSeconds, 0, "resume never writes the synced config either")

        // Disarm clears the provenance record with the armed state.
        second.stopHeartbeat()
        XCTAssertNil(UserDefaults.standard.object(forKey: armSourceKey))
    }

    /// 1c: a watchdog-armed episode that concludes TASK COMPLETE converges
    /// silently — disarm, suppression, and an audit line, but no turn-finished
    /// notification for supervision the user never asked for. Console episodes
    /// keep the notification path (and never write the quiet audit line).
    @MainActor
    func testWatchdogArmedTaskCompleteConcludesQuietly() async {
        var records: [AgentLogRecord] = []
        let (runtime, agent) = makeArmableRuntime(log: { records.append($0) })
        let quietLine = "[watchdog] auto-monitor concluded TASK COMPLETE — disarming quietly"

        XCTAssertTrue(runtime.watchdogTick(now: Date().addingTimeInterval(61)))
        await drainUntil { runtime.consecutiveFailedBeats == 1 } // the immediate beat fails
        runtime.concludeMonitoredTaskComplete()

        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertTrue(runtime.monitoringSuppressed)
        XCTAssertEqual(records.filter { $0.text == quietLine }.count, 1)

        // A console-armed conclusion takes the notification path instead.
        runtime.submit("watch it again") // user intent: lifts suppression
        await drainMainActorTasks()
        runtime.toggleMonitoringFromConsole()
        XCTAssertTrue(runtime.isMonitoring)
        runtime.concludeMonitoredTaskComplete()
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertTrue(runtime.monitoringSuppressed)
        XCTAssertEqual(
            records.filter { $0.text == quietLine }.count, 1,
            "a sanctioned episode's completion is not the watchdog's quiet convergence"
        )
    }

    /// Five straight failed beats pause a watchdog-armed monitor durably, so a
    /// dead endpoint can't be retried every interval forever on nobody's say-so.
    /// Driven through real beats against the unparseable endpoint. (Console/tool
    /// episodes back off instead — see the backoff lifecycle test.)
    @MainActor
    func testConsecutiveFailedBeatsPauseMonitoringDurably() async {
        var records: [AgentLogRecord] = []
        let (runtime, agent) = makeArmableRuntime(log: { records.append($0) })

        // arm + immediate (failing) beat
        XCTAssertTrue(runtime.watchdogTick(now: Date().addingTimeInterval(61)))
        await drainUntil { runtime.consecutiveFailedBeats == 1 }

        // A successful beat resets the streak…
        runtime.registerHeartbeatBeatOutcome(failed: false, usedSendInput: false)
        XCTAssertEqual(runtime.consecutiveFailedBeats, 0)

        // …then five real failures in a row hit the cap.
        for beat in 1...AgentWatchdog.maxRecoveryFailures {
            await runtime.runHeartbeatTurn()
            XCTAssertEqual(runtime.consecutiveFailedBeats, beat)
        }
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertTrue(runtime.monitoringSuppressed)
        XCTAssertTrue(records.contains {
            $0.text == "[watchdog] monitor paused after 5 consecutive failed beats"
        })
    }

    /// The monitor tool's interval clamp floors at 15s — a model-chosen 1s cadence
    /// is a turn storm — while 0 still means "unset" and takes the 60s default.
    @MainActor
    func testMonitorToolIntervalClampFloor() {
        let (runtime, agent) = makeArmableRuntime(heartbeatSeconds: 0, history: [])

        _ = runtime.executeMonitor(action: "start", intervalSeconds: 1, rawArguments: "{}")
        XCTAssertEqual(agent.heartbeatSeconds, 15)
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")

        _ = runtime.executeMonitor(action: "start", intervalSeconds: 30, rawArguments: "{}")
        XCTAssertEqual(agent.heartbeatSeconds, 30, "in-range intervals pass through")
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")

        _ = runtime.executeMonitor(action: "start", intervalSeconds: 900, rawArguments: "{}")
        XCTAssertEqual(agent.heartbeatSeconds, 600, "ceiling unchanged")
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")

        agent.heartbeatSeconds = 0
        _ = runtime.executeMonitor(action: "start", intervalSeconds: 0, rawArguments: "{}")
        XCTAssertEqual(agent.heartbeatSeconds, 60, "0 means unset → active-supervision default")
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")

        // The user's stepper is the authoritative knob: a model that omits the
        // interval inherits the agent's configured cadence, never a hardcoded 60.
        agent.heartbeatSeconds = 120
        _ = runtime.executeMonitor(action: "start", intervalSeconds: 0, rawArguments: "{}")
        XCTAssertEqual(agent.heartbeatSeconds, 120,
                       "an omitted interval defers to the agent's own setting")
        _ = runtime.executeMonitor(action: "stop", intervalSeconds: 0, rawArguments: "{}")
    }

    // MARK: - Heartbeat default migration

    /// New agents start at the 60s default; legacy agents with an implicit 0 are
    /// bumped exactly once, and an explicit Off chosen after the migration holds.
    func testHeartbeatDefaultMigrationBumpsZeroOnceAndRespectsExplicitOff() {
        XCTAssertEqual(Agent.defaultHeartbeatSeconds, 60)
        let fresh = Agent(name: "Fin")
        XCTAssertEqual(fresh.heartbeatSeconds, 60, "new agents default to 60")
        XCTAssertTrue(fresh.heartbeatDefaultUpgraded, "new agents are never migrated")

        // A new agent whose creator explicitly chose Off stays Off.
        let explicitOff = Agent(name: "Fin", heartbeatSeconds: 0)
        explicitOff.upgradeHeartbeatDefaultIfNeeded()
        XCTAssertEqual(explicitOff.heartbeatSeconds, 0)

        // Legacy shape: created before the default changed, still carrying 0.
        let legacy = Agent(name: "Fin")
        legacy.heartbeatDefaultUpgraded = false
        legacy.heartbeatSeconds = 0
        legacy.upgradeHeartbeatDefaultIfNeeded()
        XCTAssertEqual(legacy.heartbeatSeconds, 60, "the one-shot migration bumps 0→60")
        XCTAssertTrue(legacy.heartbeatDefaultUpgraded)

        // The user's later explicit Off survives every subsequent upgrade pass.
        legacy.heartbeatSeconds = 0
        legacy.upgradeHeartbeatDefaultIfNeeded()
        legacy.upgradeHeartbeatDefaultIfNeeded()
        XCTAssertEqual(legacy.heartbeatSeconds, 0, "an explicit Off after migration stays Off")

        // A legacy agent with a configured interval is stamped, never changed.
        let configured = Agent(name: "Fin", heartbeatSeconds: 300)
        configured.heartbeatDefaultUpgraded = false
        configured.upgradeHeartbeatDefaultIfNeeded()
        XCTAssertEqual(configured.heartbeatSeconds, 300, "non-zero intervals are untouched")
        XCTAssertTrue(configured.heartbeatDefaultUpgraded)
    }

    // MARK: - Prompt queue

    /// The live field failure this queue fixes: while heartbeat turns chain
    /// back-to-back, a typed message used to bounce off the isBusy guard. Now it
    /// queues, and queued prompts run FIFO through the normal submitted-turn path
    /// as each in-flight turn completes.
    @MainActor
    func testSubmitQueuesWhileBusyAndDrainsFIFO() async {
        var records: [AgentLogRecord] = []
        let (runtime, _) = makeArmableRuntime(history: [], log: { records.append($0) })

        XCTAssertEqual(runtime.submit(""), .rejected, "empty text is never queued")
        XCTAssertEqual(runtime.submit("one"), .started)
        XCTAssertTrue(runtime.isBusy)
        XCTAssertEqual(runtime.submit("two"), .queued)
        XCTAssertEqual(runtime.submit("  three  "), .queued, "trim rules hold at enqueue")
        XCTAssertEqual(runtime.queuedPrompts, ["two", "three"])
        XCTAssertTrue(records.contains { $0.kind == .notice && $0.text == "[queue] prompt queued (1 waiting)" })
        XCTAssertTrue(records.contains { $0.kind == .notice && $0.text == "[queue] prompt queued (2 waiting)" })

        await drainUntil {
            runtime.queuedPrompts.isEmpty && !runtime.isBusy
                && runtime.transcript.messages.filter { $0.role == .user }.count == 3
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["one", "two", "three"],
            "queued prompts run FIFO through the same submitted-turn path"
        )
        XCTAssertEqual(
            records.filter { $0.kind == .userMessage }.map(\.text),
            ["one", "two", "three"]
        )
    }

    /// A replaced runtime must never run its backlog: suspend() discards the queue
    /// and the cancelled task's tail must not drain it — otherwise queued prompts
    /// start invisible turns against the terminal the replacement runtime owns.
    @MainActor
    func testSuspendDiscardsQueueAndNeverZombieDrains() async {
        var records: [AgentLogRecord] = []
        let (runtime, _) = makeArmableRuntime(history: [], log: { records.append($0) })

        XCTAssertEqual(runtime.submit("one"), .started)
        XCTAssertEqual(runtime.submit("two"), .queued)
        XCTAssertEqual(runtime.queuedPrompts, ["two"])

        runtime.suspend()
        XCTAssertTrue(runtime.queuedPrompts.isEmpty, "suspend discards the backlog")
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text.hasPrefix("[queue] discarded unrun prompt: two")
        })

        // Give the cancelled turn's tail every chance to resume and misbehave.
        await drainUntil { !runtime.isBusy }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["one"],
            "the discarded prompt must never start a turn"
        )
    }

    /// Draining outranks heartbeats absolutely: while the queue is non-empty the
    /// beat gate no-ops (no prompt, no stamp) and every watchdog dispatch site
    /// yields — including the idle-unfinished arm.
    @MainActor
    func testQueueVetoesHeartbeatBeatAndWatchdogDispatch() async {
        var records: [AgentLogRecord] = []
        let (runtime, _) = makeArmableRuntime(log: { records.append($0) })
        runtime.enqueuePromptForTesting("queued work")

        await runtime.runHeartbeatTurn()
        XCTAssertNil(runtime.lastHeartbeatFiredAt, "a vetoed beat must not stamp")
        XCTAssertFalse(runtime.transcript.messages.contains { $0.isHeartbeat })

        // Armable conditions past the idle delay: without the queue this tick
        // would arm and dispatch an immediate beat (see the arm test above).
        let armNow = Date().addingTimeInterval(AgentWatchdog.idleArmDelay + 1)
        XCTAssertFalse(runtime.watchdogTick(now: armNow, isExplicit: false),
                       "a tick landing on a non-empty queue dispatches nothing")
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(records.contains {
            $0.text == "[watchdog] agent idle with unfinished work — arming monitor loop"
        })
    }

    /// Stop discards the backlog, audibly — a cancelled turn's queued follow-ups
    /// must not fire the moment the cancel lands.
    @MainActor
    func testStopClearsQueuedPrompts() async {
        var records: [AgentLogRecord] = []
        let (runtime, _) = makeArmableRuntime(history: [], log: { records.append($0) })

        XCTAssertEqual(runtime.submit("one"), .started)
        XCTAssertEqual(runtime.submit("two"), .queued)
        XCTAssertEqual(runtime.submit("three"), .queued)
        runtime.cancel()

        XCTAssertTrue(runtime.queuedPrompts.isEmpty, "Stop clears the queue")
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[queue] 2 queued prompts discarded"
        })
        await drainMainActorTasks()
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["one"],
            "discarded prompts never reach the transcript"
        )
        XCTAssertFalse(runtime.isBusy)
    }

    /// The dispatch-to-execution race: a user submit queued on the MainActor can
    /// claim the runtime between a beat being scheduled and its body running. The
    /// claimed runtime's beat must vanish — no transcript rows, no stamp overwrite.
    @MainActor
    func testHeartbeatBeatNoOpsWhenAnotherTurnClaimedTheRuntime() async {
        let (runtime, _) = makeArmableRuntime()
        let armNow = Date().addingTimeInterval(61)
        XCTAssertTrue(runtime.watchdogTick(now: armNow))

        // Claims the runtime synchronously (state → .thinking) before the
        // dispatched beat's body has had any chance to run.
        runtime.submit("also check the logs")
        await drainUntil {
            if case .failed = runtime.state { return true }
            return false
        }

        XCTAssertFalse(
            runtime.transcript.messages.contains { $0.isHeartbeat },
            "the orphaned beat must not inject its prompt into the claimed turn"
        )
        XCTAssertEqual(
            runtime.lastHeartbeatFiredAt, armNow,
            "the no-op beat must not restamp the arm-time beat stamp"
        )
    }

    /// The arm stamps `lastHeartbeatFiredAt` at arm time, so a back-to-back tick
    /// cannot read a stale stamp from an earlier episode and fire
    /// `.overdueHeartbeat` over the still-pending first beat.
    @MainActor
    func testArmTimeStampSuppressesOverdueRaceOnBackToBackTicks() async {
        var records: [AgentLogRecord] = []
        let session = TerminalSession(serverID: UUID())
        session.simulateConnectedStateForTesting()
        let agent = Agent(
            name: "Fin",
            provider: .openAICompatible, // blocked for now: beats no-op but stamp
            defaultMode: .auto,
            heartbeatSeconds: 60
        )
        let runtime = AgentRuntime(
            agent: agent,
            session: session,
            serverName: "box",
            log: { records.append($0) },
            history: [AgentMessage(role: .user, text: "watch the build")]
        )

        // A previous episode's beat leaves an old stamp behind.
        await runtime.runHeartbeatTurn()
        guard let staleStamp = runtime.lastHeartbeatFiredAt else {
            return XCTFail("expected the blocked beat to stamp lastHeartbeatFiredAt")
        }

        // Now runnable; the arm happens well past the overdue threshold.
        agent.endpointURL = Self.unparseableEndpointURL
        agent.modelIdentifier = "m"
        let armNow = staleStamp.addingTimeInterval(300)
        XCTAssertTrue(runtime.watchdogTick(now: armNow))
        XCTAssertEqual(runtime.lastHeartbeatFiredAt, armNow, "the arm itself stamps the beat time")

        // Without the arm-time stamp this tick would see the previous episode's
        // stamp, judge the loop overdue, and overwrite the pending beat's runTask.
        XCTAssertFalse(runtime.watchdogTick(now: armNow.addingTimeInterval(1)))
        XCTAssertFalse(records.contains { $0.text.hasPrefix("[watchdog] fired overdue heartbeat") })
        await drainUntil { runtime.consecutiveFailedBeats == 1 } // let the beat finish
    }

    /// Explicit (launch/foreground) ticks leave one proof-of-life line per non-empty
    /// conversation; the quiet 5s loop writes nothing when nothing needs doing.
    @MainActor
    func testForegroundCheckAuditLines() {
        // Finished conversation, nothing due: silent on quiet ticks, "all quiet"
        // on the explicit one.
        var records: [AgentLogRecord] = []
        let finished = AgentRuntime(
            agent: Agent(name: "Fin"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { records.append($0) },
            history: [
                AgentMessage(role: .user, text: "watch the deploy"),
                AgentMessage(role: .assistant, text: "TASK COMPLETE"),
            ]
        )
        finished.watchdogTick()
        XCTAssertFalse(
            records.contains { $0.text.hasPrefix("[watchdog] foreground check") },
            "the quiet 5s tick never writes"
        )
        finished.watchdogTick(isExplicit: true)
        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[watchdog] foreground check — all quiet"
        })

        // Unfinished work but no session to act on: the check says why it can't.
        var stuckRecords: [AgentLogRecord] = []
        let stuck = AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible, defaultMode: .auto, heartbeatSeconds: 60),
            session: TerminalSession(serverID: UUID()), // never connected
            serverName: "box",
            log: { stuckRecords.append($0) },
            history: [AgentMessage(role: .user, text: "watch the deploy")]
        )
        stuck.watchdogTick(isExplicit: true)
        XCTAssertTrue(stuckRecords.contains {
            $0.kind == .notice
                && $0.text == "[watchdog] foreground check — unfinished conversation, but no connected session"
        })

        // No conversation at all: even the explicit tick stays silent.
        var emptyRecords: [AgentLogRecord] = []
        let empty = AgentRuntime(
            agent: Agent(name: "Fin"),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { emptyRecords.append($0) }
        )
        empty.watchdogTick(isExplicit: true)
        XCTAssertFalse(emptyRecords.contains { $0.text.hasPrefix("[watchdog] foreground check") })
    }

    /// The daily consolidation floor announces itself distinctly from post-turn
    /// pacing runs, and only fetches candidates when the 24h stamp says it is due.
    @MainActor
    func testConsolidationDailyFloorTriggerIsAudited() async {
        let defaults = UserDefaults.standard
        let successBefore = defaults.object(forKey: AgentRuntime.lastConsolidationSuccessKey)
        let pacingBefore = defaults.object(forKey: AgentRuntime.lastConsolidationKey)
        defer {
            if let successBefore {
                defaults.set(successBefore, forKey: AgentRuntime.lastConsolidationSuccessKey)
            } else {
                defaults.removeObject(forKey: AgentRuntime.lastConsolidationSuccessKey)
            }
            if let pacingBefore {
                defaults.set(pacingBefore, forKey: AgentRuntime.lastConsolidationKey)
            } else {
                defaults.removeObject(forKey: AgentRuntime.lastConsolidationKey)
            }
        }
        // No success ever and no recent attempt → the floor is due. The endpoint
        // agent has no URL, so the dispatched attempt fails fast with no model call.
        defaults.removeObject(forKey: AgentRuntime.lastConsolidationSuccessKey)
        defaults.set(Date().addingTimeInterval(-31 * 60), forKey: AgentRuntime.lastConsolidationKey)

        var records: [AgentLogRecord] = []
        var fetches = 0
        var access = AgentMemoryAccess.noop
        access.consolidationCandidates = { _ in
            fetches += 1
            return [AgentMemoryHit(id: UUID(), title: "t", content: "c", tags: "", updatedAt: Date())]
        }
        let runtime = AgentRuntime(
            agent: Agent(name: "Fin", provider: .openAICompatible),
            session: TerminalSession(serverID: UUID()),
            serverName: "box",
            log: { records.append($0) },
            memory: access
        )

        runtime.consolidateIfDailyFloorDue()

        XCTAssertTrue(records.contains {
            $0.kind == .notice && $0.text == "[consolidation] daily floor triggered"
        })
        XCTAssertEqual(fetches, 1)
        for _ in 0..<20 { await Task.yield() } // drain the fast-failing dispatched task

        // With the pacing stamp fresh again (the attempt re-stamped it), a due floor
        // stays quiet instead of audit-logging a guaranteed no-op every tick.
        let recordCount = records.count
        let fetchCount = fetches // the attempt itself fetched its own candidates
        runtime.consolidateIfDailyFloorDue()
        XCTAssertEqual(records.count, recordCount)
        XCTAssertEqual(fetches, fetchCount, "a paced tick must not re-fetch candidates")
    }
}

import Foundation
import XCTest
@testable import fin

#if os(macOS)

/// Exercises the agent against a REAL SSH + tmux session and Apple's real on-device model —
/// no mocks anywhere in the loop. This connects to this machine's own local sshd on
/// 127.0.0.1 using the developer's own `~/.ssh/id_ed25519`, attaches a scratch tmux
/// session, and drives a real `AgentRuntime` end to end.
///
/// This is deliberately not portable: it skips itself out on any machine that doesn't have
/// this dev setup (own key, own local sshd + tmux) or isn't running an Apple-Intelligence-
/// capable OS, rather than failing the suite red elsewhere. It's the harness the "test and
/// tune relentlessly" workflow drives to observe and correct real agent behavior, as
/// opposed to `AgentLogicTests`, which covers pure logic with no live model or session.
@MainActor
final class AgentBehaviorTests: XCTestCase {

    private var session: TerminalSession?

    override func setUpWithError() throws {
        guard AppleOnDeviceBackend.isAvailable else {
            throw XCTSkip("Apple on-device model isn't available on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.privateKeyPath) else {
            throw XCTSkip("No provisioned SSH key at \(Self.privateKeyPath) — run "
                + "scripts/provision-agent-test-key.sh first. This test drives a real SSH "
                + "session and only runs against a dev machine set up for it.")
        }
    }

    override func tearDown() {
        session?.disconnect()
        session = nil
    }

    // MARK: - Harness

    /// The signed macOS test host runs inside `fin.app`'s real App Sandbox, which can't
    /// read `~/.ssh` directly (no home-relative file-read entitlement — same reason
    /// `KeychainStoreTests` skips on macOS). `scripts/provision-agent-test-key.sh` copies
    /// the dev machine's own key into the app's own sandbox container, which it can read
    /// freely; `NSHomeDirectory()` here already resolves to that container.
    private static var privateKeyPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("tmp/fin-agent-tests/id_ed25519")
    }

    /// Connects a real SSH session to this machine's own sshd and attaches a scratch tmux
    /// session, so each test starts from a clean, known shell instead of reusing state.
    private func connectedSession(tmuxName: String) async throws -> TerminalSession {
        let keyPEM = try String(contentsOfFile: Self.privateKeyPath, encoding: .utf8)
        let credentials = ServerCredentials(
            username: NSUserName(),
            keyPEM: keyPEM,
            keyType: .ed25519,
            passphrase: nil
        )
        // destroy-unattached makes each scratch session vanish when the test disconnects,
        // so runs don't accumulate sessions on the dev machine.
        let server = Server(
            name: "AgentBehaviorTests",
            host: "127.0.0.1",
            port: 22,
            username: NSUserName(),
            // status off: the status bar redraws on a timer, which pollutes the event log
            // and can masquerade as a command's response in the send_input await path.
            connectCommand: "tmux new-session -A -s \(tmuxName) \\; set destroy-unattached on \\; set status off\n"
        )

        let session = TerminalSession(serverID: server.id)
        // The dev machine's fish profile execs any interactive SSH login straight into the
        // user's real tmux "main" session — where their actual work (including a live
        // Claude Code session) runs. Without this marker, every keystroke this harness
        // types would land in that session instead of a scratch shell; config.fish skips
        // its auto-attach when it sees this variable. LC_-prefixed because macOS sshd's
        // default AcceptEnv only forwards LANG and LC_*.
        session.connect(
            server: server,
            credentials: credentials,
            environment: ["LC_FIN_AGENT_TEST": "1"]
        )

        try await waitUntil(timeout: 20, description: "SSH connect to 127.0.0.1") {
            session.state == .connected || session.lastError != nil
        }
        if let error = session.lastError {
            XCTFail("SSH connect to 127.0.0.1 failed: \(error)")
            throw XCTSkip("Cannot proceed without a connected session.")
        }
        // connectCommand is written the instant state flips to .connected, not after the
        // shell has actually settled into the new tmux session — give it a beat.
        try await Task.sleep(for: .milliseconds(800))
        self.session = session
        return session
    }

    private func waitUntil(
        timeout: TimeInterval,
        description: String,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for: \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Pumps until one agent turn settles (an answer, a failure, or a pending approval).
    /// On-device generation time is inherently variable, so this applies its own timeout
    /// rather than relying on the model to be fast.
    private func runTurn(_ runtime: AgentRuntime, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch runtime.state {
            case .thinking:
                break
            case .idle, .failed, .awaitingApproval:
                return
            }
            if Date() > deadline {
                XCTFail("Agent turn did not finish within \(timeout)s (state: \(runtime.state))")
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func makeRuntime(mode: AgentMode = .auto) -> AgentRuntime {
        let agent = Agent(name: "Behavior Test Agent", defaultMode: mode)
        let runtime = AgentRuntime(agent: agent, session: session!, serverName: "127.0.0.1")
        runtime.mode = mode
        return runtime
    }

    /// Same scenarios, different backend — isolates whether a tool-calling failure is an
    /// Apple on-device model/framework limitation or a wiring bug that would reproduce on
    /// any backend. Points at this dev machine's local LM Studio server; `modelIdentifier`
    /// lets the same harness sweep across model sizes.
    private func makeEndpointRuntime(modelIdentifier: String, mode: AgentMode = .auto) -> AgentRuntime {
        let agent = Agent(
            name: "Endpoint Diagnostic Agent (\(modelIdentifier))",
            provider: .openAICompatible,
            endpointURL: "http://localhost:1234/v1",
            modelIdentifier: modelIdentifier,
            defaultMode: mode
        )
        let runtime = AgentRuntime(agent: agent, session: session!, serverName: "127.0.0.1")
        runtime.mode = mode
        return runtime
    }

    // MARK: - Tests (diagnostic: endpoint backend, swept across model sizes)

    private func assertReadsTerminal(modelIdentifier: String, tmuxSuffix: String) async throws {
        let session = try await connectedSession(tmuxName: "fin-test-ep-read-\(tmuxSuffix)")
        let marker = "FIN_EP_MARKER_\(Int.random(in: 10_000...99_999))"
        session.send(text: "echo \(marker)\n")
        try await Task.sleep(for: .milliseconds(1_200))

        let runtime = makeEndpointRuntime(modelIdentifier: modelIdentifier)
        runtime.submit("Read the terminal and tell me exactly what word was echoed most recently.")
        try await runTurn(runtime, timeout: 90)

        if case .failed(let message) = runtime.state {
            XCTFail("[\(modelIdentifier)] Agent turn failed: \(message)")
            return
        }
        let usedReadTool = runtime.transcript.messages.contains {
            $0.toolCalls.contains { $0.name == AgentToolSpec.readTerminal.name }
        }
        XCTAssertTrue(usedReadTool, "[\(modelIdentifier)] expected the agent to call read_terminal")

        let reply = runtime.transcript.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(reply.contains(marker), "[\(modelIdentifier)] expected the reply to reference \(marker), got: \(reply)")
    }

    private func assertRunsCommand(modelIdentifier: String, tmuxSuffix: String) async throws {
        let session = try await connectedSession(tmuxName: "fin-test-ep-run-\(tmuxSuffix)")
        let runtime = makeEndpointRuntime(modelIdentifier: modelIdentifier, mode: .auto)
        let marker = "FIN_EP_RUN_\(Int.random(in: 10_000...99_999))"

        runtime.submit("Run this exact shell command in the terminal right now: echo \(marker)")
        try await runTurn(runtime, timeout: 90)

        if case .awaitingApproval(let call, let reason) = runtime.state {
            XCTFail("[\(modelIdentifier)] did not expect an approval gate for a plain echo (reason: \(reason)): \(call.arguments)")
            return
        }
        if case .failed(let message) = runtime.state {
            XCTFail("[\(modelIdentifier)] Agent turn failed: \(message)")
            return
        }

        let sentInput = runtime.transcript.messages
            .flatMap(\.toolCalls)
            .contains { $0.name == AgentToolSpec.sendInput.name && ($0.argument("input")?.contains(marker) ?? false) }
        XCTAssertTrue(sentInput, "[\(modelIdentifier)] expected a send_input tool call containing \(marker)")

        try await waitUntil(timeout: 10, description: "marker to appear in the terminal event log") {
            session.eventLog.recentText(maxLines: 200).contains(marker)
        }
    }

    /// The transcript failure this guards against: the agent asks a slow program (another
    /// agent, a long build) a question, reads the terminal 600ms later, and reasons over
    /// stale screen content. The awaited send_input must carry the real, delayed response
    /// in its own tool result — no follow-up read_terminal racing the program.
    func testSendInputAwaitsADelayedResponse() async throws {
        _ = try await connectedSession(tmuxName: "fin-test-await")
        let runtime = makeRuntime(mode: .auto)
        let marker = "FIN_DELAYED_\(Int.random(in: 10_000...99_999))"

        runtime.submit("Run this exact shell command in the terminal right now: sleep 3; echo \(marker)")
        try await runTurn(runtime)

        if case .failed(let message) = runtime.state {
            XCTFail("Agent turn failed: \(message)")
            return
        }

        let sendResult = runtime.transcript.messages.first {
            $0.role == .tool && $0.text.contains("INPUT SENT")
        }
        XCTAssertNotNil(sendResult, "expected a send_input tool result in the transcript")
        // The marker must appear as the command's own printed output — a line that isn't
        // just the echoed `sleep 3; echo …` keystrokes, or the await settled too early.
        let hasResponseLine = (sendResult?.text ?? "")
            .split(separator: "\n")
            .contains { line in
                line.contains(marker) && !line.contains("echo")
            }
        XCTAssertTrue(
            hasResponseLine,
            "the send_input result must contain the delayed response as its own line, got: \(sendResult?.text ?? "nil")"
        )
    }

    func testEndpoint12bReadsTerminal() async throws {
        try await assertReadsTerminal(modelIdentifier: "google/gemma-4-12b-qat", tmuxSuffix: "12b")
    }

    func testEndpoint12bRunsCommand() async throws {
        try await assertRunsCommand(modelIdentifier: "google/gemma-4-12b-qat", tmuxSuffix: "12b")
    }

    func testEndpoint26bReadsTerminal() async throws {
        try await assertReadsTerminal(modelIdentifier: "google/gemma-4-26b-a4b", tmuxSuffix: "26b")
    }

    func testEndpoint26bRunsCommand() async throws {
        try await assertRunsCommand(modelIdentifier: "google/gemma-4-26b-a4b", tmuxSuffix: "26b")
    }

    func testEndpointQwen27bReadsTerminal() async throws {
        try await assertReadsTerminal(modelIdentifier: "qwen/qwen3.6-27b", tmuxSuffix: "qwen27b")
    }

    func testEndpointQwen27bRunsCommand() async throws {
        try await assertRunsCommand(modelIdentifier: "qwen/qwen3.6-27b", tmuxSuffix: "qwen27b")
    }

    // MARK: - Tests

    /// The baseline: a question with no terminal dependency shouldn't need a tool call and
    /// shouldn't trip the degenerate-output guard.
    func testAnswersASimpleQuestionWithoutDegenerating() async throws {
        _ = try await connectedSession(tmuxName: "fin-test-basic")
        let runtime = makeRuntime()

        runtime.submit("What is 2 + 2? Answer in one short sentence.")
        try await runTurn(runtime)

        if case .failed(let message) = runtime.state {
            XCTFail("Agent turn failed: \(message)")
            return
        }
        let reply = runtime.transcript.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertFalse(reply.isEmpty, "expected a reply")
        XCTAssertFalse(AppleOnDeviceBackend.looksDegenerate(reply), "reply looked degenerate: \(reply)")
    }

    /// Confirms the agent actually reaches for `read_terminal` when the question depends on
    /// live session state, and that the chunked/timestamped event log gives it enough to
    /// find a specific marker rather than just describing the format back.
    func testReadsTerminalToAnswerAboutRecentOutput() async throws {
        let session = try await connectedSession(tmuxName: "fin-test-read")
        let marker = "FIN_MARKER_\(Int.random(in: 10_000...99_999))"
        session.send(text: "echo \(marker)\n")
        try await Task.sleep(for: .milliseconds(1_200))

        let runtime = makeRuntime()
        runtime.submit("Read the terminal and tell me exactly what word was echoed most recently.")
        try await runTurn(runtime)

        if case .failed(let message) = runtime.state {
            XCTFail("Agent turn failed: \(message)")
            return
        }
        let usedReadTool = runtime.transcript.messages.contains {
            $0.toolCalls.contains { $0.name == AgentToolSpec.readTerminal.name }
        }
        XCTAssertTrue(usedReadTool, "expected the agent to call read_terminal")

        let reply = runtime.transcript.messages.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(reply.contains(marker), "expected the reply to reference \(marker), got: \(reply)")
    }

    /// Confirms the agent can actually drive the session — a `send_input` tool call that
    /// really lands in the live shell, not just a claim in the model's own text.
    func testRunsACommandViaSendInputWhenAskedDirectly() async throws {
        let session = try await connectedSession(tmuxName: "fin-test-run")
        let runtime = makeRuntime(mode: .auto)
        let marker = "FIN_RUN_\(Int.random(in: 10_000...99_999))"

        runtime.submit("Run this exact shell command in the terminal right now: echo \(marker)")
        try await runTurn(runtime)

        if case .awaitingApproval(let call, let reason) = runtime.state {
            XCTFail("did not expect an approval gate for a plain echo (reason: \(reason)): \(call.arguments)")
            return
        }
        if case .failed(let message) = runtime.state {
            XCTFail("Agent turn failed: \(message)")
            return
        }

        let sentInput = runtime.transcript.messages
            .flatMap(\.toolCalls)
            .contains { $0.name == AgentToolSpec.sendInput.name && ($0.argument("input")?.contains(marker) ?? false) }
        XCTAssertTrue(sentInput, "expected a send_input tool call containing \(marker)")

        // The model claiming it ran the command isn't proof — check the real shell.
        try await waitUntil(timeout: 10, description: "marker to appear in the terminal event log") {
            session.eventLog.recentText(maxLines: 200).contains(marker)
        }
    }
}

#endif

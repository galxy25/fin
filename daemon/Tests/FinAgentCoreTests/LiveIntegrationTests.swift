import XCTest
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live tests against this dev machine's own sshd + tmux and its local LM Studio server —
/// the same proven recipe as the app's `AgentBehaviorTests`, minus the app: SSH to
/// 127.0.0.1 as the current user with `~/.ssh/levi_id_ed25519`, `LC_FIN_AGENT_TEST=1` so
/// the remote fish profile hands out a plain shell instead of attaching the user's real
/// tmux, and a scratch `tmux new-session` that destroys itself on detach.
///
/// A daemon test process is NOT sandboxed, so `~/.ssh` is readable directly. Each test
/// skips itself cleanly when a prerequisite is missing rather than failing red elsewhere.
@MainActor
final class LiveIntegrationTests: XCTestCase {

    private static let privateKeyPath = ("~/.ssh/levi_id_ed25519" as NSString).expandingTildeInPath
    private static let lmStudioBaseURL = "http://localhost:1234/v1"
    private static let lmStudioModel = "google/gemma-4-12b-qat"

    private var session: HeadlessTerminalSession?

    override func tearDown() {
        // corelibs-xctest (Linux) keeps `tearDown` nonisolated even on a @MainActor
        // test class; it still runs on the main thread, so hop explicitly.
        MainActor.assumeIsolated {
            session?.disconnect()
            session = nil
        }
        super.tearDown()
    }

    // MARK: - Prerequisites

    private func requireSSHKey() throws -> String {
        guard FileManager.default.fileExists(atPath: Self.privateKeyPath) else {
            throw XCTSkip("No SSH key at \(Self.privateKeyPath) — live tests only run on the provisioned dev machine.")
        }
        return try String(contentsOfFile: Self.privateKeyPath, encoding: .utf8)
    }

    private func requireLMStudio() async throws {
        guard let url = URL(string: Self.lmStudioBaseURL + "/models") else { throw XCTSkip("bad URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  String(data: data, encoding: .utf8)?.contains(Self.lmStudioModel) == true
            else {
                throw XCTSkip("LM Studio at \(Self.lmStudioBaseURL) isn't serving \(Self.lmStudioModel).")
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("LM Studio not reachable at \(Self.lmStudioBaseURL): \(error.localizedDescription)")
        }
    }

    private func connectedSession(tmuxName: String) async throws -> HeadlessTerminalSession {
        let keyPEM = try requireSSHKey()
        let session = HeadlessTerminalSession(configuration: HeadlessSessionConfiguration(
            host: "127.0.0.1",
            port: 22,
            username: NSUserName(),
            privateKeyPEM: keyPEM,
            // destroy-unattached: scratch sessions vanish on disconnect. status off: the
            // status bar's timer redraws pollute the event log.
            connectCommand: "tmux new-session -A -s \(tmuxName) \\; set destroy-unattached on \\; set status off",
            environment: ["LC_FIN_AGENT_TEST": "1"]
        ))
        session.connect()
        do {
            try await session.waitForConnection(timeout: 20)
        } catch {
            throw XCTSkip("Local sshd not reachable: \(error.localizedDescription)")
        }
        // Probe-based readiness: the session types echo probes until the shell inside
        // the tmux attach demonstrably answers one, so tests never type into a shell
        // that is still spawning.
        try await session.waitForShellReady(timeout: 30)
        self.session = session
        return session
    }

    // MARK: - (a) Headless session end to end

    func testHeadlessSessionRunsACommandAndLogsItsOutput() async throws {
        let session = try await connectedSession(tmuxName: "fin-agentd-test-echo")
        let marker = "MARKER_\(Int.random(in: 100_000...999_999))"

        session.sendAgentInput("echo \(marker)\r")

        let deadline = Date().addingTimeInterval(10)
        var sawMarkerAsOutput = false
        while Date() < deadline, !sawMarkerAsOutput {
            // The marker must appear as terminal OUTPUT (the echo command's result), not
            // merely as our own recorded keystrokes.
            sawMarkerAsOutput = session.eventLog.events.contains {
                $0.kind == .output && $0.text.contains(marker)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(
            sawMarkerAsOutput,
            "expected \(marker) in the event log's output; log:\n\(session.eventLog.recentText(maxLines: 60))"
        )
    }

    // MARK: - (b) Full engine turn against LM Studio

    func testEngineTurnRunsACommandThroughLMStudio() async throws {
        try await requireLMStudio()
        let session = try await connectedSession(tmuxName: "fin-agentd-test-engine")
        let marker = "DAEMON_\(Int.random(in: 100_000...999_999))"

        var audited: [AgentAuditEvent] = []
        let engine = AgentTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: Self.lmStudioBaseURL,
                modelIdentifier: Self.lmStudioModel
            ),
            session: session,
            audit: { audited.append($0) }
        )

        let outcome = await engine.submit("run this exact shell command in the terminal right now: echo \(marker)")

        if case .failed(let message) = outcome {
            XCTFail("engine turn failed: \(message)")
            return
        }

        // The send_input tool result must carry the marker as the command's real,
        // awaited response — not just an echo of the keystrokes.
        let sendResult = engine.transcript.messages.first {
            $0.role == .tool && $0.text.contains("INPUT SENT")
        }
        XCTAssertNotNil(sendResult, "expected a send_input tool result; transcript roles: \(engine.transcript.messages.map(\.role))")
        XCTAssertTrue(
            sendResult?.text.contains(marker) ?? false,
            "expected the tool result to contain \(marker); got: \(sendResult?.text ?? "nil")"
        )

        // And the marker must actually have landed in the live shell.
        XCTAssertTrue(
            session.eventLog.recentText(maxLines: 200).contains(marker),
            "marker never appeared in the real terminal"
        )
        XCTAssertTrue(audited.contains { $0.kind == "toolCall" }, "audit trail should record the tool call")
    }
}

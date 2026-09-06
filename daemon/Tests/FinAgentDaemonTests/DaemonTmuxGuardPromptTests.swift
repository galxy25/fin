import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The daemon's half of the send-keys guard. `TmuxCommandGuardTests` proves the policy;
/// this proves the SHIPPED daemon derives it and tells the model about it — the gap that
/// let the previous version's README claim a guarantee the running code did not have.
///
/// `Daemon.run()` is an un-unit-testable async loop, so its three seams are tested
/// directly: `TmuxSendGuard.forHost` (what arms the guard, from the same `connectCommand`
/// the installer writes), `Daemon.makeTurnEngine` (the wiring that hands it to the running
/// engine — the seam a review found untested, where a deleted assignment left the whole
/// suite green and production unguarded), and `Daemon.composedSystemPrompt(…tmuxGuard:)`
/// (what the model is told). If any regresses, production runs unguarded or silently
/// guarded.
final class DaemonTmuxGuardPromptTests: XCTestCase {

    private func registryURL(sessions: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-tmuxguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RegistryDocument.standardFileName)
        if !sessions.isEmpty {
            let document = RegistryDocument(sessions: sessions.map { SessionRegistration(session: $0) })
            try JSONEncoder().encode(document).write(to: url)
        }
        return url
    }

    /// The resident-site posture the installer actually writes: a tmux `connectCommand`
    /// and a registry. Both halves of the allow-list have to survive the trip.
    func testGuardArmsFromTheShippedResidentSiteShape() throws {
        let url = try registryURL(sessions: ["fin", "pocketdj"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.resolved().allowed, ["fin", "pocketdj"])
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t main 'rm -rf ~' Enter").isRefusal)
        XCTAssertEqual(guardPolicy.evaluate("tmux capture-pane -p -t main"), .allow)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t pocketdj 'git status' Enter"), .allow)
    }

    /// The connectCommand the installer ACTUALLY writes
    /// (`scripts/mac-fin-agentd/provision-config.sh`), `\;` and all — the shape that ships
    /// on the resident site. The simplified `tmux new-session -A -s fin` every other test
    /// passes exercises a different lexer path: here the `\;` must survive as a bare `;`
    /// word so `subcommands` splits on it, and the trailing `set status off` must not
    /// itself be refused. A regression there ships a guard whose ownSession is nil, which
    /// refuses every no-`-t` command in the daemon's own session.
    func testGuardArmsFromTheConnectCommandTheInstallerActuallyWrites() throws {
        let url = try registryURL(sessions: ["pocketdj"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin \\; set status off",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.ownSession, "fin")
        XCTAssertEqual(guardPolicy.resolved().allowed, ["fin", "pocketdj"])
        // The own-session fallback is what a no-`-t` command depends on.
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys 'git status' Enter"), .allow)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t fin 'git status' Enter"), .allow)
        XCTAssertTrue(guardPolicy.evaluate("tmux kill-session -t main").isRefusal)
    }

    /// THE WIRING ITSELF. `forHost` and `composedSystemPrompt` were each covered while the
    /// line that joins them to the running engine was not: deleting `engine.tmuxGuard =
    /// tmuxGuard` left the whole suite green while production ran unguarded — and worse
    /// than unguarded, because the prompt still told the model the gate existed. The
    /// assertion is on a refused send, not on the property, so it fails if any link in
    /// factory → engine → send_input comes apart.
    @MainActor
    func testTheDaemonsOwnEngineFactoryArmsTheGuardOnTheSendPath() async throws {
        let session = GuardStubSession()
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin \\; set status off",
            registryFileURL: try registryURL(sessions: ["fin"])
        )
        let engine = Daemon.makeTurnEngine(
            configuration: AgentEngineConfiguration(
                endpointURL: "http://127.0.0.1:1",  // never reached on this path
                modelIdentifier: "stub"
            ),
            session: session,
            tmuxGuard: guardPolicy,
            audit: { _ in }
        )

        let refused = await engine.execute(AgentToolCall(
            id: "t1",
            name: AgentToolSpec.sendInput.name,
            arguments: #"{"input": "tmux send-keys -t main 'rm -rf ~/forges' Enter"}"#
        ))

        XCTAssertTrue(refused.contains("REFUSED"), "got: \(refused)")
        XCTAssertTrue(refused.contains("main"), "got: \(refused)")
        XCTAssertTrue(session.sentInputs.isEmpty, "nothing may reach the PTY")
    }

    /// Told, not just enforced: an armed guard appends its paragraph, and it names the
    /// read path, the allow-list, and the namespace the model may create sessions in.
    func testArmedGuardAppendsItsParagraphToTheSystemPrompt() throws {
        let registry = try registryURL(sessions: ["fin"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: registry
        )
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            tmuxGuard: guardPolicy
        )
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt), "the guard section is additive")
        XCTAssertTrue(prompt.contains("tmux guard"), "got: \(prompt)")
        XCTAssertTrue(prompt.contains("capture-pane"))
        XCTAssertTrue(prompt.contains(TmuxCommandGuard.ownedSessionPrefix))
        XCTAssertTrue(prompt.contains("Sessions you may act on: fin"))
    }

    /// The default parameter is `.unenforced`, so a caller that forgets the argument must
    /// produce a byte-identical prompt — an omission can change nothing.
    func testUnarmedGuardLeavesTheSystemPromptByteIdentical() throws {
        let registry = try registryURL()
        let base = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry
        )
        let explicit = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            tmuxGuard: .unenforced
        )
        XCTAssertEqual(base, Daemon.defaultSystemPrompt)
        XCTAssertEqual(explicit, base)
        XCTAssertFalse(base.contains("tmux guard"))
    }

    /// A host with no tmux session and no registry has no namespace to defend: the guard
    /// stays off, and nothing about the prompt changes. This is also the fail-closed
    /// boundary — `forHost` must not arm with a nil own session and an empty allow-list.
    func testHostWithNeitherTmuxNorRegistryStaysUnarmed() throws {
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "bash -l",
            registryFileURL: try registryURL()
        )
        XCTAssertFalse(guardPolicy.isEnforced)
        XCTAssertNil(guardPolicy.promptSection)
    }
}

/// Minimal `AgentSessionDriving` for the wiring test: no SSH, no PTY, and it records what
/// would have been typed so a refusal can be proven by absence.
@MainActor
final class GuardStubSession: AgentSessionDriving {
    let eventLog = TerminalEventLog()
    var isSessionConnected = true
    private(set) var sentInputs: [String] = []

    func sendAgentInput(_ text: String) {
        sentInputs.append(text)
        eventLog.recordInput(Array(text.utf8))
    }
}

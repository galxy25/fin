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

    /// The resident-site posture the installer actually writes SINCE THE PRIVATE SOCKET:
    /// a `-L`-bearing tmux `connectCommand`. Both facts the guard needs — which socket,
    /// which session — have to survive the trip out of that one string.
    func testGuardArmsFromTheShippedResidentSiteShape() throws {
        let url = try registryURL(sessions: ["fin"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux -L fin new-session -A -s fin",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.ownSocket, .name("fin"))
        XCTAssertEqual(guardPolicy.ownSession, "fin")
        // Its own server, named: unrestricted, no allow-list, nothing to register.
        XCTAssertEqual(
            guardPolicy.evaluate("tmux -L fin send-keys -t fin-build 'git status' Enter"), .allow
        )
        XCTAssertEqual(guardPolicy.evaluate("tmux -L fin ls"), .allow)
        // The ways out: another server, and naming no server at all.
        XCTAssertTrue(guardPolicy.evaluate("tmux -L default send-keys -t main 'rm -rf ~' Enter").isRefusal)
        XCTAssertTrue(guardPolicy.evaluate("TMUX= tmux -L fin kill-session -t main").isRefusal)
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t main 'rm -rf ~' Enter").isRefusal)
    }

    /// NOTHING IS HARDCODED TO "fin". The daemon derives its socket and session names
    /// from whatever `connectCommand` the config carries — a site provisioned with
    /// FIN_TMUX_SOCKET=wharf must guard `wharf`, and must then refuse `-L fin`.
    func testSocketAndSessionNamesComeFromTheConfigNotFromAConstant() throws {
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux -L wharf new-session -A -s dockside \\; set status off",
            registryFileURL: try registryURL()
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.ownSocket, .name("wharf"))
        XCTAssertEqual(guardPolicy.ownSession, "dockside")
        XCTAssertEqual(guardPolicy.evaluate("tmux -L wharf kill-session -t dockside-old"), .allow)
        XCTAssertTrue(guardPolicy.evaluate("tmux -L fin ls").isRefusal)
    }

    /// The connectCommand the installer ACTUALLY writes
    /// (`scripts/mac-fin-agentd/provision-config.sh`), `\;` and all — the shape that ships
    /// on the resident site. The simplified `tmux new-session -A -s fin` every other test
    /// passes exercises a different lexer path: here the `\;` must survive as a bare `;`
    /// word so `subcommands` splits on it, and the trailing `set status off` must not
    /// itself be refused. A regression there ships a guard whose ownSession is nil, which
    /// refuses every no-`-t` command in the daemon's own session.
    func testGuardArmsFromTheConnectCommandTheInstallerActuallyWrites() throws {
        let url = try registryURL(sessions: ["fin"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux -L fin new-session -A -s fin \\; set status off",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.ownSession, "fin")
        XCTAssertEqual(guardPolicy.ownSocket, .name("fin"))
        XCTAssertEqual(guardPolicy.evaluate("tmux -L fin send-keys 'git status' Enter"), .allow)
        XCTAssertEqual(
            guardPolicy.evaluate("tmux -L fin send-keys -t fin 'git status' Enter"), .allow
        )
        XCTAssertTrue(guardPolicy.evaluate("tmux -S /tmp/tmux-501/default kill-session -t main").isRefusal)
    }

    /// The FAIL-CLOSED half of that derivation. A `connectCommand` this parser cannot
    /// read yields `.standard`, and on `.standard` every explicit socket is somebody
    /// else's — so a site that loses its `-L` (a hand-edited config, an old install)
    /// degrades to refusing MORE, never less.
    func testAConnectCommandWithoutASocketDegradesToRefusingEverySocket() throws {
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: try registryURL()
        )
        XCTAssertEqual(guardPolicy.ownSocket, .standard)
        XCTAssertTrue(guardPolicy.evaluate("tmux -L fin ls").isRefusal)
        XCTAssertTrue(guardPolicy.evaluate("tmux -L default ls").isRefusal)
        XCTAssertEqual(guardPolicy.evaluate("tmux ls"), .allow)
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
            connectCommand: "tmux -L fin new-session -A -s fin \\; set status off",
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
            arguments: #"{"input": "tmux -L default send-keys -t main 'rm -rf ~/forges' Enter"}"#
        ))

        XCTAssertTrue(refused.contains("REFUSED"), "got: \(refused)")
        XCTAssertTrue(refused.contains("-L default"), "got: \(refused)")
        XCTAssertTrue(session.sentInputs.isEmpty, "nothing may reach the PTY")
    }

    /// THE SAME WIRING, ONE STEP FURTHER, AND WITHOUT ASKING THE TERMINAL ANYTHING. The
    /// engine used to probe the live shell for `$TMUX` before every tmux-bearing send, so
    /// that a socket-less `tmux …` could be allowed when the shell was proven to be inside
    /// Fin's own server. That proof came back through the same PTY the model types into.
    /// Now the rule is on the command instead: a socket-less tmux command is refused in a
    /// shell that reports confinement and in one that does not, identically — and neither
    /// answer costs a keystroke in the terminal.
    @MainActor
    func testTheFactorysEngineRefusesASocketLessTmuxWhateverTheShellReports() async throws {
        for reported in ["/private/tmp/tmux-501/fin,4242,0", "", nil] {
            let session = GuardStubSession()
            session.reportedTmux = reported
            let engine = Daemon.makeTurnEngine(
                configuration: AgentEngineConfiguration(
                    endpointURL: "http://127.0.0.1:1",
                    modelIdentifier: "stub"
                ),
                session: session,
                tmuxGuard: TmuxSendGuard.forHost(
                    connectCommand: "exec tmux -L fin new-session -A -s fin \\; set status off",
                    registryFileURL: try registryURL(sessions: ["fin"])
                ),
                audit: { _ in }
            )

            let refused = await engine.execute(AgentToolCall(
                id: "t1",
                name: AgentToolSpec.sendInput.name,
                arguments: #"{"input": "tmux send-keys -t main 'rm -rf ~/forges' Enter"}"#
            ))

            XCTAssertTrue(refused.contains("REFUSED"), "got: \(refused)")
            XCTAssertTrue(refused.contains("names no tmux server"), "got: \(refused)")
            XCTAssertTrue(session.sentInputs.isEmpty, "nothing may reach the PTY")
        }
    }

    /// Told, not just enforced: an armed guard appends its paragraph, and it names the
    /// read path and the read-only way to see everything outside Fin's own server.
    func testArmedGuardAppendsItsParagraphToTheSystemPrompt() throws {
        let registry = try registryURL(sessions: ["fin"])
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux -L fin new-session -A -s fin",
            registryFileURL: registry
        )
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            tmuxGuard: guardPolicy
        )
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt), "the guard section is additive")
        XCTAssertTrue(prompt.contains("tmux (enforced in code"), "got: \(prompt)")
        // The model must be told BOTH halves: its own server is unrestricted, and the
        // human's sessions are reachable only through read_session.
        XCTAssertTrue(prompt.contains("-L fin"), "got: \(prompt)")
        XCTAssertTrue(prompt.contains("read_session"), "got: \(prompt)")
        XCTAssertTrue(prompt.contains("\"fin\""), "got: \(prompt)")
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
        XCTAssertFalse(base.contains("tmux (enforced in code"))
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
    /// What the "live shell" would answer if anything asked it for `$TMUX`. Nothing in the
    /// engine does any more — the guard's rules are about the command text — but the daemon
    /// still asks once at launch for its log line, and a test pins that the ANSWER changes
    /// no verdict.
    var reportedTmux: String? = "/private/tmp/tmux-501/fin,4242,0"

    func sendAgentInput(_ text: String) {
        sentInputs.append(text)
        eventLog.recordInput(Array(text.utf8))
    }

    func probeEnvironment(_ name: String, timeout: TimeInterval) async -> String? {
        name == "TMUX" ? reportedTmux : nil
    }
}

import XCTest
@testable import FinAgentCore

/// The send-keys guard's policy table, driven as strings — the production port of
/// `evals/tmux-routing/run_evals.py`'s GuardedTmuxExecutor and its refuse-scenarios
/// ("GUARDRAIL FAILED OPEN"). Every case here is a line a local 12B model could
/// plausibly type into `send_input`.
///
/// No tmux process is started anywhere in this file: the whole guard is pure string
/// logic, which is the point — the machine hosting this suite is the machine at risk.
final class TmuxCommandGuardTests: XCTestCase {

    // The shape of the resident iMac site: the daemon lives in `fin`, `pocketdj` is a
    // registered coding-agent session, and Levi's own `main` is live but unregistered.
    private let allowed: Set<String> = ["fin", "pocketdj"]

    private func verdict(
        _ input: String,
        allowed: Set<String>? = nil,
        own: String? = "fin",
        socket: TmuxSocket = .standard,
        hasRegistry: Bool = true
    ) -> TmuxGuardVerdict {
        TmuxCommandGuard.evaluate(
            input,
            allowedSessions: allowed ?? self.allowed,
            ownSession: own,
            ownSocket: socket,
            hasRegistry: hasRegistry
        )
    }

    private func assertAllows(
        _ input: String,
        allowed: Set<String>? = nil,
        own: String? = "fin",
        socket: TmuxSocket = .standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = verdict(input, allowed: allowed, own: own, socket: socket)
        XCTAssertEqual(
            result, .allow,
            "expected ALLOW for \(input) — got: \(result.refusalMessage ?? "")",
            file: file, line: line
        )
    }

    private func assertRefuses(
        _ input: String,
        naming session: String? = nil,
        allowed: Set<String>? = nil,
        own: String? = "fin",
        socket: TmuxSocket = .standard,
        hasRegistry: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = verdict(input, allowed: allowed, own: own, socket: socket, hasRegistry: hasRegistry)
        guard let message = result.refusalMessage else {
            return XCTFail("expected REFUSE for \(input)", file: file, line: line)
        }
        if let session {
            XCTAssertTrue(
                message.contains(session),
                "refusal must name the session it protected — got: \(message)",
                file: file, line: line
            )
        }
    }

    // MARK: - Read anything

    /// The load-bearing half of the policy: a resident agent that cannot SEE the
    /// machine's real work is useless, so inspection of ANY session — registered or
    /// not — is allowed. "What is the status of all in-flight missions" is literally
    /// `tmux capture-pane -t main -p`.
    func testReadOnlyInspectionOfAnyUnregisteredSessionIsAllowed() {
        assertAllows("tmux capture-pane -t main -p")
        assertAllows("tmux capture-pane -p -t main:0.1")
        assertAllows("tmux list-sessions")
        assertAllows("tmux ls")
        assertAllows("tmux list-windows -t main")
        assertAllows("tmux lsw -t main")
        assertAllows("tmux list-panes -t main")
        assertAllows("tmux lsp -a")
        assertAllows("tmux list-clients")
        assertAllows("tmux has-session -t main")
        assertAllows("tmux display-message -p -t main '#{pane_current_command}'")
        assertAllows("tmux show-options -t main")
        assertAllows("tmux capture-pane -p -t main | tail -40")
        assertAllows("tmux list-sessions -F '#{session_name}' > /dev/null")
    }

    /// Non-tmux traffic must be byte-for-byte unaffected, including commands that merely
    /// mention tmux — the survey's own `grep tmux AgentTools.swift` must keep working.
    func testOrdinaryCommandsAreUntouched() {
        assertAllows("git status")
        assertAllows("ls -la")
        assertAllows("grep -rn tmux daemon/Sources/FinAgentCore/AgentTools.swift")
        assertAllows("cat ~/.tmux.conf")
        assertAllows("swift test --package-path daemon")
        assertAllows("")
    }

    // MARK: - Write only what is registered

    func testSendKeysToAnUnregisteredSessionIsRefused() {
        assertRefuses("tmux send-keys -t main 'rm -rf ~/forges' Enter", naming: "main")
        assertRefuses("tmux send-keys -t main hello", naming: "main")
        assertRefuses("tmux paste-buffer -t main", naming: "main")
    }

    func testEveryMutatingVerbIsTargetChecked() {
        for command in [
            "tmux kill-session -t main",
            "tmux kill-window -t main",
            "tmux kill-pane -t main",
            "tmux respawn-pane -k -t main",
            "tmux respawn-window -k -t main",
            "tmux new-window -t main",
            "tmux split-window -t main",
            "tmux swap-window -s main -t fin",
            "tmux move-window -s main -t fin",
            "tmux join-pane -s main -t fin",
            "tmux break-pane -s main",
            "tmux link-window -s main -t fin",
            "tmux unlink-window -t main",
            "tmux rename-session -t main wrecked",
            "tmux rename-window -t main wrecked",
            "tmux set-option -t main status off",
            "tmux set-window-option -t main automatic-rename off",
            "tmux set-environment -t main FOO bar",
            "tmux clear-history -t main",
            "tmux pipe-pane -t main 'cat > /tmp/spy'",
            "tmux resize-pane -t main -x 1",
            "tmux select-window -t main:0",
        ] {
            assertRefuses(command, naming: "main")
        }
    }

    /// The same verbs against a REGISTERED session are the agent's actual job.
    func testMutatingVerbsAgainstRegisteredSessionsAreAllowed() {
        assertAllows("tmux send-keys -t fin 'swift build' Enter")
        assertAllows("tmux send-keys -t pocketdj 'git status' Enter")
        assertAllows("tmux kill-window -t pocketdj:1")
        assertAllows("tmux new-window -t fin")
        assertAllows("tmux set-option -t fin status off")
    }

    /// No `-t` means tmux acts on the CURRENT session, which is the agent's own — the
    /// one case where an absent target is benign, and only because the daemon's own
    /// session is itself on the allow-list.
    func testMutationWithNoTargetActsOnTheAgentsOwnSession() {
        assertAllows("tmux send-keys 'echo hi' Enter")
        assertAllows("tmux set-option status off")
        assertAllows("tmux new-window")
        // …but not when the host cannot say what its own session is called.
        assertRefuses("tmux send-keys 'echo hi' Enter", own: nil)
        // …and not when its own session is not on the list.
        assertRefuses("tmux send-keys 'echo hi' Enter", naming: "fin", allowed: ["pocketdj"], own: "fin")
    }

    // MARK: - Unconditional refusals

    /// Commands that execute, reach the whole server, or move the human's client are
    /// refused no matter what they target — `kill-server` would take Levi's `main`, this
    /// session, and a running fine-tune with it.
    func testExecutingAndServerWideCommandsAreRefusedRegardlessOfTarget() {
        for command in [
            "tmux kill-server",
            "tmux run-shell 'rm -rf ~/forges'",
            "tmux run -t fin 'echo hi'",
            "tmux if-shell true 'kill-server'",
            "tmux source-file ~/.tmux.conf",
            "tmux bind-key X kill-server",
            "tmux unbind-key C-b",
            "tmux set-hook -t fin pane-died 'kill-server'",
            "tmux command-prompt 'kill-session -t main'",
            "tmux confirm-before -p yes? 'kill-server'",
            "tmux display-popup -t fin -E 'bash'",
            "tmux display-menu -t fin x x x",
            "tmux attach-session -t fin",
            "tmux attach -t main",
            "tmux switch-client -t main",
            "tmux detach-client -s main",
            "tmux lock-server",
            "tmux -c 'rm -rf ~/forges'",
            "tmux -f /tmp/evil.conf new-window",
        ] {
            assertRefuses(command)
        }
    }

    /// Not a tmux command at all, but it ends exactly the way `kill-server` does.
    func testProcessKillersAimedAtTmuxAreRefused() {
        assertRefuses("pkill -f tmux")
        assertRefuses("killall tmux")
        assertAllows("pkill -f some-other-daemon")
    }

    // MARK: - Abbreviations

    /// tmux resolves any unambiguous prefix, so the guard has to as well — otherwise
    /// `tmux send-key` walks straight past a table keyed on `send-keys`.
    func testAbbreviationsAndAliasesResolveToTheirCommand() {
        assertRefuses("tmux send -t main hi", naming: "main")
        assertRefuses("tmux send-key -t main hi", naming: "main")
        assertRefuses("tmux send-k -t main hi", naming: "main")
        assertRefuses("tmux kill-ses -t main", naming: "main")
        assertRefuses("tmux killw -t main", naming: "main")
        assertRefuses("tmux neww -t main")
        assertRefuses("tmux splitw -t main")
        assertRefuses("tmux renamew -t main gone")
        // Ambiguous between kill-server (never allowed) and kill-session: fail closed.
        assertRefuses("tmux kill-se -t fin")
        assertRefuses("tmux kill -t fin")
        // Read-only aliases and prefixes still read.
        assertAllows("tmux capturep -p -t main")
        assertAllows("tmux capture -p -t main")
        assertAllows("tmux has -t main")
    }

    /// An unknown verb cannot be proven read-only, so it is refused rather than guessed
    /// at — the fail-closed rule that keeps a stale table from becoming a hole.
    func testUnknownVerbsFailClosed() {
        assertRefuses("tmux frobnicate -t fin")
        assertRefuses("tmux send-keyz -t fin hi")
    }

    /// A prefix short enough to be ambiguous in real tmux must never be laundered into
    /// a read-only classification here: when several commands match, the most
    /// restrictive class wins.
    func testAmbiguousShortPrefixesResolveToTheMostRestrictiveMatch() {
        for prefix in ["s", "k", "l", "d", "c", "r", "se", "li", "ki", "ne", "sw"] {
            assertRefuses("tmux \(prefix) -t main")
        }
        // A prefix every one of whose matches only reads stays a read: `sh` can only be
        // some `show-*`, and reading is allowed against any session anyway.
        assertAllows("tmux sh -t main")
    }

    /// The table is the policy, so a duplicated name or alias would silently make one
    /// entry unreachable — including, potentially, an `alwaysRefuse` one.
    func testCommandTableHasNoDuplicateNamesOrAliases() {
        var seen: Set<String> = []
        for command in TmuxCommandGuard.commands {
            for token in [command.name] + command.aliases {
                XCTAssertFalse(seen.contains(token), "duplicate tmux command token: \(token)")
                seen.insert(token)
            }
        }
    }

    // MARK: - Target syntax

    func testTargetFormsResolveToTheirSession() {
        assertRefuses("tmux send-keys -t main:0 hi", naming: "main")
        assertRefuses("tmux send-keys -t main:0.1 hi", naming: "main")
        assertRefuses("tmux send-keys -t =main hi", naming: "main")
        assertRefuses("tmux send-keys -tmain hi", naming: "main")
        assertRefuses("tmux send-keys -t \"main\" hi", naming: "main")
        assertRefuses("tmux send-keys -t 'main' hi", naming: "main")
        assertAllows("tmux send-keys -t fin:0.1 hi")
        assertAllows("tmux send-keys -t =fin hi")
        assertAllows("tmux send-keys -tfin hi")
        // A session id, a pane id, a window id or a bare index can point into ANY
        // session on the server, so none of them can be proven safe.
        assertRefuses("tmux send-keys -t $0 hi")
        assertRefuses("tmux send-keys -t %3 hi")
        assertRefuses("tmux send-keys -t @2 hi")
        assertRefuses("tmux send-keys -t 0 hi")
        assertRefuses("tmux send-keys -t")
        // A leading colon is the current session's window — the agent's own.
        assertAllows("tmux send-keys -t :1 hi")
    }

    // MARK: - Sockets

    func testExplicitSocketFlagsCannotReachAnotherServer() {
        assertRefuses("tmux -L other send-keys -t fin hi")
        assertRefuses("tmux -Lother send-keys -t fin hi")
        assertRefuses("tmux -S /tmp/other.sock send-keys -t fin hi")
        assertRefuses("tmux -S /tmp/other.sock kill-server")
        // Reading is allowed everywhere, including on another server.
        assertAllows("tmux -L other list-sessions")
        // A host that already runs on a dedicated socket writes to its own — the shape
        // the structural fix would take. With no `-L`, tmux follows `$TMUX` to the
        // server the agent's own shell is already inside, which is that same socket.
        assertAllows("tmux -L fin send-keys -t fin hi", socket: .name("fin"))
        assertAllows("tmux send-keys -t fin hi", socket: .name("fin"))
        assertRefuses("tmux -L fin send-keys -t main hi", naming: "main", socket: .name("fin"))
    }

    // MARK: - Shell shapes

    func testTmuxIsFoundBehindShellChainingAndPrefixes() {
        assertRefuses("echo hi && tmux send-keys -t main hi", naming: "main")
        assertRefuses("echo hi; tmux send-keys -t main hi", naming: "main")
        assertRefuses("false || tmux send-keys -t main hi", naming: "main")
        assertRefuses("echo hi\ntmux send-keys -t main hi", naming: "main")
        assertRefuses("true | tmux send-keys -t main hi", naming: "main")
        assertRefuses("sudo tmux send-keys -t main hi", naming: "main")
        assertRefuses("sudo -n tmux send-keys -t main hi", naming: "main")
        assertRefuses("command tmux send-keys -t main hi", naming: "main")
        assertRefuses("exec tmux send-keys -t main hi", naming: "main")
        assertRefuses("FOO=1 env BAR=2 tmux send-keys -t main hi", naming: "main")
        assertRefuses("/opt/homebrew/bin/tmux send-keys -t main hi", naming: "main")
        assertRefuses("nohup tmux send-keys -t main hi", naming: "main")
        assertRefuses("$(tmux kill-server)")
        assertRefuses("`tmux kill-server`")
        assertRefuses("ssh localhost tmux send-keys -t main hi", naming: "main")
    }

    /// Quoted shell text is its own command line: `sh -c '…'` and the two-hop
    /// "send a send-keys into a session I AM allowed to drive" both land here.
    func testTmuxNestedInQuotedShellTextIsUnwrapped() {
        assertRefuses("sh -c 'tmux send-keys -t main hi'", naming: "main")
        assertRefuses("bash -c \"tmux kill-server\"")
        assertRefuses("eval 'tmux send-keys -t main hi'", naming: "main")
        assertRefuses("tmux send-keys -t fin 'tmux send-keys -t main hi' Enter", naming: "main")
        // …but ordinary quoted payloads that merely contain the word are fine.
        assertAllows("tmux send-keys -t fin 'grep tmux AgentTools.swift' Enter")
        assertAllows("tmux send-keys -t fin 'cat ~/.tmux.conf' Enter")
    }

    // MARK: - tmux's own command chaining

    func testMultiCommandFormChecksEverySubcommand() {
        assertAllows("tmux new-session -A -s fin \\; set status off")
        assertRefuses("tmux list-sessions \\; kill-server")
        assertRefuses("tmux capture-pane -p -t main \\; send-keys -t main hi", naming: "main")
        assertAllows("tmux capture-pane -p -t main \\; list-windows -t main")
    }

    // MARK: - new-session

    /// Creating a session is the router's `start` action and must stay legal, or the
    /// guardrail inverts. Grouping onto, or attaching to, someone else's session is not.
    func testNewSessionCreatesFreelyButCannotAdoptAnotherSession() {
        assertAllows("tmux new-session -d -s scratch")
        assertAllows("tmux new -d -s pocketdj-2 -c ~/forges")
        assertRefuses("tmux new-session -A -s main", naming: "main")
        assertRefuses("tmux new-session -t main", naming: "main")
        assertAllows("tmux new-session -A -s fin")
    }

    // MARK: - Fail-closed defaults

    /// No registry means the allow-list is exactly the agent's own session — never
    /// "everything" — and the refusal says so, because a model that thinks the registry
    /// merely failed to load will keep trying.
    func testNoRegistryFailsClosedToTheAgentsOwnSession() throws {
        let result = verdict(
            "tmux send-keys -t pocketdj hi",
            allowed: ["fin"],
            hasRegistry: false
        )
        let message = try XCTUnwrap(result.refusalMessage)
        XCTAssertTrue(message.contains("no routing registry"), "got: \(message)")
        XCTAssertTrue(message.contains("fail-closed"), "got: \(message)")
        // The agent's own session still works — a fail-closed guard that bricks the
        // agent is a broken guard.
        assertAllows("tmux send-keys -t fin hi", allowed: ["fin"])
    }

    /// The refusal is a tool result the model must be able to act on: it names the
    /// session, says the attempt is over, and hands back the read commands that DO work.
    func testRefusalTellsTheModelWhatItMayDoInstead() throws {
        let message = try XCTUnwrap(verdict("tmux send-keys -t main hi").refusalMessage)
        XCTAssertTrue(message.contains("REFUSED"))
        XCTAssertTrue(message.contains("main"))
        XCTAssertTrue(message.contains("capture-pane"))
        XCTAssertTrue(message.contains("list-sessions"))
        XCTAssertTrue(message.contains("do not retry"))
        XCTAssertTrue(message.contains("fin, pocketdj"))
        XCTAssertTrue(message.contains("routing-registry.json"))
    }

    // MARK: - The host policy object

    /// `.unenforced` is the app's posture: an arbitrary SSH session where tmux is
    /// optional and the user's own session is often literally named `main`.
    func testUnenforcedGuardChangesNothing() {
        XCTAssertEqual(TmuxSendGuard.unenforced.evaluate("tmux kill-server"), .allow)
        XCTAssertEqual(TmuxSendGuard.unenforced.evaluate("tmux send-keys -t main hi"), .allow)
        XCTAssertNil(TmuxSendGuard.unenforced.promptSection)
    }

    func testForHostArmsOnATmuxConnectCommandEvenWithNoRegistry() throws {
        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin \\; set status off",
            registryFileURL: nil
        )
        XCTAssertTrue(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.ownSession, "fin")
        XCTAssertEqual(guardPolicy.resolved().allowed, ["fin"])
        XCTAssertFalse(guardPolicy.resolved().hasRegistry)
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t main hi").isRefusal)
        XCTAssertEqual(guardPolicy.evaluate("tmux capture-pane -p -t main"), .allow)
        let section = try XCTUnwrap(guardPolicy.promptSection)
        XCTAssertTrue(section.contains("capture-pane"))
        XCTAssertTrue(section.contains("fail-closed"))
    }

    /// A host with neither a tmux session nor a registry has no namespace to defend, so
    /// the guard stays off and `send_input` behaves exactly as it did before.
    func testForHostStaysUnarmedWithoutTmuxOrRegistry() {
        let guardPolicy = TmuxSendGuard.forHost(connectCommand: "", registryFileURL: nil)
        XCTAssertFalse(guardPolicy.isEnforced)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t main hi"), .allow)
    }

    /// The registry file is the authority on every send, not a launch-time snapshot:
    /// a session registered mid-run becomes writable, and a registry that is deleted
    /// shrinks the allow-list back to the agent's own session.
    func testRegistryFileIsRereadOnEveryEvaluation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-tmux-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RegistryDocument.standardFileName)

        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin"),
        ])).write(to: url)

        let guardPolicy = TmuxSendGuard.forHost(
            connectCommand: "tmux new-session -A -s fin",
            registryFileURL: url
        )
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t pocketdj hi").isRefusal)

        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin"),
            SessionRegistration(session: "pocketdj"),
        ])).write(to: url)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t pocketdj hi"), .allow)

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(guardPolicy.evaluate("tmux send-keys -t pocketdj hi").isRefusal)
        XCTAssertEqual(guardPolicy.evaluate("tmux send-keys -t fin hi"), .allow)
    }

    // MARK: - connectCommand parsing

    func testOwnSessionNameIsParsedOutOfTheConnectCommand() {
        XCTAssertEqual(
            TmuxCommandGuard.ownSessionName(inConnectCommand: "tmux new-session -A -s fin \\; set status off"),
            "fin"
        )
        XCTAssertEqual(
            TmuxCommandGuard.ownSessionName(inConnectCommand: "tmux new-session -A -s fin-agentd"),
            "fin-agentd"
        )
        XCTAssertEqual(
            TmuxCommandGuard.ownSessionName(inConnectCommand: "exec tmux new -A -s fin"),
            "fin"
        )
        XCTAssertEqual(
            TmuxCommandGuard.ownSessionName(inConnectCommand: "tmux attach -t fin"),
            "fin"
        )
        XCTAssertNil(TmuxCommandGuard.ownSessionName(inConnectCommand: ""))
        XCTAssertNil(TmuxCommandGuard.ownSessionName(inConnectCommand: "bash -l"))
    }

    func testOwnSocketIsParsedOutOfTheConnectCommand() {
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: "tmux new-session -A -s fin"), .standard)
        XCTAssertEqual(
            TmuxCommandGuard.socket(inConnectCommand: "tmux -L fin new-session -A -s fin"),
            .name("fin")
        )
        XCTAssertEqual(
            TmuxCommandGuard.socket(inConnectCommand: "tmux -S /tmp/fin.sock new-session -A -s fin"),
            .path("/tmp/fin.sock")
        )
    }
}

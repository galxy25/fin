import XCTest
@testable import FinAgentCore

/// The SHRUNKEN guard's rule set, driven as strings.
///
/// The boundary that actually keeps Fin out of the human's tmux sessions is structural —
/// the agent's shell runs on its own tmux socket (`tmux -L fin …`), so its tmux client
/// talks to a different server process. This file tests what is left over: the small,
/// provable rules that stop a command from LEAVING that server (`-L`/`-S`/`TMUX=`),
/// `kill-server`, `pkill tmux`, and the half-typed line that would let a socket flag be
/// assembled across two sends.
///
/// The previous version of this suite tested a 90-command classification table, an
/// allow-list of session names, target extraction and inversion flags — about 900 lines
/// proving properties of a parser that eight reviews still walked through 35 different
/// ways. All of that is deleted along with the code it covered. What remains is the
/// lexing needed to FIND a tmux invocation (which the same reviews proved is genuinely
/// hard) and a fail-closed default.
///
/// No tmux process is started anywhere in this file: the whole guard is pure string
/// logic, which is the point — the machine hosting this suite is the machine at risk.
final class TmuxCommandGuardTests: XCTestCase {

    /// The shape of the resident iMac site after the private socket lands: the daemon's
    /// shell is session `fin` on socket `fin`, and Levi's live `main` is on the DEFAULT
    /// socket, a different server entirely.
    private let ownSocket = TmuxSocket.name("fin")

    private func verdict(
        _ input: String,
        socket: TmuxSocket? = nil,
        own: String? = "fin"
    ) -> TmuxGuardVerdict {
        TmuxCommandGuard.evaluate(input, ownSocket: socket ?? ownSocket, ownSession: own)
    }

    private func assertAllows(
        _ input: String,
        socket: TmuxSocket? = nil,
        own: String? = "fin",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = verdict(input, socket: socket, own: own)
        XCTAssertEqual(
            result, .allow,
            "expected ALLOW for \(input) — got: \(result.refusalMessage ?? "")",
            file: file, line: line
        )
    }

    private func assertRefuses(
        _ input: String,
        naming fragment: String? = nil,
        socket: TmuxSocket? = nil,
        own: String? = "fin",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = verdict(input, socket: socket, own: own)
        guard let message = result.refusalMessage else {
            return XCTFail("expected REFUSE for \(input)", file: file, line: line)
        }
        if let fragment {
            XCTAssertTrue(
                message.contains(fragment),
                "refusal must name what it protected — got: \(message)",
                file: file, line: line
            )
        }
    }

    // MARK: - R1: socket selection, the one rule

    /// THE RULE. Every way of naming another tmux server is refused; the agent's OWN
    /// socket is not.
    func testNamingAnotherTmuxServerIsRefused() {
        assertRefuses("tmux -L default ls", naming: "-L default")
        assertRefuses("tmux -L main send-keys -t main 'rm -rf ~' Enter")
        assertRefuses("tmux -S /private/tmp/tmux-501/default ls", naming: "-S /private/tmp/tmux-501/default")
        assertRefuses("tmux -S /tmp/tmux-501/default kill-session -t main")
        // Even a read: on another server, a read is the first half of learning what to
        // aim at, and read_session is the supported path for it.
        assertRefuses("tmux -L default capture-pane -p -t main")
    }

    /// The agent's own server, named explicitly, is still the agent's own server.
    func testNamingTheAgentsOwnSocketIsAllowed() {
        assertAllows("tmux -L fin ls")
        assertAllows("tmux -L fin new-session -d -s fin-build")
        assertAllows("tmux -L fin send-keys -t fin-build 'swift build' Enter")
    }

    /// Getopt packs short options, so the socket flag can hide anywhere in a cluster —
    /// this is the shape that let `tmux -2f ls <mutation>` slip past the old parser
    /// entirely. Real tmux reads `-2`, then `-L other`, then the command.
    func testAClusteredSocketFlagIsStillASocketFlag() {
        assertRefuses("tmux -2L default kill-server")
        assertRefuses("tmux -uL default ls")
        assertRefuses("tmux -Ldefault ls")
        assertRefuses("tmux -S/tmp/tmux-501/default ls")
        // Quoting says nothing about what is a flag: the shell strips it before tmux
        // sees argv.
        assertRefuses("tmux '-L' default ls")
        assertRefuses("tmux \"-L\" \"default\" ls")
    }

    /// A dangling socket flag is a socket flag whose value has not been typed yet. It
    /// used to walk off the end of the argument array and trap — a four-character
    /// `send_input` crashed the daemon, which is the one thing the guard must never do.
    func testADanglingSocketFlagIsAVerdictNotACrash() {
        assertRefuses("tmux -L")
        assertRefuses("tmux -S")
        // A value flag in last position that is NOT a socket flag must be a verdict too,
        // not a trap: the old parser advanced its index twice and walked off the end.
        XCTAssertEqual(verdict("tmux -f"), .allow)
        XCTAssertEqual(verdict("tmux -c"), .allow)
    }

    /// On a host that never got a private socket, `ownSocket` is `.standard` and ANY
    /// explicit socket is somebody else's. Fail closed: the daemon's `socket(inConnect…)`
    /// falls back to `.standard` whenever it cannot read the connect command.
    func testOnTheSharedSocketEveryExplicitSocketIsRefused() {
        assertRefuses("tmux -L fin ls", socket: .standard)
        assertRefuses("tmux -S /tmp/tmux-501/fin ls", socket: .standard)
        assertAllows("tmux ls", socket: .standard)
    }

    // MARK: - R2: kill-server

    /// `kill-server` ends a whole server. On the private socket that is the agent's own
    /// shell mid-turn; on a shared one it is everything.
    func testKillServerAndItsPrefixesAreRefused() {
        assertRefuses("tmux kill-server")
        assertRefuses("tmux kill-serv")
        assertRefuses("tmux kill-ser")
        assertRefuses("tmux kill")
        assertRefuses("tmux ls \\; kill-server")
        assertRefuses("tmux ls ';' kill-server")
    }

    /// The kill family that is NOT kill-server stays allowed: on Fin's own server every
    /// session is Fin's, so killing one is ordinary housekeeping.
    func testKillingFinsOwnSessionsIsOrdinaryWork() {
        assertAllows("tmux kill-session -t fin-build")
        assertAllows("tmux kill-window -t fin-build:1")
        assertAllows("tmux kill-pane -t fin-build")
        assertAllows("tmux kill-session -a -t fin")
    }

    // MARK: - R3: process killers

    /// A signal is not a tmux command and no socket boundary stops one: `pkill tmux`
    /// kills every tmux server on the machine, the human's included.
    func testProcessKillersAimedAtTmuxAreRefused() {
        assertRefuses("pkill tmux")
        assertRefuses("killall tmux")
        assertRefuses("pkill -f tmux")
        assertRefuses("sudo pkill -9 tmux")
        assertAllows("pkill node")
        assertAllows("killall Dock")
    }

    // MARK: - R4: editing TMUX out of the environment

    /// THE HOLE THE PRIVATE SOCKET DOES NOT CLOSE, and the reason this rule exists.
    /// Verified on tmux 3.6a against two private sockets (never the default one): from a
    /// pane on socket A, `TMUX=<socket B path>,0,0 tmux ls` listed socket B's sessions —
    /// tmux takes its socket path from `$TMUX` when neither `-L` nor `-S` is given. So
    /// editing that variable away is a socket selection wearing no flag, and with TMUX
    /// unset tmux falls back to the label `default`, which is the human's server.
    func testEditingTheTmuxVariableAwayIsRefused() {
        assertRefuses("TMUX= tmux ls", naming: "TMUX")
        assertRefuses("TMUX=/private/tmp/tmux-501/default,0,0 tmux ls")
        assertRefuses("env -u TMUX tmux ls")
        assertRefuses("env --unset=TMUX tmux kill-server")
        assertRefuses("unset TMUX; tmux ls")
        assertRefuses("set -e TMUX; tmux ls")
    }

    /// AND WITHOUT A TMUX COMMAND IN THE SAME SEND. `export TMUX=…` contains no tmux
    /// TOKEN at all (its basename is `default`), so a rule that waited for one would allow
    /// the assignment and then judge the NEXT send — a bare `tmux send-keys -t main …` —
    /// against a variable that no longer points at Fin's server. The guard sees one send at
    /// a time, so the assignment is the only moment it can act.
    func testEditingTheTmuxVariableIsRefusedEvenWithNoTmuxCommandInTheSend() {
        assertRefuses("export TMUX=/private/tmp/tmux-501/default")
        assertRefuses("set -x TMUX /private/tmp/tmux-501/default")
        assertRefuses("unset TMUX")
        assertRefuses("env -u TMUX bash")
        assertAllows("export FOO=/private/tmp/tmux-501/default")
        // …including inside a payload a runner will execute, where the unwrapping path
        // reaches the same rule.
        assertRefuses("sh -c 'TMUX= tmux ls'")
        assertRefuses("bash -c \"env -u TMUX tmux kill-server\"")
    }

    // MARK: - R0: the confinement the other rules assume

    /// EVERY OTHER RULE ASSUMES A BARE `tmux …` REACHES FIN'S OWN SERVER, and that is true
    /// only because `$TMUX` points there — a fact about a connectCommand typed into a PTY,
    /// which can fail quietly. When the daemon's probe cannot confirm it, a bare command
    /// names no socket for R1 to catch and would land on the human's server, so every tmux
    /// command is refused instead. read_session still works; the refusal says so.
    func testWithoutProofOfConfinementEveryTmuxCommandIsRefused() {
        let unproven = TmuxSendGuard(
            isEnforced: true, ownSession: "fin", ownSocket: .name("fin"),
            shellIsOnOwnServer: false
        )
        XCTAssertTrue(unproven.evaluate("tmux ls").isRefusal)
        XCTAssertTrue(unproven.evaluate("tmux send-keys -t fin-build 'make' Enter").isRefusal)
        XCTAssertTrue(unproven.evaluate("tmux -L fin ls").isRefusal)
        XCTAssertEqual(unproven.evaluate("git status"), .allow, "non-tmux work is untouched")
        XCTAssertTrue(
            unproven.evaluate("tmux ls").refusalMessage?.contains("never confirmed") == true,
            "the refusal must say WHY, or the model will keep retrying"
        )
    }

    /// The probe's answer, parsed. `$TMUX` is `<socket path>,<pid>,<session>`.
    func testShellReportIsMatchedAgainstTheConfiguredSocket() {
        let fin = TmuxSocket.name("fin")
        XCTAssertTrue(TmuxSendGuard.shellReportIsOwnServer("/private/tmp/tmux-501/fin,4242,0", socket: fin))
        XCTAssertTrue(TmuxSendGuard.shellReportIsOwnServer("/private/tmp/tmux-501/fin", socket: fin))
        // The human's server, an empty variable, and a shell that never answered.
        XCTAssertFalse(TmuxSendGuard.shellReportIsOwnServer("/private/tmp/tmux-501/default,1,0", socket: fin))
        XCTAssertFalse(TmuxSendGuard.shellReportIsOwnServer("", socket: fin))
        XCTAssertFalse(TmuxSendGuard.shellReportIsOwnServer(nil, socket: fin))
        // A socket named by PATH is compared as a path.
        let path = TmuxSocket.path("/var/run/fin.sock")
        XCTAssertTrue(TmuxSendGuard.shellReportIsOwnServer("/var/run/fin.sock,9,0", socket: path))
        XCTAssertFalse(TmuxSendGuard.shellReportIsOwnServer("/var/run/other.sock,9,0", socket: path))
        // `.standard` cannot be proven this way and does not need to be: there is no
        // confinement to lose on the shared socket, and demanding proof there would refuse
        // every tmux command on a host that deliberately runs without a private one.
        XCTAssertTrue(TmuxSendGuard.shellReportIsOwnServer(nil, socket: .standard))
    }

    /// The rule is anchored to heads that actually edit the environment. Loose, it made
    /// `grep -e tmux config.fish` a refusal — an ordinary read of the very file that
    /// configures this.
    func testOrdinaryCommandsThatMentionTmuxKeepWorking() {
        assertAllows("grep -e tmux ~/.config/fish/config.fish")
        assertAllows("env tmux ls")
        assertAllows("env FOO=1 tmux ls")
        assertAllows("unset FOO; tmux ls")
    }

    // MARK: - R5: half a command is not a command

    /// The PTY concatenates sends, so a line ending in a continuation or an open quote is
    /// judged with the next send it has not seen. `tmux -L \` then `default kill-server`
    /// is two individually-harmless calls the shell joins at its continuation prompt.
    func testHalfTypedLinesAreRefusedBecauseThePtyJoinsThem() {
        assertRefuses("tmux -L \\")
        assertRefuses("tmux \\")
        assertRefuses("tmux ls '")
        // A fragment that could still BECOME tmux, with no tmux in it at all.
        assertRefuses("t\\")
        assertRefuses("tm\\")
        // …and the normal shape, with the trailing newline the engine's forced path adds
        // to every command it extracts. Judging the raw argument let this pass.
        assertRefuses("tmux ls \\\n")
        assertAllows("echo hi \\\n")
    }

    // MARK: - Finding the word tmux at all

    /// The lexer's job, and the part of the old file that earned its keep: the shell
    /// assembles the word out of quoting and escaping, and every one of these spellings
    /// was verified to run tmux.
    func testTmuxSpelledToDefeatASubstringTestIsStillFound() {
        assertRefuses("t\\mux -L default kill-server")
        assertRefuses("tm\"u\"x -L default ls")
        assertRefuses("tm'u'x -L default ls")
        assertRefuses("TMUX -L default ls")            // case-insensitive volume
        assertRefuses("$'tmux' -L default ls")
        assertRefuses("/opt/homebrew/bin/tmux -L default ls")
    }

    /// Wrappers, shell keywords, chaining and command substitution: the head is not
    /// always the command, and an unknown head is not a stop sign.
    func testTmuxIsFoundBehindShellChainingAndWrappers() {
        assertRefuses("sudo tmux -L default kill-server")
        assertRefuses("env FOO=1 tmux -L default ls")
        assertRefuses("cd /tmp && tmux -L default ls")
        assertRefuses("echo hi; tmux -L default ls")
        assertRefuses("$(tmux -L default ls)")
        assertRefuses("if tmux -L default kill-server; then :; fi")
        assertRefuses("for i in 1; do tmux -L default ls; done")
        assertRefuses("find . -maxdepth 0 -exec tmux -L default ls \\;")
        assertRefuses("timeout 5 tmux -L default ls")
        assertRefuses("ssh localhost tmux -L default ls")
    }

    /// Payloads that a runner will EXECUTE are unwrapped with the same lexer; the word
    /// and its socket flag sit in plain sight in a single send.
    func testTmuxNestedInQuotedShellTextIsUnwrapped() {
        assertRefuses("sh -c 'tmux -L default kill-server'")
        assertRefuses("bash -c \"tmux -L default ls\"")
        assertRefuses("eval 'tmux -L default ls'")
        assertRefuses("python3 -c 'import os; os.system(\"tmux -L default kill-server\")'")
        assertRefuses("perl -e 'system(\"tmux -L default ls\")'")
        assertRefuses("awk 'BEGIN{system(\"tmux -L default ls\")}'")
        assertRefuses("osascript -e 'do shell script \"tmux -L default ls\"'")
    }

    /// stdin is invisible to a byte-level guard, so both shapes that build tmux's command
    /// on the other side of a pipe are refused whole rather than parsed.
    func testCommandsBuiltOnTheOtherSideOfAPipeAreRefused() {
        assertRefuses("echo \"tmux -L default kill-server\" | sh")
        assertRefuses("printf 'tmux -L default ls\\n' | bash")
        assertRefuses("echo \"-L default kill-server\" | xargs tmux")
    }

    /// Text that merely MENTIONS tmux is data, not a command — and this repo's current
    /// work is documenting this guard, so refusing it costs real work.
    func testTextThatMerelyMentionsTmuxIsNotACommand() {
        assertAllows("grep -rn 'tmux -L default' daemon/Sources")
        assertAllows("git commit -m 'guard: refuse tmux -L other'")
        assertAllows("echo 'tmux -L default kill-server' >> notes.md")
        assertAllows("printf 'tmux -L other ls\\n' >> notes.md")
        assertAllows("man tmux")
        assertAllows("brew install tmux")
        assertAllows("which tmux")
    }

    // MARK: - Everything else is untouched

    /// Non-tmux traffic must be byte-for-byte unaffected, and so must ordinary work on
    /// the agent's OWN server — there is no allow-list any more, and nothing to register.
    func testOrdinaryCommandsAndOwnServerWorkAreUntouched() {
        assertAllows("git status")
        assertAllows("ls -la")
        assertAllows("swift test --package-path daemon")
        assertAllows("cat ~/.tmux.conf")
        assertAllows("")
        assertAllows("tmux ls")
        assertAllows("tmux new-session -d -s fin-build")
        assertAllows("tmux send-keys -t fin-build 'swift build' Enter")
        assertAllows("tmux capture-pane -p -t fin-build")
        assertAllows("tmux rename-session -t fin-build builder")
        assertAllows("tmux set-option -g status off")
        assertAllows("tmux run-shell 'echo hi'")
    }

    /// The guard is OFF unless a host arms it, and `.unenforced` is a named value rather
    /// than a nil hook so it can never be disarmed by omission. This is the Fin app's
    /// posture: an arbitrary SSH session where the user's own session is often `main`.
    func testUnenforcedGuardChangesNothing() {
        let unenforced = TmuxSendGuard.unenforced
        XCTAssertEqual(unenforced.evaluate("tmux -L default kill-server"), .allow)
        XCTAssertEqual(unenforced.evaluate("pkill tmux"), .allow)
        XCTAssertNil(unenforced.promptSection)
    }

    // MARK: - Reading the connectCommand

    /// The daemon derives BOTH its own socket and its own session from the connectCommand
    /// the installer writes — nothing is hardcoded to "fin". A regression here disarms R1
    /// (the guard would think it lives on the default socket and refuse its own server).
    func testOwnSocketAndSessionAreParsedOutOfTheConnectCommand() {
        let command = "tmux -L fin new-session -A -s fin \\; set status off"
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: command), .name("fin"))
        XCTAssertEqual(TmuxCommandGuard.ownSessionName(inConnectCommand: command), "fin")

        let renamed = "tmux -L wharf new-session -A -s dockside"
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: renamed), .name("wharf"))
        XCTAssertEqual(TmuxCommandGuard.ownSessionName(inConnectCommand: renamed), "dockside")

        let pathForm = "tmux -S /var/run/fin.sock attach-session -t fin"
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: pathForm), .path("/var/run/fin.sock"))
        XCTAssertEqual(TmuxCommandGuard.ownSessionName(inConnectCommand: pathForm), "fin")

        // Clustered and case-folded forms, both legal on this volume.
        XCTAssertEqual(TmuxCommandGuard.ownSessionName(inConnectCommand: "tmux new -As fin"), "fin")
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: "TMUX -L fin new -A -s fin"), .name("fin"))

        // A connectCommand with no tmux in it: no socket, no session — and `forHost`
        // leaves the guard unarmed rather than guessing.
        XCTAssertEqual(TmuxCommandGuard.socket(inConnectCommand: "bash -l"), .standard)
        XCTAssertNil(TmuxCommandGuard.ownSessionName(inConnectCommand: "bash -l"))
    }

    /// The whole posture, end to end: a guard built from the connectCommand the installer
    /// writes allows everything on its own server and refuses the way out.
    func testTheShippedPrivateSocketPostureAllowsItsOwnServerAndRefusesTheWayOut() {
        let policy = TmuxSendGuard(
            isEnforced: true,
            ownSession: TmuxCommandGuard.ownSessionName(
                inConnectCommand: "tmux -L fin new-session -A -s fin \\; set status off"
            ),
            ownSocket: TmuxCommandGuard.socket(
                inConnectCommand: "tmux -L fin new-session -A -s fin \\; set status off"
            )
        )
        XCTAssertEqual(policy.ownSession, "fin")
        XCTAssertEqual(policy.ownSocket, .name("fin"))
        XCTAssertEqual(policy.evaluate("tmux send-keys -t fin-build 'make' Enter"), .allow)
        XCTAssertEqual(policy.evaluate("tmux -L fin ls"), .allow)
        XCTAssertTrue(policy.evaluate("tmux -L default send-keys -t main 'rm -rf ~' Enter").isRefusal)
        XCTAssertTrue(policy.evaluate("TMUX= tmux kill-session -t main").isRefusal)
    }

    /// The refusal the MODEL reads has to end the attempt AND redirect it — a vague
    /// refusal just gets retried, because `send_input`'s own description tells the model
    /// not to ask before acting. Since the private socket landed there is exactly one
    /// right answer to redirect to, and it is not a shell command.
    func testRefusalPointsTheModelAtReadSession() throws {
        let message = try XCTUnwrap(verdict("tmux -L default capture-pane -p -t main").refusalMessage)
        XCTAssertTrue(message.contains("REFUSED"))
        XCTAssertTrue(message.contains("read_session"), "got: \(message)")
        XCTAssertTrue(message.contains("do not retry"), "got: \(message)")
        // The one legitimate shape the guard cannot tell from a command: file content.
        XCTAssertTrue(message.contains("here-doc"), "got: \(message)")
    }

    /// The half-typed refusal is the one refusal the model SHOULD retry, so it must not
    /// carry the standard "do not retry" text.
    func testTheHalfCommandRefusalTellsTheModelToResendOnOneLine() throws {
        let message = try XCTUnwrap(verdict("tmux -L \\").refusalMessage)
        XCTAssertTrue(message.contains("one line"), "got: \(message)")
        XCTAssertTrue(message.contains("SHOULD retry"), "got: \(message)")
    }

    /// The prompt the model gets when the guard is armed: where it lives, that its own
    /// server is unrestricted, and that read_session is the path to everything else.
    func testArmedPromptNamesTheOwnServerAndTheReadPath() throws {
        let policy = TmuxSendGuard(isEnforced: true, ownSession: "fin", ownSocket: .name("fin"))
        let section = try XCTUnwrap(policy.promptSection)
        XCTAssertTrue(section.contains("-L fin"), "got: \(section)")
        XCTAssertTrue(section.contains("read_session"), "got: \(section)")
        XCTAssertTrue(section.contains("kill-server"), "got: \(section)")
    }
}

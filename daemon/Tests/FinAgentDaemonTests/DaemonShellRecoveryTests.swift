import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The pure halves of shell recovery (`Daemon.recoverUnreadyShell`) and of the
/// pre-readiness heartbeat. The recovery itself needs a tmux server and belongs in the
/// live shakedown; what can go wrong WITHOUT one is the kill pattern — `pkill -f` is a
/// regex over every process's argv, including the `sh -c pkill …` that carries it.
@MainActor
final class DaemonShellRecoveryTests: XCTestCase {

    private func matches(_ pattern: String, _ argv: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: argv, range: NSRange(argv.startIndex..., in: argv)) != nil
    }

    /// The server's argv is the first client's (macOS tmux has no setproctitle), so it
    /// and Fin's own attached client match; the human's server, a similarly-named
    /// socket, and the kill command itself do not.
    func testTheServerPatternMatchesFinsServerAndNothingElse() {
        let pattern = Daemon.tmuxServerProcessPattern(for: .name("fin"))!
        XCTAssertTrue(matches(pattern, "tmux -L fin new-session -A -s fin ; set status off"))
        XCTAssertTrue(matches(pattern, "/opt/homebrew/bin/tmux -L fin new-session -A -s fin"))
        XCTAssertTrue(matches(pattern, "tmux -L fin"), "a bare server that dropped its arguments")
        XCTAssertFalse(matches(pattern, "tmux new-session -s main"), "the human's server on the default socket")
        XCTAssertFalse(matches(pattern, "tmux -L finance attach"), "a socket whose name merely starts the same")
        XCTAssertFalse(matches(pattern, "tmux -L fin2 attach"))
        let quoted = Daemon.shellQuoted(pattern)
        let killer = "sh -c pkill -TERM -f \(quoted); sleep 1; pkill -KILL -f \(quoted); true"
        XCTAssertFalse(matches(pattern, killer), "the kill command must not match its own argv: \(killer)")
    }

    func testNoPatternForTheDefaultSocketOrAnOddName() {
        XCTAssertNil(Daemon.tmuxServerProcessPattern(for: .standard), "the default socket is the human's server")
        XCTAssertNil(Daemon.tmuxServerProcessPattern(for: .name("we ird")))
        XCTAssertNil(Daemon.tmuxServerProcessPattern(for: .name("a|b")))
        XCTAssertNil(Daemon.tmuxServerProcessPattern(for: .name("")))
        XCTAssertEqual(Daemon.tmuxServerProcessPattern(for: .path("/tmp/fin.sock")), "(^|/)tmux -S /tmp/fin\\.sock( |$)")
    }

    func testTheTmuxInvocationNamesAndQuotesTheSocket() {
        XCTAssertEqual(Daemon.tmuxInvocation(for: .standard), "tmux")
        XCTAssertEqual(Daemon.tmuxInvocation(for: .name("fin")), "tmux -L 'fin'")
        XCTAssertEqual(Daemon.tmuxInvocation(for: .path("/tmp/it's.sock")), "tmux -S '/tmp/it'\\''s.sock'")
    }

    /// A body that has not proved its shell yet says so, whatever else is true.
    func testAFreshDaemonReportsUnavailableUntilItsShellAnswers() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/nonexistent"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "auditLogPath": "\(NSTemporaryDirectory())fin-agentd-recovery-\(UUID().uuidString).jsonl"
        }
        """
        let daemon = Daemon(config: try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8)))
        XCTAssertEqual(daemon.siteStateName, "unavailable")
    }
}

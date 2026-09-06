import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(Glibc)
import Glibc
#endif

/// Live proof that the `LC_FIN_AGENT` marker reaches the REMOTE login shell — the hijack
/// guard's load-bearing link, which `DaemonSessionEnvironmentTests` (dictionary merging)
/// and `DaemonLaunchOrderTests` (what `run()` requests) cannot see. The session is built
/// exactly the way `Daemon.run()` builds its own, from a `server` block with no
/// `environment` at all (the deployed cloud config's shape), against this dev machine's
/// sshd as the current user; then the shell is asked what it sees.
///
/// No tmux anywhere, on purpose: the variable has to be read by the login shell itself,
/// where the auto-attach guards run. A shell inside a tmux attach inherits only what the
/// tmux SERVER was started with (plus `update-environment`), so probing there would
/// false-fail whenever the user's own tmux server is up. Skips cleanly off the provisioned
/// dev machine, like `LiveIntegrationTests`.
///
/// Two rules keep the test from performing the very hijack it guards against:
///
/// - **It types exactly one line, and only after the shell has spoken and gone quiet.**
///   Not `waitForShellReady`: that probes with `echo FIN_READY_<n>` in a retry loop, and
///   on the regression this test exists to catch — the login shell exec'd into the
///   human's live tmux session — every one of those probes would execute at whatever
///   prompt, or inside whatever full-screen program, is open there. The single line is
///   the marker probe itself; the moment its answer shows a non-empty `$TMUX` the
///   session is disconnected before anything else can be typed.
/// - **It refuses to run where it could prove nothing, and refuses to connect where it
///   would hijack.** The auto-attach lives outside the repo (this machine's
///   `~/.config/fish/config.fish`); on a host whose login shell has no auto-attach at all
///   `TMUX=[]` holds trivially and a broken marker is invisible, so the test skips. On a
///   host whose auto-attach does not mention the marker, the daemon would land in the
///   live session — the test fails right there, statically, without opening SSH.
///
/// A red run therefore means one of: a Citadel upgrade that sends env requests after the
/// shell request (today `TTY.swift` sends them first), an sshd whose `AcceptEnv` no
/// longer forwards `LC_*`, or a login shell that attaches tmux without honoring the
/// marker — each of which quietly re-opens the 2026-09-05 iMac hijack while every unit
/// test stays green.
@MainActor
final class DaemonSessionMarkerLiveTests: XCTestCase {

    private static let privateKeyPath = ("~/.ssh/levi_id_ed25519" as NSString).expandingTildeInPath
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

    /// What the login shell's own startup files say about tmux auto-attach: nothing (no
    /// exec'd attach anywhere — the marker has nothing to guard), an attach that never
    /// mentions the marker (the hijack, live), or an attach that does.
    enum AutoAttachPosture: Equatable {
        case noAutoAttach
        case unguarded(file: String)
        case guarded(file: String)
    }

    /// The account's login shell from the user database — what sshd starts for this
    /// user. Not `$SHELL`: the test process inherits that from whatever launched it (a
    /// zsh tool shell on a fish account, say), and reading the wrong shell's startup
    /// files would skip this test on the one machine it exists for.
    static func accountLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? ""
    }

    /// The files an SSH login shell of the given kind reads.
    static func loginShellStartupFiles(shell: String, home: String) -> [String] {
        if shell.hasSuffix("/fish") { return ["\(home)/.config/fish/config.fish"] }
        if shell.hasSuffix("/zsh") { return ["\(home)/.zprofile", "\(home)/.zshrc"] }
        return ["\(home)/.bash_profile", "\(home)/.profile", "\(home)/.bashrc"]
    }

    static func autoAttachPosture(files: [String]) -> AutoAttachPosture {
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let attaches = text.contains("tmux new-session") || text.contains("tmux attach")
                || text.contains("tmux new ")
            guard attaches else { continue }
            return text.contains(DaemonConfig.ServerConfig.agentMarkerName)
                ? .guarded(file: file)
                : .unguarded(file: file)
        }
        return .noAutoAttach
    }

    /// The posture detector itself, against fixtures the test owns — so the live test's
    /// precondition is not the one thing in this file that runs unverified.
    func testAutoAttachPostureReadsTheGuardFromTheStartupFile() throws {
        let dir = NSTemporaryDirectory() + "fin-agentd-posture-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let guarded = dir + "/guarded.fish"
        try Data("""
        if status is-interactive; and set -q SSH_TTY; and not set -q TMUX; and not set -q LC_FIN_AGENT
            exec tmux new-session -A -s main
        end
        """.utf8).write(to: URL(fileURLWithPath: guarded))
        let unguarded = dir + "/unguarded.sh"
        try Data("""
        if [ -n "$SSH_TTY" ] && [ -z "$TMUX" ]; then exec tmux new-session -A -s main; fi
        """.utf8).write(to: URL(fileURLWithPath: unguarded))
        let plain = dir + "/plain.sh"
        try Data("export EDITOR=vim\n".utf8).write(to: URL(fileURLWithPath: plain))

        XCTAssertEqual(Self.autoAttachPosture(files: [guarded]), .guarded(file: guarded))
        XCTAssertEqual(Self.autoAttachPosture(files: [unguarded]), .unguarded(file: unguarded))
        XCTAssertEqual(Self.autoAttachPosture(files: [plain]), .noAutoAttach)
        XCTAssertEqual(Self.autoAttachPosture(files: [dir + "/missing"]), .noAutoAttach)
        XCTAssertEqual(Self.autoAttachPosture(files: [plain, guarded]), .guarded(file: guarded),
                       "the first file that attaches decides")
        XCTAssertEqual(Self.loginShellStartupFiles(shell: "/opt/homebrew/bin/fish", home: "/h"),
                       ["/h/.config/fish/config.fish"])
        XCTAssertEqual(Self.loginShellStartupFiles(shell: "/bin/zsh", home: "/h"), ["/h/.zprofile", "/h/.zshrc"])
        XCTAssertEqual(Self.loginShellStartupFiles(shell: "/bin/bash", home: "/h"),
                       ["/h/.bash_profile", "/h/.profile", "/h/.bashrc"])
    }

    func testMarkerReachesTheRemoteLoginShellAndKeepsItOutOfTmux() async throws {
        guard FileManager.default.fileExists(atPath: Self.privateKeyPath) else {
            throw XCTSkip("No SSH key at \(Self.privateKeyPath) — live tests only run on the provisioned dev machine.")
        }
        let startupFiles = Self.loginShellStartupFiles(
            shell: Self.accountLoginShell(),
            home: NSHomeDirectory()
        )
        switch Self.autoAttachPosture(files: startupFiles) {
        case .noAutoAttach:
            throw XCTSkip("""
                No tmux auto-attach in the login shell's startup files (\(startupFiles.joined(separator: ", "))) — \
                nothing for the marker to guard here, so a green run would prove nothing about the hijack.
                """)
        case .unguarded(let file):
            XCTFail("""
                \(file) auto-attaches tmux without honoring \(DaemonConfig.ServerConfig.agentMarkerName): \
                the daemon WOULD land in the live session, so this test refuses to connect. \
                Gate the attach on the marker (README: "The session marker").
                """)
            return
        case .guarded:
            break
        }
        let keyPEM = try String(contentsOfFile: Self.privateKeyPath, encoding: .utf8)

        // The deployed shape: no `environment`, no `connectCommand`. The marker is the only
        // env request on the channel, and the bare login shell is what answers.
        let server = try JSONDecoder().decode(DaemonConfig.ServerConfig.self, from: Data("""
        {"host": "127.0.0.1", "port": 22, "username": "\(NSUserName())", "privateKeyPath": "\(Self.privateKeyPath)"}
        """.utf8))
        let configuration = Daemon.sessionConfiguration(server: server, privateKeyPEM: keyPEM)
        XCTAssertEqual(configuration.environment, ["LC_FIN_AGENT": "1"])
        XCTAssertEqual(configuration.connectCommand, "")

        let session = HeadlessTerminalSession(configuration: configuration)
        self.session = session
        session.connect()
        do {
            try await session.waitForConnection(timeout: 20)
        } catch {
            throw XCTSkip("Local sshd not reachable: \(error.localizedDescription)")
        }

        // Readiness without typing: the login shell has printed something (its prompt)
        // and then said nothing for a second. A keystroke sent to a still-spawning shell
        // would be flushed, which is a failed run, not a hijack — the acceptable side.
        try await Self.waitUntilOutputSettles(session, quietFor: 1.0, timeout: 20)

        // The one line. It carries `$LC_FIN_AGENT` and `$TMUX` unexpanded, so the expected
        // text can only come from the remote shell expanding them: the marker arrived,
        // and the shell that got it is not inside a tmux session.
        let nonce = Int.random(in: 100_000...999_999)
        let baseline = session.eventLog.events.last?.id
        let sentAt = Date()
        session.sendAgentInput("echo \"P\(nonce) LCVAL=$LC_FIN_AGENT TMUX=[$TMUX]\"\r")
        let expected = "P\(nonce) LCVAL=1 TMUX=[]"

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let response = session.eventLog.outputText(after: baseline, orRecordedAfter: sentAt)
            // The answer, as opposed to the terminal's echo of the keystrokes.
            if let answer = response.split(separator: "\n").first(where: {
                $0.contains("P\(nonce) LCVAL=") && !$0.contains("echo")
            }) {
                if !answer.contains("TMUX=[]") {
                    // Inside somebody's tmux: stop typing NOW, then report.
                    session.disconnect()
                }
                XCTAssertTrue(answer.contains(expected), """
                    the login shell must see LC_FIN_AGENT=1 and must not be inside tmux; it answered:
                    \(answer)
                    """)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("""
            no answer to the single marker probe within 10s (a still-spawning shell may have flushed it); log:
            \(session.eventLog.recentText(maxLines: 60))
            """)
    }

    private struct ShellNeverSettled: Error, CustomStringConvertible {
        let timeout: TimeInterval
        let log: String
        var description: String {
            "the login shell never printed a prompt and went quiet within \(Int(timeout))s; log:\n\(log)"
        }
    }

    /// Blocks until the session has produced output and that output has been quiet for
    /// `quietFor` seconds. Passive on purpose — see the class comment.
    private static func waitUntilOutputSettles(
        _ session: HeadlessTerminalSession, quietFor: TimeInterval, timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let last = session.eventLog.lastOutputActivity,
               Date().timeIntervalSince(last) >= quietFor {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ShellNeverSettled(timeout: timeout, log: session.eventLog.recentText(maxLines: 60))
    }
}

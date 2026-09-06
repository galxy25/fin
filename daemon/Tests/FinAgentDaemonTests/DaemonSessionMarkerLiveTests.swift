import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// Live proof that the `LC_FIN_AGENT` marker reaches the REMOTE login shell — the hijack
/// guard's load-bearing link, which `DaemonSessionEnvironmentTests` (dictionary merging)
/// cannot see. The session is built exactly the way `Daemon.run()` builds its own, from a
/// `server` block with no `environment` at all (the deployed cloud config's shape), against
/// this dev machine's sshd as the current user; then the shell is asked what it sees.
///
/// No tmux anywhere, on purpose: the variable has to be read by the login shell itself,
/// where the auto-attach guards run. A shell inside a tmux attach inherits only what the
/// tmux SERVER was started with (plus `update-environment`), so probing there would
/// false-fail whenever the user's own tmux server is up. Skips cleanly off the provisioned
/// dev machine, like `LiveIntegrationTests`.
///
/// A red run means one of: a Citadel upgrade that sends env requests after the shell
/// request (today `TTY.swift` sends them first), an sshd whose `AcceptEnv` no longer
/// forwards `LC_*`, or a login shell that attaches tmux without honoring the marker — each
/// of which quietly re-opens the 2026-09-05 iMac hijack while every unit test stays green.
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

    func testMarkerReachesTheRemoteLoginShellAndKeepsItOutOfTmux() async throws {
        guard FileManager.default.fileExists(atPath: Self.privateKeyPath) else {
            throw XCTSkip("No SSH key at \(Self.privateKeyPath) — live tests only run on the provisioned dev machine.")
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
        try await session.waitForShellReady(timeout: 30)

        // The typed line carries `$LC_FIN_AGENT` and `$TMUX` unexpanded, so the expected
        // text can only come from the remote shell expanding them: the marker arrived, and
        // the shell that got it is not inside a tmux session.
        let nonce = Int.random(in: 100_000...999_999)
        session.sendAgentInput("echo \"P\(nonce) LCVAL=$LC_FIN_AGENT TMUX=[$TMUX]\"\r")
        let expected = "P\(nonce) LCVAL=1 TMUX=[]"

        let deadline = Date().addingTimeInterval(10)
        var answered = false
        while Date() < deadline, !answered {
            answered = session.eventLog.recentText(maxLines: 200).contains(expected)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(answered, """
            the login shell must see LC_FIN_AGENT=1 and must not be inside tmux; log:
            \(session.eventLog.recentText(maxLines: 60))
            """)
    }
}

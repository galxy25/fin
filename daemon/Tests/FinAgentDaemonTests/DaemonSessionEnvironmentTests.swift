import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The login-shell hijack guard: every SSH session fin-agentd opens carries the
/// `LC_FIN_AGENT` env request, whether or not the operator configured `server.environment`.
/// A login shell that execs remote logins into the human's real tmux session (the dev
/// iMac's fish config) skips that exec when it sees the marker; without it the daemon's
/// tmux attach, `FIN_READY_*` probes and keystrokes land in the user's live session —
/// the 2026-09-05 shakedown bug. `LC_`-prefixed because sshd's default AcceptEnv is
/// `LANG LC_*`.
final class DaemonSessionEnvironmentTests: XCTestCase {

    private func config(server: String) throws -> DaemonConfig {
        let json = """
        {
          "server": \(server),
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing"
        }
        """
        return try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
    }

    func testMarkerIsSentWhenNoEnvironmentIsConfigured() throws {
        let config = try config(server: #"{"host": "h", "username": "u", "privateKeyPath": "/k"}"#)
        XCTAssertNil(config.server.environment, "the deployed cloud config has no environment block")
        XCTAssertEqual(config.server.sessionEnvironment, ["LC_FIN_AGENT": "1"])

        // Down to the struct HeadlessTerminalSession turns into SSH env requests.
        let session = Daemon.sessionConfiguration(server: config.server, privateKeyPEM: "pem")
        XCTAssertEqual(session.environment, ["LC_FIN_AGENT": "1"])
        XCTAssertEqual(session.host, "h")
        XCTAssertEqual(session.username, "u")
        XCTAssertEqual(session.privateKeyPEM, "pem")
        XCTAssertEqual(session.port, 22, "port default survives the extraction")
        XCTAssertEqual(session.connectCommand, "", "connectCommand default survives the extraction")
        XCTAssertNil(session.passphrase)
    }

    func testConfiguredEnvironmentMergesAndMayOverrideTheMarkerValue() throws {
        let config = try config(server: """
        {"host": "h", "port": 2222, "username": "u", "privateKeyPath": "/k",
         "passphrase": "pw", "connectCommand": "tmux new-session -A -s fin",
         "environment": {"LC_FOO": "bar", "LC_FIN_AGENT": "imac-2"}}
        """)
        let session = Daemon.sessionConfiguration(server: config.server, privateKeyPEM: "pem")
        XCTAssertEqual(session.environment, ["LC_FOO": "bar", "LC_FIN_AGENT": "imac-2"],
                       "operator entries ride along; a non-blank marker value is the operator's call")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.passphrase, "pw")
        XCTAssertEqual(session.connectCommand, "tmux new-session -A -s fin")
    }

    func testConfiguredEnvironmentCannotDropTheMarker() throws {
        // Other variables only: the marker is added alongside them.
        XCTAssertEqual(
            DaemonConfig.ServerConfig.sessionEnvironment(merging: ["LC_FOO": "bar"]),
            ["LC_FOO": "bar", "LC_FIN_AGENT": "1"]
        )
        // Blanking it is the one "override" that would defeat `[ -z "$LC_FIN_AGENT" ]`
        // guards, so a blank value is treated as absent.
        XCTAssertEqual(
            DaemonConfig.ServerConfig.sessionEnvironment(merging: ["LC_FIN_AGENT": ""]),
            ["LC_FIN_AGENT": "1"]
        )
        XCTAssertEqual(
            DaemonConfig.ServerConfig.sessionEnvironment(merging: ["LC_FIN_AGENT": " \n"]),
            ["LC_FIN_AGENT": "1"]
        )
        XCTAssertEqual(DaemonConfig.ServerConfig.sessionEnvironment(merging: nil), ["LC_FIN_AGENT": "1"])
        XCTAssertEqual(DaemonConfig.ServerConfig.sessionEnvironment(merging: [:]), ["LC_FIN_AGENT": "1"])

        // Through the config too: a blank marker in JSON still arrives as "1".
        let config = try config(server: """
        {"host": "h", "username": "u", "privateKeyPath": "/k", "environment": {"LC_FIN_AGENT": ""}}
        """)
        XCTAssertEqual(
            Daemon.sessionConfiguration(server: config.server, privateKeyPEM: "pem").environment,
            ["LC_FIN_AGENT": "1"]
        )
    }

    /// The name is a contract with the shell profiles that guard on it (and with sshd's
    /// default AcceptEnv); a rename would silently re-open the hijack.
    func testMarkerNameIsTheOneShellProfilesGuardOn() {
        XCTAssertEqual(DaemonConfig.ServerConfig.agentMarkerName, "LC_FIN_AGENT")
        XCTAssertEqual(DaemonConfig.ServerConfig.agentMarkerDefaultValue, "1")
        XCTAssertTrue(DaemonConfig.ServerConfig.agentMarkerName.hasPrefix("LC_"),
                      "sshd's default AcceptEnv forwards only LANG and LC_*")
    }
}

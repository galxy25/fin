import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The daemon's half of the registry wiring: `Daemon.composedSystemPrompt` is the one
/// seam through which routing-registry.json reaches the engine's system prompt, and
/// its absent-file fork is the bootstrap contract — no file, no prompt change, byte
/// for byte.
final class DaemonRoutingPromptTests: XCTestCase {

    /// A path in a fresh unique directory, so "absent" can never collide with another
    /// test's leftover file.
    private func registryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(RegistryDocument.standardFileName)
    }

    func testAbsentRegistryFileLeavesSystemPromptUnchanged() throws {
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL()
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
    }

    /// An empty registry document is the same bootstrap state as no file: nothing is
    /// registered, so the model must not be invited to route.
    func testEmptyRegistryFileLeavesSystemPromptUnchanged() throws {
        let url = try registryURL()
        try JSONEncoder().encode(RegistryDocument()).write(to: url)
        XCTAssertEqual(
            Daemon.composedSystemPrompt(base: Daemon.defaultSystemPrompt, registryFileURL: url),
            Daemon.defaultSystemPrompt
        )
    }

    func testRegistryFileAppendsRoutingSectionNamingEverySession() throws {
        let url = try registryURL()
        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin", cwd: "~/forges/levi/fin", tasks: ["fin", "widget"]),
            SessionRegistration(session: "pocketdj", tasks: ["dj", "audio engine"]),
        ])).write(to: url)

        let prompt = Daemon.composedSystemPrompt(base: Daemon.defaultSystemPrompt, registryFileURL: url)
        // The base prompt survives untouched up front; routing is strictly additive.
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt))
        XCTAssertTrue(prompt.contains("Session routing:"))
        XCTAssertTrue(prompt.contains("fin"))
        XCTAssertTrue(prompt.contains("pocketdj"))
        XCTAssertTrue(prompt.contains("OFF-LIMITS"))
        // The app's posture is the default: one tmux server, so the shell really can read
        // every session on it.
        XCTAssertTrue(prompt.contains("tmux capture-pane -p -t <session>"), prompt)
    }

    /// ON A PRIVATE SOCKET THE ROUTING PROMPT MUST NOT TEACH A COMMAND THAT CANNOT WORK.
    /// The daemon's shell talks only to its own tmux server, where the human's `main` does
    /// not exist: a model told to read other sessions with `tmux capture-pane -p -t main`
    /// gets `can't find session: main` and reports a live session as dead — and the "not
    /// live means DEAD, recreate it" rule would then have it start a same-named duplicate
    /// on its own server and route work into it. It also contradicted the guard's own
    /// paragraph, which is appended to the very same prompt.
    func testOnAPrivateSocketTheRoutingSectionSendsTheModelToReadSession() throws {
        let url = try registryURL()
        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin", cwd: "~", tasks: ["fin"]),
        ])).write(to: url)

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: url,
            tmuxGuard: TmuxSendGuard(
                isEnforced: true, ownSession: "fin", ownSocket: .name("fin")
            )
        )

        XCTAssertTrue(prompt.contains("Session routing:"))
        XCTAssertTrue(prompt.contains("read_session"), prompt)
        XCTAssertFalse(
            prompt.contains("tmux capture-pane -p -t <session>"),
            "the shell cannot read another server's sessions on this host: \(prompt)"
        )
        XCTAssertFalse(
            prompt.contains("the namespace the send_input guard"),
            "there is no fin- namespace any more: \(prompt)"
        )
        XCTAssertTrue(prompt.contains("OFF-LIMITS"), prompt)
    }
}

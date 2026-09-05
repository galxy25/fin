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
    }
}

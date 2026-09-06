import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The gate on Fin's proactively-social persona: `Daemon.composedSystemPrompt` appends
/// the notify persona guidance ONLY when a push channel exists. A headless daemon with
/// no control plane and no shell hook must keep a byte-identical prompt — coaching the
/// model to notify an owner it can't reach would be a promise the runtime can't keep.
final class DaemonNotifyPromptTests: XCTestCase {

    /// A registry path in a fresh unique directory, so the "no routing" baseline can't
    /// collide with another test's leftover file.
    private func registryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-notify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(RegistryDocument.standardFileName)
    }

    func testPersonaGuidanceAbsentWhenNotifyUnavailable() throws {
        // Default (notifyAvailable omitted) is the no-channel case — the prompt is untouched.
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL()
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
        XCTAssertFalse(prompt.contains("proactively social"),
                       "no channel → the persona must not appear")
    }

    func testPersonaGuidanceAppendedWhenNotifyAvailable() throws {
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL(),
            notifyAvailable: true
        )
        // Strictly additive: the base survives untouched up front.
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt))
        XCTAssertTrue(prompt.contains(AgentToolSpec.notifyPersonaGuidance))
        XCTAssertTrue(prompt.contains("proactively social"))
        XCTAssertTrue(prompt.contains("notify tool"))
    }
}

import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// `Daemon.composedSystemPrompt`'s cumulative-profile section: strictly additive, byte-
/// identical when `DaemonMemoryConsolidator`'s local cache file is absent or empty —
/// same discipline as the goals/routing/notify sections it sits alongside.
final class DaemonProfilePromptTests: XCTestCase {

    private func registryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-profile-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(RegistryDocument.standardFileName)
    }

    func testProfileSectionAbsentWhenFileURLIsNil() throws {
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL()
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
    }

    func testProfileSectionAbsentWhenTheCacheFileDoesNotExist() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-profile-absent-\(UUID().uuidString).txt")
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL(),
            profileFileURL: missing
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
    }

    func testProfileSectionAbsentWhenTheCacheFileIsEmpty() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-profile-empty-\(UUID().uuidString).txt")
        try "   \n".write(to: empty, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL(),
            profileFileURL: empty
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
    }

    func testProfileSectionAppendedWhenTheCacheFileHasContent() throws {
        let populated = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-profile-present-\(UUID().uuidString).txt")
        try "Levi prefers concise, direct answers.".write(to: populated, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: populated) }

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL(),
            profileFileURL: populated
        )
        // Strictly additive: the base survives untouched up front.
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt))
        XCTAssertTrue(prompt.contains("User profile (from accumulated memory):"))
        XCTAssertTrue(prompt.contains("Levi prefers concise, direct answers."))
        XCTAssertTrue(prompt.contains("Use remember to save important new facts"))
    }

    func testProfileSectionCapsVeryLongContent() throws {
        let long = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-profile-long-\(UUID().uuidString).txt")
        try String(repeating: "a", count: 5000).write(to: long, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: long) }

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: try registryURL(),
            profileFileURL: long
        )
        XCTAssertTrue(prompt.contains("…"), "an over-cap profile must be truncated, not sent whole")
    }
}

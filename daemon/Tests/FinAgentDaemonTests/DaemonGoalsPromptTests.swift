import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The daemon's half of the ledger wiring: `Daemon.composedSystemPrompt` (mission
/// section) and `Daemon.composedHeartbeatPrompt` (tick beat) are the two seams through
/// which goals-ledger.json reaches the model, and their absent-file forks are the
/// bootstrap contract — no file, no prompt change, byte for byte.
final class DaemonGoalsPromptTests: XCTestCase {

    /// A path in a fresh unique directory, so "absent" can never collide with another
    /// test's leftover file.
    private func ledgerURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-agentd-goals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(LedgerDocument.standardFileName)
    }

    /// The registry sibling in the same directory — always absent in these tests, so
    /// only the goals fork is under measurement.
    private func registryURL(besides ledger: URL) -> URL {
        ledger.deletingLastPathComponent()
            .appendingPathComponent(RegistryDocument.standardFileName)
    }

    private func writtenLedger() -> LedgerDocument {
        LedgerDocument(goals: [
            Goal(
                id: "g-voice-intent",
                title: "Ship the voice intent flow",
                state: .active,
                nextAction: "Wire StartAgentTaskIntent to AgentRuntime.submit."
            ),
            Goal(
                id: "g-appstore-rejection",
                title: "Clear the App Store 2.1 rejection",
                state: .blocked,
                blockedOn: "Levi must record the demo video."
            ),
        ])
    }

    // MARK: - system prompt

    func testAbsentLedgerFileLeavesSystemPromptUnchanged() throws {
        let url = try ledgerURL()
        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registryURL(besides: url),
            goalsLedgerFileURL: url
        )
        XCTAssertEqual(prompt, Daemon.defaultSystemPrompt)
    }

    /// An empty ledger document is the same bootstrap state as no file: nothing was
    /// ever ingested, so the model must not be handed a mission it was never given.
    func testEmptyLedgerFileLeavesSystemPromptUnchanged() throws {
        let url = try ledgerURL()
        try JSONEncoder().encode(LedgerDocument()).write(to: url)
        XCTAssertEqual(
            Daemon.composedSystemPrompt(
                base: Daemon.defaultSystemPrompt,
                registryFileURL: registryURL(besides: url),
                goalsLedgerFileURL: url
            ),
            Daemon.defaultSystemPrompt
        )
    }

    func testLedgerFileAppendsMissionSectionNamingEveryGoal() throws {
        let url = try ledgerURL()
        try JSONEncoder().encode(writtenLedger()).write(to: url)

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registryURL(besides: url),
            goalsLedgerFileURL: url
        )
        // The base prompt survives untouched up front; the mission is strictly additive.
        XCTAssertTrue(prompt.hasPrefix(Daemon.defaultSystemPrompt))
        XCTAssertTrue(prompt.contains("Mission ledger:"))
        XCTAssertTrue(prompt.contains("Ship the voice intent flow"))
        XCTAssertTrue(prompt.contains("Clear the App Store 2.1 rejection"))
    }

    /// Both files at once: routing first, mission after — the same order the app's
    /// composeSystemPrompt renders, so neither surface ever reads the other's marker.
    func testMissionSectionRendersAfterTheRoutingSection() throws {
        let url = try ledgerURL()
        try JSONEncoder().encode(writtenLedger()).write(to: url)
        let registry = registryURL(besides: url)
        try JSONEncoder().encode(RegistryDocument(sessions: [
            SessionRegistration(session: "fin", tasks: ["fin", "widget"]),
        ])).write(to: registry)

        let prompt = Daemon.composedSystemPrompt(
            base: Daemon.defaultSystemPrompt,
            registryFileURL: registry,
            goalsLedgerFileURL: url
        )
        let routing = try XCTUnwrap(prompt.range(of: "Session routing:"))
        let mission = try XCTUnwrap(prompt.range(of: "Mission ledger:"))
        XCTAssertTrue(routing.lowerBound < mission.lowerBound)
    }

    // MARK: - heartbeat tick

    func testAbsentLedgerKeepsTheReflectiveHeartbeatPrompt() throws {
        XCTAssertEqual(
            Daemon.composedHeartbeatPrompt(goalsLedgerFileURL: try ledgerURL()),
            Daemon.heartbeatPrompt
        )
    }

    func testEmptyLedgerKeepsTheReflectiveHeartbeatPrompt() throws {
        let url = try ledgerURL()
        try JSONEncoder().encode(LedgerDocument()).write(to: url)
        XCTAssertEqual(
            Daemon.composedHeartbeatPrompt(goalsLedgerFileURL: url),
            Daemon.heartbeatPrompt
        )
    }

    func testLedgerSwapsTheHeartbeatToTheMissionTick() throws {
        let url = try ledgerURL()
        try JSONEncoder().encode(writtenLedger()).write(to: url)

        let beat = Daemon.composedHeartbeatPrompt(goalsLedgerFileURL: url)
        XCTAssertNotEqual(beat, Daemon.heartbeatPrompt)
        // The prefix contract survives the swap, and the fresh ledger rides inline.
        XCTAssertTrue(beat.hasPrefix("[heartbeat]"))
        XCTAssertTrue(beat.contains("g-voice-intent"))
        XCTAssertTrue(beat.contains("ingest, drive, report, idle"))
    }
}

import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// `SessionActivitySummarizer` — capture → redact → summarize → registry write, for
/// each `kind == "coding-agent"` session with a known `agentPaneTarget`. `.completion`
/// and `.capturePane` are both overridden before `run()` in every test, mirroring
/// exactly how `DaemonMemoryConsolidatorTests` injects `.completion` — no test here
/// ever reaches a real model endpoint, tmux, or SSH.
@MainActor
final class SessionActivitySummarizerTests: XCTestCase {
    private func unconnectedSession() -> HeadlessTerminalSession {
        HeadlessTerminalSession(configuration: HeadlessSessionConfiguration(
            host: "127.0.0.1", port: 22, username: "nobody", privateKeyPEM: "not-a-real-key"
        ))
    }

    private func makeSummarizer(registryURL: URL) -> (summarizer: SessionActivitySummarizer, registry: SessionRoutingRegistry, auditLines: () -> [String]) {
        var lines: [String] = []
        let registry = SessionRoutingRegistry(fileURL: registryURL)
        let summarizer = SessionActivitySummarizer(
            registry: registry, session: unconnectedSession(),
            endpointURL: "https://model.example", modelIdentifier: "m", apiKey: nil,
            temperature: 0.2, maxOutputTokens: 640,
            audit: { lines.append($0) }
        )
        return (summarizer, registry, { lines })
    }

    private func registryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-activity-summarizer-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
    }

    // MARK: - run: scope

    func testRunSkipsAPlainShellSessionEvenWithAPaneTarget() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, _) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "main", kind: "shell", cwd: "/x", agent: nil,
            agentPaneTarget: nil, registeredBy: "fin-agentd (auto)"
        )
        summarizer.capturePane = { _ in XCTFail("must never capture a shell session"); return "" }
        await summarizer.run()
    }

    func testRunSkipsAHandRegisteredCodingAgentSessionWithNoDiscoveredPaneTarget() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, _) = makeSummarizer(registryURL: url)

        try await registry.register(SessionRegistration(
            session: "fin", kind: "coding-agent", cwd: "~/fin", registeredBy: "levi", createdByFin: false
        ))
        summarizer.capturePane = { _ in XCTFail("must never capture a session with no discovered pane target"); return "" }
        await summarizer.run()
    }

    func testRunSummarizesADiscoveredCodingAgentSession() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, auditLines) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )

        var capturedTarget: String?
        summarizer.capturePane = { target in
            capturedTarget = target
            return "$ swift build\nBuild complete!\n"
        }
        summarizer.completion = { _, _ in "Building and testing the Swift daemon package." }
        await summarizer.run()

        XCTAssertEqual(capturedTarget, "fin:0.0")
        let doc = await registry.document
        XCTAssertEqual(doc.sessions[0].activityNote, "Building and testing the Swift daemon package.")
        XCTAssertNotNil(doc.sessions[0].activityNoteUpdatedAt)
        XCTAssertTrue(auditLines().contains { $0.contains("fin") && $0.contains("Building and testing") })
    }

    func testRunSkipsWritingWhenCaptureFails() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, auditLines) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )
        struct Boom: Error {}
        summarizer.capturePane = { _ in throw Boom() }
        summarizer.completion = { _, _ in XCTFail("must never call completion when capture failed"); return "" }
        await summarizer.run()

        let doc = await registry.document
        XCTAssertNil(doc.sessions[0].activityNote)
        XCTAssertTrue(auditLines().contains { $0.contains("capture failed") })
    }

    func testRunSkipsWritingWhenCapturedPaneIsEmpty() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, auditLines) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )
        summarizer.capturePane = { _ in "" }
        summarizer.completion = { _, _ in XCTFail("must never call completion for an empty capture"); return "" }
        await summarizer.run()

        let doc = await registry.document
        XCTAssertNil(doc.sessions[0].activityNote)
        // Silent skip, not a logged failure: an empty pane is not an error condition.
        XCTAssertFalse(auditLines().contains { $0.contains("fin") })
    }

    func testRunSkipsWritingWhenCapturedPaneIsWhitespaceOnly() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, _) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )
        // A freshly-created pane with only blank lines and trailing newlines —
        // non-empty as a String, but empty once trimmed, which is the actual guard.
        summarizer.capturePane = { _ in "\n\n   \n\t\n" }
        summarizer.completion = { _, _ in XCTFail("must never call completion for a whitespace-only capture"); return "" }
        await summarizer.run()

        let doc = await registry.document
        XCTAssertNil(doc.sessions[0].activityNote)
    }

    func testRunSkipsWritingWhenTheModelReturnsALeakyNote() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, auditLines) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )
        summarizer.capturePane = { _ in "some terminal output" }
        summarizer.completion = { _, _ in "Working in /Users/levi/forges/levi/fin on the daemon." }
        await summarizer.run()

        let doc = await registry.document
        XCTAssertNil(doc.sessions[0].activityNote)
        XCTAssertTrue(auditLines().contains { $0.contains("note skipped") })
    }

    // MARK: - acceptableNote (pure)

    func testAcceptableNoteRejectsShortText() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("too short"))
    }

    func testAcceptableNoteAcceptsACleanOneSentenceNote() {
        XCTAssertTrue(SessionActivitySummarizer.acceptableNote("Refactoring the routing registry to support live session discovery."))
    }

    func testAcceptableNoteAcceptsAnIdleObservation() {
        XCTAssertTrue(SessionActivitySummarizer.acceptableNote("The session looks idle; no recent activity to summarize."))
    }

    func testAcceptableNoteRejectsAPathLeak() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("Editing files under /Users/levi/forges/levi/fin right now."))
    }

    func testAcceptableNoteRejectsAHomeTildePath() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("Working inside ~/forges/levi/fin on the daemon."))
    }

    func testAcceptableNoteRejectsAnSSHCommand() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("Ran ssh deepspacenine@example.com to check the box."))
    }

    func testAcceptableNoteRejectsAnIPLiteral() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("Connecting to 192.168.1.5 to debug the server."))
    }

    func testAcceptableNoteRejectsAURL() {
        XCTAssertFalse(SessionActivitySummarizer.acceptableNote("Fetching data from https://example.com/api right now."))
    }

    // MARK: - note capping

    func testTheStoredNoteIsCappedAtMaxNoteCharacters() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (summarizer, registry, _) = makeSummarizer(registryURL: url)

        try await registry.observeDiscoveredSession(
            session: "fin", kind: "coding-agent", cwd: "~/fin", agent: nil,
            agentPaneTarget: "fin:0.0", registeredBy: "fin-agentd (auto)"
        )
        // Words with spaces (not a base64-shaped run `MemoryRedactor` would mask) so the
        // cap under test is the note's own `prefix(maxNoteCharacters)`, not a redaction.
        let longNote = String(repeating: "word ", count: 100)
        summarizer.capturePane = { _ in "output" }
        summarizer.completion = { _, _ in longNote }
        await summarizer.run()

        let doc = await registry.document
        XCTAssertEqual(doc.sessions[0].activityNote?.count, SessionActivitySummarizer.maxNoteCharacters)
    }
}

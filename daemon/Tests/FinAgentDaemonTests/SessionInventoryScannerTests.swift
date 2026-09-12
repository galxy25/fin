import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// `SessionInventoryScanner` — periodic `tmux list-panes -a` → registry upsert.
/// `.runInventory` is overridden before `run()` in every test, so the real closure's
/// capture of a `HeadlessTerminalSession` is never invoked; the initializer still needs
/// a real-ish value, so tests pass one constructed but never connected — same pattern
/// `DaemonLaunchOrderTests` already uses to avoid a live SSH connection.
@MainActor
final class SessionInventoryScannerTests: XCTestCase {
    private func unconnectedSession() -> HeadlessTerminalSession {
        HeadlessTerminalSession(configuration: HeadlessSessionConfiguration(
            host: "127.0.0.1", port: 22, username: "nobody", privateKeyPEM: "not-a-real-key"
        ))
    }

    private func makeScanner(
        registryURL: URL, knownAgentProcesses: Set<String> = TmuxSessionInventory.defaultCoderAgentProcessNames
    ) -> (scanner: SessionInventoryScanner, registry: SessionRoutingRegistry, auditLines: () -> [String]) {
        var lines: [String] = []
        let registry = SessionRoutingRegistry(fileURL: registryURL)
        let scanner = SessionInventoryScanner(
            registry: registry, session: unconnectedSession(),
            knownAgentProcesses: knownAgentProcesses,
            audit: { lines.append($0) }
        )
        return (scanner, registry, { lines })
    }

    private func registryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-inventory-scanner-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
    }

    func testRunRegistersASingleAgentSessionFromCannedTmuxOutput() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (scanner, registry, auditLines) = makeScanner(registryURL: url)

        scanner.runInventory = {
            "fin\t0.0\t/Users/levi/forges/levi/fin\tclaude\t1\n"
        }
        await scanner.run()

        let doc = await registry.document
        XCTAssertEqual(doc.sessions.count, 1)
        let entry = doc.sessions[0]
        XCTAssertEqual(entry.session, "fin")
        XCTAssertEqual(entry.kind, "coding-agent")
        XCTAssertEqual(entry.cwd, "/Users/levi/forges/levi/fin")
        XCTAssertEqual(entry.agentPaneTarget, "fin:0.0")
        XCTAssertTrue(entry.createdByFin)
        XCTAssertTrue(auditLines().contains { $0.contains("1 session(s) seen, 1 upserted") })
    }

    func testRunNeverOverwritesAHandRegisteredSession() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (scanner, registry, _) = makeScanner(registryURL: url)

        try await registry.register(SessionRegistration(
            session: "fin", kind: "coding-agent", cwd: "~/forges/levi/fin",
            tasks: ["fin"], registeredBy: "levi", createdByFin: false
        ))

        // The scan sees the same session, but as a plain shell (registration was stale).
        scanner.runInventory = {
            "fin\t0.0\t/somewhere/else\tzsh\t1\n"
        }
        await scanner.run()

        let doc = await registry.document
        XCTAssertEqual(doc.sessions[0].kind, "coding-agent")
        XCTAssertEqual(doc.sessions[0].cwd, "~/forges/levi/fin")
        XCTAssertNil(doc.sessions[0].agentPaneTarget)
    }

    func testRunSurvivesInventoryFailureWithoutThrowing() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (scanner, registry, auditLines) = makeScanner(registryURL: url)

        struct Boom: Error {}
        scanner.runInventory = { throw Boom() }
        await scanner.run()

        let doc = await registry.document
        XCTAssertTrue(doc.sessions.isEmpty)
        XCTAssertTrue(auditLines().contains { $0.contains("scan failed") })
    }

    func testTickIfDueRespectsTheConfiguredInterval() async throws {
        let url = registryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lines: [String] = []
        let registry = SessionRoutingRegistry(fileURL: url)
        let scanner = SessionInventoryScanner(
            registry: registry, session: unconnectedSession(),
            intervalSeconds: 300,
            audit: { lines.append($0) }
        )
        var callCount = 0
        scanner.runInventory = {
            callCount += 1
            return ""
        }
        // First tick: never scanned before, so it fires.
        scanner.tickIfDue(now: Date())
        // Give the fire-and-forget Task a moment to run.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 1)

        // A tick 1 second later, well inside the 300s interval, must not fire again.
        scanner.tickIfDue(now: Date().addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callCount, 1)
    }
}

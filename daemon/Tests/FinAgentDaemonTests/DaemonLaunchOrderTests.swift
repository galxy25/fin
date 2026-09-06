import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `Daemon.launch()` — the pre-connect phase `run()` executes — driven for real, with
/// the daemon's own seams standing in for the network and the sshd. These pin the two
/// load-bearing links no unit test of the parts can see: that the first-run seed is on
/// disk BEFORE the session object exists (delete the prime call and the seed slides to
/// the first poll, minutes into the run, after the first task turn), and that the
/// session `run()` actually opens — not the static helper — carries `LC_FIN_AGENT`.
@MainActor
final class DaemonLaunchOrderTests: XCTestCase {

    /// One state directory per test: the private key, the audit log, and therefore the
    /// ledger the daemon derives from the audit log's location.
    private var stateDir: String!
    private var keyPath: String { stateDir + "/key.pem" }
    private var auditPath: String { stateDir + "/fin-agentd-audit.jsonl" }
    private var ledgerPath: String { stateDir + "/fin-agentd-directives.json" }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            stateDir = NSTemporaryDirectory() + "fin-agentd-launch-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try? Data("not a real key".utf8).write(to: URL(fileURLWithPath: keyPath))
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            try? FileManager.default.removeItem(atPath: stateDir)
        }
        super.tearDown()
    }

    /// The deployed cloud config's shape: no `environment`, no `connectCommand`.
    private func makeDaemon(supervision: Bool = true) throws -> Daemon {
        let supervisionBlock = supervision ? """
        ,
          "supervision": {"directiveURL": "https://bucket.example/directives.json", "agentName": "finbot"}
        """ : ""
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "\(keyPath)"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "auditLogPath": "\(auditPath)"\(supervisionBlock)
        }
        """
        return Daemon(config: try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8)))
    }

    private func history() -> (Data, URLResponse) {
        let body = Data("""
        {"version": 1, "directives": [
          {"id": "d-1", "kind": "user_message", "text": "last week"},
          {"id": "d-2", "kind": "user_message", "text": "days ago"},
          {"id": "d-3", "kind": "user_message", "text": "yesterday"}
        ]}
        """.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://bucket.example/directives.json")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    private func auditLog() throws -> String {
        try String(contentsOfFile: auditPath, encoding: .utf8)
    }

    func testLaunchDrawsTheFirstRunSeedBeforeConstructingTheSession() async throws {
        let daemon = try makeDaemon()
        var fetches = 0
        daemon.supervisionFetch = { _ in
            fetches += 1
            return self.history()
        }
        var ledgerAtSessionConstruction: String?
        var configurationSeen: HeadlessSessionConfiguration?
        daemon.makeSession = { configuration in
            // Observed at the moment run() would build its session — not after.
            ledgerAtSessionConstruction = try? String(contentsOfFile: self.ledgerPath, encoding: .utf8)
            configurationSeen = configuration
            return HeadlessTerminalSession(configuration: configuration)
        }

        let session = await daemon.launch()

        XCTAssertNotNil(session, "a first run on a reachable bucket launches")
        XCTAssertEqual(fetches, 1, "the prime read the document once, at launch")
        XCTAssertEqual(
            ledgerAtSessionConstruction,
            #"{"applied":[],"inbox_seed_pending":false,"inbox_seeded":[],"seed_pending":false,"seeded":["d-1","d-2","d-3"]}"#,
            "the seed was on disk BEFORE any session object existed"
        )
        XCTAssertEqual(configurationSeen?.environment, ["LC_FIN_AGENT": "1"],
                       "the session run() connects carries the marker, with no environment configured")
        XCTAssertEqual(configurationSeen?.host, "h")
        XCTAssertEqual(configurationSeen?.username, "u")
        XCTAssertEqual(configurationSeen?.privateKeyPEM, "not a real key")
        XCTAssertEqual(configurationSeen?.connectCommand, "")
        let audit = try auditLog()
        XCTAssertTrue(audit.contains("3 historical directive(s) in the supervision doc marked applied, not replayed"),
                      "the seed line reached the audit log: \(audit)")
    }

    /// No supervision block: nothing to prime, and the session still carries the marker.
    func testLaunchWithoutSupervisionStillOpensTheSessionWithTheMarker() async throws {
        let daemon = try makeDaemon(supervision: false)
        var configurationSeen: HeadlessSessionConfiguration?
        daemon.makeSession = { configuration in
            configurationSeen = configuration
            return HeadlessTerminalSession(configuration: configuration)
        }

        let session = await daemon.launch()

        XCTAssertNotNil(session)
        XCTAssertEqual(configurationSeen?.environment, ["LC_FIN_AGENT": "1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerPath), "no supervision, no ledger")
    }

    /// A 1.3.0 daemon ran here for weeks and never applied a directive: an audit log,
    /// no ledger. Upgraded and restarted with a directive freshly written, the ledger
    /// alone would call this a first run and seed that directive as history. The audit
    /// log predating the launch is the evidence that it isn't.
    func testAPriorRunsAuditLogMakesAMissingLedgerNotAFirstRun() async throws {
        try Data("{\"kind\":\"notice\",\"text\":\"an older run\"}\n".utf8)
            .write(to: URL(fileURLWithPath: auditPath))
        let daemon = try makeDaemon()
        var fetches = 0
        daemon.supervisionFetch = { _ in
            fetches += 1
            return self.history()
        }
        daemon.makeSession = { HeadlessTerminalSession(configuration: $0) }

        let session = await daemon.launch()

        XCTAssertNotNil(session)
        XCTAssertEqual(fetches, 0, "not a first run — nothing to prime, nothing fetched")
        XCTAssertEqual(try JSONDecoder().decode(DaemonDirectiveClient.LedgerFile.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: ledgerPath))),
                       DaemonDirectiveClient.LedgerFile(),
                       "nothing seeded — and the verdict is persisted as an empty, non-pending ledger")
        let audit = try auditLog()
        XCTAssertTrue(audit.contains("no directive ledger, but the audit log predates this launch — not a first run, nothing seeded"),
                      "got: \(audit)")
    }

    /// SIGTERM (systemd) or Ctrl-C while the launch fetch is in flight — on a fresh
    /// install whose SSH target is down, the very case where connecting would fail into
    /// `fail()` and write to the audit log `shutdown` just closed. `launch()` notices the
    /// shutdown on resuming, opens nothing, and the signal handler's clean exit is what
    /// ends the process.
    func testAShutdownDuringTheLaunchFetchOpensNoSessionAndExitsCleanly() async throws {
        let daemon = try makeDaemon()
        var exitCodes: [Int32] = []
        daemon.terminate = { exitCodes.append($0) }
        daemon.supervisionFetch = { _ in
            // The signal lands while the GET is outstanding.
            daemon.shutdown(exitCode: 0)
            return self.history()
        }
        var sessionsBuilt = 0
        daemon.makeSession = { configuration in
            sessionsBuilt += 1
            return HeadlessTerminalSession(configuration: configuration)
        }

        let session = await daemon.launch()

        XCTAssertNil(session, "shutdown was requested: nothing to connect")
        XCTAssertEqual(sessionsBuilt, 0)
        // The seed the fetch delivered still landed; its audit lines, recorded after
        // the log was closed, were dropped rather than written into a closed handle.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerPath))
        XCTAssertTrue(try auditLog().contains("fin-agentd shutting down (exit 0)"))
        XCTAssertFalse(try auditLog().contains("historical directive(s)"),
                       "recorded after close(): dropped, and the process did not abort")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(exitCodes, [0], "the signal handler's clean exit, not a crash")
    }
}

/// The audit writer is the sink every launch-time line goes to; `shutdown` closes it
/// while `run()` may still be suspended, so a late append must be a no-op — on Darwin
/// a write to a closed `FileHandle` raises an ObjC exception, which is not catchable
/// from Swift and takes the whole process down.
final class AuditLogWriterTests: XCTestCase {

    func testAppendAfterCloseIsDroppedNotWrittenToAClosedHandle() throws {
        let path = NSTemporaryDirectory() + "fin-agentd-audit-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = AuditLogWriter(path: path)

        writer.append(AgentAuditEvent(kind: "notice", text: "before close"))
        writer.close()
        writer.append(AgentAuditEvent(kind: "notice", text: "after close"))
        writer.close()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("before close"), "got: \(contents)")
        XCTAssertFalse(contents.contains("after close"), "a late line is dropped, not written: \(contents)")
    }
}

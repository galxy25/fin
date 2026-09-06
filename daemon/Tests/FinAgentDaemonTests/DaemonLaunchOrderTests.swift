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
    /// `privateKeyPath` overrides the readable key `setUp` wrote, for the launches that
    /// must die on it.
    private func makeDaemon(supervision: Bool = true, inbox: Bool = false, privateKeyPath: String? = nil) throws -> Daemon {
        let inboxField = inbox ? #", "inboxURL": "https://bucket.example/inbox.json""# : ""
        let supervisionBlock = supervision ? """
        ,
          "supervision": {"directiveURL": "https://bucket.example/directives.json", "agentName": "finbot"\(inboxField)}
        """ : ""
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "\(privateKeyPath ?? keyPath)"},
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

    private func inboxBacklog() -> (Data, URLResponse) {
        let body = Data("""
        {"version": 1, "directives": [
          {"id": "m-1", "kind": "user_message", "text": "three weeks ago"},
          {"id": "m-2", "kind": "user_message", "text": "last tuesday"}
        ]}
        """.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://bucket.example/inbox.json")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    /// What a stale presigned URL answers: S3's 403, on any slot.
    private func denied(_ request: URLRequest) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }

    private func auditLog() throws -> String {
        try String(contentsOfFile: auditPath, encoding: .utf8)
    }

    private func ledger() throws -> DaemonDirectiveClient.LedgerFile {
        try JSONDecoder().decode(DaemonDirectiveClient.LedgerFile.self,
                                 from: Data(contentsOf: URL(fileURLWithPath: ledgerPath)))
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
    /// The first-run record is still written — the audit log is, and a later supervised
    /// launch must not find one without the other.
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
        XCTAssertEqual(try ledger(), DaemonDirectiveClient.LedgerFile(seedPending: true, inboxSeedPending: true),
                       "no supervision, but the first run is on record: both seeds owed, the resident posture")
        let audit = try auditLog()
        XCTAssertFalse(audit.contains("[s3]"), "nothing to say about a write that landed: \(audit)")
    }

    /// The crash-loop route to "audit log, no ledger": the init creates the audit log,
    /// and a private key the daemon can't read — a path typo, wrong perms, cloud-init
    /// writing it after the unit started — kills every launch under `Restart=always`.
    /// Were the first-run record written after the key read, no life would ever write
    /// it, and the operator's fixed-key launch would read the audit log as a 1.3.0
    /// upgrade and replay the supervisor's whole history. So the supervision client —
    /// its ledger write and its prime — comes first, and the fixed-key launch resumes.
    func testAnUnreadablePrivateKeyAtFirstLaunchStillRecordsTheFirstRunBeforeItDies() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: auditPath), "a box the daemon has never run on")
        let crashing = try makeDaemon(inbox: true, privateKeyPath: stateDir + "/not-there.pem")
        var exitCodes: [Int32] = []
        crashing.terminate = { exitCodes.append($0) }
        var fetches = 0
        var ledgerExistedAtFetch: [Bool] = []
        crashing.supervisionFetch = { request in
            fetches += 1
            ledgerExistedAtFetch.append(FileManager.default.fileExists(atPath: self.ledgerPath))
            return self.denied(request)
        }
        var sessionsBuilt = 0
        crashing.makeSession = { configuration in
            sessionsBuilt += 1
            return HeadlessTerminalSession(configuration: configuration)
        }

        let crashedSession = await crashing.launch()

        XCTAssertNil(crashedSession, "the key read failed: nothing to connect")
        XCTAssertEqual(exitCodes, [1], "the fatal exit, through the seam")
        XCTAssertEqual(sessionsBuilt, 0)
        XCTAssertEqual(fetches, 2, "the prime read both slots BEFORE the key was read")
        XCTAssertEqual(ledgerExistedAtFetch, [true, true], "and the pending ledger was on disk before the prime's first fetch")
        XCTAssertEqual(try ledger(), DaemonDirectiveClient.LedgerFile(seedPending: true, inboxSeedPending: true),
                       "what the crash-looping life leaves: both seeds owed")
        let crashAudit = try auditLog()
        XCTAssertTrue(crashAudit.contains("cannot read private key at \(stateDir!)/not-there.pem"), "got: \(crashAudit)")
        XCTAssertTrue(crashAudit.contains("[s3] poll failed: HTTP 403"), "got: \(crashAudit)")

        // Key fixed, same state directory: the audit log predates THIS launch.
        let fixed = try makeDaemon(inbox: true)
        fixed.supervisionFetch = { request in
            request.url?.absoluteString.contains("inbox") == true ? self.inboxBacklog() : self.history()
        }
        fixed.makeSession = { HeadlessTerminalSession(configuration: $0) }
        fixed.terminate = { _ in }

        let session = await fixed.launch()

        XCTAssertNotNil(session)
        XCTAssertEqual(try ledger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1", "m-2"]),
                       "N = 3 + M = 2 seeded on the first documents actually read")
        let delivered = await fixed.supervision?.poll()
        XCTAssertEqual(delivered?.map(\.id), [], "zero delivered: the backlog is history")
        fixed.shutdown(exitCode: 0)
        let audit = try auditLog()
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the directive seed still pending"), "got: \(audit)")
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the inbox seed still pending"), "got: \(audit)")
        XCTAssertFalse(audit.contains("not a first run, nothing seeded"), "the upgrade rule did not fire: \(audit)")
    }

    /// The other route, with no crash at all: the daemon runs unsupervised for a while
    /// (the config has no `supervision` block), then the operator adds freshly minted
    /// URLs to the same config. That first supervised launch finds the audit log every
    /// unsupervised life wrote — and must find the first-run record next to it, or it
    /// is the 1.3.0-upgrade verdict and the supervisor's whole history replays.
    func testAnUnsupervisedFirstLaunchThenSupervisionAddedSeedsTheBacklogNotZero() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: auditPath), "a box the daemon has never run on")
        let unsupervised = try makeDaemon(supervision: false)
        unsupervised.makeSession = { HeadlessTerminalSession(configuration: $0) }
        unsupervised.terminate = { _ in }

        let firstSession = await unsupervised.launch()
        XCTAssertNotNil(firstSession)
        XCTAssertNil(unsupervised.supervision)
        unsupervised.shutdown(exitCode: 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: auditPath))
        XCTAssertEqual(try ledger(), DaemonDirectiveClient.LedgerFile(seedPending: true, inboxSeedPending: true),
                       "the unsupervised life left the first-run record: both seeds owed")

        // Supervision added to the same install: audit log present, ledger present.
        let supervised = try makeDaemon(inbox: true)
        var fetches = 0
        supervised.supervisionFetch = { request in
            fetches += 1
            return request.url?.absoluteString.contains("inbox") == true ? self.inboxBacklog() : self.history()
        }
        supervised.makeSession = { HeadlessTerminalSession(configuration: $0) }
        supervised.terminate = { _ in }

        let session = await supervised.launch()

        XCTAssertNotNil(session)
        XCTAssertEqual(fetches, 2, "a first run: both slots primed at launch")
        XCTAssertEqual(try ledger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1", "m-2"]),
                       "the supervisor's history and the inbox backlog are seeded, not delivered")
        let delivered = await supervised.supervision?.poll()
        XCTAssertEqual(delivered?.map(\.id), [], "zero delivered")
        XCTAssertEqual(supervised.supervision?.isFirstRun, false)
        supervised.shutdown(exitCode: 0)
        let audit = try auditLog()
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the directive seed still pending"), "got: \(audit)")
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the inbox seed still pending"), "got: \(audit)")
        XCTAssertTrue(audit.contains("3 historical directive(s) in the supervision doc marked applied, not replayed"), "got: \(audit)")
        XCTAssertTrue(audit.contains("2 message(s) already in the inbox marked applied, not replayed"), "got: \(audit)")
        XCTAssertFalse(audit.contains("not a first run, nothing seeded"), "the upgrade rule did not fire: \(audit)")
    }

    /// What the upgrade rule is still for, kept reachable on purpose: a 1.3.0 daemon ran
    /// here (an audit log, no ledger), a 1.4.1 unsupervised life adds nothing — it has
    /// no verdict of its own to write over a box with prior-run evidence — and the
    /// first supervised launch draws the 1.3.0 verdict: not a first run, everything
    /// delivered. A replay, never a drop.
    func testAnUnsupervisedLaunchOnAPriorRunsBoxLeavesTheUpgradeVerdictToTheSupervisedLaunch() async throws {
        try Data("{\"kind\":\"notice\",\"text\":\"a 1.3.0 run\"}\n".utf8)
            .write(to: URL(fileURLWithPath: auditPath))
        let unsupervised = try makeDaemon(supervision: false)
        unsupervised.makeSession = { HeadlessTerminalSession(configuration: $0) }
        unsupervised.terminate = { _ in }

        let unsupervisedSession = await unsupervised.launch()
        XCTAssertNotNil(unsupervisedSession)
        unsupervised.shutdown(exitCode: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerPath),
                       "no first-run record on a box with prior-run evidence: the verdict is the supervised launch's to draw")

        let supervised = try makeDaemon(inbox: true)
        supervised.supervisionFetch = { request in
            request.url?.absoluteString.contains("inbox") == true ? self.inboxBacklog() : self.history()
        }
        supervised.makeSession = { HeadlessTerminalSession(configuration: $0) }
        supervised.terminate = { _ in }

        let supervisedSession = await supervised.launch()

        XCTAssertNotNil(supervisedSession)
        XCTAssertEqual(try ledger(), DaemonDirectiveClient.LedgerFile(), "the 1.3.0 verdict, on disk")
        let delivered = await supervised.supervision?.poll()
        XCTAssertEqual(delivered?.map(\.id), ["d-1", "d-2", "d-3", "m-1", "m-2"], "everything delivered, as 1.3.0 would have")
        supervised.shutdown(exitCode: 0)
        let audit = try auditLog()
        XCTAssertTrue(audit.contains("not a first run, nothing seeded"), "got: \(audit)")
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

    /// The refuted scenario, end to end and across two launches in one state directory:
    /// a resident install starts with stale presigned URLs — 403 on both slots, so
    /// neither seed can land — and the operator re-mints the URLs and restarts. The
    /// first launch created the audit log, so the second finds "audit log, no ledger"
    /// unless the first wrote one — and that is the 1.3.0-upgrade rule above, which
    /// would call this "not a first run", persist an empty non-pending ledger, and
    /// deliver the whole directive + inbox backlog on the first successful poll: the
    /// exact replay the seed exists to prevent, cemented on disk. So a first run writes
    /// its pending ledger before any document is read, and the second launch resumes
    /// the wait: the first successful read seeds N + M and delivers none of them.
    func testStaleURLsAtFirstRunThenReMintedURLsOnRestartSeedTheWholeBacklogNotZero() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: auditPath), "a box the daemon has never run on")
        let firstLife = try makeDaemon(inbox: true)
        var firstLifeFetches = 0
        firstLife.supervisionFetch = { request in
            firstLifeFetches += 1
            return self.denied(request)
        }
        firstLife.makeSession = { HeadlessTerminalSession(configuration: $0) }
        firstLife.terminate = { _ in }

        let firstSession = await firstLife.launch()
        XCTAssertNotNil(firstSession, "stale URLs never stop the daemon starting")
        XCTAssertEqual(firstLifeFetches, 2, "the prime read both slots")
        let firstLifeDelivered = await firstLife.supervision?.poll()
        XCTAssertEqual(firstLifeDelivered?.map(\.id), [], "nothing readable, nothing delivered")
        firstLife.shutdown(exitCode: 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: auditPath),
                      "the audit log the next launch would otherwise be judged by")
        XCTAssertEqual(try ledger(), DaemonDirectiveClient.LedgerFile(seedPending: true, inboxSeedPending: true),
                       "the first life left its own evidence: both seeds owed, nothing seeded")
        let firstAudit = try auditLog()
        XCTAssertTrue(firstAudit.contains("[s3] poll failed: HTTP 403"), "got: \(firstAudit)")
        XCTAssertTrue(firstAudit.contains("[s3] inbox poll failed: HTTP 403"), "got: \(firstAudit)")
        XCTAssertTrue(firstAudit.contains("directive document not read at launch — seed deferred to the next poll"), "got: \(firstAudit)")
        XCTAssertFalse(firstAudit.contains("nothing to seed"), "403 is never 'absent': \(firstAudit)")

        // URLs re-minted, same state directory: the audit log predates THIS launch.
        let secondLife = try makeDaemon(inbox: true)
        secondLife.supervisionFetch = { request in
            request.url?.absoluteString.contains("inbox") == true ? self.inboxBacklog() : self.history()
        }
        secondLife.makeSession = { HeadlessTerminalSession(configuration: $0) }
        secondLife.terminate = { _ in }

        let secondSession = await secondLife.launch()
        XCTAssertNotNil(secondSession)

        XCTAssertEqual(try ledger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1", "m-2"]),
                       "N = 3 + M = 2 seeded on the first documents actually read; both seeds done, nothing applied")
        let secondLifeDelivered = await secondLife.supervision?.poll()
        XCTAssertEqual(secondLifeDelivered?.map(\.id), [], "zero delivered: the backlog is history")
        XCTAssertEqual(secondLife.supervision?.isFirstRun, false)
        secondLife.shutdown(exitCode: 0)

        let audit = try auditLog()
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the directive seed still pending"), "got: \(audit)")
        XCTAssertTrue(audit.contains("[s3] first run: resumed with the inbox seed still pending"), "got: \(audit)")
        XCTAssertTrue(audit.contains("3 historical directive(s) in the supervision doc marked applied, not replayed"), "got: \(audit)")
        XCTAssertTrue(audit.contains("2 message(s) already in the inbox marked applied, not replayed"), "got: \(audit)")
        XCTAssertFalse(audit.contains("not a first run, nothing seeded"), "the upgrade rule did not fire: \(audit)")
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

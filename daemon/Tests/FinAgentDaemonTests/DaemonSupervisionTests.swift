import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Daemon-side coverage: the heartbeat prompt's classifier guard, the supervision
/// config, and the S3 directive client (injected transport — no network anywhere).
final class DaemonSupervisionTests: XCTestCase {

    // MARK: - Heartbeat prompt classifier guard

    /// The daemon's heartbeat prompt rides through `AgentIntentClassifier` on every
    /// beat; if a rewording ever classified it as a forced tool intent, every beat
    /// would fire that tool before the model was asked. Mirrors the app's guard test
    /// for `AgentRuntime.heartbeatPrompt`.
    @MainActor
    func testHeartbeatPromptStaysAmbiguous() {
        XCTAssertEqual(AgentIntentClassifier.classify(Daemon.heartbeatPrompt), .ambiguous)
    }

    // MARK: - Config

    func testSupervisionConfigDecodes() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "supervision": {
            "directiveURL": "https://bucket.example/directives.json",
            "statusURL": "https://bucket.example/status.json",
            "agentName": "fin-agentd-1"
          }
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        let supervision = try XCTUnwrap(config.supervision)
        XCTAssertEqual(supervision.directiveURL, "https://bucket.example/directives.json")
        XCTAssertEqual(supervision.agentName, "fin-agentd-1")
        XCTAssertNil(supervision.pollSeconds, "pollSeconds is optional; the client defaults it to 30")
    }

    func testConfigWithoutSupervisionStillDecodes() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing"
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.supervision)
    }

    /// Every cloud-host field is optional, so a config written for the pre-1.1 daemon
    /// keeps working unchanged.
    func testCloudHostFieldsAreAllOptional() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing"
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.stayResident)
        XCTAssertNil(config.agentID)
        XCTAssertNil(config.deviceToken8)
        XCTAssertNil(config.transcript)
        XCTAssertNil(try config.parsedAgentID())
    }

    func testCloudHostFieldsDecode() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "stayResident": true,
          "agentID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "deviceToken8": "ec2abcd1",
          "supervision": {
            "directiveURL": "https://bucket.example/directives.json",
            "inboxURL": "https://bucket.example/inbox.json",
            "agentName": "fin-agentd-1"
          },
          "transcript": {"putURL": "https://bucket.example/transcript.jsonl"}
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.stayResident, true)
        XCTAssertEqual(config.deviceToken8, "ec2abcd1")
        XCTAssertEqual(try config.parsedAgentID()?.uuidString,
                       "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(config.supervision?.inboxURL, "https://bucket.example/inbox.json")
        let transcript = try XCTUnwrap(config.transcript)
        XCTAssertEqual(transcript.putURL, "https://bucket.example/transcript.jsonl")
        XCTAssertNil(transcript.flushSeconds, "the daemon defaults this to 15")
        XCTAssertNil(transcript.maxLines, "the daemon defaults this to 2000")
    }

    /// A mistyped agent id must be fatal at launch (exit 64 via the caller's `bad config`
    /// path), not silently file every transcript line under an id the app can't match.
    func testMalformedAgentIDFailsTheLoad() throws {
        let path = NSTemporaryDirectory() + "fin-agentd-config-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("""
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "agentID": "not-a-uuid"
        }
        """.utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try DaemonConfig.load(from: path)) { error in
            XCTAssertTrue("\(error)".contains("agentID \"not-a-uuid\" is not a UUID"),
                          "the message must name the field and the bad value: \(error)")
        }
    }
}

// MARK: - stayResident

@MainActor
final class DaemonResidencyTests: XCTestCase {

    private var auditFile: String!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            auditFile = NSTemporaryDirectory() + "fin-agentd-audit-\(UUID().uuidString).jsonl"
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            try? FileManager.default.removeItem(atPath: auditFile)
        }
        super.tearDown()
    }

    private func makeDaemon(stayResident: Bool) throws -> Daemon {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "do the thing",
          "stayResident": \(stayResident),
          "auditLogPath": "\(auditFile!)"
        }
        """
        return Daemon(config: try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8)))
    }

    func testTaskCompleteExitsWhenNotResident() throws {
        let daemon = try makeDaemon(stayResident: false)
        XCTAssertTrue(daemon.handleTaskComplete(), "the default is still exit-on-complete")
        XCTAssertFalse(daemon.suspendedAfterCompletion)
    }

    func testTaskCompleteSuspendsInsteadOfExitingWhenResident() throws {
        let daemon = try makeDaemon(stayResident: true)
        XCTAssertFalse(daemon.handleTaskComplete(), "the process must stay up")
        XCTAssertTrue(daemon.suspendedAfterCompletion)
        XCTAssertTrue(daemon.beatsAreSuspended, "beats would re-run a finished task")
        XCTAssertEqual(daemon.idleStateName, "task-complete",
                       "a routine idle PUT must not overwrite the supervisor's last-seen state")
    }

    func testAnIncomingMessageResumesASuspendedAgent() throws {
        let daemon = try makeDaemon(stayResident: true)
        _ = daemon.handleTaskComplete()

        daemon.resumeForIncomingMessage()

        XCTAssertFalse(daemon.suspendedAfterCompletion)
        XCTAssertFalse(daemon.beatsAreSuspended)
        XCTAssertEqual(daemon.idleStateName, "idle")
    }

    /// The two gates are independent; one message lifts both, so an agent that asked a
    /// question and then completed doesn't stay half-paused.
    func testResumeAlsoLiftsTheRequestInputPause() throws {
        let daemon = try makeDaemon(stayResident: true)
        daemon.pauseHeartbeatForUserInput()
        _ = daemon.handleTaskComplete()
        XCTAssertTrue(daemon.awaitingUserInput)
        XCTAssertTrue(daemon.suspendedAfterCompletion)

        daemon.resumeForIncomingMessage()

        XCTAssertFalse(daemon.awaitingUserInput)
        XCTAssertFalse(daemon.suspendedAfterCompletion)
    }

    func testRepeatedTaskCompleteSuspendsOnlyOnce() throws {
        let daemon = try makeDaemon(stayResident: true)
        XCTAssertFalse(daemon.handleTaskComplete())
        XCTAssertFalse(daemon.handleTaskComplete())
        XCTAssertTrue(daemon.suspendedAfterCompletion)
    }
}

// MARK: - Directive client

@MainActor
final class DaemonDirectiveClientTests: XCTestCase {

    /// The applied-id ledger. It pre-exists — empty, `[]` — by default: the "daemon has
    /// run here before" posture the polling and dedupe tests want. A MISSING ledger is a
    /// first run and seeds the directive high-water (`// MARK: First run`), so tests of
    /// that path delete it first with `startWithNoLedger()`.
    private var stateFile: String!

    // corelibs-xctest (Linux) keeps setUp/tearDown nonisolated even on a @MainActor
    // test class; they still run on the main thread, so hop explicitly.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            stateFile = NSTemporaryDirectory() + "fin-agentd-test-\(UUID().uuidString).json"
            try? Data("[]".utf8).write(to: URL(fileURLWithPath: stateFile))
        }
    }

    /// A fresh box: no ledger on disk at all — as opposed to an empty or a corrupt one.
    private func startWithNoLedger() {
        try? FileManager.default.removeItem(atPath: stateFile)
    }

    /// The 1.4.0 object form the client writes.
    private func persistedLedger() throws -> DaemonDirectiveClient.LedgerFile {
        try JSONDecoder().decode(DaemonDirectiveClient.LedgerFile.self,
                                 from: Data(contentsOf: URL(fileURLWithPath: stateFile)))
    }

    /// The file's bytes as written — for the legacy `[]` posture and the corrupt case,
    /// where the point is that the client left them alone.
    private func rawLedger() throws -> String {
        try String(contentsOfFile: stateFile, encoding: .utf8)
    }

    private func seededLedger(_ ids: [String], applied: [String] = []) -> DaemonDirectiveClient.LedgerFile {
        DaemonDirectiveClient.LedgerFile(applied: applied, seeded: ids, seedPending: false)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            try? FileManager.default.removeItem(atPath: stateFile)
        }
        super.tearDown()
    }

    private func makeClient(
        agentName: String = "finbot",
        inboxURL: String? = nil,
        inboxResetAtLaunch: Bool = false,
        deviceToken8: String = DaemonConfig.defaultDeviceToken8,
        stateFilePath: String? = nil,
        hasRunHereBefore: Bool = false,
        audit: @escaping (String) -> Void = { _ in },
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse),
        put: @escaping (URLRequest) async throws -> URLResponse = { _ in
            HTTPURLResponse(url: URL(string: "https://s.example")!, statusCode: 200,
                            httpVersion: nil, headerFields: nil)!
        }
    ) -> DaemonDirectiveClient {
        DaemonDirectiveClient(
            directiveURL: "https://bucket.example/directives.json",
            statusURL: "https://bucket.example/status.json",
            inboxURL: inboxURL,
            inboxResetAtLaunch: inboxResetAtLaunch,
            agentName: agentName,
            pollSeconds: 30,
            deviceToken8: deviceToken8,
            stateFilePath: stateFilePath ?? stateFile,
            hasRunHereBefore: hasRunHereBefore,
            audit: audit,
            fetch: fetch,
            put: put
        )
    }

    /// A transport that answers the inbox URL and the directive URL differently, so
    /// merge order and per-source failure isolation are observable. `inboxResetAtLaunch`
    /// is the cloud-worker posture (the control plane emptied the inbox at the launch
    /// call); the default is the resident one.
    private func makeInboxClient(
        inboxResetAtLaunch: Bool = false,
        audit: @escaping (String) -> Void = { _ in },
        directives: @escaping () async throws -> (Data, URLResponse),
        inbox: @escaping () async throws -> (Data, URLResponse)
    ) -> DaemonDirectiveClient {
        makeClient(
            inboxURL: "https://bucket.example/inbox.json",
            inboxResetAtLaunch: inboxResetAtLaunch,
            audit: audit,
            fetch: { request in
                request.url?.absoluteString.contains("inbox") == true
                    ? try await inbox()
                    : try await directives()
            }
        )
    }

    private func response(_ status: Int, etag: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://bucket.example/directives.json")!,
            statusCode: status, httpVersion: nil,
            headerFields: etag.map { ["ETag": $0] }
        )!
    }

    private func document(_ directives: String) -> Data {
        Data("""
        {"version": 1, "directives": [\(directives)]}
        """.utf8)
    }

    // MARK: Matching and application

    func testPollReturnsMatchingUnappliedUserMessages() async {
        let body = document("""
        {"id": "d-1", "agent": "finbot", "kind": "user_message", "text": "check the build"},
        {"id": "d-2", "agent": "otherbot", "kind": "user_message", "text": "not for us"},
        {"id": "d-3", "agent": "*", "kind": "user_message", "text": "wildcard lands"},
        {"id": "d-4", "agent": "FINBOT", "kind": "user_message", "text": "case-insensitive match"}
        """)
        let client = makeClient(fetch: { _ in (body, self.response(200)) })

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["d-1", "d-3", "d-4"])
        XCTAssertEqual(pending.first?.text, "check the build")
    }

    func testAppliedDirectivesAreNotReturnedAgain() async {
        let body = document("""
        {"id": "d-1", "kind": "user_message", "text": "one"},
        {"id": "d-2", "kind": "user_message", "text": "two"}
        """)
        let client = makeClient(fetch: { _ in (body, self.response(200)) })

        var pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2"])

        client.markApplied("d-1")
        pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-2"])
    }

    func testMarkAppliedAuditsAndPersistsAcrossClientInstances() async {
        var lines: [String] = []
        let body = document(#"{"id": "d-1", "kind": "user_message", "text": "one"}"#)
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })
        _ = await client.poll()
        client.markApplied("d-1")
        XCTAssertTrue(lines.contains("[s3] applied directive d-1"), "got: \(lines)")

        // A fresh client over the same state file must remember the applied id.
        let reborn = makeClient(fetch: { _ in (body, self.response(200)) })
        let pending = await reborn.poll()
        XCTAssertTrue(pending.isEmpty, "d-1 was applied by the previous instance")
    }

    func testAppliedIDsAreCappedAtFiveHundred() {
        let client = makeClient(fetch: { _ in (Data(), self.response(200)) })
        for index in 0..<510 {
            client.markApplied("d-\(index)")
        }
        XCTAssertEqual(client.appliedIDs.count, 500)
        XCTAssertEqual(client.appliedIDs.first, "d-10", "oldest ids are evicted first")
        XCTAssertEqual(client.appliedIDs.last, "d-509")
    }

    func testArmMonitorFieldsDecode() async {
        let body = document(
            #"{"id": "d-1", "kind": "user_message", "text": "watch it", "arm_monitor": true, "interval_seconds": 120}"#
        )
        let client = makeClient(fetch: { _ in (body, self.response(200)) })
        let pending = await client.poll()
        XCTAssertEqual(pending.first?.armMonitor, true)
        XCTAssertEqual(pending.first?.intervalSeconds, 120)
    }

    // MARK: Inbox

    func testInboxMessagesFollowDirectivesEachInDocumentOrder() async {
        let directives = document("""
        {"id": "d-1", "kind": "user_message", "text": "supervisor first"},
        {"id": "d-2", "kind": "user_message", "text": "supervisor second"}
        """)
        let inbox = document("""
        {"id": "m-9F1C2A3B", "kind": "user_message", "text": "from the phone"},
        {"id": "m-0004AAAA", "kind": "user_message", "text": "and again"}
        """)
        let client = makeInboxClient(
            directives: { (directives, self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "m-9F1C2A3B", "m-0004AAAA"])
        XCTAssertEqual(pending.last?.text, "and again")
    }

    /// Inbox ids are arbitrary strings the app mints; nothing may assume the
    /// supervisor's monotonic "d-N" shape.
    func testArbitraryInboxIDsDedupeAndPersistInTheSharedLedger() async {
        let messageID = "m-\(UUID().uuidString)"
        let inbox = document("""
        {"id": "\(messageID)", "kind": "user_message", "text": "answer the question"}
        """)
        let empty = document("")
        let client = makeInboxClient(
            directives: { (empty, self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )

        var pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), [messageID])

        client.markApplied(messageID)
        pending = await client.poll()
        XCTAssertTrue(pending.isEmpty, "an applied inbox id must not replay")

        // Same state file as directives — one ledger, both channels.
        let reborn = makeInboxClient(
            directives: { (empty, self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )
        let afterRestart = await reborn.poll()
        XCTAssertTrue(afterRestart.isEmpty,
                      "the applied id survives a restart, like a directive's")
    }

    func testAFailedDirectiveFetchStillDeliversInboxMessages() async {
        struct Boom: Error {}
        var lines: [String] = []
        let inbox = document(#"{"id": "m-1", "kind": "user_message", "text": "still here"}"#)
        let client = makeInboxClient(
            audit: { lines.append($0) },
            directives: { throw Boom() },
            inbox: { (inbox, self.response(200)) }
        )

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["m-1"], "one dead source must not mute the other")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[s3] poll failed:") }, "got: \(lines)")
    }

    func testAFailedInboxFetchAuditsUnderItsOwnPrefix() async {
        var lines: [String] = []
        let directives = document(#"{"id": "d-1", "kind": "user_message", "text": "fine"}"#)
        let client = makeInboxClient(
            audit: { lines.append($0) },
            directives: { (directives, self.response(200)) },
            inbox: { (Data(), self.response(403)) }
        )

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["d-1"])
        XCTAssertTrue(lines.contains("[s3] inbox poll failed: HTTP 403"), "got: \(lines)")
    }

    func testInboxIsNotPolledWhenUnconfigured() async {
        var urls: [String] = []
        let body = document(#"{"id": "d-1", "kind": "user_message", "text": "one"}"#)
        let client = makeClient(fetch: { request in
            urls.append(request.url?.absoluteString ?? "")
            return (body, self.response(200))
        })

        _ = await client.poll()

        XCTAssertEqual(urls, ["https://bucket.example/directives.json"])
        XCTAssertNil(client.inboxURL)
    }

    /// Both documents are read on one tick, so an inbox message never waits out an extra
    /// interval behind the directive poll.
    func testOnePollReadsBothSources() async {
        var urls: [String] = []
        let empty = document("")
        let client = makeInboxClient(
            directives: {
                urls.append("directives")
                return (empty, self.response(200))
            },
            inbox: {
                urls.append("inbox")
                return (empty, self.response(200))
            }
        )

        _ = await client.poll()

        XCTAssertEqual(urls, ["directives", "inbox"])
        XCTAssertFalse(client.pollIsDue, "one poll covers both; the cadence is unchanged")
    }

    // MARK: Skips

    func testWrongKindAndEmptyTextSkipWithOneAuditLineEach() async {
        var lines: [String] = []
        let body = document("""
        {"id": "d-1", "kind": "reboot_everything", "text": "nope"},
        {"id": "d-2", "kind": "user_message", "text": "   "},
        {"id": "d-3", "kind": "user_message", "text": "legit"}
        """)
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })

        var pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-3"])
        // Second poll: skipped entries stay skipped, and no duplicate audit lines.
        pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-3"])

        XCTAssertEqual(lines.filter { $0.contains("skipped directive d-1") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("skipped directive d-2") }.count, 1)
    }

    // MARK: State file

    func testCorruptStateFileAuditsOnceAndResetsDedupe() async {
        try? Data("not json {{".utf8).write(to: URL(fileURLWithPath: stateFile))
        var lines: [String] = []
        let body = document(#"{"id": "d-1", "kind": "user_message", "text": "one"}"#)
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })

        XCTAssertEqual(lines.filter { $0 == "[s3] state file unreadable — dedupe reset" }.count, 1,
                       "got: \(lines)")
        // The reset client starts with an empty dedupe set and works normally.
        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1"])
    }

    func testMissingStateFileIsANormalFirstRunNotAReset() {
        startWithNoLedger()
        var lines: [String] = []
        _ = makeClient(audit: { lines.append($0) },
                       fetch: { _ in (Data(), self.response(200)) })
        XCTAssertTrue(lines.isEmpty, "a missing state file must not audit at init: \(lines)")
    }

    // MARK: First run (directive high-water)

    private static let firstRunAuditPrefix = "[s3] first run: "

    private func history() -> Data {
        document("""
        {"id": "d-1", "kind": "user_message", "text": "last week"},
        {"id": "d-2", "kind": "user_message", "text": "days ago"},
        {"id": "d-3", "kind": "user_message", "text": "yesterday"}
        """)
    }

    private func historyPlusOne() -> Data {
        document("""
        {"id": "d-1", "kind": "user_message", "text": "last week"},
        {"id": "d-2", "kind": "user_message", "text": "days ago"},
        {"id": "d-3", "kind": "user_message", "text": "yesterday"},
        {"id": "d-4", "kind": "user_message", "text": "fresh instruction"}
        """)
    }

    /// A fresh box (new cloud worker, new install) has no ledger, so the SHARED
    /// supervision document — every historical operator directive — would replay in
    /// full, burning a model turn per week-old prompt. The first document read is
    /// history, not instructions; only what arrives after it is delivered.
    func testFirstRunSeedsHistoricalDirectivesInsteadOfReplayingThem() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var body = history()
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })

        let first = await client.poll()

        XCTAssertTrue(first.isEmpty, "history must not replay: \(first.map(\.id))")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertTrue(client.appliedIDs.isEmpty, "seeded ids live apart from the capped applied list")
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2", "d-3"]), "the seed is durable")
        // The bytes, not a round trip through LedgerFile's own CodingKeys: every deployed
        // daemon reads this file back, so a renamed key is a fleet-wide dedupe reset.
        XCTAssertEqual(
            try rawLedger(),
            #"{"applied":[],"inbox_seed_pending":false,"inbox_seeded":[],"seed_pending":false,"seeded":["d-1","d-2","d-3"]}"#,
            "the on-disk key names are a wire contract with every deployed daemon"
        )
        XCTAssertEqual(
            lines.filter {
                $0 == "[s3] first run: 3 historical directive(s) in the supervision doc marked applied, not replayed"
            }.count,
            1, "got: \(lines)"
        )

        // A directive issued AFTER boot is the only thing the next poll delivers.
        body = historyPlusOne()
        let second = await client.poll()
        XCTAssertEqual(second.map(\.id), ["d-4"])
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) }.count, 1,
                       "seeds once per process: \(lines)")
    }

    /// Every id is seeded — other agents' entries and structurally bad ones included.
    /// Simplest and safest: none of it is this box's business, and a seeded bad entry
    /// never even reaches the kind/text checks, so no skip lines either.
    func testFirstRunSeedsEveryIdRegardlessOfAgentOrKind() async {
        startWithNoLedger()
        var lines: [String] = []
        let body = document("""
        {"id": "d-1", "agent": "otherbot", "kind": "user_message", "text": "someone else's"},
        {"id": "d-2", "kind": "reboot_everything", "text": "structurally bad"},
        {"id": "d-3", "kind": "user_message", "text": "   "},
        {"id": "d-4", "agent": "finbot", "kind": "user_message", "text": "ours, but history"}
        """)
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })

        let pending = await client.poll()

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3", "d-4"])
        XCTAssertTrue(lines.contains(
            "[s3] first run: 4 historical directive(s) in the supervision doc marked applied, not replayed"
        ), "got: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("skipped directive") }, "got: \(lines)")
    }

    /// An existing ledger — even an empty one — means the daemon has run here before:
    /// today's behavior is unchanged and every unapplied directive is delivered.
    func testPresentEmptyLedgerIsNotAFirstRun() async throws {
        XCTAssertEqual(try rawLedger(), "[]", "setUp leaves the 1.3.0 empty ledger on disk")
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "d-3"])
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(lines.contains { $0.hasPrefix(Self.firstRunAuditPrefix) }, "got: \(lines)")
        XCTAssertEqual(try rawLedger(), "[]", "nothing applied, nothing seeded — the file is untouched")
    }

    /// A 1.3.0 ledger — the bare array — loads as applied ids and is rewritten in the
    /// 1.4.0 object form on the next write, with nothing lost.
    func testLegacyArrayLedgerLoadsAndUpgradesInPlace() async throws {
        try Data(#"["d-1"]"#.utf8).write(to: URL(fileURLWithPath: stateFile))
        let client = makeClient(fetch: { _ in (self.history(), self.response(200)) })

        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-2", "d-3"], "d-1 was applied by the 1.3.0 daemon")

        client.markApplied("d-2")
        XCTAssertEqual(try persistedLedger(), seededLedger([], applied: ["d-1", "d-2"]))
    }

    /// The cloud-worker posture: the config says the launcher emptied the inbox (the
    /// control plane does, at the `POST /workers` call), so anything in it by the first
    /// read is a live message that arrived while the worker booted, and it must apply.
    func testFirstRunSeedLeavesInboxMessagesAloneWhenTheLauncherResetTheInbox() async throws {
        startWithNoLedger()
        var lines: [String] = []
        let directives = document("""
        {"id": "d-1", "kind": "user_message", "text": "history"},
        {"id": "d-2", "kind": "user_message", "text": "more history"}
        """)
        let inbox = document("""
        {"id": "m-1", "kind": "user_message", "text": "sent while booting"},
        {"id": "m-2", "kind": "user_message", "text": "and again"}
        """)
        let client = makeInboxClient(
            inboxResetAtLaunch: true,
            audit: { lines.append($0) },
            directives: { (directives, self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["m-1", "m-2"], "inbox delivers; directives are seeded")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2"], "directive ids seeded, inbox ids untouched")
        XCTAssertTrue(client.seededInboxIDs.isEmpty)
        XCTAssertTrue(client.appliedIDs.isEmpty)
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2"]))
        XCTAssertTrue(lines.contains(
            "[s3] first run: 2 historical directive(s) in the supervision doc marked applied, not replayed"
        ), "got: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("inbox") }, "nothing to say about an exempt inbox: \(lines)")
    }

    /// The resident posture (config.example.json — no `inboxResetAtLaunch`): only the
    /// control plane's launch path empties the inbox, the app only ever appends, so a
    /// first run here would otherwise replay the phone's whole backlog — weeks of
    /// prompts, one model turn each, before the first heartbeat. The inbox is seeded
    /// like the directive document, under its own ledger keys, and the status
    /// document's mark stays the directive one.
    func testFirstRunSeedsTheInboxBacklogTooUnlessTheLauncherResetIt() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var inbox = document("""
        {"id": "m-1", "kind": "user_message", "text": "three weeks ago"},
        {"id": "m-2", "kind": "user_message", "text": "last tuesday"}
        """)
        let client = makeInboxClient(
            audit: { lines.append($0) },
            directives: { (self.history(), self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )

        let first = await client.poll()

        XCTAssertTrue(first.isEmpty, "the backlog is history, not instructions: \(first.map(\.id))")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(client.seededInboxIDs, ["m-1", "m-2"])
        XCTAssertTrue(client.appliedIDs.isEmpty)
        XCTAssertEqual(try persistedLedger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1", "m-2"]))
        XCTAssertTrue(lines.contains("[s3] first run: 2 message(s) already in the inbox marked applied, not replayed"),
                      "got: \(lines)")
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) }.count, 2, "one line per source: \(lines)")

        // The status mark is the DIRECTIVE high-water; an opaque inbox id would mean
        // nothing to the supervisor reading it.
        let status = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(client.statusBody(DaemonStatusSnapshot(state: "idle")).utf8)) as? [String: Any])
        XCTAssertEqual(status["last_applied_id"] as? String, "d-3")

        // Sent after the daemon came up: delivered, and only it.
        inbox = document("""
        {"id": "m-1", "kind": "user_message", "text": "three weeks ago"},
        {"id": "m-2", "kind": "user_message", "text": "last tuesday"},
        {"id": "m-3", "kind": "user_message", "text": "just now"}
        """)
        let pending746 = await client.poll()
        XCTAssertEqual(pending746.map(\.id), ["m-3"])

        // And the inbox seed is durable across a restart, like the directive one.
        let reborn = makeInboxClient(
            directives: { (self.history(), self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )
        let pending753 = await reborn.poll()
        XCTAssertEqual(pending753.map(\.id), ["m-3"])
        XCTAssertEqual(reborn.seededInboxIDs, ["m-1", "m-2"])
    }

    /// The inbox seed waits for its own document and survives a restart on its own flag,
    /// independently of the directive seed — the two sources fail independently
    /// everywhere else too.
    func testInboxSeedPendingSurvivesARestartOnItsOwnFlag() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        let inbox = document(#"{"id": "m-1", "kind": "user_message", "text": "backlog"}"#)
        let firstLife = makeInboxClient(
            directives: { (self.history(), self.response(200)) },
            inbox: { throw Boom() }
        )
        let pending768 = await firstLife.poll()
        XCTAssertTrue(pending768.isEmpty)
        XCTAssertEqual(firstLife.seededIDs, ["d-1", "d-2", "d-3"], "the directive seed does not wait for the inbox")
        XCTAssertEqual(try persistedLedger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeedPending: true))

        var lines: [String] = []
        let secondLife = makeInboxClient(
            audit: { lines.append($0) },
            directives: { (self.history(), self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )
        XCTAssertTrue(lines.contains("[s3] first run: resumed with the inbox seed still pending"), "got: \(lines)")
        XCTAssertFalse(lines.contains("[s3] first run: resumed with the directive seed still pending"), "got: \(lines)")

        let pending = await secondLife.poll()

        XCTAssertTrue(pending.isEmpty, "the backlog is seeded when the inbox finally reads, not replayed: \(pending.map(\.id))")
        XCTAssertEqual(secondLife.seededInboxIDs, ["m-1"])
        XCTAssertEqual(try persistedLedger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1"]))
    }

    /// A corrupt ledger is a reset, not a first run: the daemon HAS run here, so it
    /// keeps today's replay-what's-unapplied behavior with its own audit line, and the
    /// two cases stay distinguishable in the log.
    func testCorruptLedgerIsNotSeeded() async throws {
        try Data("not json {{".utf8).write(to: URL(fileURLWithPath: stateFile))
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        let pending = await client.poll()

        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "d-3"])
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertEqual(lines.filter { $0 == "[s3] state file unreadable — dedupe reset" }.count, 1)
        XCTAssertFalse(lines.contains { $0.hasPrefix(Self.firstRunAuditPrefix) }, "got: \(lines)")
        XCTAssertEqual(try rawLedger(), "not json {{", "a reset never rewrites the file it couldn't read")
    }

    /// A ledger that exists but can't be read (permissions, a directory at the path) is
    /// a reset like a corrupt one — the daemon has run here — never a first run that
    /// would seed, fail to persist, and do it all again on every launch. Every write
    /// fails here too, so this also pins the failed-write path: audited, and the next
    /// life replays what this one applied (noisy, nothing lost) rather than the write
    /// silently not happening.
    func testUnreadableLedgerIsAResetNotAFirstRun() async throws {
        try FileManager.default.removeItem(atPath: stateFile)
        try FileManager.default.createDirectory(atPath: stateFile, withIntermediateDirectories: false)
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        XCTAssertEqual(lines.filter { $0 == "[s3] state file unreadable — dedupe reset" }.count, 1, "got: \(lines)")
        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "d-3"], "delivered, as after any reset")
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(lines.contains { $0.hasPrefix(Self.firstRunAuditPrefix) }, "got: \(lines)")

        client.markApplied("d-1")
        XCTAssertEqual(lines.filter { $0.hasPrefix("[s3] ledger write failed — ") }.count, 1,
                       "a write that never lands must say so: \(lines)")
        let pending830 = await client.poll()
        XCTAssertEqual(pending830.map(\.id), ["d-2", "d-3"], "in memory, d-1 is applied")

        var rebornLines: [String] = []
        let reborn = makeClient(audit: { rebornLines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })
        let pending835 = await reborn.poll()
        XCTAssertEqual(pending835.map(\.id), ["d-1", "d-2", "d-3"],
                       "the apply never persisted, so d-1 replays — visibly, after another reset line")
        XCTAssertTrue(rebornLines.contains("[s3] state file unreadable — dedupe reset"), "got: \(rebornLines)")
    }

    /// The seed's own write can fail (a state directory owned by another uid, a read-only
    /// mount, a full disk). 1.3.0 turned a lost ledger into a replay; with the seed, a
    /// lost ledger makes the NEXT launch a first run again, which seeds — and drops —
    /// whatever was written in between. That must be visible, and it must re-seed
    /// rather than pretend.
    func testFirstRunSeedThatCannotPersistAuditsAndIsAFirstRunAgainOnRestart() async throws {
        let unwritable = NSTemporaryDirectory() + "fin-agentd-missing-dir-\(UUID().uuidString)/ledger.json"
        var lines: [String] = []
        let client = makeClient(stateFilePath: unwritable, audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        let pending = await client.poll()

        XCTAssertTrue(pending.isEmpty, "the seed still holds in memory: \(pending.map(\.id))")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwritable))
        XCTAssertEqual(lines.filter { $0.hasPrefix("[s3] first run: could not persist the seed — ") }.count, 1,
                       "got: \(lines)")

        var rebornLines: [String] = []
        let reborn = makeClient(stateFilePath: unwritable, audit: { rebornLines.append($0) },
                                fetch: { _ in (self.historyPlusOne(), self.response(200)) })
        let afterRestart = await reborn.poll()
        XCTAssertTrue(afterRestart.isEmpty, "no ledger landed, so this is a first run again — it seeds, it does not replay: \(afterRestart.map(\.id))")
        XCTAssertEqual(reborn.seededIDs, ["d-1", "d-2", "d-3", "d-4"], "and d-4 is what the lost ledger cost")
        XCTAssertTrue(rebornLines.contains("[s3] first run: 4 historical directive(s) in the supervision doc marked applied, not replayed"),
                      "got: \(rebornLines)")
    }

    /// The seed waits for a document it actually read: a failed first fetch leaves it
    /// pending (and delivers nothing, as any failed source does); the next successful
    /// fetch is the one that seeds.
    func testFirstRunSeedWaitsForAFreshDirectiveDocument() async {
        startWithNoLedger()
        struct Boom: Error {}
        var lines: [String] = []
        var callCount = 0
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            callCount += 1
            if callCount == 1 { throw Boom() }
            return (self.history(), self.response(200))
        })

        let failed = await client.poll()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertTrue(client.seededIDs.isEmpty, "nothing was read, so nothing is seeded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile))

        let seeded = await client.poll()
        XCTAssertTrue(seeded.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) }.count, 1, "got: \(lines)")
    }

    func testSeededLedgerSurvivesARestartWithoutReseeding() async {
        startWithNoLedger()
        let client = makeClient(fetch: { _ in (self.history(), self.response(200)) })
        _ = await client.poll()

        var lines: [String] = []
        let reborn = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.historyPlusOne(), self.response(200)) })
        let pending = await reborn.poll()

        XCTAssertEqual(pending.map(\.id), ["d-4"], "the seed persisted; only the new directive lands")
        XCTAssertFalse(lines.contains { $0.hasPrefix(Self.firstRunAuditPrefix) },
                       "a ledger exists now — not a first run: \(lines)")
    }

    /// Nothing to seed is still a first run: the ledger is created so the next launch
    /// isn't one, but no audit line claims history was skipped.
    func testFirstRunWithAnEmptyDirectiveDocumentCreatesTheLedgerSilently() async throws {
        startWithNoLedger()
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.document(""), self.response(200)) })

        let pending = await client.poll()

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(try persistedLedger(), seededLedger([]))
        XCTAssertTrue(lines.isEmpty, "got: \(lines)")
    }

    /// The seed must outlive the applied-id cap: a shared document can hold more than
    /// 500 entries, and a seeded id evicted from a capped list would replay — the bug
    /// itself, in the large-document case. Seeded ids are therefore kept apart and
    /// uncapped, the audit count is the retained count, and the cap keeps governing
    /// only what the daemon applies itself.
    func testFirstRunSeedSurvivesTheAppliedIDCap() async throws {
        startWithNoLedger()
        let count = DaemonDirectiveClient.appliedIDsCap + 100
        let history = (1...count).map { #"{"id": "d-\#($0)", "kind": "user_message", "text": "old"}"# }
        var body = document(history.joined(separator: ","))
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (body, self.response(200)) })

        let first = await client.poll()

        XCTAssertTrue(first.isEmpty, "nothing in a \(count)-entry history may replay: \(first.map(\.id).prefix(5))")
        XCTAssertEqual(client.seededIDs.count, count)
        XCTAssertTrue(client.appliedIDs.isEmpty)
        XCTAssertTrue(lines.contains(
            "[s3] first run: \(count) historical directive(s) in the supervision doc marked applied, not replayed"
        ), "got: \(lines)")
        XCTAssertEqual(try persistedLedger().seeded.count, count, "all of it is durable, not a 500-id suffix")

        // Churn the applied list past its cap; the seed is unaffected.
        for index in 0..<(DaemonDirectiveClient.appliedIDsCap + 10) {
            client.markApplied("m-\(index)")
        }
        XCTAssertEqual(client.appliedIDs.count, DaemonDirectiveClient.appliedIDsCap)
        body = document((history + [#"{"id": "d-new", "kind": "user_message", "text": "fresh"}"#]).joined(separator: ","))
        let afterChurn = await client.poll()
        XCTAssertEqual(afterChurn.map(\.id), ["d-new"])

        // And across a restart.
        let reborn = makeClient(fetch: { _ in (body, self.response(200)) })
        let afterRestart = await reborn.poll()
        XCTAssertEqual(afterRestart.map(\.id), ["d-new"])
    }

    /// The status document's `last_applied_id` is the high-water mark after a seed —
    /// the LAST id in the directive document — until the daemon applies something
    /// itself.
    func testStatusReportsTheSeedAsLastAppliedUntilARealApply() async throws {
        startWithNoLedger()
        let client = makeClient(fetch: { _ in (self.history(), self.response(200)) })
        _ = await client.poll()

        func lastApplied() throws -> String? {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(client.statusBody(DaemonStatusSnapshot(state: "idle")).utf8)
            ) as? [String: Any])
            return object["last_applied_id"] as? String
        }
        XCTAssertEqual(try lastApplied(), "d-3")
        client.markApplied("m-1")
        XCTAssertEqual(try lastApplied(), "m-1")
    }

    /// "Last id in the document", literally — document order, never sorted, so the
    /// field is the high-water mark exactly when the supervisor appends (the document's
    /// contract) and the README says so rather than promising "newest".
    func testStatusLastAppliedAfterASeedIsTheDocumentsLastElementNotTheNewestId() async throws {
        startWithNoLedger()
        let notAppendOrdered = document("""
        {"id": "d-3", "kind": "user_message", "text": "newest, written first"},
        {"id": "d-1", "kind": "user_message", "text": "oldest"},
        {"id": "d-2", "kind": "user_message", "text": "middle"}
        """)
        let client = makeClient(fetch: { _ in (notAppendOrdered, self.response(200)) })
        _ = await client.poll()

        XCTAssertEqual(client.seededIDs, ["d-3", "d-1", "d-2"], "document order is kept")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(client.statusBody(DaemonStatusSnapshot(state: "idle")).utf8)
        ) as? [String: Any])
        XCTAssertEqual(object["last_applied_id"] as? String, "d-2")
    }

    // MARK: First run — an absent document (1.4.1)

    /// Nothing creates `fin/directives.json` until an operator writes the first directive
    /// (the control plane only ever PUTs the per-agent inbox), so on a bucket without it
    /// a first run's every read fails until that first directive — which would then be
    /// the first successful read, and seeded. A 404 on the directive slot at first run
    /// means "no history": the seed completes empty and that first directive lands.
    func testFirstRunWithNoDirectiveDocumentSeedsNothingAndDeliversTheFirstOneWritten() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var exists = false
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            if exists {
                return (self.document(#"{"id": "d-1", "kind": "user_message", "text": "the first directive ever"}"#), self.response(200))
            }
            return (Data(), self.response(404))
        })

        let first = await client.poll()

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(client.isFirstRun, "the seed is complete — empty")
        XCTAssertEqual(try persistedLedger(), seededLedger([]), "seed_pending is false on disk")
        XCTAssertEqual(lines, ["[s3] first run: no supervision directive document yet (HTTP 404) — nothing to seed"],
                       "one line, and NOT a poll failure: \(lines)")

        exists = true
        let second = await client.poll()
        XCTAssertEqual(second.map(\.id), ["d-1"], "the first directive written is delivered, not stamped history")
    }

    /// A 403 is NOT "no document", at first run or ever. S3 answers it for a missing key
    /// when the signer lacks ListBucket — but also for an expired presigned URL, a
    /// signature mismatch, a revoked key, a denied policy — and the control plane's and
    /// the operator's signers hold ListBucket, so a missing key reads 404 to them.
    /// Reading 403 as absent would complete the seed EMPTY on a denied read and write a
    /// ledger; the next launch, URLs re-minted, would then replay the whole document. So
    /// at first run a 403 is the plain poll failure it was under 1.4.0: the seed stays
    /// pending, nothing is written, and the first document actually read is what seeds.
    func testA403AtFirstRunIsAFailureThatLeavesTheSeedPending() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var status = 403
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            if status == 200 { return (self.history(), self.response(200)) }
            return (Data(), self.response(status))
        })

        await client.primeFirstRunSeed()

        XCTAssertTrue(client.isFirstRun, "a 403 may mean 'denied' — the seed is still owed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile), "nothing resolved, nothing written")
        XCTAssertTrue(lines.contains("[s3] poll failed: HTTP 403"), "got: \(lines)")
        XCTAssertTrue(lines.contains("[s3] first run: directive document not read at launch — seed deferred to the next poll"),
                      "got: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("nothing to seed") }, "403 is never 'absent': \(lines)")

        let stillDenied = await client.poll()
        XCTAssertTrue(stillDenied.isEmpty)
        XCTAssertTrue(client.isFirstRun, "still owed after a poll's 403 too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile))

        status = 200
        let firstRead = await client.poll()
        XCTAssertTrue(firstRead.isEmpty, "the first document read is history, not delivered")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"], "seeded on the first document actually read: 3, not 0")
        XCTAssertFalse(client.isFirstRun)
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2", "d-3"]))
    }

    /// The refuted scenario, end to end: a resident install starts with stale presigned
    /// URLs (403 on both slots), the operator re-mints them and restarts in the same
    /// state directory. Because the 403s wrote no ledger, the restart is still a first
    /// run, and the first successful read seeds the directive document's N ids and the
    /// inbox's M — replaying none of them. (Had 403 counted as absent, the first life
    /// would have persisted an empty seed and the second replayed all N + M.)
    func testA403AtFirstRunThenReMintedURLsOnRestartSeedTheWholeBacklogNotZero() async throws {
        startWithNoLedger()
        var lines: [String] = []
        let directives = history()
        let inbox = document("""
        {"id": "m-1", "kind": "user_message", "text": "old"},
        {"id": "m-2", "kind": "user_message", "text": "older"}
        """)
        let stale = makeInboxClient(
            audit: { lines.append($0) },
            directives: { (Data(), self.response(403)) },
            inbox: { (Data(), self.response(403)) }
        )

        await stale.primeFirstRunSeed()
        let firstLifePending = await stale.poll()

        XCTAssertTrue(firstLifePending.isEmpty)
        XCTAssertTrue(stale.isFirstRun, "both seeds are still owed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile), "no ledger: the restart must still be a first run")
        XCTAssertTrue(lines.contains("[s3] poll failed: HTTP 403"), "got: \(lines)")
        XCTAssertTrue(lines.contains("[s3] inbox poll failed: HTTP 403"), "got: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("nothing to seed") }, "got: \(lines)")

        lines = []
        let reMinted = makeInboxClient(
            audit: { lines.append($0) },
            directives: { (directives, self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )

        await reMinted.primeFirstRunSeed()
        let secondLifePending = await reMinted.poll()

        XCTAssertTrue(secondLifePending.isEmpty, "nothing replays: \(secondLifePending.map(\.id))")
        XCTAssertEqual(reMinted.seededIDs, ["d-1", "d-2", "d-3"], "N = 3 directive ids seeded, not 0")
        XCTAssertEqual(reMinted.seededInboxIDs, ["m-1", "m-2"], "M = 2 inbox ids seeded, not 0")
        XCTAssertFalse(reMinted.isFirstRun)
        XCTAssertEqual(try persistedLedger(),
                       DaemonDirectiveClient.LedgerFile(seeded: ["d-1", "d-2", "d-3"], inboxSeeded: ["m-1", "m-2"]))
        XCTAssertTrue(lines.contains("[s3] first run: 3 historical directive(s) in the supervision doc marked applied, not replayed"),
                      "got: \(lines)")
        XCTAssertTrue(lines.contains("[s3] first run: 2 message(s) already in the inbox marked applied, not replayed"),
                      "got: \(lines)")
    }

    /// Transient failures keep deferring: a 5xx, like a thrown transport error, says
    /// nothing about whether the document exists.
    func testFirstRunStillDefersTheSeedOnAServerError() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var status = 503
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            if status == 200 { return (self.history(), self.response(200)) }
            return (Data(), self.response(status))
        })

        await client.primeFirstRunSeed()

        XCTAssertTrue(client.isFirstRun, "a 503 is not 'no document'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile))
        XCTAssertTrue(lines.contains("[s3] poll failed: HTTP 503"), "got: \(lines)")
        XCTAssertTrue(lines.contains("[s3] first run: directive document not read at launch — seed deferred to the next poll"),
                      "got: \(lines)")

        status = 200
        let pending1076 = await client.poll()
        XCTAssertTrue(pending1076.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"], "seeded on the first document actually read")
    }

    /// After the first run a 404 is what it always was: a poll failure, audited under
    /// the failure prefix, with the ledger untouched.
    func testA404AfterTheFirstRunIsAPollFailureAsBefore() async throws {
        XCTAssertEqual(try rawLedger(), "[]", "setUp's ledger: the daemon has run here")
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (Data(), self.response(404)) })

        let pending = await client.poll()

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(lines, ["[s3] poll failed: HTTP 404"], "got: \(lines)")
        XCTAssertEqual(try rawLedger(), "[]", "nothing seeded, nothing written")
    }

    /// The same is true once the seed has completed inside one process: the absent
    /// reading is a first-run rule, not a permanent reinterpretation of 404.
    func testA404OnceTheSeedIsDrawnIsAPollFailureAgain() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var status = 200
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            if status == 200 { return (self.history(), self.response(200)) }
            return (Data(), self.response(status))
        })
        _ = await client.poll()
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])

        status = 404
        _ = await client.poll()

        XCTAssertTrue(lines.contains("[s3] poll failed: HTTP 404"), "got: \(lines)")
        XCTAssertEqual(lines.filter { $0.contains("nothing to seed") }.count, 0, "got: \(lines)")
    }

    /// An absent inbox never resolves the DIRECTIVE seed — the slots are independent —
    /// and, exempt (the cloud posture), the inbox's 404 is an ordinary inbox failure.
    func testAnAbsentInboxNeverResolvesTheDirectiveSeed() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        var lines: [String] = []
        var directivesReachable = false
        let client = makeInboxClient(
            inboxResetAtLaunch: true,
            audit: { lines.append($0) },
            directives: {
                guard directivesReachable else { throw Boom() }
                return (self.history(), self.response(200))
            },
            inbox: { (Data(), self.response(404)) }
        )

        await client.primeFirstRunSeed()
        XCTAssertTrue(client.isFirstRun, "the directive seed is still owed")
        XCTAssertFalse(lines.contains { $0.hasPrefix("[s3] inbox") }, "an exempt inbox is not read by the prime at all: \(lines)")

        let firstPoll = await client.poll()
        XCTAssertTrue(firstPoll.isEmpty)
        XCTAssertTrue(client.isFirstRun, "still owed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile), "nothing resolved, nothing written")
        XCTAssertTrue(lines.contains("[s3] inbox poll failed: HTTP 404"), "an exempt inbox's 404 is a plain failure: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("nothing to seed") }, "got: \(lines)")

        directivesReachable = true
        let pending1138 = await client.poll()
        XCTAssertTrue(pending1138.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"], "seeded from the directive document, when it finally read")
    }

    /// Resident posture: an inbox object that doesn't exist yet (the phone never wrote
    /// one) is no backlog — the inbox seed completes empty on its own, the directive
    /// seed stays owed, and the first message the phone ever sends is delivered.
    func testFirstRunWithNoInboxDocumentSeedsTheInboxEmptyOnItsOwn() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        var lines: [String] = []
        var inboxExists = false
        let client = makeInboxClient(
            audit: { lines.append($0) },
            directives: { throw Boom() },
            inbox: {
                if inboxExists {
                    return (self.document(#"{"id": "m-1", "kind": "user_message", "text": "first ever"}"#), self.response(200))
                }
                return (Data(), self.response(404))
            }
        )

        _ = await client.poll()

        XCTAssertTrue(client.isFirstRun, "the directive seed is still owed")
        XCTAssertEqual(try persistedLedger(), DaemonDirectiveClient.LedgerFile(seedPending: true),
                       "the inbox's seed is done (empty); the directive's is recorded as pending")
        XCTAssertTrue(lines.contains("[s3] first run: no inbox document yet (HTTP 404) — nothing to seed"), "got: \(lines)")
        XCTAssertFalse(lines.contains("[s3] inbox poll failed: HTTP 404"), "not a failure at first run: \(lines)")

        inboxExists = true
        let pending1169 = await client.poll()
        XCTAssertEqual(pending1169.map(\.id), ["m-1"], "the phone's first message lands")
    }

    // MARK: First run — evidence beyond the ledger (1.4.1)

    /// 1.3.0 wrote the ledger only on its first apply, so a box that ran it for weeks
    /// without a matching directive has no ledger at all. Upgrade it and restart with a
    /// directive freshly written: `.missing` alone would seed that directive as history.
    /// The daemon passes what it can observe — its audit log predates this launch — and
    /// that makes it not a first run: delivered, as 1.3.0 would have.
    func testMissingLedgerWithAPriorRunsAuditLogIsNotAFirstRun() async throws {
        startWithNoLedger()
        var lines: [String] = []
        let client = makeClient(hasRunHereBefore: true, audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        XCTAssertEqual(lines, ["[s3] no directive ledger, but the audit log predates this launch — not a first run, nothing seeded"],
                       "got: \(lines)")
        XCTAssertFalse(client.isFirstRun)
        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "d-3"], "every unapplied directive is delivered")
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertEqual(try persistedLedger(), DaemonDirectiveClient.LedgerFile(),
                       "the verdict is written down: an empty, non-pending ledger, not re-derived from the audit log next launch")
        XCTAssertFalse(lines.contains { $0.hasPrefix(Self.firstRunAuditPrefix) }, "got: \(lines)")

        // The next launch reads that ledger and needs no audit-log evidence at all.
        var rebornLines: [String] = []
        let reborn = makeClient(hasRunHereBefore: false, audit: { rebornLines.append($0) },
                                fetch: { _ in (self.historyPlusOne(), self.response(200)) })
        XCTAssertFalse(reborn.isFirstRun, "the ledger says it ran here")
        XCTAssertTrue(rebornLines.isEmpty, "no verdict to re-derive, nothing to say: \(rebornLines)")
        let rebornPending = await reborn.poll()
        XCTAssertEqual(rebornPending.map(\.id), ["d-1", "d-2", "d-3", "d-4"], "still delivered, still nothing seeded")
    }

    /// With no such evidence a missing ledger is still the first run it always was.
    func testMissingLedgerWithoutPriorRunEvidenceIsAFirstRun() async throws {
        startWithNoLedger()
        let client = makeClient(hasRunHereBefore: false,
                                fetch: { _ in (self.history(), self.response(200)) })
        XCTAssertTrue(client.isFirstRun)
        let pending1201 = await client.poll()
        XCTAssertTrue(pending1201.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
    }

    // MARK: Ledger file shape

    /// The load side of the wire contract: a hand-written 1.4.0 object — the exact key
    /// names — loads as what it says, with no reset, no first run, no reseed. The
    /// counterpart to `testLegacyArrayLedgerLoadsAndUpgradesInPlace`, which pins only
    /// the 1.3.0 shape.
    func testHandWrittenObjectLedgerLoadsAsIs() async throws {
        try Data(#"{"applied":["d-1"],"seeded":["d-9"],"seed_pending":false}"#.utf8)
            .write(to: URL(fileURLWithPath: stateFile))
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        XCTAssertEqual(client.appliedIDs, ["d-1"])
        XCTAssertEqual(client.seededIDs, ["d-9"])
        XCTAssertTrue(client.seededInboxIDs.isEmpty, "a 1.4.0 file has no inbox keys; they default")
        XCTAssertFalse(client.isFirstRun)
        XCTAssertTrue(lines.isEmpty, "no reset, no first run: \(lines)")
        let pending1223 = await client.poll()
        XCTAssertEqual(pending1223.map(\.id), ["d-2", "d-3"])
    }

    /// A partial object keeps what it carries. Missing keys default — the same forward
    /// tolerance the directive document has — instead of the file counting as corrupt,
    /// which would throw the applied ids away and replay them.
    func testPartialObjectLedgerKeepsItsAppliedIDs() async throws {
        try Data(#"{"applied":["d-1"]}"#.utf8).write(to: URL(fileURLWithPath: stateFile))
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (self.history(), self.response(200)) })

        XCTAssertEqual(client.appliedIDs, ["d-1"])
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(client.isFirstRun, "an object ledger means the daemon ran here")
        XCTAssertTrue(lines.isEmpty, "no 'dedupe reset', no first run: \(lines)")
        let pending1239 = await client.poll()
        XCTAssertEqual(pending1239.map(\.id), ["d-2", "d-3"], "d-1 stays applied")
    }

    // MARK: First run — 304 with nothing cached

    /// A first run's prime sends no `If-None-Match`, but a caching proxy in front of the
    /// bucket can still answer 304 — `isFresh` with no body. That must not end the
    /// first run with an empty seed, or the whole document lands on the next 200.
    func testFirstRunDoesNotSeedOnA304WithNoCachedDocument() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var status = 304
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            if status == 200 { return (self.history(), self.response(200)) }
            return (Data(), self.response(304))
        })

        await client.primeFirstRunSeed()

        XCTAssertTrue(client.isFirstRun, "a 304 with nothing cached says nothing about history")
        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile), "no ledger was written")
        XCTAssertTrue(lines.contains("[s3] first run: directive document not read at launch — seed deferred to the next poll"),
                      "got: \(lines)")

        status = 200
        let pending1264 = await client.poll()
        XCTAssertTrue(pending1264.isEmpty, "the first real body seeds")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
    }

    /// The one path where a ledger exists yet seeding still happens: the directive fetch
    /// keeps failing while an inbox message applies and persists. The seed must still
    /// land on the next successful directive read in this process.
    func testInboxApplyWhileTheSeedIsPendingKeepsTheFirstRun() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        var directivesReachable = false
        var lines: [String] = []
        let inbox = document(#"{"id": "m-1", "kind": "user_message", "text": "from the phone"}"#)
        let client = makeInboxClient(
            inboxResetAtLaunch: true,
            audit: { lines.append($0) },
            directives: {
                guard directivesReachable else { throw Boom() }
                return (self.history(), self.response(200))
            },
            inbox: { (inbox, self.response(200)) }
        )

        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["m-1"], "the inbox is exempt, and a dead directive URL is not its problem")
        client.markApplied("m-1")
        XCTAssertEqual(try persistedLedger(),
                       DaemonDirectiveClient.LedgerFile(applied: ["m-1"], seeded: [], seedPending: true),
                       "the ledger exists, and says the seed is still owed")

        directivesReachable = true
        let afterRecovery = await client.poll()

        XCTAssertTrue(afterRecovery.isEmpty, "history seeded, m-1 applied: \(afterRecovery.map(\.id))")
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2", "d-3"], applied: ["m-1"]))
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) }.count, 1, "got: \(lines)")
    }

    /// Same window, plus a restart before the directive URL recovers — real on a cloud
    /// worker (systemd `Restart=always`, and the daemon exits after five failed turns).
    /// Because the file records the pending seed, the second life is still a first run:
    /// the shared document is seeded when it finally arrives, never replayed, and the
    /// inbox id applied by the first life stays applied.
    func testRestartWhileTheSeedIsPendingIsStillAFirstRun() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        let inbox = document(#"{"id": "m-1", "kind": "user_message", "text": "from the phone"}"#)
        let firstLife = makeInboxClient(
            inboxResetAtLaunch: true,
            directives: { throw Boom() },
            inbox: { (inbox, self.response(200)) }
        )
        _ = await firstLife.poll()
        firstLife.markApplied("m-1")
        XCTAssertTrue(try persistedLedger().seedPending)

        var lines: [String] = []
        let secondLife = makeInboxClient(
            inboxResetAtLaunch: true,
            audit: { lines.append($0) },
            directives: { (self.history(), self.response(200)) },
            inbox: { (inbox, self.response(200)) }
        )
        XCTAssertTrue(lines.contains("[s3] first run: resumed with the directive seed still pending"), "got: \(lines)")

        let pending = await secondLife.poll()

        XCTAssertTrue(pending.isEmpty, "m-1 stays applied and history is seeded, not replayed: \(pending.map(\.id))")
        XCTAssertEqual(secondLife.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(secondLife.appliedIDs, ["m-1"])
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2", "d-3"], applied: ["m-1"]))
        XCTAssertTrue(lines.contains(
            "[s3] first run: 3 historical directive(s) in the supervision doc marked applied, not replayed"
        ), "got: \(lines)")
    }

    // MARK: First run — the launch-time prime

    /// `primeFirstRunSeed` is the daemon's launch hook: it draws the high-water before
    /// the SSH connect and the first task turn, so a directive written during that
    /// (minutes-long) window is delivered rather than stamped history. It is not a
    /// poll — the loop's first scheduled poll still happens, riding the ETag the prime
    /// recorded.
    func testPrimeFirstRunSeedDrawsTheHighWaterAtLaunch() async throws {
        startWithNoLedger()
        var lines: [String] = []
        var requests: [URLRequest] = []
        var body = history()
        let client = makeClient(audit: { lines.append($0) }, fetch: { request in
            requests.append(request)
            return (body, self.response(200, etag: "\"v1\""))
        })

        await client.primeFirstRunSeed()

        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(try persistedLedger(), seededLedger(["d-1", "d-2", "d-3"]))
        XCTAssertTrue(client.pollIsDue, "priming is not a poll; the loop's first poll runs on schedule")
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) }.count, 1, "got: \(lines)")

        // Written while the daemon connected and ran its first turn: delivered.
        body = historyPlusOne()
        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-4"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"",
                       "the poll's conditional GET rides the ETag the prime recorded")
    }

    func testPrimeFirstRunSeedIsANoOpWhenTheDaemonHasRunBefore() async throws {
        XCTAssertEqual(try rawLedger(), "[]")
        var fetches = 0
        let client = makeClient(fetch: { _ in
            fetches += 1
            return (self.history(), self.response(200))
        })

        await client.primeFirstRunSeed()

        XCTAssertEqual(fetches, 0, "nothing to seed, nothing to fetch")
        XCTAssertTrue(client.seededIDs.isEmpty)
        let pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1", "d-2", "d-3"], "today's behavior, untouched")
    }

    /// A launch-time fetch that fails must not stop the daemon or forfeit the seed: it
    /// says so once and the poll loop seeds on the first document it does read.
    func testPrimeFirstRunSeedDefersToThePollLoopWhenTheFetchFails() async throws {
        startWithNoLedger()
        struct Boom: Error {}
        var lines: [String] = []
        var reachable = false
        let client = makeClient(audit: { lines.append($0) }, fetch: { _ in
            guard reachable else { throw Boom() }
            return (self.history(), self.response(200))
        })

        await client.primeFirstRunSeed()

        XCTAssertTrue(client.seededIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile),
                       "nothing read, nothing written — still a first run")
        XCTAssertTrue(lines.contains(
            "[s3] first run: directive document not read at launch — seed deferred to the next poll"
        ), "got: \(lines)")

        reachable = true
        let pending = await client.poll()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(client.seededIDs, ["d-1", "d-2", "d-3"])
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.firstRunAuditPrefix) && $0.contains("historical") }.count, 1,
                       "got: \(lines)")
    }

    // MARK: ETag and caching

    func testSecondPollSendsIfNoneMatchAndReusesCachedDocumentOn304() async {
        let body = document(#"{"id": "d-1", "kind": "user_message", "text": "one"}"#)
        var requests: [URLRequest] = []
        var callCount = 0
        let client = makeClient(fetch: { request in
            requests.append(request)
            callCount += 1
            if callCount == 1 { return (body, self.response(200, etag: "\"abc\"")) }
            return (Data(), self.response(304))
        })

        var pending = await client.poll()
        XCTAssertEqual(pending.map(\.id), ["d-1"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))

        // Not applied yet — the 304 path must re-offer it from the cached document.
        pending = await client.poll()
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(pending.map(\.id), ["d-1"], "deferred directives retry on 304")
    }

    // MARK: Failure paths

    func testOversizedBodyIsRejected() async {
        var lines: [String] = []
        let oversized = Data(repeating: 0x7B, count: DaemonDirectiveClient.maxBodyBytes + 1)
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (oversized, self.response(200)) })

        let pending = await client.poll()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("body too large") }, "got: \(lines)")
    }

    func testRepeatedIdenticalFailuresAuditOncePerWindow() async {
        var lines: [String] = []
        struct Boom: Error {}
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in throw Boom() })

        _ = await client.poll()
        _ = await client.poll()
        _ = await client.poll()

        XCTAssertEqual(lines.filter { $0.hasPrefix("[s3] poll failed:") }.count, 1,
                       "identical failures must throttle to one audit line per window")
    }

    func testHTTPErrorStatusAuditsAsFailure() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (Data(), self.response(403)) })
        let pending = await client.poll()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(lines.contains("[s3] poll failed: HTTP 403"), "got: \(lines)")
    }

    func testUnparseableDocumentAudits() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) },
                                fetch: { _ in (Data("not json".utf8), self.response(200)) })
        _ = await client.poll()
        XCTAssertTrue(lines.contains { $0.contains("unparseable") }, "got: \(lines)")
    }

    // MARK: Status uplink

    func testStatusBodyCarriesTheDocumentedFields() throws {
        let client = makeClient(fetch: { _ in (Data(), self.response(200)) })
        client.markApplied("d-7")

        let turnDate = Date(timeIntervalSince1970: 1_756_400_000)
        let body = client.statusBody(DaemonStatusSnapshot(
            state: "idle",
            lastTurnAt: turnDate,
            lastAssistantPreview: String(repeating: "x", count: 300),
            lastError: "[s3] directive d-7 turn failed — not retried"
        ))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["device"] as? String, "fin-agentd")
        XCTAssertEqual(object["agent"] as? String, "finbot")
        XCTAssertEqual(object["state"] as? String, "idle")
        XCTAssertEqual(object["last_applied_id"] as? String, "d-7")
        XCTAssertEqual((object["last_assistant_preview"] as? String)?.count, 200,
                       "preview must truncate to 200 characters")
        XCTAssertEqual(object["last_error"] as? String,
                       "[s3] directive d-7 turn failed — not retried",
                       "a failed directive turn must be visible to the supervisor")
        XCTAssertNotNil(object["last_turn_at"] as? String)
        XCTAssertNotNil(object["updated_at"] as? String)
        XCTAssertEqual(object["device_id8"] as? String, DaemonConfig.defaultDeviceToken8)
        XCTAssertEqual(object["daemon_version"] as? String,
                       DaemonDirectiveClient.daemonVersion,
                       "the supervisor reads this to know which harness features exist")
    }

    func testStatusBodyCarriesTheConfiguredDeviceToken() throws {
        let client = makeClient(deviceToken8: "ec2abcd1", fetch: { _ in (Data(), self.response(200)) })
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(client.statusBody(DaemonStatusSnapshot(state: "idle")).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["device_id8"] as? String, "ec2abcd1")
    }

    func testStatusBodyWithoutAFailureCarriesANullLastError() throws {
        let client = makeClient(fetch: { _ in (Data(), self.response(200)) })
        let body = client.statusBody(DaemonStatusSnapshot(state: "idle", lastTurnAt: nil,
                                                          lastAssistantPreview: nil))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        XCTAssertTrue(object["last_error"] is NSNull, "last_error must be present but null")
    }

    func testPutStatusSendsAJSONPutToTheStatusURL() async throws {
        var putRequests: [URLRequest] = []
        let client = makeClient(
            fetch: { _ in (Data(), self.response(200)) },
            put: { request in
                putRequests.append(request)
                return self.response(200)
            }
        )

        await client.putStatus(DaemonStatusSnapshot(state: "idle", lastTurnAt: nil,
                                                    lastAssistantPreview: nil))

        let request = try XCTUnwrap(putRequests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://bucket.example/status.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: body))
    }

    func testPutFailureIsSwallowedButAudited() async {
        var lines: [String] = []
        let client = makeClient(
            audit: { lines.append($0) },
            fetch: { _ in (Data(), self.response(200)) },
            put: { _ in self.response(500) }
        )
        await client.putStatus(DaemonStatusSnapshot(state: "idle", lastTurnAt: nil,
                                                    lastAssistantPreview: nil))
        XCTAssertTrue(lines.contains("[s3] put failed: HTTP 500"), "got: \(lines)")
    }
}

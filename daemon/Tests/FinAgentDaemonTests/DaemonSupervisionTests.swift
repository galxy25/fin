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

    private var stateFile: String!

    // corelibs-xctest (Linux) keeps setUp/tearDown nonisolated even on a @MainActor
    // test class; they still run on the main thread, so hop explicitly.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            stateFile = NSTemporaryDirectory() + "fin-agentd-test-\(UUID().uuidString).json"
        }
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
        deviceToken8: String = DaemonConfig.defaultDeviceToken8,
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
            agentName: agentName,
            pollSeconds: 30,
            deviceToken8: deviceToken8,
            stateFilePath: stateFile,
            audit: audit,
            fetch: fetch,
            put: put
        )
    }

    /// A transport that answers the inbox URL and the directive URL differently, so
    /// merge order and per-source failure isolation are observable.
    private func makeInboxClient(
        audit: @escaping (String) -> Void = { _ in },
        directives: @escaping () async throws -> (Data, URLResponse),
        inbox: @escaping () async throws -> (Data, URLResponse)
    ) -> DaemonDirectiveClient {
        makeClient(
            inboxURL: "https://bucket.example/inbox.json",
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
        var lines: [String] = []
        _ = makeClient(audit: { lines.append($0) },
                       fetch: { _ in (Data(), self.response(200)) })
        XCTAssertTrue(lines.isEmpty, "a missing state file must not audit: \(lines)")
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

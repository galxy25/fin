import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon half of threads (docs/THREADS.md §2, §6): `thread_id` on every line
/// of a message turn and on none of a heartbeat's, `target` on the relay lines, the
/// pane → thread memory and its 24 h rule, the pre-turn signal, the turn-end
/// restamp, and the thread on pushes, acks, and follow-up goals.
@MainActor
final class DaemonThreadsTests: XCTestCase {

    private let runID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

    private func makeUplink(
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    ) -> DaemonTranscriptUplink {
        DaemonTranscriptUplink(
            endpointURL: "https://cp.example", token: "cp-token-123", flushSeconds: 15, maxLines: 2000,
            runID: runID, agentID: UUID(), agentName: "Fin", server: "10.0.0.7",
            modelIdentifier: "stub", temperature: 0.2, put: put
        )
    }

    private func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func linesInRequest(_ request: URLRequest) throws -> (hour: String, lines: [[String: Any]]) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let lines = try XCTUnwrap(body["lines"] as? [String]).map { try object($0) }
        return (try XCTUnwrap(body["hour"] as? String), lines)
    }

    // MARK: - thread_id and target on the lines

    func testEveryLineOfAMessageTurnCarriesTheThreadAndOnlyTheUserLineTheReply() throws {
        let uplink = makeUplink()
        uplink.beginMessageTurn(messageID: "m-1234", threadID: "m-root")
        uplink.record(AgentAuditEvent(kind: "turnStarted", text: "received"))
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "tell the claw session to ship"))
        uplink.record(AgentAuditEvent(kind: "reasoning", text: "find the pane"))
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "read_session: main:2.0 (40 lines)",
                                      toolName: "read_session", target: "main:2.0"))
        uplink.record(AgentAuditEvent(kind: "toolResult", text: "$ ..."))
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "send_session: main:2.0 (4 chars)",
                                      toolName: "send_session", target: "main:2.0"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "done"))

        let objects = try uplink.lines.map { try object($0) }
        XCTAssertEqual(objects.count, 7)
        for line in objects {
            XCTAssertEqual(line["thread_id"] as? String, "m-root", "\(line["kind"] ?? "") must carry the thread")
        }
        XCTAssertEqual(objects.compactMap { $0["in_reply_to"] as? String }, ["m-1234"], "in_reply_to stays a user-line field")
        XCTAssertEqual(objects.compactMap { $0["target"] as? String }, ["main:2.0", "main:2.0"])
        XCTAssertEqual(objects.filter { $0["target"] != nil }.compactMap { $0["tool_name"] as? String },
                       ["read_session", "send_session"])
        XCTAssertEqual(uplink.turnLines.count, 7)
    }

    func testHeartbeatLinesCarryNoThread() throws {
        let uplink = makeUplink()
        uplink.beginMessageTurn(messageID: "m-1", threadID: "m-1")
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "hi"))
        uplink.endMessageTurn()
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "[heartbeat] tick"))
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "read_session: main:2.0 (40 lines)",
                                      toolName: "read_session", target: "main:2.0"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "{\"decision\": \"idle\"}"))

        let objects = try uplink.lines.map { try object($0) }
        XCTAssertEqual(objects[0]["thread_id"] as? String, "m-1")
        for line in objects.dropFirst() {
            XCTAssertNil(line["thread_id"], "a heartbeat line names no thread: \(line["text"] ?? "")")
            XCTAssertNil(line["in_reply_to"])
        }
        XCTAssertEqual(objects[2]["target"] as? String, "main:2.0", "target is independent of the thread")
        XCTAssertTrue(uplink.turnLines.isEmpty)
    }

    func testAnEmptyTargetIsNotWritten() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "read_session: list sessions", toolName: "read_session"))
        XCTAssertNil(try object(try XCTUnwrap(uplink.lines.first))["target"])
    }

    // MARK: - restamp

    func testRestampRewritesTheTurnsLinesInPlaceWithTheSameIDs() async throws {
        var requests: [URLRequest] = []
        let uplink = makeUplink { request in
            requests.append(request)
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
        uplink.record(AgentAuditEvent(kind: "notice", text: "before the turn"))
        uplink.beginMessageTurn(messageID: "m-later", threadID: "m-later")
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "did it finish?"))
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "send_session: main:2.0 (4 chars)",
                                      toolName: "send_session", target: "main:2.0"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "yes"))
        let before = try uplink.lines.map { try object($0) }
        let turnIDs = before.dropFirst().compactMap { $0["id"] as? String }

        let restamped = await uplink.restampThread(to: "m-root")

        XCTAssertEqual(restamped, turnIDs, "the same ids, in order")
        let after = try uplink.lines.map { try object($0) }
        XCTAssertEqual(after.compactMap { $0["id"] as? String }, before.compactMap { $0["id"] as? String },
                       "no line is added or removed")
        XCTAssertNil(after[0]["thread_id"], "a line from before the turn is untouched")
        for line in after.dropFirst() {
            XCTAssertEqual(line["thread_id"] as? String, "m-root")
        }
        XCTAssertEqual(after[1]["in_reply_to"] as? String, "m-later", "everything else on the line survives")
        XCTAssertEqual(after[2]["target"] as? String, "main:2.0")
        XCTAssertEqual(uplink.pendingThreadID, "m-root", "lines recorded after the restamp join the new thread")
        XCTAssertTrue(requests.isEmpty, "current-hour lines wait for the post-turn flush")

        await uplink.flush()
        let put = try linesInRequest(try XCTUnwrap(requests.first))
        XCTAssertEqual(put.lines.compactMap { $0["thread_id"] as? String }, ["m-root", "m-root", "m-root"])
        XCTAssertEqual(put.lines.compactMap { $0["id"] as? String }, after.compactMap { $0["id"] as? String })
    }

    func testRestampRePutsLinesThatRolledIntoACompletedHour() async throws {
        var requests: [URLRequest] = []
        let uplink = makeUplink { request in
            requests.append(request)
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
        let anHourAgo = Date().addingTimeInterval(-3600)
        uplink.beginMessageTurn(messageID: "m-later", threadID: "m-later")
        var user = AgentAuditEvent(kind: "userMessage", text: "did it finish?")
        user.timestamp = anHourAgo
        uplink.record(user)
        var send = AgentAuditEvent(kind: "toolCall", text: "send_session: main:2.0 (4 chars)",
                                   toolName: "send_session", target: "main:2.0")
        send.timestamp = anHourAgo
        uplink.record(send)
        let earlyIDs = try uplink.lines.map { try object($0) }.compactMap { $0["id"] as? String }
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "yes")) // rolls the hour
        XCTAssertEqual(uplink.lines.count, 1, "the completed hour left the ring")

        let restamped = await uplink.restampThread(to: "m-root")

        XCTAssertEqual(restamped.count, 3)
        let previousHour = DaemonTranscriptUplink.hourKey(for: anHourAgo)
        let rePuts = try requests.map { try linesInRequest($0) }
            .filter { $0.hour == previousHour && $0.lines.allSatisfy { $0["thread_id"] as? String == "m-root" } }
        XCTAssertEqual(rePuts.count, 1, "the completed hour is PUT again, once, with the corrected thread")
        XCTAssertEqual(rePuts.first?.lines.compactMap { $0["id"] as? String }, earlyIDs, "same ids: the merge replaces, never duplicates")
        XCTAssertEqual(try object(try XCTUnwrap(uplink.lines.first))["thread_id"] as? String, "m-root")
    }

    func testRestampOutsideATurnDoesNothing() async {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "notice", text: "idle"))
        let restamped = await uplink.restampThread(to: "m-root")
        XCTAssertTrue(restamped.isEmpty)
        XCTAssertNil(uplink.pendingThreadID)
    }

    // MARK: - pane map

    func testProposalNamesTheNewestFreshPaneAndItsReason() {
        let now = Date()
        var map = DaemonPaneThreadMap()
        map.record(targets: ["main:1.0"], threadID: "m-old", now: now.addingTimeInterval(-3 * 3600))
        map.record(targets: ["main:2.0"], threadID: "m-new", now: now.addingTimeInterval(-60))

        let proposal = map.proposal(for: ["main:1.0", "main:2.0", "other:0.0"], now: now)
        XCTAssertEqual(proposal?.threadID, "m-new")
        XCTAssertEqual(proposal?.reason, "pane:main:2.0")
        XCTAssertEqual(map.proposal(for: ["main:1.0"], now: now)?.reason, "pane:main:1.0")
        XCTAssertNil(map.proposal(for: ["other:0.0"], now: now), "a pane nobody relayed into roots a new thread")
        XCTAssertNil(map.proposal(for: [], now: now))
        XCTAssertEqual(DaemonPaneThreadMap.rootReason, "root")
    }

    func testAPaneOlderThanTheWindowIsForgotten() {
        let now = Date()
        var map = DaemonPaneThreadMap()
        map.record(targets: ["main:2.0"], threadID: "m-old", now: now.addingTimeInterval(-DaemonPaneThreadMap.window + 1))
        XCTAssertEqual(map.proposal(for: ["main:2.0"], now: now)?.threadID, "m-old", "23 h 59 min 59 s: still the same conversation")
        map.record(targets: ["main:3.0"], threadID: "m-older", now: now.addingTimeInterval(-DaemonPaneThreadMap.window - 1))
        XCTAssertNil(map.proposal(for: ["main:3.0"], now: now), "24 h and a second: a new conversation")
        map.record(targets: ["main:4.0"], threadID: "m-now", now: now)
        XCTAssertNil(map.entries["main:3.0"], "the next recording prunes what the window no longer covers")
        XCTAssertNotNil(map.entries["main:2.0"])
    }

    func testRecordingOverwritesThePanesThreadAndPersists() throws {
        let path = NSTemporaryDirectory() + "pane-threads-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()
        var map = DaemonPaneThreadMap()
        map.record(targets: ["main:2.0"], threadID: "m-first", now: now.addingTimeInterval(-600))
        map.record(targets: ["main:2.0", "main:4.0"], threadID: "m-second", now: now)
        try map.save(to: path)

        let loaded = DaemonPaneThreadMap.load(from: path)
        XCTAssertEqual(loaded.proposal(for: ["main:2.0"], now: now)?.threadID, "m-second")
        XCTAssertEqual(loaded.proposal(for: ["main:4.0"], now: now)?.threadID, "m-second")
        XCTAssertEqual(loaded.entries.count, 2)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"threadId\""), "the file is the wire spelling, readable by hand: \(text)")
        XCTAssertEqual(DaemonPaneThreadMap.load(from: path + ".missing"), DaemonPaneThreadMap(), "a missing file is an empty map")
    }

    func testFreshTargetsAreKeyedByTmuxSession() {
        let now = Date()
        var map = DaemonPaneThreadMap()
        map.record(targets: ["main:2.0", "main:3.1", "claw:0.0"], threadID: "m-x", now: now)
        map.record(targets: ["main:9.0"], threadID: "m-y", now: now.addingTimeInterval(-2 * DaemonPaneThreadMap.window))
        XCTAssertEqual(map.freshTargets(inSession: "main", now: now), ["main:2.0", "main:3.1"])
        XCTAssertEqual(map.freshTargets(inSession: "claw", now: now), ["claw:0.0"])
        XCTAssertEqual(map.freshTargets(inSession: "nope", now: now), [])
    }

    // MARK: - pre-turn signal

    private let registry = RegistryDocument(sessions: [
        SessionRegistration(session: "claw", agent: "claude-code", cwd: "~/forges/levi/africanintellect",
                            tasks: ["grants", "newsletter"], registeredBy: "levi"),
        SessionRegistration(session: "pocketdj", agent: "claude-code", cwd: "~/forges/levi/pocketdj",
                            tasks: ["dj"], registeredBy: "levi"),
    ])

    func testPreTurnTargetNeedsOneNamedLiveSessionWithOneFreshPane() {
        let now = Date()
        var map = DaemonPaneThreadMap()
        map.record(targets: ["claw:2.0"], threadID: "m-root", now: now.addingTimeInterval(-60))

        XCTAssertEqual(Daemon.preTurnPaneTarget(
            request: "tell the claw session to send the PDF", registry: registry,
            liveSessions: ["main", "claw"], paneThreads: map, now: now
        ), "claw:2.0")
        XCTAssertNil(Daemon.preTurnPaneTarget(
            request: "send the grants newsletter", registry: registry,
            liveSessions: ["main", "claw"], paneThreads: map, now: now
        ), "a vocabulary match is a guess, not a name")
        XCTAssertNil(Daemon.preTurnPaneTarget(
            request: "tell the claw session to send the PDF", registry: registry,
            liveSessions: ["main"], paneThreads: map, now: now
        ), "a session that is not live has no pane to match")
        XCTAssertNil(Daemon.preTurnPaneTarget(
            request: "claw and pocketdj: both ship", registry: registry,
            liveSessions: ["claw", "pocketdj"], paneThreads: map, now: now
        ), "two named sessions is ambiguous")
        XCTAssertNil(Daemon.preTurnPaneTarget(
            request: "tell the claw session to send the PDF", registry: nil,
            liveSessions: ["claw"], paneThreads: map, now: now
        ), "no registry, no pre-turn answer")

        map.record(targets: ["claw:3.0"], threadID: "m-other", now: now)
        XCTAssertNil(Daemon.preTurnPaneTarget(
            request: "tell the claw session to send the PDF", registry: registry,
            liveSessions: ["claw"], paneThreads: map, now: now
        ), "two fresh panes in the session: the turn decides")
    }

    func testLiveSessionsComeFromThePaneInventoryFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "pane-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["at": "2026-09-12T10:00:00Z", "lines": [
            "main:2.0 fin — swift test", "claw:0.0 africanintellect — claude", "main:3.1 pocketdj — zsh",
        ]]).write(to: url)
        XCTAssertEqual(Daemon.liveSessions(paneInventoryFileURL: url), ["main", "claw"])
        XCTAssertEqual(Daemon.liveSessions(paneInventoryFileURL: url.appendingPathExtension("missing")), [])
    }

    // MARK: - acks

    func testAppliedAndAnsweredAcksCarryTheProposalAndReturnTheSettledThread() async throws {
        let ledgerPath = NSTemporaryDirectory() + "site-ledger-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: ledgerPath) }
        final class Box: @unchecked Sendable { var acks: [[String: Any]] = [] }
        let box = Box()
        let client = DaemonSiteClient(
            siteID: "A4A1D987-0000-4000-8000-000000000000", displayName: "iMac", token: "site-secret",
            heartbeatSeconds: 20, endpointURL: "https://cp.example", ledgerPath: ledgerPath, audit: { _ in }
        )
        await client.configure(
            runID: "run-1",
            transport: { request in
                let path = request.url!.path
                var body = "{}"
                if path.hasSuffix("/ack") {
                    let object = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
                    await MainActor.run { box.acks.append(object) }
                    body = #"{"messageId":"m-3","state":"ok","threadId":"m-root"}"#
                } else if path.hasSuffix("/claim") {
                    body = #"{"granted":true,"messageId":"m-3","text":"go","threadId":"m-explicit"}"#
                } else {
                    body = #"{"role":"primary","messages":[{"id":"m-3","text":"go","source":"voice"}]}"#
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            },
            state: { "idle" }, capabilities: { [:] }, onCommand: { _ in }
        )
        await client.beat()
        let popped = await client.nextHeldMessage()
        let held = try XCTUnwrap(popped)
        XCTAssertEqual(held.threadID, "m-explicit", "the claim's threadId is kept with the held message")
        XCTAssertTrue(held.hasExplicitThread)
        XCTAssertFalse(DaemonSiteClient.Ledger.HeldMessage(id: "m-9", text: "x", source: "app", threadID: "m-9").hasExplicitThread)
        XCTAssertFalse(DaemonSiteClient.Ledger.HeldMessage(id: "m-9", text: "x", source: "app").hasExplicitThread)

        let applied = await client.markApplied("m-3", runID: "run-1", thread: .init(threadID: "m-root", reason: "pane:main:2.0"))
        XCTAssertEqual(applied, "m-root")
        let answered = await client.markAnswered("m-3", replyPreview: "done", thread: .init(threadID: "m-root", reason: "pane:main:2.0"))
        XCTAssertEqual(answered, "m-root")
        let plain = await client.markAnswered("m-3", replyPreview: "done")

        XCTAssertEqual(plain, "m-root")
        XCTAssertEqual(box.acks.count, 3)
        XCTAssertEqual(box.acks[0]["threadId"] as? String, "m-root")
        XCTAssertEqual(box.acks[0]["threadReason"] as? String, "pane:main:2.0")
        XCTAssertEqual(box.acks[1]["state"] as? String, "answered")
        XCTAssertEqual(box.acks[1]["threadId"] as? String, "m-root")
        XCTAssertEqual(box.acks[1]["threadReason"] as? String, "pane:main:2.0")
        XCTAssertNil(box.acks[2]["threadId"], "no proposal, no keys")
        XCTAssertNil(box.acks[2]["threadReason"])
    }

    func testAnsweredAckBodyWithAProposal() {
        let body = DaemonSiteClient.answeredAckBody(
            replyPreview: "done", agentID: nil, originDeviceID8: "", thread: .init(threadID: "m-root", reason: "pane:main:2.0")
        )
        XCTAssertEqual(Set(body.keys), ["state", "replyPreview", "threadId", "threadReason"])
        XCTAssertEqual(DaemonSiteClient.threadID(inResponse: Data(#"{"threadId":""}"#.utf8)), nil)
        XCTAssertEqual(DaemonSiteClient.threadID(inResponse: Data("not json".utf8)), nil)
    }

    // MARK: - notify

    func testNotifyBodiesCarryTheThread() async throws {
        var bodies: [[String: Any]] = []
        let client = DaemonNotifyClient(endpointURL: "https://cp.example", token: "t", agentName: "Fin") { request in
            bodies.append((try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:])
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
        await client.send(event: "request-input", message: "which branch?", messageID: "m-1", threadID: "m-root")
        await client.send(event: "task-complete", message: "shipped", messageID: "m-1", threadID: "m-root")
        await client.send(event: "agent-stalled", message: "5 failures", messageID: "m-1", threadID: "m-root")
        await client.sendDirect(title: "PDF sent", body: "the claw session finished", threadID: "m-root")
        await client.send(event: "task-complete", message: "no message in flight")

        XCTAssertEqual(bodies.count, 5)
        for body in bodies.prefix(4) {
            XCTAssertEqual(body["threadId"] as? String, "m-root", "\(body["event"] ?? "")")
        }
        XCTAssertEqual(bodies[3]["event"] as? String, "notify")
        XCTAssertNil(bodies[3]["messageId"])
        XCTAssertNil(bodies[4]["threadId"], "no thread, no key")
        let data = try XCTUnwrap(DaemonNotifyClient.requestBody(title: "t", body: "b", agentName: "Fin", threadID: ""))
        XCTAssertNil(try object(String(decoding: data, as: UTF8.self))["threadId"], "an empty thread is not sent")
    }

    // MARK: - follow-up goals

    func testFollowUpGoalCarriesTheThreadAndMessageOnTheWire() throws {
        let goal = GoalsTick.followUpGoal(
            request: "tell the claw session to send the PDF", target: "main:2.0", source: "voice",
            messageID: "m-9db0e9b4-db1a", threadID: "m-root"
        )
        XCTAssertEqual(goal.id, "g-followup-9db0e9b4", "the id is unchanged")
        XCTAssertEqual(goal.threadID, "m-root")
        XCTAssertEqual(goal.messageID, "m-9db0e9b4-db1a")
        let encoded = try object(String(decoding: try JSONEncoder().encode(goal), as: UTF8.self))
        XCTAssertEqual(encoded["thread_id"] as? String, "m-root", "the key the Lambda's _followup_goal_thread reads")
        XCTAssertEqual(encoded["message_id"] as? String, "m-9db0e9b4-db1a")
        let decoded = try JSONDecoder().decode(Goal.self, from: try JSONEncoder().encode(goal))
        XCTAssertEqual(decoded, goal)

        let bare = GoalsTick.followUpGoal(request: "x", target: "main:2.0", source: nil, messageID: "m-1")
        let bareEncoded = try object(String(decoding: try JSONEncoder().encode(bare), as: UTF8.self))
        XCTAssertNil(bareEncoded["thread_id"], "no thread, no key — an older ledger reads unchanged")
        let legacy = try JSONDecoder().decode(Goal.self, from: Data(#"{"id":"g-1","title":"t"}"#.utf8))
        XCTAssertNil(legacy.threadID)
    }
}

import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/notify` wire contract and the client's failure discipline. The Lambda side of
/// the contract lives in scripts/cloud-agent/control-plane/lambda.py (`notify`); the
/// body keys asserted here — `title`, `body`, `agent` required, `agentID`/
/// `originDeviceID8` when the daemon has them — are what it validates, so a
/// drift on either side fails loudly in exactly one place.
@MainActor
final class DaemonNotifyClientTests: XCTestCase {

    private func makeClient(
        endpointURL: String = "https://cp.example",
        agentName: String = "Nimbus",
        agentID: UUID? = nil,
        originDeviceID8: String = "",
        audit: @escaping (String) -> Void = { _ in },
        post: @escaping (URLRequest) async throws -> URLResponse = { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    ) -> DaemonNotifyClient {
        DaemonNotifyClient(
            endpointURL: endpointURL,
            token: "cp-token-123",
            agentName: agentName,
            agentID: agentID,
            originDeviceID8: originDeviceID8,
            audit: audit,
            post: post
        )
    }

    // MARK: - Wire shape

    func testSendPostsTheNotifyContract() async throws {
        var captured: URLRequest?
        let client = makeClient(endpointURL: "https://cp.example///") { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "request-input", message: "Which branch should I deploy?")

        let request = try XCTUnwrap(captured)
        // Trailing slashes trimmed, path appended — same URL join as every sibling client.
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/notify")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Nimbus needs input")
        XCTAssertEqual(object["body"] as? String, "Which branch should I deploy?")
        XCTAssertEqual(object["agent"] as? String, "Nimbus")
        XCTAssertEqual(object["event"] as? String, "request-input")
        XCTAssertNil(object["messageId"], "a request-input push is not the message's one reply push")
        XCTAssertEqual(object.count, 4, "the contract has exactly four keys: title, body, agent, event")
    }

    /// A task-complete push for a claimed message names it, so the Lambda can
    /// dedupe it against the answered ack's own push (one push per message).
    func testTaskCompleteForAClaimedMessageCarriesTheMessageID() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "task-complete", message: "TASK COMPLETE", messageID: "m-4f0c")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "task-complete")
        XCTAssertEqual(object["messageId"] as? String, "m-4f0c")
        XCTAssertEqual(object.count, 5, "title, body, agent, event, messageId")
    }

    /// The model's notify tool is a plain "notify" event on the wire: no
    /// messageId (it is never the message's reply push) and never time-sensitive.
    func testSendDirectIsANotifyEvent() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.sendDirect(title: "Deploy done", body: "main is live on prod.")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "notify")
        XCTAssertNil(object["messageId"])
    }

    /// An unpaired daemon (no agentID) omits both new keys rather than sending
    /// them null — a push still lands, it just can't deep-link a tap. Same
    /// three-key shape as `testSendPostsTheNotifyContract`, pinned separately
    /// here so a regression on either optional field fails in the right test.
    func testSendOmitsAgentIDAndOriginDeviceID8WhenUnpaired() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "task-complete", message: "done")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertNil(object["agentID"])
        XCTAssertNil(object["originDeviceID8"])
        XCTAssertEqual(object.count, 4)
    }

    /// A daemon paired to an Agent record (the normal case) includes both —
    /// this is what lets the Lambda (`lambda.py`'s `notify`) build the "fin"
    /// payload a tap deep-links from (see `AgentNotificationService`).
    func testSendIncludesAgentIDAndOriginDeviceID8WhenPaired() async throws {
        let agentID = UUID()
        var captured: URLRequest?
        let client = makeClient(agentID: agentID, originDeviceID8: "a4a1d987") { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.sendDirect(title: "Deploy done", body: "main is live on prod.")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["agentID"] as? String, agentID.uuidString)
        XCTAssertEqual(object["originDeviceID8"] as? String, "a4a1d987")
        XCTAssertEqual(object.count, 6, "title, body, agent, event, agentID, originDeviceID8")
    }

    /// The model's `notify` tool authors its own title, so `sendDirect` must push that
    /// headline verbatim — NOT the event→title table `send(event:)` uses — while keeping
    /// the same three-key contract.
    func testSendDirectPostsModelAuthoredTitleVerbatim() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.sendDirect(title: "Deploy done", body: "main is live on prod.")

        let request = try XCTUnwrap(captured)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Deploy done")
        XCTAssertEqual(object["body"] as? String, "main is live on prod.")
        XCTAssertEqual(object["agent"] as? String, "Nimbus")
        XCTAssertEqual(object.count, 4, "the contract still has exactly four keys: title, body, agent, event")
    }

    /// An empty headline falls back to the agent name, so a lock screen always shows
    /// something recognizable.
    func testSendDirectFallsBackToAgentNameForEmptyTitle() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.sendDirect(title: "   ", body: "quiet update")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Nimbus")
    }

    /// A model-authored title leaves the machine too, so it passes through the redactor
    /// exactly as the body does.
    func testSendDirectRedactsTheTitle() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.sendDirect(title: "token api_key=sk-verysecretvalue", body: "done")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        let title = try XCTUnwrap(object["title"] as? String)
        XCTAssertFalse(title.contains("sk-verysecretvalue"))
        XCTAssertTrue(title.contains("[redacted]"))
    }

    /// `send`/`sendDirect` must report the REAL outcome, not just "handed off" — this is
    /// what lets a caller (the `notify` tool's bounded await) tell the model the truth.
    func testSendReturnsTrueOnConfirmedDelivery() async {
        let client = makeClient { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
        let delivered = await client.send(event: "task-complete", message: "done")
        XCTAssertTrue(delivered)
    }

    func testSendReturnsFalseOnHTTPFailure() async {
        let client = makeClient { request in
            HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        }
        let delivered = await client.send(event: "task-complete", message: "done")
        XCTAssertFalse(delivered)
    }

    func testSendDirectReturnsFalseOnTransportError() async {
        struct Unreachable: Error {}
        let client = makeClient { _ in throw Unreachable() }
        let delivered = await client.sendDirect(title: "hi", body: "there")
        XCTAssertFalse(delivered)
    }

    func testTitlesPerEvent() {
        XCTAssertEqual(
            DaemonNotifyClient.title(event: "request-input", agentName: "Nimbus"),
            "Nimbus needs input"
        )
        XCTAssertEqual(
            DaemonNotifyClient.title(event: "task-complete", agentName: "Nimbus"),
            "Nimbus: task complete"
        )
        XCTAssertEqual(
            DaemonNotifyClient.title(event: "agent-stalled", agentName: "Nimbus"),
            "Nimbus is stuck"
        )
        XCTAssertEqual(
            DaemonNotifyClient.title(event: "someday-a-new-event", agentName: "Nimbus"),
            "Nimbus"
        )
    }

    // MARK: - The message leaves the machine

    func testAlertBodyIsRedacted() {
        let body = DaemonNotifyClient.alertBody("done; the api_key=sk-verysecretvalue was used")
        XCTAssertFalse(body.contains("sk-verysecretvalue"))
        XCTAssertTrue(body.contains("[redacted]"))
    }

    func testAlertBodyIsCappedWithEllipsis() {
        // Spaced words, not one long run: a 2000-char unbroken string would trip the
        // redactor's long-base64 mask and test the wrong thing.
        let body = DaemonNotifyClient.alertBody(String(repeating: "all clear. ", count: 200))
        XCTAssertEqual(body.count, DaemonNotifyClient.maxMessageLength + 1)
        XCTAssertTrue(body.hasSuffix("…"))
    }

    func testAlertBodyShortMessagePassesThrough() {
        XCTAssertEqual(DaemonNotifyClient.alertBody("  build finished  "), "build finished")
    }

    // MARK: - Failure discipline

    func testHTTPFailureAuditsWithoutTokenOrEndpoint() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) }) { request in
            HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "task-complete", message: "TASK COMPLETE")

        XCTAssertEqual(lines, ["[notify] post failed: HTTP 503"])
        XCTAssertFalse(lines[0].contains("cp-token-123"))
        XCTAssertFalse(lines[0].contains("cp.example"))
    }

    func testRepeatedFailureAuditsOncePerWindow() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) }) { request in
            HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "request-input", message: "one")
        await client.send(event: "request-input", message: "two")

        XCTAssertEqual(lines.count, 1, "same error inside the window audits once")
    }

    func testTransportErrorIsSwallowedAfterAudit() async {
        struct Unreachable: Error {}
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) }) { _ in throw Unreachable() }

        await client.send(event: "request-input", message: "hello")

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("[notify] post failed: "))
    }

    func testInvalidEndpointAuditsAndNeverPosts() async {
        var posted = false
        var lines: [String] = []
        let client = makeClient(endpointURL: "   ", audit: { lines.append($0) }) { request in
            posted = true
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }

        await client.send(event: "request-input", message: "hello")

        XCTAssertFalse(posted)
        XCTAssertEqual(lines, ["[notify] control plane URL is not a valid URL"])
    }

    // MARK: - Config plumbing

    func testControlPlaneBlockDecodes() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "t",
          "controlPlane": {
            "endpointURL": "https://api.example",
            "token": "secret"
          }
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.controlPlane?.endpointURL, "https://api.example")
        XCTAssertEqual(config.controlPlane?.token, "secret")
    }

    func testAbsentControlPlaneBlockDecodesAsNil() throws {
        let json = """
        {
          "server": {"host": "h", "username": "u", "privateKeyPath": "/k"},
          "agent": {"endpointURL": "http://localhost:1234/v1", "modelIdentifier": "m"},
          "task": "t"
        }
        """
        let config = try JSONDecoder().decode(DaemonConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.controlPlane, "no block, no client — the daemon stays silent")
    }
}

/// `firstToFinish` is the bounded-wait race `notifyFromTool` uses so the `notify` tool
/// call awaits a real outcome without blocking indefinitely — covered directly since
/// `Daemon` itself (SSH session, supervision, …) is too heavy to stage just for this.
final class NotifyRaceTests: XCTestCase {

    func testReturnsTheResultWhenTheTaskFinishesFirst() async {
        let task = Task<Bool, Never> { true }
        let result = await firstToFinish(task, timeoutSeconds: 5)
        XCTAssertEqual(result, true)
    }

    func testReturnsFalseWhenTheTaskFinishesFirstWithFailure() async {
        let task = Task<Bool, Never> { false }
        let result = await firstToFinish(task, timeoutSeconds: 5)
        XCTAssertEqual(result, false)
    }

    /// The whole point: a task slower than the deadline must not hold up the caller for
    /// its own full duration — the race returns nil at (about) the deadline, not later.
    func testReturnsNilAtTheDeadlineWithoutWaitingForTheSlowTask() async {
        let task = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(5))
            return true
        }
        let startedAt = Date()
        let result = await firstToFinish(task, timeoutSeconds: 0.1)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0, "must return near the deadline, not wait out the slow task")
        task.cancel()
    }
}

/// `notifyOutcome` is `notifyFromTool`'s decision table pulled out as a pure function —
/// same rationale as `NotifyRaceTests` above: `Daemon` is too heavy to stage just to
/// drive one `private` method. This is the regression cover for the bug where a
/// CONFIRMED control-plane failure got silently overridden into `.delivered` by the
/// shell hook's mere (unconfirmed) launch, and for `.unavailable` being reported for a
/// channel that was actually configured and attempted, just unsuccessfully.
final class NotifyOutcomeDecisionTests: XCTestCase {

    // MARK: - Client-only / dual-channel: the client's confirmed result always wins

    func testConfirmedDeliveryIsDelivered() {
        XCTAssertEqual(
            notifyOutcome(commandLaunched: false, hasClient: true, confirmed: true),
            .delivered
        )
    }

    func testConfirmedDeliveryIsDeliveredEvenWithNoCommandHook() {
        // A client-only configuration (no notifyCommand at all) must still report a
        // confirmed success as delivered.
        XCTAssertEqual(
            notifyOutcome(commandLaunched: false, hasClient: true, confirmed: true),
            .delivered
        )
    }

    func testConfirmedFailureIsFailedRegardlessOfCommandLaunch() {
        // THE regression: a confirmed-false client result must never be promoted to
        // `.delivered` just because the unrelated, unconfirmable shell hook launched.
        XCTAssertEqual(
            notifyOutcome(commandLaunched: true, hasClient: true, confirmed: false),
            .failed
        )
    }

    func testConfirmedFailureWithNoCommandHookIsAlsoFailed() {
        XCTAssertEqual(
            notifyOutcome(commandLaunched: false, hasClient: true, confirmed: false),
            .failed
        )
    }

    func testUnconfirmedWithinTheBoundIsQueuedRegardlessOfCommandLaunch() {
        XCTAssertEqual(
            notifyOutcome(commandLaunched: true, hasClient: true, confirmed: nil),
            .queued
        )
        XCTAssertEqual(
            notifyOutcome(commandLaunched: false, hasClient: true, confirmed: nil),
            .queued
        )
    }

    // MARK: - Shell-hook-only (no control-plane client configured)

    func testCommandLaunchWithNoClientIsQueuedNotDelivered() {
        // A launch is not a confirmation: `AgentNotifyOutcome.delivered` means the
        // channel CONFIRMED the push went out, and a fire-and-forget shell hook can
        // never confirm that (see `runNotifyCommand`'s own doc comment). `.queued` is
        // the honest answer — handed off, unconfirmed — matching the client-side
        // unconfirmed case above rather than overclaiming success.
        XCTAssertEqual(
            notifyOutcome(commandLaunched: true, hasClient: false, confirmed: nil),
            .queued
        )
    }

    func testCommandLaunchFailureWithNoClientIsFailedNotUnavailable() {
        // A configured-but-failed-to-launch shell hook is a real failure of a channel
        // that DOES exist — must never read as "no channel configured" (`.unavailable`
        // is reserved for `hasNotifyChannel == false`, decided before this function is
        // ever called).
        XCTAssertEqual(
            notifyOutcome(commandLaunched: false, hasClient: false, confirmed: nil),
            .failed
        )
    }
}

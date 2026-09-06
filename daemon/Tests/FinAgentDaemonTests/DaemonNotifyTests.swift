import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/notify` wire contract and the client's failure discipline. The Lambda side of
/// the contract lives in scripts/cloud-agent/control-plane/lambda.py (`notify`); the
/// body keys asserted here — `title`, `body`, `agent` — are what it validates, so a
/// drift on either side fails loudly in exactly one place.
@MainActor
final class DaemonNotifyClientTests: XCTestCase {

    private func makeClient(
        endpointURL: String = "https://cp.example",
        agentName: String = "Nimbus",
        audit: @escaping (String) -> Void = { _ in },
        post: @escaping (URLRequest) async throws -> URLResponse = { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    ) -> DaemonNotifyClient {
        DaemonNotifyClient(
            endpointURL: endpointURL,
            token: "cp-token-123",
            agentName: agentName,
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
        XCTAssertEqual(object.count, 3, "the contract has exactly three keys")
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
        XCTAssertEqual(object.count, 3, "the contract still has exactly three keys")
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

import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/artifacts` wire contract. The Lambda side lives in
/// scripts/cloud-agent/control-plane/lambda.py (`put_artifact`/`get_artifact`/
/// `list_artifacts`/`delete_artifact`); the URLs/methods/bodies asserted here are what
/// it expects and returns, so a drift on either side fails loudly in exactly one place.
@MainActor
final class DaemonArtifactClientTests: XCTestCase {

    private func makeClient(
        endpointURL: String = "https://cp.example",
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ) -> DaemonArtifactClient {
        DaemonArtifactClient(endpointURL: endpointURL, token: "cp-token-123", audit: audit, transport: transport)
    }

    // MARK: - write

    func testWritePutsTheArtifactContract() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(#"{"path":"notes/todo.txt","size":11}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let outcome = await client.write(path: "notes/todo.txt", content: "buy some milk")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/artifacts/notes/todo.txt")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["content"] as? String, "buy some milk")
        XCTAssertEqual(outcome, .saved(size: 11))
    }

    func testWriteReturnsFailedOnHTTPFailure() async {
        let client = makeClient { request in
            (Data(#"{"error":"path must match ..."}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.write(path: "bad path!!", content: "x")
        guard case .failed(let reason) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(reason, "path must match ...")
    }

    func testWriteReturnsFailedOnTransportError() async {
        struct Boom: Error {}
        let client = makeClient { _ in throw Boom() }
        let outcome = await client.write(path: "a.txt", content: "x")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - read

    func testReadGetsTheArtifact() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(#"{"path":"notes/todo.txt","content":"buy some milk"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.read(path: "notes/todo.txt")
        XCTAssertEqual(captured?.url?.absoluteString, "https://cp.example/artifacts/notes/todo.txt")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(outcome, .found(content: "buy some milk"))
    }

    func testReadReturnsNotFoundOn404() async {
        let client = makeClient { request in
            (Data(#"{"error":"no artifact at x"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.read(path: "missing.txt")
        XCTAssertEqual(outcome, .notFound)
    }

    func testReadReturnsFailedOnOtherHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.read(path: "a.txt")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - list

    func testListGetsEveryEntry() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(#"{"artifacts":[{"path":"a.txt","size":3},{"path":"notes/b.txt","size":7}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.list()
        XCTAssertEqual(captured?.url?.absoluteString, "https://cp.example/artifacts")
        XCTAssertEqual(captured?.httpMethod, "GET")
        guard case .found(let entries) = outcome else { return XCTFail("expected .found, got \(outcome)") }
        XCTAssertEqual(entries, [
            AgentArtifactEntry(path: "a.txt", size: 3),
            AgentArtifactEntry(path: "notes/b.txt", size: 7),
        ])
    }

    func testListReturnsFailedOnHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.list()
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - delete

    func testDeleteHitsTheArtifactPath() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(#"{"path":"notes/todo.txt","deleted":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.delete(path: "notes/todo.txt")
        XCTAssertEqual(captured?.url?.absoluteString, "https://cp.example/artifacts/notes/todo.txt")
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(outcome, .deleted)
    }

    func testDeleteReturnsFailedOnHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.delete(path: "a.txt")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - path escaping

    func testPathSegmentsArePercentEncodedIndividually() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = await client.read(path: "notes/a b.txt")
        XCTAssertEqual(captured?.url?.absoluteString, "https://cp.example/artifacts/notes/a%20b.txt")
    }

    // MARK: - failure audit throttling

    func testFailureAuditsOncePerWindow() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) }) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        _ = await client.write(path: "a.txt", content: "1")
        _ = await client.write(path: "a.txt", content: "2")
        XCTAssertEqual(lines, ["[artifacts] write failed: HTTP 503"])
    }
}

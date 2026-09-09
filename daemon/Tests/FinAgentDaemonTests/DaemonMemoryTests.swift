import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/memory` wire contract and `DaemonMemoryClient`'s search logic. The Lambda side
/// of the contract lives in scripts/cloud-agent/control-plane/lambda.py (`put_memory_entry`/
/// `get_memory`); the body/response keys asserted here are what it validates and returns,
/// so a drift on either side fails loudly in exactly one place.
@MainActor
final class DaemonMemoryClientTests: XCTestCase {

    private let agentID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private func makeClient(
        endpointURL: String = "https://cp.example",
        agentName: String = "Nimbus",
        agentID: UUID? = nil,
        originDeviceID8: String = "a4a1d987",
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ) -> DaemonMemoryClient {
        DaemonMemoryClient(
            endpointURL: endpointURL,
            token: "cp-token-123",
            agentName: agentName,
            agentID: agentID ?? self.agentID,
            originDeviceID8: originDeviceID8,
            audit: audit,
            transport: transport
        )
    }

    // MARK: - remember wire shape

    func testRememberPostsTheMemoryContract() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let outcome = await client.remember(title: "Deploy target", content: "prod-east", tags: "infra,deploy")

        XCTAssertEqual(outcome, .saved)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/memory")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["agent"] as? String, "Nimbus")
        XCTAssertEqual(object["kind"] as? String, "episodic")
        XCTAssertEqual(object["title"] as? String, "Deploy target")
        XCTAssertEqual(object["content"] as? String, "prod-east")
        XCTAssertEqual(object["tags"] as? String, "infra,deploy")
        XCTAssertEqual(object["agentId"] as? String, agentID.uuidString)
        XCTAssertEqual(object["originDevice8"] as? String, "a4a1d987")
        XCTAssertNotNil(object["id"] as? String)
        XCTAssertNotNil(object["createdAt"] as? String)
        XCTAssertNotNil(object["updatedAt"] as? String)
    }

    func testRememberOmitsTagsWhenNilOrEmpty() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = await client.remember(title: "t", content: "c", tags: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any]
        )
        XCTAssertNil(object["tags"])
    }

    func testRememberReturnsFailedOnHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.remember(title: "t", content: "c", tags: nil)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testRememberReturnsFailedOnTransportError() async {
        struct Boom: Error {}
        let client = makeClient { _ in throw Boom() }
        let outcome = await client.remember(title: "t", content: "c", tags: nil)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testRememberAuditsHTTPFailureOncePerWindow() async {
        var lines: [String] = []
        let client = makeClient(audit: { lines.append($0) }) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        _ = await client.remember(title: "one", content: "c", tags: nil)
        _ = await client.remember(title: "two", content: "c", tags: nil)
        XCTAssertEqual(lines, ["[memory] remember failed: HTTP 503"])
    }

    // MARK: - recall wire shape

    func testRecallGetsTheAgentsWholeDocument() async throws {
        var captured: URLRequest?
        let document = #"{"entries":[{"id":"m-1","title":"Deploy target","content":"prod-east","tags":"","updatedAt":"2026-09-08T20:00:00Z"}]}"#
        let client = makeClient { request in
            captured = request
            return (Data(document.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let outcome = await client.recall(query: "")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/memory?agent=Nimbus")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")

        guard case .found(let hits) = outcome else { return XCTFail("expected .found, got \(outcome)") }
        XCTAssertEqual(hits, [AgentRecallHit(title: "Deploy target", content: "prod-east")])
    }

    func testRecallReturnsFailedOnHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.recall(query: "")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testRecallReturnsFailedOnTransportError() async {
        struct Boom: Error {}
        let client = makeClient { _ in throw Boom() }
        let outcome = await client.recall(query: "")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - search (pure)

    private func document(_ entries: [(id: String, title: String, content: String, tags: String, updatedAt: String)]) -> Data {
        let object: [String: Any] = [
            "entries": entries.map {
                ["id": $0.id, "title": $0.title, "content": $0.content, "tags": $0.tags, "updatedAt": $0.updatedAt]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testSearchWithEmptyQueryReturnsMostRecentFirst() {
        let data = document([
            (id: "m-1", title: "Old", content: "old fact", tags: "", updatedAt: "2026-09-08T10:00:00Z"),
            (id: "m-2", title: "New", content: "new fact", tags: "", updatedAt: "2026-09-08T20:00:00Z"),
        ])
        let hits = DaemonMemoryClient.search(document: data, query: "")
        XCTAssertEqual(hits.map(\.title), ["New", "Old"])
    }

    func testSearchFiltersCaseInsensitivelyAcrossTitleContentAndTags() {
        let data = document([
            (id: "m-1", title: "Deploy target", content: "prod-east", tags: "infra", updatedAt: "2026-09-08T10:00:00Z"),
            (id: "m-2", title: "Lunch order", content: "burrito", tags: "", updatedAt: "2026-09-08T11:00:00Z"),
            (id: "m-3", title: "Note", content: "ask about DEPLOY window", tags: "", updatedAt: "2026-09-08T12:00:00Z"),
            (id: "m-4", title: "Tagged", content: "irrelevant", tags: "deploy-related", updatedAt: "2026-09-08T13:00:00Z"),
        ])
        let hits = DaemonMemoryClient.search(document: data, query: "deploy")
        XCTAssertEqual(Set(hits.map(\.title)), ["Deploy target", "Note", "Tagged"])
    }

    func testSearchCapsAtRecallLimit() {
        let entries = (1...10).map {
            (id: "m-\($0)", title: "t\($0)", content: "c", tags: "",
             updatedAt: String(format: "2026-09-08T%02d:00:00Z", $0))
        }
        let hits = DaemonMemoryClient.search(document: document(entries), query: "")
        XCTAssertEqual(hits.count, DaemonMemoryClient.recallLimit)
        XCTAssertEqual(hits.first?.title, "t10", "most recent first")
    }

    func testSearchToleratesAMalformedDocument() {
        XCTAssertEqual(DaemonMemoryClient.search(document: Data("not json".utf8), query: ""), [])
        XCTAssertEqual(DaemonMemoryClient.search(document: Data("{}".utf8), query: ""), [])
    }
}

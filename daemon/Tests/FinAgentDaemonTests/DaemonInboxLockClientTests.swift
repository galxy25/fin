import XCTest
@testable import FinAgentDaemon
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/inbox/{agent}/lock` wire contract — the write half of cross-site inbox
/// cooperation. Mirrors `DaemonMemoryClientTests`' profile-lock coverage exactly; the
/// Lambda side of the contract lives in scripts/cloud-agent/control-plane/lambda.py
/// (`claim_inbox_lock`/`release_inbox_lock`, sharing `_claim_lock`/`_release_lock` with
/// the memory-profile lock), so a drift on either side fails loudly in exactly one place.
@MainActor
final class DaemonInboxLockClientTests: XCTestCase {

    private func makeClient(
        endpointURL: String = "https://cp.example",
        agentName: String = "Fin",
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ) -> DaemonInboxLockClient {
        DaemonInboxLockClient(
            endpointURL: endpointURL, token: "cp-token-123", agentName: agentName,
            audit: audit, transport: transport
        )
    }

    func testClaimPutsToThePerAgentLockPathWithTheHolderContract() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(#"{"holder":"a4a1d987","claimedAt":"2026-09-09T04:00:00Z"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.claim(holder: "a4a1d987")
        XCTAssertEqual(outcome, .claimed)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/inbox/Fin/lock")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(object["holder"] as? String, "a4a1d987")
    }

    func testAgentNameIsPathEncoded() async throws {
        var captured: URLRequest?
        let client = makeClient(agentName: "My Agent") { request in
            captured = request
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = await client.claim(holder: "x")
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/inbox/My%20Agent/lock")
    }

    func testClaimReturnsLockedWithHolderOn409() async {
        let client = makeClient { request in
            (Data(#"{"error":"locked by cloud-worker-9f"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.claim(holder: "me")
        XCTAssertEqual(outcome, .locked(holder: "locked by cloud-worker-9f"))
    }

    func testClaimReturnsFailedOnOtherHTTPFailure() async {
        let client = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await client.claim(holder: "me")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testClaimReturnsFailedWhenEndpointURLIsEmpty() async {
        let client = makeClient(endpointURL: "")
        let outcome = await client.claim(holder: "me")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testClaimReturnsFailedOnTransportError() async {
        struct Boom: Error {}
        let client = makeClient { _ in throw Boom() }
        let outcome = await client.claim(holder: "me")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testReleaseHitsTheLockPathWithDelete() async throws {
        var captured: URLRequest?
        let client = makeClient { request in
            captured = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await client.release()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/inbox/Fin/lock")
        XCTAssertEqual(request.httpMethod, "DELETE")
    }

    func testReleaseIsANoOpWhenEndpointURLIsEmpty() async {
        var called = false
        let client = makeClient(endpointURL: "", transport: { request in
            called = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await client.release()
        XCTAssertFalse(called)
    }
}

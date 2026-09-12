import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// The site client's wire shape and its ledger discipline (docs/SITES.md §6.3),
/// driven through an injected transport — no network, no tmux.
final class DaemonSiteClientTests: XCTestCase {
    private var ledgerPath: String!

    override func setUp() {
        super.setUp()
        ledgerPath = NSTemporaryDirectory() + "site-ledger-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: ledgerPath)
        super.tearDown()
    }

    /// A scripted server. `handler` runs on the main actor so tests can mutate
    /// captured arrays without Sendable ceremony.
    private func makeClient(
        state: String = "idle",
        onCommand: @escaping @MainActor (DaemonSiteClient.Command) -> Void = { _ in },
        _ handler: @escaping @MainActor (URLRequest) -> (Int, String)
    ) async -> DaemonSiteClient {
        let client = DaemonSiteClient(
            siteID: "A4A1D987-0000-4000-8000-000000000000", displayName: "Levi's iMac", token: "site-secret",
            heartbeatSeconds: 20, endpointURL: "https://cp.example/", ledgerPath: ledgerPath,
            audit: { _ in }
        )
        await client.configure(
            runID: "run-1",
            transport: { request in
                let (status, body) = await MainActor.run { handler(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            },
            state: { state },
            capabilities: { ["daemon_version": "test"] },
            onCommand: { command in await MainActor.run { onCommand(command) } }
        )
        return client
    }

    @MainActor private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    func testDecodeHeartbeatIsTolerantOfMissingFields() {
        let response = DaemonSiteClient.decodeHeartbeat(Data(#"{"role":"primary","messages":[{"id":"m-1","text":"hi"}],"commands":[{"id":"c-1","kind":"restart"}],"extra":1}"#.utf8))
        XCTAssertEqual(response.role, "primary")
        XCTAssertEqual(response.messages, [.init(id: "m-1", text: "hi", source: "app")])
        XCTAssertEqual(response.commands, [.init(id: "c-1", kind: "restart")])
        XCTAssertEqual(DaemonSiteClient.decodeHeartbeat(Data("not json".utf8)).messages, [])
    }

    @MainActor
    func testABeatSendsTheSiteHeaderAndTheSiteToken() async {
        let seen = Box<URLRequest?>(nil)
        let client = await makeClient(state: "working") { request in
            seen.value = request
            return (200, #"{"role":"standby","messages":[],"commands":[]}"#)
        }
        await client.beat()
        let request = seen.value
        XCTAssertEqual(request?.url?.path, "/sites/a4a1d987-0000-4000-8000-000000000000/heartbeat")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Fin-Site"), "a4a1d987-0000-4000-8000-000000000000")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "authorization"), "Bearer site-secret")
        let body = try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["state"] as? String, "working")
        XCTAssertEqual(body?["wantsPrimary"] as? Bool, true)
        XCTAssertEqual(body?["runId"] as? String, "run-1")
        XCTAssertEqual(client.siteID8, "a4a1d987")
    }

    @MainActor
    func testAnOfferIsClaimedAndHeldThenPoppedIntoUnacked() async {
        let claims = Box<[String]>([])
        let client = await makeClient { request in
            if request.url!.path.hasSuffix("/claim") {
                claims.value.append(request.url!.path)
                return (200, #"{"granted":true}"#)
            }
            return (200, #"{"role":"primary","messages":[{"id":"m-1","text":"deploy it","source":"voice"}]}"#)
        }
        await client.beat()
        XCTAssertEqual(claims.value, ["/messages/m-1/claim"])
        let v1 = await client.ledger.held.map(\.id)
        XCTAssertEqual(v1, ["m-1"])

        // A second beat re-offering the same id (lease still ours) must not re-claim.
        await client.beat()
        XCTAssertEqual(claims.value.count, 1)

        let popped = await client.nextHeldMessage()
        XCTAssertEqual(popped?.text, "deploy it")
        XCTAssertEqual(popped?.source, "voice")
        let v2 = await client.ledger.held
        XCTAssertEqual(v2, [])
        let v3 = await client.ledger.unacked
        XCTAssertEqual(v3, ["m-1"])
        // Persisted: a restart resumes from here.
        XCTAssertEqual(DaemonSiteClient.loadLedger(from: ledgerPath).unacked, ["m-1"])
    }

    @MainActor
    func testALostClaimIsForgotten() async {
        let client = await makeClient { request in
            if request.url!.path.hasSuffix("/claim") { return (409, #"{"granted":false}"#) }
            return (200, #"{"role":"standby","messages":[{"id":"m-2","text":"x"}]}"#)
        }
        await client.beat()
        let v4 = await client.ledger.held
        XCTAssertEqual(v4, [])
    }

    @MainActor
    func testAppliedAckClearsUnackedAndAnsweredCarriesARedactedPreview() async {
        let acks = Box<[[String: Any]]>([])
        let client = await makeClient { request in
            if request.url!.path.hasSuffix("/ack") {
                acks.value.append((try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:])
                return (200, "{}")
            }
            if request.url!.path.hasSuffix("/claim") { return (200, "{}") }
            return (200, #"{"role":"primary","messages":[{"id":"m-3","text":"go"}]}"#)
        }
        await client.beat()
        _ = await client.nextHeldMessage()
        await client.markApplied("m-3", runID: "run-9")
        let v5 = await client.ledger.unacked
        XCTAssertEqual(v5, [])
        await client.markAnswered("m-3", replyPreview: "done, api_key=ZmFrZS1zZWNyZXQtdmFsdWUtZm9yLXRlc3Rpbmc0MjQy")
        XCTAssertEqual(acks.value.count, 2)
        XCTAssertEqual(acks.value[0]["state"] as? String, "applied")
        XCTAssertEqual(acks.value[0]["runId"] as? String, "run-9")
        XCTAssertEqual(acks.value[1]["state"] as? String, "answered")
        XCTAssertFalse((acks.value[1]["replyPreview"] as? String ?? "").contains("ZmFrZS1zZWNyZXQ"), "the preview leaves the machine — redact it")
    }

    @MainActor
    func testUnackedIdsRideTheNextBeatThenClear() async {
        try? Data(#"{"held":[],"unacked":["m-old"]}"#.utf8).write(to: URL(fileURLWithPath: ledgerPath))
        let sent = Box<[String]?>(nil)
        let client = await makeClient { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
            sent.value = body["unacked"] as? [String]
            return (200, #"{"role":"primary"}"#)
        }
        let v6 = await client.ledger.unacked
        XCTAssertEqual(v6, ["m-old"], "a restart resumes the persisted ledger")
        await client.beat()
        XCTAssertEqual(sent.value, ["m-old"])
        let v7 = await client.ledger.unacked
        XCTAssertEqual(v7, [], "acked by the control plane during that beat")
    }

    @MainActor
    func testDrainStopsClaimingAndDropsThePrimaryBid() async {
        let wants = Box<[Bool]>([])
        let claims = Box<Int>(0)
        let delivered = Box<[String]>([])
        let client = await makeClient(onCommand: { delivered.value.append($0.kind) }) { request in
            if request.url!.path.hasSuffix("/claim") { claims.value += 1; return (200, "{}") }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
            wants.value.append(body["wantsPrimary"] as? Bool ?? true)
            return (200, #"{"role":"primary","commands":[{"id":"c-1","kind":"drain"}],"messages":[{"id":"m-4","text":"late"}]}"#)
        }
        await client.beat()
        XCTAssertEqual(delivered.value, ["drain"])
        let draining = await client.isDraining
        XCTAssertTrue(draining)
        await client.beat()
        XCTAssertEqual(wants.value, [true, false])
        XCTAssertEqual(claims.value, 1, "the offer in the SAME beat as the drain was still claimed; later ones are not")
    }
}

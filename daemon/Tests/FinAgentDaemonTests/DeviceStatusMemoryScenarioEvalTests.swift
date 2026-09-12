import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Standalone eval for the multi-device-status-memory feature, covering scenarios the
/// implementer's own tests (`DaemonDeviceStatusClientTests`,
/// `DaemonMemoryConsolidatorTests`) did not exercise:
///   (b) `otherDevices` correctly enumerates + decodes MULTIPLE device rows from one
///       `/devices/status` response (the implementer's fixture only ever has one
///       surviving row after self-exclusion + staleness filtering).
///   (c) the compaction input's "Other devices right now:" block for 1 / 3 / 0 other
///       devices — 0-others-but-provider-is-set is a materially different case from
///       "provider left nil" (already pinned) and was not covered.
///   (d) redaction: device/agent/state text that looks secret-shaped must not reach
///       the completion() call unredacted via the cross-device section.
@MainActor
final class DeviceStatusMemoryScenarioEvalTests: XCTestCase {
    private var cacheFileURL: URL!

    override func setUp() {
        super.setUp()
        cacheFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-eval-consolidator-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheFileURL)
        super.tearDown()
    }

    // MARK: - shared fixtures

    private func makeStatusClient(
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> DaemonDeviceStatusClient {
        let client = DaemonDeviceStatusClient(endpointURL: "https://cp.example", token: "cp-token")
        client.transport = transport
        return client
    }

    private func ok(_ body: String, for request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func makeConsolidator(
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> DaemonMemoryConsolidator {
        let memory = DaemonMemoryClient(
            endpointURL: "https://cp.example", token: "cp-token", agentName: "Nimbus",
            agentID: nil, originDeviceID8: "abcd1234", audit: { _ in }, transport: transport
        )
        return DaemonMemoryConsolidator(
            memory: memory, cacheFileURL: cacheFileURL, holder: "abcd1234",
            endpointURL: "https://model.example", modelIdentifier: "m", apiKey: nil,
            temperature: 0.2, maxOutputTokens: 640, audit: { _ in }
        )
    }

    /// A driveable pass through `run(refreshCache:attemptConsolidation:)` with a fixed
    /// one-candidate episodic history, capturing exactly what reaches `completion`.
    private func drive(
        _ consolidator: DaemonMemoryConsolidator,
        transportOverride: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) async -> String? {
        var completionInput: String?
        consolidator.completion = { _, input in
            completionInput = input
            return "Levi is working on Fin; prefers direct, concise answers and end-to-end verification."
        }
        await consolidator.run(refreshCache: false, attemptConsolidation: true)
        return completionInput
    }

    private func baseTransport(_ request: URLRequest) -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/lock") {
            if request.httpMethod == "DELETE" { return ok(#"{"released":true}"#, for: request) }
            return ok(#"{"holder":"abcd1234","claimedAt":"2026-09-08T00:00:00Z"}"#, for: request)
        }
        if path.hasSuffix("/profile"), request.httpMethod == "PUT" {
            return ok(#"{"content":"ok","updatedAt":"2026-09-09T00:00:00Z"}"#, for: request)
        }
        if request.url?.absoluteString.contains("/memory?agent=") == true {
            return ok(#"{"entries":[{"id":"m-1","title":"Deploy target","content":"prod-east","updatedAt":"2026-09-09T00:00:00Z"}]}"#, for: request)
        }
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        return ok(#"{"content":"existing profile text","updatedAt":"\#(old)"}"#, for: request)
    }

    // MARK: - (b) aggregation/read path: multiple device rows in one response

    func testOtherDevicesEnumeratesThreeFreshNonSelfDevicesFromOneResponse() async {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func t(_ minutesAgo: Double) -> String { iso.string(from: now.addingTimeInterval(-minutesAgo * 60)) }
        let body = """
        {"devices": [
          {"device": "Self Mac", "device_id8": "abcd1234", "agent": "Fin", "state": "idle", "updated_at": "\(t(1))"},
          {"device": "MacBook", "device_id8": "11112222", "agent": "Fin", "state": "idle", "updated_at": "\(t(3))"},
          {"device": "iPhone", "device_id8": "33334444", "agent": "Fin", "state": "thinking", "updated_at": "\(t(20))"},
          {"device": "iPad", "device_id8": "55556666", "agent": "Fin", "state": "awaitingApproval", "updated_at": "\(t(90))"}
        ]}
        """
        let client = makeStatusClient { request in self.ok(body, for: request) }

        let others = await client.otherDevices(excludingDeviceID8: "abcd1234", now: now)

        XCTAssertEqual(
            Set(others.map(\.device_id8)), Set(["11112222", "33334444", "55556666"]),
            "all three non-self devices must survive decoding from a single multi-row response"
        )
        let lines = others
            .sorted { ($0.device_id8 ?? "") < ($1.device_id8 ?? "") }
            .map { DaemonDeviceStatusClient.formatLine($0, now: now) }
        XCTAssertEqual(lines, [
            "MacBook — idle, working on Fin, last seen 3m ago",
            "iPhone — thinking, working on Fin, last seen 20m ago",
            "iPad — awaitingApproval, working on Fin, last seen 1h ago",
        ])
    }

    // MARK: - (a) two devices writing under the new per-device key format don't clobber

    /// Simulates the S3-backed `/devices/status` aggregation the Lambda performs: each
    /// device PUTs its OWN object at `users/{user}/fin/devices/{device_id8}/status.json`
    /// (a distinct key per device — the whole point of the schema change from the old
    /// single shared `fin/status.json`), and the GET route reads all of them back. This
    /// models that contract at the client's decode boundary: two devices' rows, each
    /// keeping its own state/agent, both present and distinguishable in one response —
    /// the failure mode being tested against is "device B's write silently overwrote
    /// device A's" (which the OLD shared-key schema was exactly vulnerable to, and the
    /// per-device key path is designed to prevent).
    func testTwoDevicesWritingUnderDistinctKeysBothSurviveAggregation() async {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let t1 = iso.string(from: now.addingTimeInterval(-2 * 60))
        let t2 = iso.string(from: now.addingTimeInterval(-4 * 60))
        // Two independent device documents, as if two devices each PUT to their own
        // users/{user}/fin/devices/{id8}/status.json key and the Lambda's list route
        // concatenated them (see lambda.py's list_device_status).
        let deviceADoc = #"{"device":"iMac","device_id8":"aaaa1111","agent":"Fin","state":"idle","updated_at":"\#(t1)"}"#
        let deviceBDoc = #"{"device":"MacBook Air","device_id8":"bbbb2222","agent":"Fin","state":"thinking","updated_at":"\#(t2)"}"#
        let aggregated = #"{"devices": [\#(deviceADoc), \#(deviceBDoc)]}"#

        let client = makeStatusClient { request in self.ok(aggregated, for: request) }
        let others = await client.otherDevices(excludingDeviceID8: "cccc3333", now: now)

        XCTAssertEqual(others.count, 2, "both devices' independently-written documents must be present, neither clobbered by the other")
        XCTAssertEqual(others.first { $0.device_id8 == "aaaa1111" }?.device, "iMac")
        XCTAssertEqual(others.first { $0.device_id8 == "aaaa1111" }?.state, "idle")
        XCTAssertEqual(others.first { $0.device_id8 == "bbbb2222" }?.device, "MacBook Air")
        XCTAssertEqual(others.first { $0.device_id8 == "bbbb2222" }?.state, "thinking")
    }

    // MARK: - (c) compaction input block: 1 device / 3 devices / 0 other devices

    func testCompactionInputFor3DevicesRendersOneLinePerDeviceInOrder() async {
        let consolidator = makeConsolidator(transport: baseTransport)
        consolidator.crossDeviceStatusProvider = {
            [
                "MacBook — idle, working on Fin, last seen 3m ago",
                "iPhone — thinking, working on Fin, last seen 20m ago",
                "iPad — awaitingApproval, working on Fin, last seen 1h ago",
            ]
        }
        let input = await drive(consolidator, transportOverride: baseTransport)
        let expected = "Current profile:\nexisting profile text"
            + "\n\nOther devices right now:"
            + "\n- MacBook — idle, working on Fin, last seen 3m ago"
            + "\n- iPhone — thinking, working on Fin, last seen 20m ago"
            + "\n- iPad — awaitingApproval, working on Fin, last seen 1h ago"
            + "\n\nRecent conversations:\n\nDeploy target\nprod-east"
        XCTAssertEqual(input, expected, "3-device block must render exactly one line per device, in the provider's order")
        print("EVAL[3-device compaction input]:\n\(input ?? "nil")")
    }

    func testCompactionInputForZeroOtherDevicesOmitsTheSectionEntirely() async {
        // Distinct from "provider left nil" (already pinned elsewhere): here the
        // provider IS wired (e.g. this is the only device that has ever registered,
        // or every other device's status is stale) and explicitly returns [].
        let consolidator = makeConsolidator(transport: baseTransport)
        consolidator.crossDeviceStatusProvider = { [] }
        let input = await drive(consolidator, transportOverride: baseTransport)
        XCTAssertEqual(
            input,
            "Current profile:\nexisting profile text\n\nRecent conversations:\n\nDeploy target\nprod-east",
            "an empty (but non-nil) cross-device result must omit the 'Other devices right now:' section entirely, not print it with zero lines"
        )
        print("EVAL[0-other-devices compaction input]:\n\(input ?? "nil")")
    }

    func testCompactionInputFor1DeviceMatchesExactly() async {
        let consolidator = makeConsolidator(transport: baseTransport)
        consolidator.crossDeviceStatusProvider = { ["MacBook — idle, working on Fin, last seen 3m ago"] }
        let input = await drive(consolidator, transportOverride: baseTransport)
        XCTAssertEqual(
            input,
            "Current profile:\nexisting profile text\n\nOther devices right now:\n- MacBook — idle, working on Fin, last seen 3m ago\n\nRecent conversations:\n\nDeploy target\nprod-east"
        )
        print("EVAL[1-device compaction input]:\n\(input ?? "nil")")
    }

    // MARK: - (d) redaction before the completion() call / before persistence

    /// `crossDeviceStatusProvider`'s lines are spliced into `input` with plain string
    /// interpolation (see `DaemonMemoryConsolidator.compact`) — there is no
    /// `MemoryRedactor.redact` call anywhere on that path before `completion(instruction,
    /// input)` runs. This test proves it concretely: a secret-shaped device/agent string
    /// (as would appear if a device name or the app's `last_assistant_preview`-derived
    /// text were ever surfaced into a device-status line) reaches the model call intact.
    func testSecretShapedCrossDeviceLineReachesTheCompletionCallUnredacted() async {
        let consolidator = makeConsolidator(transport: baseTransport)
        let secretLine = "prod-imac — idle, working on api_key: AKIAABCDEFGHIJKLMNOP, last seen 1m ago"
        consolidator.crossDeviceStatusProvider = { [secretLine] }
        let input = await drive(consolidator, transportOverride: baseTransport)
        XCTAssertTrue(
            input?.contains("AKIAABCDEFGHIJKLMNOP") ?? false,
            "FINDING: unlike sessionActivityNotesProvider (pre-redacted at the source by " +
            "SessionActivitySummarizer before it ever reaches the consolidator), " +
            "crossDeviceStatusProvider has no redaction step on the read/compact side. " +
            "MemoryRedactor.redact is only ever applied to the model's OUTPUT " +
            "(`compact()`'s `bounded = String(MemoryRedactor.redact(trimmed)...)`), never " +
            "to this input. Today this is dormant because `formatLine` only surfaces " +
            "device/state/agent/updated_at (themselves redacted at write time in " +
            "AgentDirectiveChannel.statusBody) — but nothing in DaemonDeviceStatusClient " +
            "or DaemonMemoryConsolidator enforces that invariant, so it silently breaks " +
            "the moment a freer-text field (e.g. last_assistant_preview) is added to the " +
            "cross-device line."
        )
    }

    /// Confirms the one place redaction DOES apply on this path: the model's output is
    /// redacted before being persisted back to the shared profile, same as before this
    /// feature existed. (Sanity check, not a new finding — pins existing behavior so a
    /// regression here would be caught.)
    func testModelOutputIsStillRedactedBeforePersistenceRegardlessOfCrossDeviceInput() async {
        var writtenProfileContent: String?
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/lock") {
                if request.httpMethod == "DELETE" { return self.ok(#"{"released":true}"#, for: request) }
                return self.ok(#"{"holder":"abcd1234","claimedAt":"2026-09-08T00:00:00Z"}"#, for: request)
            }
            if path.hasSuffix("/profile"), request.httpMethod == "PUT" {
                if let body = request.httpBody, let text = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    writtenProfileContent = text["content"] as? String
                }
                return self.ok(#"{"content":"ok","updatedAt":"2026-09-09T00:00:00Z"}"#, for: request)
            }
            if request.url?.absoluteString.contains("/memory?agent=") == true {
                return self.ok(#"{"entries":[{"id":"m-1","title":"Deploy target","content":"prod-east","updatedAt":"2026-09-09T00:00:00Z"}]}"#, for: request)
            }
            let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
            return self.ok(#"{"content":"existing profile text","updatedAt":"\#(old)"}"#, for: request)
        }
        let consolidator = makeConsolidator(transport: transport)
        consolidator.crossDeviceStatusProvider = { ["MacBook — idle, working on Fin, last seen 3m ago"] }
        consolidator.completion = { _, _ in
            "Levi's AWS key is AKIAABCDEFGHIJKLMNOP and he prefers concise answers about deployment status overall."
        }

        await consolidator.run(refreshCache: false, attemptConsolidation: true)

        XCTAssertNotNil(writtenProfileContent)
        XCTAssertFalse(writtenProfileContent?.contains("AKIAABCDEFGHIJKLMNOP") ?? true, "the persisted profile must still be redacted")
        XCTAssertTrue(writtenProfileContent?.contains("[redacted]") ?? false)
    }
}

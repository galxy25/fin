import XCTest
@testable import fin

/// Queue behavior for the feedback pipeline: consent gating (off → nothing even
/// queues; on → the frozen contract shape goes out), the 404 not-deployed hold,
/// exponential backoff with a loud give-up, comment redaction at enqueue time,
/// and consent revocation emptying the queue. All transport is injected — no
/// network, no real control plane, no standard UserDefaults.
@MainActor
final class FeedbackServiceTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var queueDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "feedback-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        queueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-queue-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: queueDir)
        super.tearDown()
    }

    private func makeService(
        sharing: @escaping (FeedbackService.Item.Kind) -> Bool = { _ in true },
        configured: Bool = true
    ) -> FeedbackService {
        let service = FeedbackService(defaults: defaults, queueDirectory: queueDir)
        service.automaticProcessing = false
        service.isSharingAllowed = sharing
        service.controlPlane = configured
            ? { ("https://cp.example.com/prod/", "tok-1234") }
            : { nil }
        return service
    }

    // MARK: - Consent gating

    func testSharingOffQueuesNothingAndSendsNothing() async {
        var transportCalls = 0
        var auditLines: [String] = []
        let service = makeService(sharing: { _ in false })
        service.transport = { _ in transportCalls += 1; return (200, nil) }
        service.audit = { auditLines.append($0) }

        service.submitUserFeedback(rating: 1, comment: "great")
        service.submitTrajectory(TrajectoryDigest(
            conversationID: UUID().uuidString, turns: 1, toolCallCounts: [:],
            durationSeconds: 5, outcome: "completed", transcriptChars: 40,
            model: "m", hostingMode: "local"
        ))
        await service.processOnce()

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(transportCalls, 0)
        // The rating drop is loud (the UI shouldn't have allowed it); the
        // trajectory drop is the normal not-opted-in path and stays quiet.
        XCTAssertEqual(auditLines.count, 1)
        XCTAssertTrue(auditLines[0].contains("rating dropped"))
    }

    func testUnconfiguredControlPlaneHoldsWithoutBurningAttempts() async {
        var transportCalls = 0
        let service = makeService(configured: false)
        service.transport = { _ in transportCalls += 1; return (200, nil) }

        service.submitUserFeedback(rating: -1, comment: nil)
        await service.processOnce()

        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items[0].attempts, 0)
    }

    // MARK: - Contract shape

    func testSharingOnSendsContractShapedBody() async throws {
        var captured: URLRequest?
        let service = makeService()
        service.transport = { request in captured = request; return (200, nil) }

        service.submitUserFeedback(rating: 1, comment: "loving the monitor mode")
        await service.processOnce()

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example.com/prod/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer tok-1234")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["kind"] as? String, "user_feedback")
        XCTAssertEqual(body["rating"] as? Int, 1)
        XCTAssertEqual(body["comment"] as? String, "loving the monitor mode")
        XCTAssertTrue(body["payload"] is NSNull)
        XCTAssertNotNil(body["appVersion"] as? String)
        XCTAssertNotNil(body["platform"] as? String)
        let createdAt = try XCTUnwrap(body["createdAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: createdAt))
        // The frozen contract's exact key set — nothing extra rides along.
        XCTAssertEqual(
            Set(body.keys),
            ["kind", "rating", "comment", "payload", "appVersion", "platform", "createdAt"]
        )
        XCTAssertTrue(service.items.isEmpty)
    }

    func testTrajectoryBodyCarriesDigestPayloadAndNullRating() async throws {
        var captured: URLRequest?
        let service = makeService()
        service.transport = { request in captured = request; return (201, nil) }

        service.submitTrajectory(TrajectoryDigest(
            conversationID: "conv-1", turns: 3, toolCallCounts: ["readTerminal": 4],
            durationSeconds: 92, outcome: "completed", transcriptChars: 512,
            model: "qwen-32b", hostingMode: "cloud"
        ))
        await service.processOnce()

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(captured?.httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(body["kind"] as? String, "trajectory")
        XCTAssertTrue(body["rating"] is NSNull)
        XCTAssertTrue(body["comment"] is NSNull)
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(payload["turns"] as? Int, 3)
        XCTAssertEqual((payload["toolCallCounts"] as? [String: Int])?["readTerminal"], 4)
        XCTAssertEqual(payload["outcome"] as? String, "completed")
        XCTAssertEqual(payload["hostingMode"] as? String, "cloud")
    }

    // MARK: - Redaction at the queue boundary

    func testCommentIsRedactedBeforeItIsStored() {
        let service = makeService()
        service.transport = { _ in (500, nil) } // hold it in the queue

        service.submitUserFeedback(rating: -1, comment: "it broke after export TOKEN=sk-abc123secret")
        XCTAssertEqual(service.items.count, 1)
        let stored = service.items[0].comment ?? ""
        XCTAssertFalse(stored.contains("sk-abc123secret"))
        XCTAssertTrue(stored.contains("[redacted]"))
    }

    // MARK: - Retry behavior

    func testNotDeployed404HoldsWithoutBurningAttempts() async {
        var auditLines: [String] = []
        let service = makeService()
        service.transport = { _ in (404, nil) }
        service.audit = { auditLines.append($0) }

        service.submitUserFeedback(rating: 1, comment: nil)
        await service.processOnce()

        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items[0].attempts, 0)
        XCTAssertGreaterThan(service.items[0].nextAttemptAt, Date())
        XCTAssertTrue(auditLines.contains { $0.contains("not deployed yet") })
    }

    func testServerErrorBacksOffThenGivesUpLoudly() async {
        var auditLines: [String] = []
        var fakeNow = Date()
        let service = makeService()
        service.transport = { _ in (500, nil) }
        service.audit = { auditLines.append($0) }
        service.now = { fakeNow }

        service.submitUserFeedback(rating: 1, comment: nil)
        for _ in 0..<FeedbackService.maxAttempts {
            await service.processOnce()
            // Jump past whatever backoff the failure just scheduled.
            fakeNow = fakeNow.addingTimeInterval(FeedbackService.maxRetryDelay + 1)
        }

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertTrue(auditLines.contains { $0.contains("gave up") && $0.contains("HTTP 500") })
    }

    func testBackoffDoublesFromBaseToCap() {
        XCTAssertEqual(FeedbackService.backoffDelay(attempts: 1), FeedbackService.baseRetryDelay)
        XCTAssertEqual(FeedbackService.backoffDelay(attempts: 2), FeedbackService.baseRetryDelay * 2)
        XCTAssertEqual(FeedbackService.backoffDelay(attempts: 3), FeedbackService.baseRetryDelay * 4)
        XCTAssertEqual(FeedbackService.backoffDelay(attempts: 99), FeedbackService.maxRetryDelay)
    }

    func testQueuePersistsAcrossInstances() {
        let first = makeService()
        first.transport = { _ in (503, nil) }
        first.submitUserFeedback(rating: 1, comment: "persist me")

        let second = FeedbackService(defaults: defaults, queueDirectory: queueDir)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertEqual(second.items[0].comment, "persist me")
    }

    // MARK: - Consent revocation

    func testTurningSharingOffDiscardsQueuedItemsLoudly() {
        var auditLines: [String] = []
        var allowed = true
        let service = makeService(sharing: { _ in allowed })
        service.transport = { _ in (500, nil) }
        service.audit = { auditLines.append($0) }

        service.submitUserFeedback(rating: 1, comment: nil)
        XCTAssertEqual(service.items.count, 1)

        allowed = false
        NotificationCenter.default.post(name: FeedbackSettings.changedNotification, object: nil)

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertTrue(auditLines.contains { $0.contains("discarded 1 queued user_feedback") })
    }
}

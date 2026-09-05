import XCTest
@testable import fin

/// Throttling for the "How's Fin doing?" card: silent until three conversations
/// have completed, then at most once per seven days, dismissed-forever wins over
/// everything. Pure UserDefaults state against an isolated suite.
final class FeedbackPromptGateTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var gate: FeedbackPromptGate!

    override func setUp() {
        super.setUp()
        suiteName = "prompt-gate-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        gate = FeedbackPromptGate(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSilentBeforeThreeCompletedConversations() {
        XCTAssertFalse(gate.shouldPrompt())
        gate.noteConversationCompleted()
        gate.noteConversationCompleted()
        XCTAssertFalse(gate.shouldPrompt())
        gate.noteConversationCompleted()
        XCTAssertTrue(gate.shouldPrompt())
    }

    func testPromptingStartsTheSevenDayClock() {
        for _ in 0..<3 { gate.noteConversationCompleted() }
        let day0 = Date()
        XCTAssertTrue(gate.shouldPrompt(now: day0))

        gate.notePrompted(now: day0)
        XCTAssertFalse(gate.shouldPrompt(now: day0))
        XCTAssertFalse(gate.shouldPrompt(now: day0.addingTimeInterval(6.9 * 86_400)))
        XCTAssertTrue(gate.shouldPrompt(now: day0.addingTimeInterval(7 * 86_400)))
    }

    func testDismissForeverBeatsEverything() {
        for _ in 0..<10 { gate.noteConversationCompleted() }
        gate.dismissForever()
        XCTAssertFalse(gate.shouldPrompt())
        XCTAssertFalse(gate.shouldPrompt(now: Date().addingTimeInterval(365 * 86_400)))
        // More completed conversations can't resurrect it.
        gate.noteConversationCompleted()
        XCTAssertFalse(gate.shouldPrompt())
    }

    func testDismissingWithoutAnsweringStillCountsAsPrompted() {
        for _ in 0..<3 { gate.noteConversationCompleted() }
        let shown = Date()
        // The console marks prompted on APPEARANCE, so a wave-away buys the same
        // quiet week an answer does — this test pins that contract.
        gate.notePrompted(now: shown)
        XCTAssertFalse(gate.shouldPrompt(now: shown.addingTimeInterval(86_400)))
    }
}

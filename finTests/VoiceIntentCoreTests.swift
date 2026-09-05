import XCTest
@testable import fin

/// Pure-logic coverage for the voice intents' shared core (`FinVoiceIntentCore`)
/// and the setup screen's hardware branch (`TriggerHardware`). No `ModelContainer`,
/// no S3, no live device — the SwiftData fetch and network polling that wrap these
/// helpers live in the intent, so the decision rules are testable in isolation.
final class VoiceIntentCoreTests: XCTestCase {

    // MARK: - Target resolution

    func testPrefersAgentNamedFinCaseInsensitively() {
        XCTAssertEqual(FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: ["Ops", "Fin", "Scout"]), 1)
        XCTAssertEqual(FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: ["ops", "fIn"]), 1)
    }

    func testFallsBackToFirstWhenNoFin() {
        XCTAssertEqual(FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: ["Ops", "Scout"]), 0)
    }

    func testNoCloudAgentsResolvesToNil() {
        XCTAssertNil(FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: []))
    }

    // MARK: - Reply detection

    private func record(_ id: String, _ kind: AgentLogKind, _ text: String, at seconds: TimeInterval, sequence: Int = 0) -> AgentMirrorRecord {
        AgentMirrorRecord(
            id: id, kind: kind, text: text,
            timestamp: Date(timeIntervalSince1970: seconds), sequence: sequence
        )
    }

    func testNewReplyIgnoresAlreadyKnownAssistantLines() {
        let transcript = [
            record("a1", .assistantMessage, "old answer", at: 100),
            record("u1", .userMessage, "my question", at: 200),
            record("a2", .assistantMessage, "fresh answer", at: 300),
        ]
        let reply = FinVoiceIntentCore.newReply(in: transcript, knownIDs: ["a1"])
        XCTAssertEqual(reply, "fresh answer")
    }

    func testNewReplyReturnsNewestWhenSeveralArrive() {
        let transcript = [
            record("a2", .assistantMessage, "first turn", at: 300, sequence: 1),
            record("a3", .assistantMessage, "final turn", at: 300, sequence: 2),
        ]
        XCTAssertEqual(FinVoiceIntentCore.newReply(in: transcript, knownIDs: []), "final turn")
    }

    func testNewReplySkipsEmptyAssistantTurnsAndNonAssistantKinds() {
        let transcript = [
            record("t1", .toolCall, "read_terminal", at: 300),
            record("a2", .assistantMessage, "   ", at: 310),
            record("a1", .assistantMessage, "the real answer", at: 305),
        ]
        // Newest non-empty assistant line wins; the blank a2 is skipped even
        // though it is newest, and the tool call never counts.
        XCTAssertEqual(FinVoiceIntentCore.newReply(in: transcript, knownIDs: []), "the real answer")
    }

    func testNewReplyNilWhenNothingNew() {
        let transcript = [record("a1", .assistantMessage, "old", at: 100)]
        XCTAssertNil(FinVoiceIntentCore.newReply(in: transcript, knownIDs: ["a1"]))
        XCTAssertNil(FinVoiceIntentCore.newReply(in: [], knownIDs: []))
    }

    // MARK: - Spoken summary

    func testSpokenSummaryLeavesShortTextIntact() {
        XCTAssertEqual(FinVoiceIntentCore.spokenSummary("All done."), "All done.")
    }

    func testSpokenSummaryTruncatesAtWordBoundary() {
        let long = String(repeating: "word ", count: 200) // 1000 chars
        let summary = FinVoiceIntentCore.spokenSummary(long, limit: 20)
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.count, 21)
        XCTAssertFalse(summary.dropLast().hasSuffix(" "), "should trim trailing space before the ellipsis")
    }

    // MARK: - Trigger hardware

    func testActionButtonDevices() {
        // iPhone 15 Pro / Pro Max (major 16), iPhone 16 line (major 17), future (18).
        for id in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,3", "iPhone18,1"] {
            XCTAssertEqual(TriggerHardware.classify(machineIdentifier: id), .actionButton, "expected .actionButton for \(id)")
        }
    }

    func testBackTapDevices() {
        // iPhone 15 / 15 Plus (major 15) and older have no Action Button.
        for id in ["iPhone15,4", "iPhone15,5", "iPhone14,7", "iPhone12,1"] {
            XCTAssertEqual(TriggerHardware.classify(machineIdentifier: id), .backTap, "expected .backTap for \(id)")
        }
    }

    func testNonPhoneDevicesHaveNoHardwareButton() {
        for id in ["iPad13,1", "Mac15,3", "simulator", "arm64"] {
            XCTAssertEqual(TriggerHardware.classify(machineIdentifier: id), .noHardwareButton, "expected .noHardwareButton for \(id)")
        }
    }
}

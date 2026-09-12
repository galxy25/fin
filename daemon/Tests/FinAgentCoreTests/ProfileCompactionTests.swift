import XCTest
@testable import FinAgentCore

final class ProfileCompactionTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_789_200_000) // 2026-09-12 UTC

    func testInstructionDatesTodayAndTimeboxesCurrentWork() {
        let text = ProfileCompaction.instruction(today: day)
        XCTAssertTrue(text.contains("Today is 2026-09-12"))
        XCTAssertTrue(text.contains("last \(ProfileCompaction.currentWorkWindowDays) days"))
        XCTAssertTrue(text.contains("drop it"), "the prune rule must be explicit, not implied by 'merge'")
        for heading in ProfileCompaction.sectionHeadings {
            XCTAssertTrue(text.contains(heading), heading)
        }
    }

    func testInputDatesEveryConversationAndLabelsObservations() {
        let input = ProfileCompaction.input(
            currentProfile: "old profile",
            observed: [
                .init(title: "Terminal panes right now", lines: ["main:1 fin — control plane"]),
                .init(title: "Empty section", lines: []),
            ],
            conversations: [.init(title: "Deploy chat", date: day, content: "we deployed")],
            perConversationCap: 1500
        )
        XCTAssertTrue(input.hasPrefix("Current profile:\nold profile"))
        XCTAssertTrue(input.contains("Terminal panes right now:\n- main:1 fin — control plane"))
        XCTAssertFalse(input.contains("Empty section"), "an empty section must not be rendered")
        XCTAssertTrue(input.contains("Deploy chat (2026-09-12)\nwe deployed"))
    }

    func testInputCapsAConversationFromItsTail() {
        let input = ProfileCompaction.input(
            currentProfile: "", observed: [],
            conversations: [.init(title: "t", date: nil, content: "aaaa" + "bbbb")],
            perConversationCap: 4
        )
        XCTAssertTrue(input.contains("t\n…bbbb"))
        XCTAssertTrue(input.contains("(none)"))
    }

    func testAStructuredRewriteMayShrinkFreely() {
        // The reason this type exists: pruning a stale profile down to what is
        // actually current must not read as a bad model reply.
        let existing = String(repeating: "troubleshooting iPad connectivity and other old things. ", count: 10)
        let pruned = "**Current work**\n- shipping sites (2026-09-11)\n**Environment**\n- iMac runs Fin (2026-09-11)"
        XCTAssertLessThan(pruned.count, existing.count * 3 / 10)
        XCTAssertTrue(ProfileCompaction.acceptable(pruned, replacing: existing))
    }

    func testAnUnstructuredDrasticShrinkIsStillRejected() {
        let existing = String(repeating: "User is building Fin and prefers terse answers. ", count: 7)
        XCTAssertFalse(ProfileCompaction.acceptable("User likes terse answers, ships from the terminal daily.", replacing: existing))
    }

    func testRefusalsAndPlaceholderEchoesAreRejected() {
        XCTAssertFalse(ProfileCompaction.acceptable("short", replacing: ""))
        XCTAssertFalse(ProfileCompaction.acceptable(
            "Current profile: (none). Nothing new to add from the recent conversations.", replacing: ""))
    }

    func testAModerateUnstructuredRewriteIsAccepted() {
        let existing = String(repeating: "User is building Fin and prefers terse answers. ", count: 7)
        let distilled = String(repeating: "Building Fin; terse answers; fish shell; TestFlight beta. ", count: 3)
        XCTAssertTrue(ProfileCompaction.acceptable(distilled, replacing: existing))
    }
}

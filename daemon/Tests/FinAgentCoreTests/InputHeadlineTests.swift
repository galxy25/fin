import XCTest
@testable import FinAgentCore

final class InputHeadlineTests: XCTestCase {
    func testSanitizeStripsQuotesPrefixAndTrailingPeriod() {
        XCTAssertEqual(InputHeadline.sanitize("\"Pick a branch for the rebase.\""), "Pick a branch for the rebase")
        XCTAssertEqual(InputHeadline.sanitize("Title: Approve deleting build/"), "Approve deleting build/")
        XCTAssertEqual(InputHeadline.sanitize("\n\n  Choose the deploy target\nbecause…"), "Choose the deploy target")
    }

    func testSanitizeDropsAThinkBlockAndRejectsAnUnfinishedOne() {
        XCTAssertEqual(InputHeadline.sanitize("<think>hmm</think>\nConfirm the API key rotation"), "Confirm the API key rotation")
        XCTAssertNil(InputHeadline.sanitize("<think>Let me consider what the user"))
        XCTAssertNil(InputHeadline.sanitize("   "))
        XCTAssertNil(InputHeadline.sanitize(String(repeating: "word ", count: 20)))
    }

    func testFallbackIsTheFirstSentenceClipped() {
        XCTAssertEqual(InputHeadline.fallback(question: "Which branch? main or dev."), "Which branch?")
        XCTAssertEqual(InputHeadline.fallback(question: ""), "Fin needs your input")
        let long = InputHeadline.fallback(question: String(repeating: "abcdefg ", count: 20))
        XCTAssertLessThanOrEqual(long.count, InputHeadline.maxCharacters)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testGenerateFallsBackOnErrorTimeoutAndJunk() async {
        struct Boom: Error {}
        let q = "Should I force-push the rebased branch? It rewrites 3 commits."
        let ok = await InputHeadline.generate(question: q) { _ in "Approve force-pushing the rebase" }
        XCTAssertEqual(ok, "Approve force-pushing the rebase")
        let failed = await InputHeadline.generate(question: q) { _ in throw Boom() }
        XCTAssertEqual(failed, "Should I force-push the rebased branch?")
        let slow = await InputHeadline.generate(question: q, timeoutSeconds: 0.05) { _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return "too late"
        }
        XCTAssertEqual(slow, "Should I force-push the rebased branch?")
    }

    func testMarkerDecodesPreHeadlineFiles() throws {
        let json = #"{"question":"q?","since":"2026-10-22T07:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AwaitingUserInputState.self, from: Data(json.utf8))
        XCTAssertNil(state.headline)
    }
}

/// The 2026-10-22 Neo case: a mission question about a goal Levi had dropped
/// two weeks earlier kept the daemon paused (and paging) indefinitely.
final class AwaitingUserInputRevalidationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(messageID: String? = nil, ageHours: Double = 2) -> AwaitingUserInputState {
        AwaitingUserInputState(question: "Where is data-anamoly-reporter-agent?", messageID: messageID,
                               threadID: nil, since: now.addingTimeInterval(-ageHours * 3600))
    }

    func ledger(_ states: GoalState...) -> LedgerDocument {
        LedgerDocument(goals: states.enumerated().map { Goal(id: "g\($0.offset)", title: "t", state: $0.element) })
    }

    func testAMissionQuestionIsReleasedOnceNoGoalIsOpen() {
        XCTAssertNotNil(AwaitingUserInputRevalidation.releaseReason(state(), ledger: ledger(.done, .done), now: now))
        XCTAssertNil(AwaitingUserInputRevalidation.releaseReason(state(), ledger: ledger(.done, .blocked), now: now))
    }

    func testAMissionQuestionIsReDecidedAfterADay() {
        XCTAssertNotNil(AwaitingUserInputRevalidation.releaseReason(state(ageHours: 25), ledger: ledger(.open), now: now))
        XCTAssertNil(AwaitingUserInputRevalidation.releaseReason(state(ageHours: 23), ledger: nil, now: now))
    }

    func testAQuestionAskedInAConversationWaitsForTheAnswer() {
        let asked = state(messageID: "m-1", ageHours: 300)
        XCTAssertNil(AwaitingUserInputRevalidation.releaseReason(asked, ledger: ledger(.done), now: now))
    }
}

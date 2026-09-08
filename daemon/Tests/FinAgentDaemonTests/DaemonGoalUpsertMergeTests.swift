import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// `Daemon.mergedGoal` — the pure create/update logic behind `goal_upsert`, extracted
/// (review, same day) so its field-merge semantics are directly testable rather than
/// embedded, untested, in `Daemon.goalUpsert`'s I/O. Two real bugs were caught by
/// inspection before this file existed: an update's `title` could be silently blanked to
/// "", and `tags`' replace-not-merge behavior was undocumented (fixed in the tool
/// description, not here — the behavior itself was correct, just unstated).
final class DaemonGoalUpsertMergeTests: XCTestCase {

    private let existing = Goal(
        id: "g-x", title: "Original title", state: .active, priority: 1,
        why: "original why", nextAction: "original next", blockedOn: nil,
        tags: ["a", "b"], source: "m-1"
    )

    // MARK: - Create (existing == nil)

    func testCreateRequiresANonEmptyTitle() {
        let result = Daemon.mergedGoal(
            existing: nil, id: "g-new", title: nil, state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .failure(let message) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("g-new"))
        XCTAssertTrue(message.contains("title"))
    }

    func testCreateRejectsAWhitespaceOnlyTitle() {
        let result = Daemon.mergedGoal(
            existing: nil, id: "g-new", title: "   ", state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    func testCreateWithATitleSucceedsAndDefaultsStateToOpen() {
        let result = Daemon.mergedGoal(
            existing: nil, id: "g-new", title: "New goal", state: nil, why: "why",
            nextAction: "next", blockedOn: nil, tags: ["t"], source: "m-2"
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.id, "g-new")
        XCTAssertEqual(goal.title, "New goal")
        XCTAssertEqual(goal.state, .open)
        XCTAssertEqual(goal.why, "why")
        XCTAssertEqual(goal.nextAction, "next")
        XCTAssertEqual(goal.tags, ["t"])
        XCTAssertEqual(goal.source, "m-2")
    }

    func testCreateTrimsTheTitle() {
        let result = Daemon.mergedGoal(
            existing: nil, id: "g-new", title: "  spaced  ", state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.title, "spaced")
    }

    // MARK: - Update (existing != nil) — omitted fields stay unchanged

    func testUpdateWithEveryFieldOmittedLeavesTheGoalUnchanged() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: nil, state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal, existing)
    }

    func testUpdateChangesOnlyTheFieldsProvided() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: nil, state: nil, why: "new why",
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.why, "new why")
        XCTAssertEqual(goal.title, existing.title, "untouched fields must survive the update")
        XCTAssertEqual(goal.nextAction, existing.nextAction)
        XCTAssertEqual(goal.tags, existing.tags)
    }

    /// THE BUG CAUGHT IN REVIEW: create already guarded against a blank title; update did
    /// not. A model sending `title: ""` on an update (rather than omitting the field)
    /// must be refused, not silently blank the goal's identity.
    func testUpdateRejectsBlankingTheTitleToEmptyString() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: "", state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .failure = result else { return XCTFail("expected failure — empty title must be refused") }
    }

    func testUpdateRejectsAWhitespaceOnlyTitle() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: "   ", state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    func testUpdateTrimsAGenuineTitleChange() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: "  New title  ", state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.title, "New title")
    }

    /// Tags REPLACE, not merge — confirmed-correct behavior (now documented in the tool
    /// description), pinned here so it can't silently flip to a different semantic.
    func testUpdateTagsReplaceTheWholeListNotMerge() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: nil, state: nil, why: nil,
            nextAction: nil, blockedOn: nil, tags: ["only-this-one"], source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.tags, ["only-this-one"])
    }

    // MARK: - state / blockedOn interaction

    func testChangingStateAwayFromBlockedClearsBlockedOnEvenIfNotMentioned() {
        let blocked = Goal(
            id: "g-b", title: "T", state: .blocked, blockedOn: "waiting on X"
        )
        let result = Daemon.mergedGoal(
            existing: blocked, id: "g-b", title: nil, state: .active, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.state, .active)
        XCTAssertNil(goal.blockedOn, "a stale blocked-on must not survive leaving the blocked state")
    }

    func testReaffirmingBlockedStateWithNoBlockedOnGivenKeepsTheExistingOne() {
        let blocked = Goal(
            id: "g-b", title: "T", state: .blocked, blockedOn: "waiting on X"
        )
        let result = Daemon.mergedGoal(
            existing: blocked, id: "g-b", title: nil, state: .blocked, why: nil,
            nextAction: nil, blockedOn: nil, tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.blockedOn, "waiting on X",
                      "re-affirming blocked with no new blocked_on must not lose the existing one")
    }

    func testAnExplicitBlockedOnInTheSameCallStillWinsOverTheClear() {
        let result = Daemon.mergedGoal(
            existing: existing, id: "g-x", title: nil, state: .blocked, why: nil,
            nextAction: nil, blockedOn: "newly blocked on Y", tags: nil, source: nil
        )
        guard case .success(let goal) = result else { return XCTFail("expected success") }
        XCTAssertEqual(goal.state, .blocked)
        XCTAssertEqual(goal.blockedOn, "newly blocked on Y")
    }
}

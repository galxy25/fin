import XCTest
@testable import fin

/// Covers the terminal event log the agent reads from — the chunking that turns a raw
/// byte stream into readable bursts, the ANSI stripping that keeps ordinary command output
/// legible, and the budget walk that renders a bounded, whole-chunk tail.
@MainActor
final class TerminalEventLogTests: XCTestCase {

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - Chunking

    func testConsecutiveSameKindWritesCoalesceIntoOneEvent() {
        let log = TerminalEventLog()
        log.recordInput(bytes("l"))
        log.recordInput(bytes("s"))
        log.recordInput(bytes("\n"))

        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events.first?.kind, .input)
        XCTAssertEqual(log.events.first?.text, "ls\n")
    }

    func testInputAndOutputNeverShareAChunkEvenBackToBack() {
        let log = TerminalEventLog()
        log.recordInput(bytes("ls\n"))
        log.recordOutput(bytes("file.txt\n"))

        XCTAssertEqual(log.events.count, 2)
        XCTAssertEqual(log.events[0].kind, .input)
        XCTAssertEqual(log.events[1].kind, .output)
    }

    func testEmptyDecodedTextIsDropped() {
        let log = TerminalEventLog()
        log.recordOutput([])
        log.recordOutput(bytes("\u{1B}[2J"))  // pure escape sequence, strips to nothing

        XCTAssertTrue(log.events.isEmpty)
    }

    // MARK: - ANSI / control stripping

    func testStripsCSISequencesFromOutput() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("\u{1B}[31mred text\u{1B}[0m"))

        XCTAssertEqual(log.events.first?.text, "red text")
    }

    func testStripsOSCSequenceTerminatedByBEL() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("\u{1B}]0;window title\u{07}prompt$ "))

        XCTAssertEqual(log.events.first?.text, "prompt$ ")
    }

    func testDropsBareCarriageReturnsFromProgressBars() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("50%\r100%\r\ndone"))

        XCTAssertEqual(log.events.first?.text, "50%100%\ndone")
    }

    func testStripsCharacterSetDesignationEntirely() {
        let log = TerminalEventLog()
        // ESC ( B is three bytes, not two — a prior bug dropped only the ESC, leaving the
        // literal "(B" behind.
        log.recordOutput(bytes("done\u{1B}(B"))

        XCTAssertEqual(log.events.first?.text, "done")
    }

    /// Reproduces a real tmux status-bar redraw: save cursor, jump to the status row, write
    /// the window list/clock, reset the character set, restore cursor. This is exactly the
    /// pattern that leaked "[main] <2.1.23>...(B"-style chrome into a real user's agent
    /// transcript — none of the text between save and restore should survive, since it was
    /// never scrollback, just a fixed row being redrawn on a timer.
    func testExcludesTextBetweenSaveAndRestoreCursor() {
        let log = TerminalEventLog()
        let statusBar = "\u{1B}7\u{1B}[24;1H\u{1B}[K[main] <2.1.23>\"status\" 09:44\u{1B}(B\u{1B}8"
        log.recordOutput(bytes("real output\n" + statusBar + "more real output"))

        let text = log.events.first?.text ?? ""
        XCTAssertFalse(text.contains("main"), text)
        XCTAssertFalse(text.contains("status"), text)
        XCTAssertTrue(text.contains("real output"), text)
        XCTAssertTrue(text.contains("more real output"), text)
    }

    func testExcludesTextBetweenCSISaveAndRestoreCursor() {
        let log = TerminalEventLog()
        // ANSI.SYS-style CSI save/restore (ESC [ s / ESC [ u), the less common alternative
        // to DECSC/DECRC — same exclusion should apply.
        log.recordOutput(bytes("before\u{1B}[shidden status\u{1B}[uafter"))

        XCTAssertEqual(log.events.first?.text, "beforeafter")
    }

    // MARK: - recentText rendering

    func testRecentTextLabelsInputAndOutputWithDistinctMarkers() {
        let log = TerminalEventLog()
        log.recordInput(bytes("whoami\n"))
        log.recordOutput(bytes("deepspacenine\n"))

        let rendered = log.recentText(maxLines: 100)
        XCTAssertTrue(rendered.contains("> whoami"), rendered)
        XCTAssertTrue(rendered.contains("< deepspacenine"), rendered)
    }

    func testRecentTextIsEmptyWhenNoEventsRecorded() {
        let log = TerminalEventLog()
        XCTAssertEqual(log.recentText(maxLines: 50), "")
    }

    func testRecentTextRespectsWholeChunkBoundariesUnderALineBudget() {
        let log = TerminalEventLog()
        // Each call is a distinct chunk because they alternate kind, guaranteeing separate
        // events regardless of the coalescing-gap timer.
        log.recordInput(bytes("first command\n"))
        log.recordOutput(bytes("first output\n"))
        log.recordInput(bytes("second command\n"))
        log.recordOutput(bytes("second output\n"))

        // A tight budget should still keep newest content and drop the oldest chunk whole,
        // never truncate a chunk mid-way through.
        let rendered = log.recentText(maxLines: 1)
        XCTAssertTrue(rendered.contains("second output"), rendered)
        XCTAssertFalse(rendered.contains("first command"), rendered)
    }

    func testRecentTextOrdersOldestFirst() {
        let log = TerminalEventLog()
        log.recordInput(bytes("one\n"))
        log.recordOutput(bytes("two\n"))

        let rendered = log.recentText(maxLines: 100)
        let oneRange = rendered.range(of: "one")
        let twoRange = rendered.range(of: "two")
        XCTAssertNotNil(oneRange)
        XCTAssertNotNil(twoRange)
        if let oneRange, let twoRange {
            XCTAssertLessThan(oneRange.lowerBound, twoRange.lowerBound)
        }
    }

    // MARK: - outputText(after:) — the send_input await path

    func testOutputTextAfterEventExcludesEarlierEventsAndAllInput() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("old output\n"))
        let baseline = log.events.last?.id
        log.recordInput(bytes("what time is it?\r"))
        log.recordOutput(bytes("It is 6:58 PM.\n"))

        let text = log.outputText(after: baseline)
        XCTAssertTrue(text.contains("It is 6:58 PM."), text)
        XCTAssertFalse(text.contains("old output"), text)
        XCTAssertFalse(text.contains("what time is it?"), "input must not count as response: \(text)")
    }

    func testOutputTextAfterNilReturnsAllOutput() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("first\n"))
        log.recordInput(bytes("x"))
        log.recordOutput(bytes("second\n"))

        let text = log.outputText(after: nil)
        XCTAssertTrue(text.contains("first"), text)
        XCTAssertTrue(text.contains("second"), text)
    }

    func testOutputTextAfterEvictedEventFallsBackToEverything() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("only\n"))
        // An id that never existed behaves like one evicted by the event cap.
        let text = log.outputText(after: UUID())
        XCTAssertTrue(text.contains("only"), text)
    }

    /// A long await can outlive the 500-event cap: the baseline event gets evicted, and
    /// without the timestamp fallback the render would present pre-command scrollback as
    /// the command's response.
    func testEvictedBaselineWithTimestampFallbackExcludesOlderOutput() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("pre-command scrollback\n"))
        let sentAt = Date()
        // Baseline id evicted (simulated with a never-existed id); newer output only.
        log.recordInput(bytes("x"))
        log.recordOutput(bytes("the real response\n"))

        let text = log.outputText(after: UUID(), orRecordedAfter: sentAt)
        XCTAssertTrue(text.contains("the real response"), text)
        XCTAssertFalse(text.contains("pre-command scrollback"), text)
    }

    func testOutputTextEmptyWhenNothingPrintedAfterBaseline() {
        let log = TerminalEventLog()
        log.recordOutput(bytes("before\n"))
        let baseline = log.events.last?.id
        log.recordInput(bytes("fire and forget\r"))

        XCTAssertEqual(log.outputText(after: baseline), "")
    }

    func testRecentTextTruncatesToCharacterBudgetWithEllipsisPrefix() {
        let log = TerminalEventLog()
        log.recordOutput(bytes(String(repeating: "x", count: 500)))

        let rendered = log.recentText(maxLines: 100, maxCharacters: 50)
        // Truncation prepends "…\n" (2 characters) ahead of the character-budget suffix.
        XCTAssertLessThanOrEqual(rendered.count, 52)
        XCTAssertTrue(rendered.hasPrefix("\u{2026}"), rendered)
    }
}

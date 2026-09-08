import XCTest
@testable import FinAgentCore

/// `send_session`'s validator and its fixed argv — the write half of the private-socket
/// design, and deliberately stricter than `TmuxSessionRead`'s. No tmux process is
/// started here; the argv is built and inspected as strings, same as `TmuxSessionReadTests`.
final class TmuxSessionSendTests: XCTestCase {

    // MARK: - Target validation: the bare-name refusal is the whole point

    func testExplicitSessionColonWindowTargetsAreAccepted() {
        for target in ["main:0", "main:2", "fin:1.0", "agent-2026.09.06:3"] {
            XCTAssertEqual(TmuxSessionSend.validateTarget(name: target), target,
                          "\(target) must be accepted")
        }
    }

    func testBareNamesAreRefusedEvenWhenTheyWouldValidateForReading() {
        // Every one of these passes TmuxSessionRead.validate — that is exactly why the
        // send-side check must be strictly stronger, not merely different.
        for bare in ["main", "pocketdj", "fin", "africanintellect"] {
            XCTAssertNotNil(TmuxSessionRead.validate(name: bare), "\(bare) should read-validate")
            XCTAssertNil(TmuxSessionSend.validateTarget(name: bare),
                        "\(bare) must be refused for sending — no colon, no target")
        }
    }

    func testIllegalCharactersAreStillRefused() {
        for hostile in ["main:0; rm -rf /", "-x:0", "main:0 && evil", ""] {
            XCTAssertNil(TmuxSessionSend.validateTarget(name: hostile))
        }
    }

    func testTargetRejectionMessagePointsAtReadSessionAsTheFix() {
        let message = TmuxSessionSend.targetRejectionMessage(for: "pocketdj")
        XCTAssertTrue(message.contains("read_session"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("exact"))
    }

    // MARK: - Text validation

    func testOrdinaryTextIsAcceptedAndTrimmed() {
        XCTAssertEqual(TmuxSessionSend.validateText("  hello there  "), "hello there")
    }

    func testEmptyOrWhitespaceOnlyTextIsRejected() {
        XCTAssertNil(TmuxSessionSend.validateText(""))
        XCTAssertNil(TmuxSessionSend.validateText("   \n\t "))
    }

    func testTextAtExactlyTheLimitIsAccepted() {
        let text = String(repeating: "x", count: TmuxSessionSend.maxTextLength)
        XCTAssertEqual(TmuxSessionSend.validateText(text), text)
    }

    func testTextOverTheLimitIsRejected() {
        let text = String(repeating: "x", count: TmuxSessionSend.maxTextLength + 1)
        XCTAssertNil(TmuxSessionSend.validateText(text))
    }

    /// THE CRITICAL REGRESSION: `send-keys -l` delivers `text` to the target pty as
    /// literal BYTES, and an embedded `\n` IS a real newline byte there — the target's
    /// own line discipline treats it exactly like a keypress and submits everything
    /// before it immediately, with zero involvement from the later, deliberate Enter
    /// call. Confirmed live against real tmux (not just asserted here): a two-line
    /// `send-keys -l` string ran its first line and printed output before any Enter
    /// command was ever issued. So "one call, one line, submitted once" must be enforced
    /// here — an internal newline is not cosmetic whitespace to tolerate, it is a second,
    /// uncontrolled submission.
    func testTextContainingAnEmbeddedNewlineIsRejected() {
        XCTAssertNil(TmuxSessionSend.validateText("line one\nline two"))
        XCTAssertNil(TmuxSessionSend.validateText("line one\rline two"))
    }

    /// THE ACTUAL BUG CAUGHT WRITING THE FIRST VERSION OF THIS FIX: `\r\n` is ONE
    /// extended grapheme cluster in Swift's `String`/`Character` model (Unicode's CRLF
    /// rule), so a naive `trimmed.contains("\n")` / `.contains("\r")` check — each
    /// looking for a STANDALONE grapheme cluster — independently returns false against
    /// text whose only line break is "\r\n": neither needle equals that combined
    /// cluster. A Windows-style-newline message sailed straight through the very check
    /// meant to stop it, silently, with zero test failure — until this exact case was
    /// tested on its own instead of folded into a loop with the simpler cases. Pinned
    /// permanently, separately, so it can never regress unnoticed again.
    func testTextContainingWindowsStyleCRLFIsRejected() {
        XCTAssertNil(TmuxSessionSend.validateText("line one\r\nline two"))
    }

    func testTextRejectionMessageNamesTheNewlineSpecifically() {
        let message = TmuxSessionSend.textRejectionMessage(for: "line one\nline two")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("newline"), "got: \(message)")
    }

    // MARK: - The fixed argv

    func testSendTextArgumentsUseLiteralModeAndADashDashGuard() {
        let argv = TmuxSessionSend.sendTextArguments(session: "main:0", text: "-x --help")
        XCTAssertEqual(argv, ["tmux", "send-keys", "-l", "-t", "main:0", "--", "-x --help"])
    }

    func testSendEnterArgumentsSendARealKeyNameNotLiteralText() {
        let argv = TmuxSessionSend.sendEnterArguments(session: "main:0")
        XCTAssertEqual(argv, ["tmux", "send-keys", "-t", "main:0", "Enter"])
        XCTAssertFalse(argv.contains("-l"), "Enter must be a real key press, not literal text")
    }

    /// A message that happens to spell a key name ("Enter", "C-c") must still be typed
    /// literally, not interpreted — this is exactly what `-l` on the TEXT call (and its
    /// absence on the Enter call) is for.
    func testAMessageThatLooksLikeAKeyNameStillGoesThroughLiteralMode() {
        let argv = TmuxSessionSend.sendTextArguments(session: "main:0", text: "Enter")
        XCTAssertTrue(argv.contains("-l"), "must stay in literal mode even for key-name-shaped text")
    }

    // MARK: - Await clamping

    func testOmittedOrZeroAwaitSecondsMeansNoWait() {
        XCTAssertEqual(TmuxSessionSend.clampAwaitSeconds(nil), 0)
        XCTAssertEqual(TmuxSessionSend.clampAwaitSeconds(0), 0)
        XCTAssertEqual(TmuxSessionSend.clampAwaitSeconds(-5), 0)
    }

    func testAwaitSecondsIsClampedToTheCeiling() {
        XCTAssertEqual(TmuxSessionSend.clampAwaitSeconds(TmuxSessionSend.maxAwaitSeconds + 500),
                      TmuxSessionSend.maxAwaitSeconds)
    }

    func testAnOrdinaryAwaitSecondsPassesThroughUnchanged() {
        XCTAssertEqual(TmuxSessionSend.clampAwaitSeconds(15), 15)
    }
}

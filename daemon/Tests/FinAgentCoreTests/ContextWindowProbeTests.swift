import XCTest
@testable import FinAgentCore

/// The 2026-09-16 root cause: the daemon was configured for 32768 context tokens while
/// the model was loaded at 8192, and nothing reconciled the two. Every budget derives
/// from that number — including how much of a pane capture one tool result may carry —
/// so a single capture was allowed to be larger than the whole real window, and the turn
/// came back EMPTY rather than erroring. Three live requests died as "the model stopped
/// without producing an answer" with the real cause nowhere in sight.
final class ContextWindowProbeTests: XCTestCase {

    /// Verbatim from the live endpoint, probed at 16:38Z.
    private let realRefusal = #"{"error":"Engine protocol predict request returned 400: {\"error\":{\"code\":400,\"message\":\"request (9025 tokens) exceeds the available context size (8192 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":9025,\"n_ctx\":8192}}"}"#

    func testTheRealRefusalYieldsTheRealWindowAndNotThePromptSize() {
        XCTAssertEqual(ContextWindowProbe.windowTokens(fromRefusal: realRefusal), 8192,
                       "9025 is the prompt that was refused, not the window")
    }

    func testTheProseFormAloneIsEnough() {
        let body = "request (9025 tokens) exceeds the available context size (4096 tokens), try increasing it"
        XCTAssertEqual(ContextWindowProbe.windowTokens(fromRefusal: body), 4096)
    }

    func testAnUnrelatedBadRequestKeepsItsOwnMeaning() {
        XCTAssertNil(ContextWindowProbe.windowTokens(
            fromRefusal: #"{"error":{"message":"unknown parameter: stream_options"}}"#))
        XCTAssertNil(ContextWindowProbe.windowTokens(
            fromRefusal: #"{"error":{"message":"model not found: gemma-99"}}"#))
    }

    func testOnlyClaimingMoreThanTheServerHasIsTheBug() {
        // The live mismatch.
        XCTAssertTrue(ContextWindowProbe.isOverstated(configured: 32768, serverWindow: 8192))
        // An agent may legitimately use less of a larger window.
        XCTAssertFalse(ContextWindowProbe.isOverstated(configured: 8192, serverWindow: 32768))
        XCTAssertFalse(ContextWindowProbe.isOverstated(configured: 8192, serverWindow: 8192))
    }

    func testTheOperatorMessageNamesBothNumbersAndTheFix() {
        let message = ContextWindowProbe.mismatchMessage(configured: 32768, serverWindow: 8192)
        XCTAssertTrue(message.contains("32768"))
        XCTAssertTrue(message.contains("8192"))
        XCTAssertTrue(message.contains("contextWindowTokens"),
                      "the operator must be told which knob to turn")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("empty completions"),
                      "and which symptom this explains")
    }
}

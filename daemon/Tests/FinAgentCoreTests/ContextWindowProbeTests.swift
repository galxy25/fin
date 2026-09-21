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

    /// Verbatim from the iMac's live `audit.jsonl`, 218 occurrences over two days
    /// (2026-09-20). No digits at all — `windowTokens` correctly returns nil for it, but
    /// callers that stopped at `windowTokens != nil` never noticed this WAS a context
    /// overflow and never fell back to inferring a number. `isContextOverflow` is what a
    /// caller checks instead.
    private let bareOverflow = #"{"code":500,"message":"Context size has been exceeded.","type":"server_error"}"#

    func testTheBareOverflowIsRecognizedEvenWithNoNumber() {
        XCTAssertTrue(ContextWindowProbe.isContextOverflow(bareOverflow))
        XCTAssertNil(ContextWindowProbe.windowTokens(fromRefusal: bareOverflow),
                     "no digits to parse — this is exactly the case isContextOverflow exists for")
    }

    func testIsContextOverflowAgreesWithWindowTokensOnEveryOtherCase() {
        XCTAssertTrue(ContextWindowProbe.isContextOverflow(realRefusal))
        XCTAssertFalse(ContextWindowProbe.isContextOverflow(#"{"error":{"message":"model not found: gemma-99"}}"#))
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

/// Reading the real window off the endpoint, and putting it in traces — the telemetry
/// that was missing on 2026-09-16, when nothing anywhere recorded how much of the window
/// a turn had used or how much of it existed.
final class ContextWindowTelemetryTests: XCTestCase {

    /// Verbatim from `GET /api/v0/models` on the live endpoint, 17:12Z.
    private let liveListing = Data("""
    {"data":[
      {"id":"google/gemma-4-12b-qat","object":"model","type":"vlm","publisher":"google",
       "arch":"gemma4","compatibility_type":"gguf","quantization":"Q4_0","state":"loaded",
       "max_context_length":262144,"loaded_context_length":32768,"capabilities":["tool_use"]},
      {"id":"qwen/qwen3.6-27b","object":"model","state":"not-loaded","max_context_length":262144}
    ]}
    """.utf8)

    func testTheLoadedWindowAndTheCeilingBothComeBack() {
        let reading = ContextWindowProbe.reading(fromModelsListing: liveListing, model: "google/gemma-4-12b-qat")
        XCTAssertEqual(reading?.loadedTokens, 32768)
        XCTAssertEqual(reading?.maxTokens, 262144, "the ceiling is what says whether to ask for more")
        XCTAssertEqual(reading?.source, .modelsAPI)
    }

    func testAModelThatIsNotLoadedReportsNoWindow() {
        XCTAssertNil(ContextWindowProbe.reading(fromModelsListing: liveListing, model: "qwen/qwen3.6-27b"))
    }

    func testAnUnknownModelReportsNothingRatherThanTheWrongModelsWindow() {
        XCTAssertNil(ContextWindowProbe.reading(fromModelsListing: liveListing, model: "google/gemma-4-26b-a4b"))
    }

    func testTheLoadedInstanceWinsWhenTwoOfTheSameModelAreResident() {
        // Exactly what an `lms load` beside a JIT reload produced on 2026-09-16.
        let both = Data("""
        {"data":[
          {"id":"google/gemma-4-12b-qat","state":"not-loaded","loaded_context_length":8192},
          {"id":"google/gemma-4-12b-qat","state":"loaded","loaded_context_length":32768}
        ]}
        """.utf8)
        XCTAssertEqual(
            ContextWindowProbe.reading(fromModelsListing: both, model: "google/gemma-4-12b-qat")?.loadedTokens,
            32768
        )
    }

    /// LM Studio answers an unknown path with HTTP 200 and an error body, so a probe that
    /// trusted the status code would read a window out of a failure.
    func testAnErrorBodyServedWithHTTP200IsNotAReading() {
        let body = Data(#"{"error":"Unexpected endpoint or method. (GET /props)"}"#.utf8)
        XCTAssertNil(ContextWindowProbe.reading(fromModelsListing: body, model: "google/gemma-4-12b-qat"))
    }

    func testTheStandardModelsListingCarriesNoWindowWhichIsTheWholeProblem() {
        // `/v1/models` — what every server implements — reports nothing about the window.
        let standard = Data(#"{"data":[{"id":"google/gemma-4-12b-qat","object":"model","owned_by":"x"}]}"#.utf8)
        XCTAssertNil(ContextWindowProbe.reading(fromModelsListing: standard, model: "google/gemma-4-12b-qat"))
    }

    func testTheProbeURLIsDerivedFromWhateverVersionSegmentTheChatEndpointCarries() {
        for base in ["http://127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1/", "http://127.0.0.1:1234"] {
            XCTAssertEqual(
                ContextWindowProbe.modelsAPIURL(forBaseURL: base)?.absoluteString,
                "http://127.0.0.1:1234/api/v0/models",
                "failed for \(base)"
            )
        }
    }

    // MARK: - The trace line

    func testTheTraceLineNamesHeadroomAndProvenance() {
        let reading = ContextWindowReading(loadedTokens: 32768, maxTokens: 262144, source: .modelsAPI)
        let line = reading.turnTelemetry(promptTokens: 5_930, completionTokens: 412, outputReserve: 2_048)
        XCTAssertTrue(line.contains("5930/32768"))
        XCTAssertTrue(line.contains("18%"))
        XCTAssertTrue(line.contains("room for the answer 24790"))
        XCTAssertTrue(line.contains("models_api"), "a number without its provenance is what caused this")
    }

    func testTheExactShapeOfTheOutageIsCalledOutInTheLine() {
        // The 8192-window turn that returned empty: prompt + reserve exceeds the window.
        let reading = ContextWindowReading(loadedTokens: 8_192, source: .refusal)
        let line = reading.turnTelemetry(promptTokens: 6_500, completionTokens: nil, outputReserve: 2_048)
        XCTAssertTrue(line.contains("OVER BUDGET by 356"))
        XCTAssertTrue(line.localizedCaseInsensitiveContains("empty reply"),
                      "the line must name the symptom it predicts")
        XCTAssertTrue(reading.isStarvedOfOutputRoom(promptTokens: 6_500, outputReserve: 2_048))
    }

    func testAHealthyTurnIsNotFlaggedAsStarved() {
        let reading = ContextWindowReading(loadedTokens: 32_768, source: .modelsAPI)
        XCTAssertFalse(reading.isStarvedOfOutputRoom(promptTokens: 6_500, outputReserve: 2_048))
    }

    func testAConfiguredReadingIsLabelledAsUnverified() {
        let reading = ContextWindowReading(loadedTokens: 32_768, source: .configured)
        XCTAssertTrue(reading.summary.contains("configured"),
                      "a hoped-for number must never read as an observed one")
    }
}

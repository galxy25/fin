import XCTest
@testable import FinAgentCore

/// Everything that had to be true before a HOSTED model (OpenRouter and friends) could be
/// Fin's brain. Each case here is one finding from the 2026-09-16 feasibility audit.
final class HostedBrainTests: XCTestCase {

    // MARK: - A failure that arrives after the 200

    /// The shape OpenRouter actually sends: 200 OK, then an error frame mid-stream.
    private func frame(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testAProviderErrorFrameIsReadAsAFailureWithItsStatus() {
        let object = frame(#"{"error":{"code":429,"message":"rate limited by upstream"}}"#)
        guard case .streamFailure(let status, let message)? = AgentEndpointClient.streamFailure(in: object) else {
            return XCTFail("a mid-stream error frame must not be silently ignored")
        }
        XCTAssertEqual(status, 429)
        XCTAssertTrue(message.contains("rate limited by upstream"))
    }

    func testTheUpstreamProvidersOwnWordsSurvive() {
        let object = frame(#"""
        {"error":{"code":502,"message":"Provider returned error",
          "metadata":{"provider_name":"Anthropic","raw":"overloaded_error: server busy"}}}
        """#)
        guard case .streamFailure(_, let message)? = AgentEndpointClient.streamFailure(in: object) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("overloaded_error: server busy"),
                      "the aggregator's passthrough is the only useful part of this error")
    }

    func testACodeDeliveredAsAStringStillClassifies() {
        // Some OpenAI-dialect servers send `"code": "429"`.
        let object = frame(#"{"error":{"code":"429","message":"slow down"}}"#)
        XCTAssertEqual(AgentEndpointClient.streamFailure(in: object)?.statusCode, 429)
    }

    func testABareStringErrorIsStillAFailure() {
        let object = frame(#"{"error":"something went wrong"}"#)
        guard case .streamFailure(let status, let message)? = AgentEndpointClient.streamFailure(in: object) else {
            return XCTFail("expected a failure")
        }
        XCTAssertNil(status)
        XCTAssertEqual(message, "something went wrong")
    }

    func testAnOrdinaryContentFrameIsNotAFailure() {
        XCTAssertNil(AgentEndpointClient.streamFailure(in: frame(
            #"{"choices":[{"delta":{"content":"hello"}}]}"#
        )))
        XCTAssertNil(AgentEndpointClient.streamFailure(in: frame(
            #"{"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        )))
    }

    // MARK: - Retry rules judged on the status, wherever it arrived

    func testAMidStreamRateLimitIsRetriedLikeAStatusLineOne() {
        XCTAssertTrue(AgentTurnLogic.isRetryableEndpointError(
            AgentEndpointError.streamFailure(status: 429, message: "rate limited")))
        XCTAssertTrue(AgentTurnLogic.isRetryableEndpointError(
            AgentEndpointError.http(status: 429, body: "")))
    }

    func testAMidStreamAuthFailureIsNotRetried() {
        // Retrying a revoked key just spends the remaining budget faster.
        for status in [401, 402, 403] {
            XCTAssertFalse(
                AgentTurnLogic.isRetryableEndpointError(
                    AgentEndpointError.streamFailure(status: status, message: "nope")),
                "HTTP \(status) must not be retried"
            )
        }
    }

    func testAMidStreamFailureWithNoCodeIsRetriedLikeADroppedConnection() {
        XCTAssertTrue(AgentTurnLogic.isRetryableEndpointError(
            AgentEndpointError.streamFailure(status: nil, message: "stream ended early")))
    }

    // MARK: - Retry-After

    func testRetryAfterSurvivesIntoTheErrorAndBackOut() {
        let body = "[retry-after: 60s] {\"error\":\"rate limited\"}"
        XCTAssertEqual(AgentEndpointClient.retryAfterSeconds(inErrorBody: body), 60)
    }

    func testAnErrorWithoutARetryAfterYieldsNothing() {
        XCTAssertNil(AgentEndpointClient.retryAfterSeconds(inErrorBody: #"{"error":"nope"}"#))
    }

    func testTheRetryAfterCapIsShorterThanAPersonsPatience() {
        XCTAssertLessThanOrEqual(AgentTurnEngine.maxRetryAfterSeconds, 120,
                                 "a turn the owner is waiting on must not be parked for minutes")
    }

    // MARK: - Brain outages: the failures no restart fixes

    func testCredentialAndPaymentFailuresAreClassified() {
        XCTAssertEqual(BrainOutage.forStatus(401), .credentials)
        XCTAssertEqual(BrainOutage.forStatus(403), .credentials)
        XCTAssertEqual(BrainOutage.forStatus(402), .payment)
    }

    func testTransientsAreNotBrainOutages() {
        for status in [408, 429, 500, 502, 503, 200, 404] {
            XCTAssertNil(BrainOutage.forStatus(status), "HTTP \(status) is not a permanent outage")
        }
        XCTAssertNil(BrainOutage.forError(AgentEndpointError.transport("connection reset")))
    }

    func testAnOutageIsClassifiedFromAMidStreamFailureToo() {
        // The whole point: on a hosted endpoint this arrives inside a 200.
        XCTAssertEqual(
            BrainOutage.forError(AgentEndpointError.streamFailure(status: 402, message: "no credit")),
            .payment
        )
    }

    func testTheOwnerMessageNamesTheFixNotJustTheSymptom() {
        XCTAssertTrue(BrainOutage.credentials.ownerMessage.contains("apiKey"))
        XCTAssertTrue(BrainOutage.credentials.ownerMessage.localizedCaseInsensitiveContains("newline"),
                      "the trailing-newline trap is the likeliest cause and must be named")
        XCTAssertTrue(BrainOutage.payment.ownerMessage.localizedCaseInsensitiveContains("credit"))
    }

    // MARK: - The context window on a hosted endpoint

    func testTheModelsAPIURLNoLongerDoublesTheAPISegment() {
        XCTAssertEqual(
            ContextWindowProbe.modelsAPIURL(forBaseURL: "https://openrouter.ai/api/v1")?.absoluteString,
            "https://openrouter.ai/api/v0/models",
            "stripping only /v1 left …/api and built …/api/api/v0/models, a 404 that read as 'dialect unsupported'"
        )
        // The local case must not regress.
        XCTAssertEqual(
            ContextWindowProbe.modelsAPIURL(forBaseURL: "http://127.0.0.1:1234/v1")?.absoluteString,
            "http://127.0.0.1:1234/api/v0/models"
        )
    }

    func testTheCatalogURLIsTheBasesOwnModelsListing() {
        XCTAssertEqual(
            ContextWindowProbe.catalogURL(forBaseURL: "https://openrouter.ai/api/v1")?.absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
        XCTAssertEqual(
            ContextWindowProbe.catalogURL(forBaseURL: "https://openrouter.ai/api/v1/")?.absoluteString,
            "https://openrouter.ai/api/v1/models",
            "a trailing slash must not produce //models"
        )
    }

    /// Shaped like a real OpenRouter catalog entry.
    private let catalog = Data(#"""
    {"data":[
      {"id":"anthropic/claude-opus-5","context_length":200000,
       "top_provider":{"context_length":128000,"max_completion_tokens":32000},
       "supported_parameters":["tools","temperature"]},
      {"id":"some/other-model","context_length":8192}
    ]}
    """#.utf8)

    func testTheRoutableWindowBeatsTheHeadlineNumber() {
        let reading = ContextWindowProbe.reading(fromCatalog: catalog, model: "anthropic/claude-opus-5")
        XCTAssertEqual(reading?.loadedTokens, 128000,
                       "top_provider is what is actually routable; context_length is the headline")
        XCTAssertEqual(reading?.source, .catalog)
    }

    func testARoutingSuffixStillFindsItsModel() {
        // ":nitro" is a valid request slug that the catalog does not list.
        XCTAssertEqual(
            ContextWindowProbe.reading(fromCatalog: catalog, model: "anthropic/claude-opus-5:nitro")?.loadedTokens,
            128000
        )
    }

    func testAModelWithNoTopProviderFallsBackToItsContextLength() {
        XCTAssertEqual(
            ContextWindowProbe.reading(fromCatalog: catalog, model: "some/other-model")?.loadedTokens,
            8192
        )
    }

    func testAnUnknownModelReadsNothingFromTheCatalog() {
        XCTAssertNil(ContextWindowProbe.reading(fromCatalog: catalog, model: "nobody/nothing"))
    }

    func testACatalogReadingIsLabelledWeakerThanAnObservedOne() {
        let reading = ContextWindowReading(loadedTokens: 128000, source: .catalog)
        XCTAssertTrue(reading.summary.contains("catalog"),
                      "a ceiling must never read as an observed window")
        XCTAssertNotEqual(ContextWindowReading.Source.catalog, .modelsAPI)
    }
}

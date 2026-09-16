import XCTest
@testable import FinAgentCore

/// Opt-in live check: FIN_LIVE_CONTEXT_PROBE=1 swift test --filter LiveContextProbe
/// Exercises the real probe chain — the loaded-window dialect first, the standard
/// catalog second — against both endpoint shapes Fin supports.
final class LiveContextProbeTests: XCTestCase {
    private var live: Bool { ProcessInfo.processInfo.environment["FIN_LIVE_CONTEXT_PROBE"] == "1" }

    func testTheLocalServerReportsItsLoadedWindow() async throws {
        try XCTSkipUnless(live)
        let reading = await ContextWindowProbe.probe(
            baseURL: "http://127.0.0.1:1234/v1", model: "google/gemma-4-12b-qat"
        )
        print("LOCAL:", reading.map(\.summary) ?? "nil")
        XCTAssertEqual(reading?.source, .modelsAPI, "a local server reports what it has LOADED")
    }

    func testAHostedCatalogReportsAContextLength() async throws {
        try XCTSkipUnless(live)
        // Unauthenticated: OpenRouter's catalog is public. No completion is requested,
        // so this spends nothing.
        //
        // The slug is READ FROM THE CATALOG rather than written here. The first draft
        // hardcoded "anthropic/claude-3.5-sonnet", which had already been delisted — the
        // test failed for a reason that had nothing to do with the code under test, which
        // is exactly the rot a live test should not have.
        let base = "https://openrouter.ai/api/v1"
        guard let url = ContextWindowProbe.catalogURL(forBaseURL: base),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["data"] as? [[String: Any]],
              let first = entries.first(where: { ($0["context_length"] as? Int ?? 0) > 0 }),
              let slug = first["id"] as? String
        else { return XCTFail("the public catalog did not answer") }

        let reading = await ContextWindowProbe.probe(baseURL: base, model: slug)
        print("HOSTED:", slug, "->", reading.map(\.summary) ?? "nil")
        XCTAssertEqual(reading?.source, .catalog, "an aggregator publishes a ceiling, not a loaded window")
        XCTAssertGreaterThan(reading?.loadedTokens ?? 0, 0)
    }

    func testARoutingVariantResolvesThroughTheCatalogToo() async throws {
        try XCTSkipUnless(live)
        // ":nitro"-style suffixes are valid request slugs the catalog does not list.
        let reading = await ContextWindowProbe.probe(
            baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-opus-5:nitro"
        )
        print("VARIANT:", reading.map(\.summary) ?? "nil")
        XCTAssertEqual(reading?.source, .catalog)
    }
}

import XCTest
@testable import FinAgentCore

/// Opt-in live check: FIN_LIVE_CONTEXT_PROBE=1 swift test --filter LiveContextProbe
final class LiveContextProbeTests: XCTestCase {
    func testTheProbeReadsTheRealEndpoint() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FIN_LIVE_CONTEXT_PROBE"] == "1")
        let reading = await ContextWindowProbe.probe(
            baseURL: "http://127.0.0.1:1234/v1", model: "google/gemma-4-12b-qat"
        )
        print("LIVE READING:", reading.map(\.summary) ?? "nil")
        XCTAssertNotNil(reading)
        XCTAssertEqual(reading?.source, .modelsAPI)
    }
}

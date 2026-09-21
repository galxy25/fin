import XCTest
@testable import FinAgentCore

/// The marker that makes a learned context ceiling survive a daemon restart. Without it,
/// a ceiling learned from a real refusal is forgotten on every restart and relearned from
/// a fresh round of empty completions — the exact cost `[[fin-pane-reporting-failures]]`
/// and the 2026-09-20 audit measured.
final class ContextWindowMarkerTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "context-window-marker-test-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testARoundTripReturnsTheSameReadingForTheSameModel() {
        let reading = ContextWindowReading(loadedTokens: 8_192, maxTokens: 262_144, source: .refusal)
        ContextWindowMarker.write(reading, modelIdentifier: "google/gemma-4-12b-qat", at: path)
        let restored = ContextWindowMarker.state(at: path, forModel: "google/gemma-4-12b-qat")
        XCTAssertEqual(restored?.loadedTokens, 8_192)
        XCTAssertEqual(restored?.maxTokens, 262_144)
        XCTAssertEqual(restored?.source, .refusal)
    }

    /// The whole reason this marker is keyed to the model at all: LM Studio can swap
    /// models under the same endpoint, and a ceiling learned for one must never clamp a
    /// different one loaded later.
    func testAMarkerFromADifferentModelIsNotApplied() {
        let reading = ContextWindowReading(loadedTokens: 8_192, source: .refusal)
        ContextWindowMarker.write(reading, modelIdentifier: "google/gemma-4-12b-qat", at: path)
        XCTAssertNil(ContextWindowMarker.state(at: path, forModel: "qwen/qwen3.6-27b"))
    }

    func testAMissingFileReadsAsNilNotAsAFailure() {
        XCTAssertNil(ContextWindowMarker.state(at: path, forModel: "any-model"))
    }

    func testACorruptFileReadsAsNil() {
        try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(ContextWindowMarker.state(at: path, forModel: "any-model"))
    }

    func testClearRemovesTheFile() {
        ContextWindowMarker.write(
            ContextWindowReading(loadedTokens: 8_192, source: .refusal),
            modelIdentifier: "m", at: path
        )
        ContextWindowMarker.clear(at: path)
        XCTAssertNil(ContextWindowMarker.state(at: path, forModel: "m"))
    }

    func testAnInferredReadingRoundTripsItsSource() {
        let reading = ContextWindowReading(loadedTokens: 5_500, source: .inferredFromOverflow)
        ContextWindowMarker.write(reading, modelIdentifier: "m", at: path)
        XCTAssertEqual(ContextWindowMarker.state(at: path, forModel: "m")?.source, .inferredFromOverflow)
    }
}

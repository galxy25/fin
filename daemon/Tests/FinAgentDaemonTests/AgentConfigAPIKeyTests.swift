import XCTest
@testable import FinAgentDaemon

/// The trailing-newline trap (2026-09-16 hosted-brain audit): the daemon tested only
/// `!isEmpty` for the bearer token while `launch-agentd.sh` and `enroll-config.py` both
/// `.strip()`. A key copied out of a terminal or a browser — which ordinarily brings a
/// newline with it — therefore PASSED the launchd preflight and 401'd on every real turn.
/// A green light and a dead brain is the worst pair of signals this daemon can produce.
final class AgentConfigAPIKeyTests: XCTestCase {

    private func decode(_ json: String) throws -> DaemonConfig.AgentConfig {
        try JSONDecoder().decode(DaemonConfig.AgentConfig.self, from: Data(json.utf8))
    }

    func testATrailingNewlineIsTrimmedOffTheKey() throws {
        let config = try decode(#"""
        {"endpointURL":"https://openrouter.ai/api/v1","modelIdentifier":"anthropic/claude-opus-5",
         "apiKey":"sk-or-v1-abc123\n"}
        """#)
        XCTAssertEqual(config.apiKey, "sk-or-v1-abc123")
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let config = try decode(#"""
        {"endpointURL":"x","modelIdentifier":"y","apiKey":"  sk-or-v1-abc123\t "}
        """#)
        XCTAssertEqual(config.apiKey, "sk-or-v1-abc123")
    }

    func testAnAllWhitespaceKeyIsNoKeyAtAll() throws {
        // Otherwise it is "non-empty" and the Authorization header goes out blank.
        let config = try decode(#"{"endpointURL":"x","modelIdentifier":"y","apiKey":"   \n"}"#)
        XCTAssertNil(config.apiKey)
    }

    func testAMissingKeyStaysNil() throws {
        let config = try decode(#"{"endpointURL":"x","modelIdentifier":"y"}"#)
        XCTAssertNil(config.apiKey)
    }

    /// The explicit CodingKeys added alongside the trim must not have dropped a field.
    func testEveryOtherAgentFieldStillDecodes() throws {
        let config = try decode(#"""
        {"endpointURL":"https://openrouter.ai/api/v1","modelIdentifier":"m","apiKey":"k",
         "contextWindowTokens":128000,"maxOutputTokens":4096,"temperature":0.3,
         "systemPrompt":"be brief","terminalContextLines":120,"heartbeatSeconds":900,
         "requestTimeoutSeconds":300}
        """#)
        XCTAssertEqual(config.endpointURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(config.modelIdentifier, "m")
        XCTAssertEqual(config.apiKey, "k")
        XCTAssertEqual(config.contextWindowTokens, 128000)
        XCTAssertEqual(config.maxOutputTokens, 4096)
        XCTAssertEqual(config.temperature, 0.3)
        XCTAssertEqual(config.systemPrompt, "be brief")
        XCTAssertEqual(config.terminalContextLines, 120)
        XCTAssertEqual(config.heartbeatSeconds, 900)
        XCTAssertEqual(config.requestTimeoutSeconds, 300)
    }
}

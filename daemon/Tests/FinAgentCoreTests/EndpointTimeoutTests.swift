import XCTest
@testable import FinAgentCore

final class EndpointTimeoutTests: XCTestCase {
    func testClientTakesTheProcessDefaultAndCanBeOverridden() {
        let saved = AgentEndpointClient.defaultRequestTimeout
        defer { AgentEndpointClient.defaultRequestTimeout = saved }
        AgentEndpointDefaults.setRequestTimeout(seconds: 300)
        XCTAssertEqual(AgentEndpointDefaults.requestTimeoutSeconds, 300)
        AgentEndpointDefaults.setRequestTimeout(seconds: 5)
        XCTAssertEqual(AgentEndpointDefaults.requestTimeoutSeconds, 30, "floor")
        AgentEndpointDefaults.setRequestTimeout(seconds: 300)
        let client = AgentEndpointClient(baseURL: "http://127.0.0.1:1234/v1", model: "m", apiKey: nil, temperature: 0.2, maxOutputTokens: 512)
        XCTAssertEqual(client.requestTimeout, 300)
        var custom = client
        custom.requestTimeout = 45
        XCTAssertEqual(custom.requestTimeout, 45)
    }
}

import XCTest
@testable import fin

/// The three relay-opening calls can launch an EC2 relay and wait for its address (~10 s),
/// so they must outlive the 10-second timeout every other control-plane call uses — with it,
/// the first terminal/desktop/browser open after a quiet spell reported "could not reach the
/// control plane" while the relay booted. And a transport failure must leave its reason
/// behind (domain, code, elapsed) instead of collapsing to a bare "network".
final class RelayOpenTimeoutTests: XCTestCase {
    private var savedTransport: ControlPlaneClient.Transport!
    private var savedEndpoint = ""
    private var savedToken = ""

    override func setUp() {
        super.setUp()
        savedTransport = ControlPlaneClient.transport
        savedEndpoint = CloudControlPlaneConfig.endpointURL
        savedToken = CloudControlPlaneConfig.token
        CloudControlPlaneConfig.setEndpointURL("https://cp.example")
        CloudControlPlaneConfig.setToken("cp-token")
    }

    override func tearDown() {
        ControlPlaneClient.transport = savedTransport
        CloudControlPlaneConfig.setEndpointURL(savedEndpoint)
        CloudControlPlaneConfig.setToken(savedToken)
        super.tearDown()
    }

    func testRelayOpeningCallsUseTheLongTimeout() async {
        var timeouts: [TimeInterval] = []
        ControlPlaneClient.transport = { request in
            timeouts.append(request.timeoutInterval)
            throw URLError(.timedOut)
        }
        _ = await ControlPlaneClient.openTerminalRelay("s1", sessionId: "a", tmuxSession: "main")
        _ = await ControlPlaneClient.openBrowserRelay("s1", sessionId: "b")
        _ = await ControlPlaneClient.openDesktopRelay("s1", sessionId: "d")
        XCTAssertEqual(timeouts, [ControlPlaneClient.relayOpenTimeout, ControlPlaneClient.relayOpenTimeout, ControlPlaneClient.relayOpenTimeout])
        XCTAssertGreaterThan(ControlPlaneClient.relayOpenTimeout, 20)
    }

    func testOrdinaryCallsKeepTheShortTimeout() async {
        var seen: TimeInterval?
        ControlPlaneClient.transport = { request in seen = request.timeoutInterval; throw URLError(.timedOut) }
        _ = await ControlPlaneClient.perform(ControlPlaneClient.request("GET", path: "/sites"))
        XCTAssertEqual(seen, ControlPlaneClient.requestTimeout)
    }

    func testATransportFailureLeavesItsReason() async {
        ControlPlaneClient.transport = { _ in throw URLError(.timedOut) }
        let result = await ControlPlaneClient.perform(ControlPlaneClient.request("GET", path: "/sites"))
        XCTAssertEqual(result.failureValue, .network)
        let detail = ControlPlaneClient.lastTransportError ?? ""
        XCTAssertTrue(detail.contains("NSURLErrorDomain"), detail)
        XCTAssertTrue(detail.contains("-1001"), detail)   // timed out
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}

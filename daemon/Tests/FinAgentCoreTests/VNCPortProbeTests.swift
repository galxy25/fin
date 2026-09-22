import XCTest
@testable import FinAgentCore

/// `VNCPortProbe` — the loopback connect-and-close that decides half of the
/// `vnc_proxy` capability (docs/VNC.md §2). The other half is the config opt-in,
/// which is a plain boolean and needs no test of its own; this is the half that
/// talks to the world and therefore the half that can be wrong.
final class VNCPortProbeTests: XCTestCase {
    /// Binds an ephemeral loopback port and starts listening, returning the port and a
    /// close handle. Real sockets on purpose: the whole value of this probe is that it
    /// answers with a TCP fact rather than a service-state reading, so a test that
    /// mocked the socket away would be testing nothing this file actually does.
    private func listeningPort() throws -> (port: UInt16, close: () -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "no socket available in this environment")
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // ephemeral: the kernel picks a free one
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        // Darwin.bind explicitly: a bare `bind` resolves to XCTestCase's own inherited
        // instance method, not the socket call.
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "could not bind a loopback port in this environment")
        try XCTSkipIf(listen(fd, 1) != 0, "could not listen in this environment")

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (UInt16(bigEndian: actual.sin_port), { close(fd) })
    }

    func testReachableWhenSomethingIsListening() throws {
        let listener = try listeningPort()
        defer { listener.close() }
        XCTAssertTrue(VNCPortProbe.isReachable(port: listener.port))
    }

    func testNotReachableOnceTheListenerGoesAway() throws {
        let listener = try listeningPort()
        let port = listener.port
        listener.close()
        // The capability has to self-correct within one heartbeat when Screen Sharing is
        // switched off outside Fin's control — that is this assertion, in miniature.
        XCTAssertFalse(VNCPortProbe.isReachable(port: port))
    }

    func testAMalformedHostIsNotReachableRatherThanAnError() {
        // "not reachable" and "not there" are the same answer to the only question the
        // capability asks, so every failure mode collapses to false rather than throwing
        // into the heartbeat's path.
        XCTAssertFalse(VNCPortProbe.isReachable(host: "not-an-address", port: 5900))
    }

    func testTheDefaultPortIsScreenSharings() {
        XCTAssertEqual(VNCPortProbe.port, 5900)
    }
}

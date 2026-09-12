import XCTest
@testable import FinAgentDaemon
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `DaemonDeviceStatusClient` — GET /devices/status, filtered to other devices'
/// fresh-enough rows and formatted into the compaction prompt's one-line-per-device
/// shape. No real network calls: every test injects `transport`.
@MainActor
final class DaemonDeviceStatusClientTests: XCTestCase {
    private func makeClient(
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> (client: DaemonDeviceStatusClient, auditLines: () -> [String]) {
        var lines: [String] = []
        let client = DaemonDeviceStatusClient(
            endpointURL: "https://cp.example",
            token: "cp-token",
            audit: { lines.append($0) }
        )
        client.transport = transport
        return (client, { lines })
    }

    private func ok(_ body: String, for request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - otherDevices

    func testOtherDevicesReturnsOnlyTheFreshNonSelfDevice() async {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let fresh = iso.string(from: now.addingTimeInterval(-5 * 60)) // 5m ago: within 2h maxAge
        let stale = iso.string(from: now.addingTimeInterval(-3 * 60 * 60)) // 3h ago: past 2h maxAge
        let selfFresh = iso.string(from: now.addingTimeInterval(-1 * 60))

        let body = """
        {"devices": [
          {"device": "Self Mac", "device_id8": "abcd1234", "agent": "Fin", "state": "idle", "updated_at": "\(selfFresh)"},
          {"device": "Fresh MacBook", "device_id8": "11112222", "agent": "Fin", "state": "idle", "updated_at": "\(fresh)"},
          {"device": "Stale iPhone", "device_id8": "33334444", "agent": "Fin", "state": "idle", "updated_at": "\(stale)"}
        ]}
        """
        let (client, _) = makeClient { request in self.ok(body, for: request) }

        let others = await client.otherDevices(excludingDeviceID8: "abcd1234", now: now)

        XCTAssertEqual(others.map(\.device_id8), ["11112222"], "must exclude self and drop anything past maxAge")
    }

    func testOtherDevicesReturnsEmptyOnTransportFailure() async {
        let (client, auditLines) = makeClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let others = await client.otherDevices(excludingDeviceID8: "abcd1234")
        XCTAssertTrue(others.isEmpty)
        XCTAssertTrue(auditLines().contains { $0.contains("status fetch failed") })
    }

    func testOtherDevicesReturnsEmptyOnMalformedBody() async {
        let (client, _) = makeClient { request in self.ok("not json", for: request) }
        let others = await client.otherDevices(excludingDeviceID8: "abcd1234")
        XCTAssertTrue(others.isEmpty)
    }

    // MARK: - formatLine

    func testFormatLinePinsTheExactStringForAFullRecord() {
        let now = Date()
        let updated = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 60))
        let device = DaemonDeviceStatusClient.DeviceStatus(
            device: "MacBook", device_id8: "11112222", agent: "Fin",
            state: "idle", last_turn_at: nil, updated_at: updated
        )
        XCTAssertEqual(
            DaemonDeviceStatusClient.formatLine(device, now: now),
            "MacBook — idle, working on Fin, last seen 3m ago"
        )
    }

    func testFormatLineFallsBackForARecordMissingEveryOptionalField() {
        let now = Date()
        let device = DaemonDeviceStatusClient.DeviceStatus(
            device: nil, device_id8: "abcd1234", agent: nil,
            state: nil, last_turn_at: nil, updated_at: nil
        )
        XCTAssertEqual(
            DaemonDeviceStatusClient.formatLine(device, now: now),
            "device-abcd1234 — unknown, working on no agent, last seen unknown"
        )
    }

    // MARK: - relativeTimeLabel

    func testRelativeTimeLabelBuckets() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(DaemonDeviceStatusClient.relativeTimeLabel(iso: iso.string(from: now.addingTimeInterval(-10)), now: now), "just now")
        XCTAssertEqual(DaemonDeviceStatusClient.relativeTimeLabel(iso: iso.string(from: now.addingTimeInterval(-5 * 60)), now: now), "5m ago")
        XCTAssertEqual(DaemonDeviceStatusClient.relativeTimeLabel(iso: iso.string(from: now.addingTimeInterval(-2 * 3600)), now: now), "2h ago")
        XCTAssertEqual(DaemonDeviceStatusClient.relativeTimeLabel(iso: iso.string(from: now.addingTimeInterval(-3 * 86400)), now: now), "3d ago")
        XCTAssertEqual(DaemonDeviceStatusClient.relativeTimeLabel(iso: nil, now: now), "unknown")
    }
}

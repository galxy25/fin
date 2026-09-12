import XCTest
import SwiftData
@testable import fin

/// Exercises `AgentMemorySyncService` — the app-side half of "the memory is something
/// that both the client side and cloud agents should keep in sync" — against an
/// in-memory container and an injected transport, the same shape
/// `DaemonMemoryClientTests` (daemon side) and `AgentMemoryTests` (this file's own
/// `MemoryStore` counterpart) already use.
final class AgentMemorySyncServiceTests: XCTestCase {
    private var container: ModelContainer?
    private let thisDevice = "aaaaaaaa"
    private let otherDevice = "bbbbbbbb"

    @MainActor
    private func makeService() throws -> (AgentMemorySyncService, ModelContext) {
        let container = try ModelContainer(
            for: AgentMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
        return (
            AgentMemorySyncService(context: container.mainContext, deviceID8: thisDevice, defaults: .init(suiteName: #function)!),
            container.mainContext
        )
    }

    private func withControlPlaneConfigured(_ body: () async throws -> Void) async rethrows {
        let endpoint = CloudControlPlaneConfig.endpointURL
        let token = CloudControlPlaneConfig.token
        CloudControlPlaneConfig.setEndpointURL("https://cp.example")
        CloudControlPlaneConfig.setToken("cp-token")
        defer {
            CloudControlPlaneConfig.setEndpointURL(endpoint)
            CloudControlPlaneConfig.setToken(token)
        }
        try await body()
    }

    private func emptyMemoryDocumentResponse(for request: URLRequest) -> (Data, URLResponse) {
        (Data(#"{"agent":"a","entries":[]}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - Pure id mapping

    func testLedgerIDRoundTripsThroughLocalID() {
        let id = UUID()
        let ledgerID = AgentMemorySyncService.ledgerID(forLocalID: id)
        XCTAssertTrue(ledgerID.hasPrefix("m-"))
        XCTAssertEqual(AgentMemorySyncService.localID(forLedgerID: ledgerID), id)
    }

    func testLocalIDIsStableForANonConformingLedgerID() {
        let first = AgentMemorySyncService.localID(forLedgerID: "some-other-writer-id")
        let second = AgentMemorySyncService.localID(forLedgerID: "some-other-writer-id")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, AgentMemorySyncService.localID(forLedgerID: "a-different-id"))
    }

    // MARK: - Push

    @MainActor
    func testSyncPushesADeviceAuthoredRow() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let row = AgentMemory(
                kind: .episodic, agentID: agentID, conversationID: UUID(),
                title: "Deploy notes", content: "shipped v2", tags: "work"
            )
            row.originDeviceID8 = thisDevice
            context.insert(row)
            try context.save()

            var captured: [URLRequest] = []
            service.transport = { request in
                captured.append(request)
                if request.httpMethod == "POST" {
                    return (Data(#"{"agent":"a","id":"m-x","entries":1}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return self.emptyMemoryDocumentResponse(for: request)
            }

            await service.sync(agentID: agentID, agentName: "Nimbus")

            let posts = captured.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 1)
            let post = try XCTUnwrap(posts.first)
            XCTAssertEqual(post.url?.absoluteString, "https://cp.example/memory")
            XCTAssertEqual(post.value(forHTTPHeaderField: "authorization"), "Bearer cp-token")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(body["agent"] as? String, "Nimbus")
            XCTAssertEqual(body["id"] as? String, AgentMemorySyncService.ledgerID(forLocalID: row.id))
            XCTAssertEqual(body["title"] as? String, "Deploy notes")
            XCTAssertEqual(body["content"] as? String, "shipped v2")
            XCTAssertEqual(body["tags"] as? String, "work")
            XCTAssertEqual(body["originDevice8"] as? String, thisDevice)
            XCTAssertEqual(body["agentId"] as? String, agentID.uuidString)
        }
    }

    @MainActor
    func testSyncDoesNotPushARowAuthoredByAnotherDevice() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let row = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(), title: "t", content: "c")
            row.originDeviceID8 = otherDevice
            context.insert(row)
            try context.save()

            var captured: [URLRequest] = []
            service.transport = { request in
                captured.append(request)
                return self.emptyMemoryDocumentResponse(for: request)
            }

            await service.sync(agentID: agentID, agentName: "Nimbus")

            XCTAssertTrue(captured.filter { $0.httpMethod == "POST" }.isEmpty)
        }
    }

    @MainActor
    func testPushStopsAtFirstFailureAndRetriesBothRowsNextPass() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let older = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(), title: "older", content: "c1")
            older.originDeviceID8 = thisDevice
            older.updatedAt = Date(timeIntervalSince1970: 1_000)
            let newer = AgentMemory(kind: .episodic, agentID: agentID, conversationID: UUID(), title: "newer", content: "c2")
            newer.originDeviceID8 = thisDevice
            newer.updatedAt = Date(timeIntervalSince1970: 2_000)
            context.insert(older)
            context.insert(newer)
            try context.save()

            var postCount = 0
            service.transport = { request in
                if request.httpMethod == "POST" {
                    postCount += 1
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
                }
                return self.emptyMemoryDocumentResponse(for: request)
            }
            await service.sync(agentID: agentID, agentName: "Nimbus")
            XCTAssertEqual(postCount, 1, "the failing first row must block the second from being sent this pass")

            postCount = 0
            service.transport = { request in
                if request.httpMethod == "POST" { postCount += 1 }
                return (Data(#"{"agent":"a","id":"m-x","entries":1}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await service.sync(agentID: agentID, agentName: "Nimbus")
            XCTAssertEqual(postCount, 2, "an un-advanced watermark must retry BOTH rows, not just the one that failed")
        }
    }

    // MARK: - Pull

    @MainActor
    func testPullInsertsANewLocalRowForAnotherDevicesEntry() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let ledgerID = "m-\(UUID().uuidString)"
            let responseBody: [String: Any] = [
                "agent": "Nimbus",
                "entries": [[
                    "id": ledgerID, "agentId": agentID.uuidString, "kind": "episodic",
                    "title": "learned from the daemon", "content": "the build script moved",
                    "tags": "", "originDevice8": otherDevice,
                    "createdAt": "2026-09-08T12:00:00Z", "updatedAt": "2026-09-08T12:00:00Z",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: responseBody)
            service.transport = { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            await service.sync(agentID: agentID, agentName: "Nimbus")

            let rows = try context.fetch(FetchDescriptor<AgentMemory>())
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.id, AgentMemorySyncService.localID(forLedgerID: ledgerID))
            XCTAssertEqual(row.title, "learned from the daemon")
            XCTAssertEqual(row.content, "the build script moved")
            XCTAssertEqual(row.agentID, agentID)
            XCTAssertEqual(row.originDeviceID8, otherDevice)
            XCTAssertNil(row.consolidatedAt, "a pulled entry stays a consolidation candidate like any other")
        }
    }

    /// Live, 2026-09-12 (Mac): the iMac daemon writes digests under ITS configured
    /// UUID; the Mac's Fin record has another. The memory view filters by the local
    /// id, so 31 digests pulled that day were invisible. The ledger is keyed by agent
    /// NAME; the local agent the pull was made for owns the rows.
    @MainActor
    func testPulledEntriesBelongToTheLocalAgentNotTheWritersUUID() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let localAgentID = UUID()
            let daemonAgentID = UUID()
            let ledgerID = "m-\(UUID().uuidString)"
            // A row an older build pulled under the daemon's UUID: must be re-homed.
            let stale = AgentMemory(kind: .episodic, agentID: daemonAgentID, conversationID: nil, title: "old", content: "old")
            stale.id = AgentMemorySyncService.localID(forLedgerID: ledgerID)
            context.insert(stale)
            try context.save()
            let responseBody: [String: Any] = ["agent": "Fin", "entries": [[
                "id": ledgerID, "agentId": daemonAgentID.uuidString, "kind": "episodic",
                "title": "old", "content": "old", "tags": "", "originDevice8": otherDevice,
                "createdAt": "2026-09-12T12:00:00Z", "updatedAt": "2026-09-12T12:00:00Z",
            ], [
                "id": "m-\(UUID().uuidString)", "agentId": daemonAgentID.uuidString, "kind": "episodic",
                "title": "new", "content": "new", "tags": "", "originDevice8": otherDevice,
                "createdAt": "2026-09-12T13:00:00Z", "updatedAt": "2026-09-12T13:00:00Z",
            ]]]
            let data = try JSONSerialization.data(withJSONObject: responseBody)
            service.transport = { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await service.sync(agentID: localAgentID, agentName: "Fin")
            let rows = try context.fetch(FetchDescriptor<AgentMemory>())
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0.agentID == localAgentID }, "every pulled row belongs to the local agent")
        }
    }

    @MainActor
    func testPullSkipsEntriesAuthoredByThisDevice() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let responseBody: [String: Any] = [
                "agent": "Nimbus",
                "entries": [[
                    "id": "m-\(UUID().uuidString)", "kind": "episodic",
                    "title": "my own round trip", "content": "c",
                    "originDevice8": thisDevice,
                    "createdAt": "2026-09-08T12:00:00Z", "updatedAt": "2026-09-08T12:00:00Z",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: responseBody)
            service.transport = { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            await service.sync(agentID: agentID, agentName: "Nimbus")

            XCTAssertTrue(try context.fetch(FetchDescriptor<AgentMemory>()).isEmpty)
        }
    }

    @MainActor
    func testPullDoesNotOverwriteAFresherLocalRowWithStaleServerData() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let agentID = UUID()
            let ledgerID = "m-\(UUID().uuidString)"
            let localID = AgentMemorySyncService.localID(forLedgerID: ledgerID)

            let existing = AgentMemory(kind: .episodic, agentID: agentID, conversationID: nil, title: "fresh local edit", content: "c")
            existing.id = localID
            existing.originDeviceID8 = otherDevice
            existing.updatedAt = Date()
            context.insert(existing)
            try context.save()

            let responseBody: [String: Any] = [
                "agent": "Nimbus",
                "entries": [[
                    "id": ledgerID, "kind": "episodic",
                    "title": "stale server copy", "content": "old",
                    "originDevice8": otherDevice,
                    "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-01T00:00:00Z",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: responseBody)
            service.transport = { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            await service.sync(agentID: agentID, agentName: "Nimbus")

            let row = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
            XCTAssertEqual(row.title, "fresh local edit", "a stale pull must never clobber a fresher local row")
        }
    }

    // MARK: - Cumulative profile sync

    private func profileResponse(content: String, updatedAt: String?, for request: URLRequest) -> (Data, URLResponse) {
        let updated = updatedAt.map { "\"\($0)\"" } ?? "null"
        let body = #"{"content":"\#(content)","updatedAt":\#(updated)}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    @MainActor
    func testSyncCumulativeProfilePullsNewerRemoteContentWhenNoneExistsLocally() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            service.transport = { request in
                self.profileResponse(content: "Levi ships fast and verifies end to end", updatedAt: "2026-09-08T20:00:00Z", for: request)
            }

            await service.syncCumulativeProfile()

            let record = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
            XCTAssertEqual(record.kind, .cumulative)
            XCTAssertEqual(record.content, "Levi ships fast and verifies end to end")
        }
    }

    @MainActor
    func testSyncCumulativeProfileDoesNotOverwriteAFresherLocalProfile() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let local = AgentMemory(kind: .cumulative, title: "User profile", tags: "profile")
            local.content = "fresher local profile text"
            local.updatedAt = Date()
            context.insert(local)
            try context.save()

            service.transport = { request in
                self.profileResponse(content: "stale server text", updatedAt: "2020-01-01T00:00:00Z", for: request)
            }

            await service.syncCumulativeProfile()

            let record = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentMemory>()).first)
            XCTAssertEqual(record.content, "fresher local profile text")
        }
    }

    @MainActor
    func testSyncCumulativeProfilePushesLocalContentNewerThanTheWatermark() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let local = AgentMemory(kind: .cumulative, title: "User profile", tags: "profile")
            local.content = "this device's own distilled profile"
            local.updatedAt = Date()
            context.insert(local)
            try context.save()

            var pushedContent: String?
            service.transport = { request in
                if request.httpMethod == "PUT" {
                    let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    pushedContent = object?["content"] as? String
                    return self.profileResponse(content: local.content, updatedAt: "2026-09-08T20:00:00Z", for: request)
                }
                // GET: nothing on the server yet.
                return self.profileResponse(content: "", updatedAt: nil, for: request)
            }

            await service.syncCumulativeProfile()

            XCTAssertEqual(pushedContent, "this device's own distilled profile")
        }
    }

    @MainActor
    func testSyncCumulativeProfileDoesNotRepushContentAlreadyPastTheWatermark() async throws {
        try await withControlPlaneConfigured {
            let (service, context) = try makeService()
            let local = AgentMemory(kind: .cumulative, title: "User profile", tags: "profile")
            local.content = "already pushed"
            local.updatedAt = Date()
            context.insert(local)
            try context.save()

            var pushCount = 0
            service.transport = { request in
                if request.httpMethod == "PUT" { pushCount += 1 }
                return self.profileResponse(content: "", updatedAt: nil, for: request)
            }

            await service.syncCumulativeProfile()
            await service.syncCumulativeProfile()

            XCTAssertEqual(pushCount, 1, "the second pass must see its own watermark and skip re-pushing unchanged content")
        }
    }
}

import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fin replies with files (docs/XANADU.md v1.1), site side: `attach_file`'s checks,
/// the site upload route + PUT, the answered ack's `replyAttachments` and failure
/// trailer, and the `[Attached: …]` line on the transcript's reply — no network.
final class DaemonReplyFilesTests: XCTestCase {
    private var scratch: String!
    private var ledgerPath: String!

    override func setUp() {
        super.setUp()
        scratch = NSTemporaryDirectory() + "fin-reply-files-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        ledgerPath = scratch + "/site-ledger.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    @discardableResult
    private func file(_ name: String, bytes: Int = 5) -> String {
        let path = (scratch as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
        return path
    }

    // MARK: attach_file's checks

    func testARegularFileIsQueuedWithItsNameMimeAndSize() throws {
        let path = file("Q3 chart.png", bytes: 1234)
        let queued = try DaemonAttachments.validateReplyFile(path: path, name: nil, queued: []).get()
        XCTAssertEqual(queued.name, "Q3 chart.png")
        XCTAssertEqual(queued.mime, "image/png")
        XCTAssertEqual(queued.size, 1234)
        XCTAssertTrue(queued.path.hasSuffix("/Q3 chart.png"))
        let renamed = try DaemonAttachments.validateReplyFile(path: path, name: "  Costs by quarter.png ", queued: []).get()
        XCTAssertEqual(renamed.name, "Costs by quarter.png")
        let mimeFollowsTheFile = try DaemonAttachments.validateReplyFile(path: path, name: "x.pdf", queued: []).get()
        XCTAssertEqual(mimeFollowsTheFile.mime, "image/png")
    }

    func testRefusalsAreReasonsTheModelCanActOn() throws {
        func reason(_ path: String, queued: [QueuedReplyFile] = []) -> String? {
            if case .failure(let refusal) = DaemonAttachments.validateReplyFile(path: path, name: nil, queued: queued) {
                return refusal.reason
            }
            return nil
        }
        XCTAssertEqual(reason(scratch + "/missing.csv"), "no such file")
        XCTAssertNotNil(reason(scratch)?.range(of: "not a regular file"))
        XCTAssertNotNil(reason("relative/path.csv")?.range(of: "full path"))
        // Over 25 MiB: a sparse file, so the test writes nothing real.
        let big = file("big.bin", bytes: 0)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: big))
        try handle.truncate(atOffset: UInt64(DaemonAttachments.maxReplyFileBytes + 1))
        try handle.close()
        XCTAssertNotNil(reason(big)?.range(of: "25 MB"))
        // Exactly at the cap is fine.
        try FileHandle(forWritingAtPath: big).map { try $0.truncate(atOffset: UInt64(DaemonAttachments.maxReplyFileBytes)); try $0.close() }
        XCTAssertNil(reason(big))
        // Already queued, and the per-turn cap of 8.
        let one = try DaemonAttachments.validateReplyFile(path: file("a.csv"), name: nil, queued: []).get()
        XCTAssertNotNil(reason(one.path, queued: [one])?.range(of: "already attached"))
        let eight = Array(repeating: one, count: DaemonAttachments.maxReplyFilesPerTurn)
        XCTAssertNotNil(reason(file("b.csv"), queued: eight)?.range(of: "at most 8"))
    }

    func testMimeTypesAndTheFailureNote() {
        XCTAssertEqual(DaemonAttachments.mimeType(forFileName: "a.CSV"), "text/csv")
        XCTAssertEqual(DaemonAttachments.mimeType(forFileName: "r.xlsx"),
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(DaemonAttachments.mimeType(forFileName: "noext"), "application/octet-stream")
        XCTAssertEqual(DaemonAttachments.replyFailureNote(name: "chart.png", reason: "upload refused (HTTP 409)"),
                       "(couldn't attach chart.png: upload refused (HTTP 409))")
    }

    // MARK: Upload

    @MainActor private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func makeClient(
        _ handler: @escaping @MainActor (URLRequest) -> (Int, String)
    ) async -> DaemonSiteClient {
        let client = DaemonSiteClient(
            siteID: "A4A1D987-0000-4000-8000-000000000000", displayName: "Levi's iMac", token: "site-secret",
            heartbeatSeconds: 20, endpointURL: "https://cp.example/", ledgerPath: ledgerPath, audit: { _ in }
        )
        await client.configure(
            runID: "run-1",
            transport: { request in
                let (status, body) = await MainActor.run { handler(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            },
            state: { "idle" }, capabilities: { [:] }, onCommand: { _ in }
        )
        return client
    }

    @MainActor
    func testUploadAsksTheSiteRouteThenPutsTheBytesWithItsHeaders() async throws {
        let path = file("chart.png", bytes: 7)
        let queued = try DaemonAttachments.validateReplyFile(path: path, name: "Q3 chart.png", queued: []).get()
        let requests = Box<[URLRequest]>([])
        let client = await makeClient { request in
            requests.value.append(request)
            if request.httpMethod == "PUT" { return (200, "") }
            return (200, #"{"key":"users/u/fin/attachments/fin/abc/Q3_chart.png","putUrl":"https://s3.example/put?sig=1","headers":{"Content-Type":"image/png"}}"#)
        }
        let result = await client.uploadReplyFile(messageID: "m-12345678", file: queued)
        let entry = try result.get()
        XCTAssertEqual(entry, MessageAttachment(key: "users/u/fin/attachments/fin/abc/Q3_chart.png",
                                                name: "Q3 chart.png", mime: "image/png", size: 7))
        XCTAssertEqual(requests.value.count, 2)
        let slot = requests.value[0]
        XCTAssertEqual(slot.url?.absoluteString, "https://cp.example/sites/a4a1d987-0000-4000-8000-000000000000/attachments")
        XCTAssertEqual(slot.value(forHTTPHeaderField: "X-Fin-Site"), "a4a1d987-0000-4000-8000-000000000000")
        XCTAssertEqual(slot.value(forHTTPHeaderField: "authorization"), "Bearer site-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(slot.httpBody)) as? [String: Any])
        XCTAssertEqual(body["messageId"] as? String, "m-12345678")
        XCTAssertEqual(body["name"] as? String, "Q3 chart.png")
        XCTAssertEqual(body["mime"] as? String, "image/png")
        XCTAssertEqual(body["size"] as? Int, 7)
        let put = requests.value[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "https://s3.example/put?sig=1")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertNil(put.value(forHTTPHeaderField: "authorization"), "the bearer never rides to S3")
        XCTAssertEqual(put.httpBody?.count, 7)
    }

    @MainActor
    func testARefusedSlotOrAFailedPutIsAReasonNotAThrow() async throws {
        let queued = try DaemonAttachments.validateReplyFile(path: file("a.csv"), name: nil, queued: []).get()
        let refused = await makeClient { _ in (409, #"{"error":"not claimed"}"#) }
        guard case .failure(let r1) = await refused.uploadReplyFile(messageID: "m-1", file: queued) else {
            return XCTFail("a 409 slot must fail")
        }
        XCTAssertEqual(r1.reason, "upload refused (HTTP 409)")
        let badPut = await makeClient { request in
            request.httpMethod == "PUT" ? (403, "") : (200, #"{"key":"k","putUrl":"https://s3.example/p","headers":{}}"#)
        }
        guard case .failure(let r2) = await badPut.uploadReplyFile(messageID: "m-1", file: queued) else {
            return XCTFail("a 403 PUT must fail")
        }
        XCTAssertEqual(r2.reason, "upload failed (HTTP 403)")
        try FileManager.default.removeItem(atPath: queued.path)
        guard case .failure(let r3) = await badPut.uploadReplyFile(messageID: "m-1", file: queued) else {
            return XCTFail("a vanished file must fail")
        }
        XCTAssertEqual(r3.reason, "could not read the file")
    }

    // MARK: The answered ack

    func testTheAckCarriesReplyAttachmentsAndKeepsTheTrailerPastTheCut() throws {
        let files = [MessageAttachment(key: "users/u/fin/attachments/fin/1/a.png", name: "a.png", mime: "image/png", size: 9)]
        let body = DaemonSiteClient.answeredAckBody(
            replyPreview: "here", agentID: nil, originDeviceID8: "", replyAttachments: files
        )
        let entries = try XCTUnwrap(body["replyAttachments"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["key"] as? String, "users/u/fin/attachments/fin/1/a.png")
        XCTAssertEqual(entries[0]["name"] as? String, "a.png")
        XCTAssertEqual(entries[0]["mime"] as? String, "image/png")
        XCTAssertEqual(entries[0]["size"] as? Int, 9)
        XCTAssertEqual(Set(entries[0].keys), ["key", "name", "mime", "size"])
        XCTAssertEqual(body["replyPreview"] as? String, "here")

        let note = "(couldn't attach b.csv: upload refused (HTTP 409))"
        let long = DaemonSiteClient.answeredAckBody(
            replyPreview: String(repeating: "x", count: 900), agentID: nil, originDeviceID8: "", trailer: note
        )
        let preview = try XCTUnwrap(long["replyPreview"] as? String)
        XCTAssertLessThanOrEqual(preview.count, DaemonSiteClient.maxReplyPreviewCharacters)
        XCTAssertTrue(preview.hasSuffix("\n" + note), "the missing-file note survives the cut")
        XCTAssertNil(long["replyAttachments"], "omitted, never empty, when no file went up")

        let filesOnly = DaemonSiteClient.answeredAckBody(replyPreview: "", agentID: nil, originDeviceID8: "", trailer: note)
        XCTAssertEqual(filesOnly["replyPreview"] as? String, note)
    }

    // MARK: The transcript's reply line

    @MainActor
    func testTheReplyLineGainsTheAttachedLineUnderTheSameID() async throws {
        let uplink = DaemonTranscriptUplink(
            endpointURL: "https://cp.example", token: "t", flushSeconds: 15, maxLines: 2000,
            runID: UUID(), agentID: UUID(), agentName: "Fin", server: "s",
            modelIdentifier: "stub", temperature: 0.2,
            put: { request in HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)! }
        )
        func object(_ line: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        uplink.beginMessageTurn(messageID: "m-1", threadID: "m-1")
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "chart my costs"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "(tool call only)"))
        uplink.record(AgentAuditEvent(kind: "toolCall", text: "attach_file: /tmp/c.png", toolName: "attach_file"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "Here is the chart."))
        let before = try uplink.lines.map { try object($0) }
        let display = try XCTUnwrap(DaemonAttachments.displayLine([
            MessageAttachment(key: "k", name: "chart.png", mime: "image/png", size: 48_213),
        ]))

        let rewritten = await uplink.appendToFinalAssistantLine(display)

        XCTAssertTrue(rewritten)
        let after = try uplink.lines.map { try object($0) }
        XCTAssertEqual(after.compactMap { $0["id"] as? String }, before.compactMap { $0["id"] as? String })
        XCTAssertEqual(after[3]["text"] as? String, "Here is the chart.\n[Attached: chart.png (image, 47 KB)]")
        XCTAssertEqual(after[1]["text"] as? String, "(tool call only)", "only the final reply line")
        XCTAssertEqual(after[3]["thread_id"] as? String, "m-1")
        uplink.endMessageTurn()
        let nothing = await uplink.appendToFinalAssistantLine(display)
        XCTAssertFalse(nothing, "after the turn there is no reply line to stamp")
    }
}

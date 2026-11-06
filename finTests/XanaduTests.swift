import XCTest
@testable import fin

/// docs/XANADU.md (app): the current-thread rules, the attachment wire shapes
/// (request bodies, Message / ThreadDetail decode with and without
/// attachments), the safe upload-then-send flow against a mocked client, and
/// the pure transcript helpers. No network, no ModelContainer.
@MainActor
final class XanaduTests: XCTestCase {
    private var savedDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        savedDefaults = XanaduCurrentThread.defaults
        let suite = "xanadu.tests.\(UUID().uuidString)"
        XanaduCurrentThread.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        XanaduCurrentThread.defaults = savedDefaults
        super.tearDown()
    }

    private func decodeMessage(_ json: [String: Any]) throws -> ControlPlaneClient.Message {
        try ControlPlaneClient.decoder.decode(ControlPlaneClient.Message.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func row(_ id: String, thread: String? = nil, text: String = "hi", source: String = "app",
                     attachments: [[String: Any]]? = nil) -> [String: Any] {
        var json: [String: Any] = ["messageId": id, "agent": "Fin", "text": text, "source": source,
                                   "createdAt": "2027-01-01T10:00:00Z", "state": "queued"]
        if let thread { json["threadId"] = thread }
        if let attachments { json["attachments"] = attachments }
        return json
    }

    // MARK: - Current thread

    func testCurrentThreadIsPerAgentAndClears() {
        XCTAssertNil(XanaduCurrentThread.get(agent: "Fin"))
        XanaduCurrentThread.set("m-1", agent: "Fin")
        XanaduCurrentThread.set("m-9", agent: "Ops")
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Fin"), "m-1")
        XCTAssertEqual(XanaduCurrentThread.get(agent: " Fin "), "m-1")
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Ops"), "m-9")
        XanaduCurrentThread.set(nil, agent: "Fin")
        XCTAssertNil(XanaduCurrentThread.get(agent: "Fin"))
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Ops"), "m-9")
    }

    func testSendTargetRules() {
        // Explicit wins over everything.
        XCTAssertEqual(XanaduCurrentThread.target(explicit: "m-x", startNewThread: true, current: "m-c"), "m-x")
        // No explicit thread: a follow-up in the current thread…
        XCTAssertEqual(XanaduCurrentThread.target(explicit: nil, startNewThread: false, current: "m-c"), "m-c")
        // …unless a new thread was asked for…
        XCTAssertNil(XanaduCurrentThread.target(explicit: nil, startNewThread: true, current: "m-c"))
        // …or there is no current thread yet.
        XCTAssertNil(XanaduCurrentThread.target(explicit: "  ", startNewThread: false, current: nil))
    }

    func testANewThreadsIdIsItsRootMessageAndBecomesCurrent() throws {
        // A root with no row back: its own id.
        XCTAssertEqual(XanaduCurrentThread.threadAfterSend(messageID: "m-new", sentThreadID: nil, row: nil), "m-new")
        // The control plane's answer is the authority.
        let joined = try decodeMessage(row("m-2", thread: "m-1"))
        XCTAssertEqual(XanaduCurrentThread.threadAfterSend(messageID: "m-2", sentThreadID: nil, row: joined), "m-1")
        let root = try decodeMessage(row("m-3"))
        XanaduCurrentThread.adoptSend(messageID: "m-3", sentThreadID: nil, row: root, agent: "Fin")
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Fin"), "m-3")
    }

    func testOpeningAThreadAnywhereMakesItCurrentButTheDefaultRuleDoesNot() {
        let store = ThreadStore(agentName: "Fin")
        store.select("m-auto", byUser: false)
        XCTAssertNil(XanaduCurrentThread.get(agent: "Fin"))
        store.select("m-tapped")
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Fin"), "m-tapped")
        store.preselect("m-notification")
        XCTAssertEqual(XanaduCurrentThread.get(agent: "Fin"), "m-notification")
    }

    func testChangingTheCurrentThreadIsAnnounced() {
        let expectation = expectation(forNotification: XanaduCurrentThread.changedNotification, object: "Fin")
        XanaduCurrentThread.set("m-1", agent: "Fin")
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Wire shapes

    func testMessageBodyCarriesAttachmentsOnlyWhenThereAreAny() {
        let plain = ControlPlaneClient.sendMessageBody(agent: "Fin", text: "hi", messageID: "m-1", context: .init())
        XCTAssertNil(plain["attachments"])
        let voice = MessageAttachment(key: "users/u/fin/attachments/fin/x/note.m4a", name: "note.m4a", mime: "audio/mp4",
                                      size: 1200, transcript: String(repeating: "a", count: 9000),
                                      url: URL(string: "https://example.com/get"))
        let sheet = MessageAttachment(key: "users/u/fin/attachments/fin/y/Q3.xlsx", name: "Q3 costs.xlsx",
                                      mime: "application/vnd.ms-excel", size: 48213)
        let body = ControlPlaneClient.sendMessageBody(agent: "Fin", text: "", messageID: "m-1",
                                                      context: .init(threadID: "m-0"), attachments: [voice, sheet])
        let entries = try? XCTUnwrap(body["attachments"] as? [[String: Any]])
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[0]["key"] as? String, voice.key)
        XCTAssertEqual(entries?[0]["size"] as? Int, 1200)
        XCTAssertEqual((entries?[0]["transcript"] as? String)?.count, MessageAttachment.maxTranscriptCharacters)
        XCTAssertNil(entries?[0]["url"], "the presigned GET is the server's to mint, never sent")
        XCTAssertNil(entries?[1]["transcript"])
        XCTAssertEqual(entries?[1]["name"] as? String, "Q3 costs.xlsx")
        XCTAssertEqual(body["text"] as? String, "")
        XCTAssertEqual(body["threadId"] as? String, "m-0")
    }

    func testUploadRequestBodyAndResponseDecode() throws {
        let body = ControlPlaneClient.attachmentUploadBody(agent: "Fin", name: "a.pdf", mime: "application/pdf", size: 10)
        XCTAssertEqual(body["agent"] as? String, "Fin")
        XCTAssertEqual(body["size"] as? Int, 10)
        let json: [String: Any] = ["key": "users/u/fin/attachments/fin/x/a.pdf", "putUrl": "https://s3.example.com/put?sig=1",
                                   "headers": ["Content-Type": "application/pdf"]]
        let upload = try ControlPlaneClient.decoder.decode(
            ControlPlaneClient.AttachmentUpload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(upload.headers, ["Content-Type": "application/pdf"])
    }

    func testThePresignedPutCarriesExactlyTheNamedHeadersAndNeverTheToken() throws {
        let upload = ControlPlaneClient.AttachmentUpload(
            key: "k", putUrl: "https://s3.example.com/put?sig=1", headers: ["Content-Type": "image/jpeg"])
        let request = try XCTUnwrap(ControlPlaneClient.attachmentPutRequest(upload, body: Data([1, 2, 3])))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.allHTTPHeaderFields, ["Content-Type": "image/jpeg"])
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertEqual(request.httpBody, Data([1, 2, 3]))
        XCTAssertNil(ControlPlaneClient.attachmentPutRequest(
            .init(key: "k", putUrl: "file:///etc/passwd", headers: [:]), body: Data()))
    }

    func testMessageDecodesWithAndWithoutAttachments() throws {
        let bare = try decodeMessage(row("m-1"))
        XCTAssertNil(bare.attachments)
        let empty = try decodeMessage(row("m-2", attachments: []))
        XCTAssertEqual(empty.attachments, [])
        let full = try decodeMessage(row("m-3", text: "", attachments: [
            ["key": "users/u/fin/attachments/fin/x/photo.jpg", "name": "photo.jpg", "mime": "image/jpeg",
             "size": 2048, "url": "https://s3.example.com/get?sig=1"],
            ["key": "users/u/fin/attachments/fin/y/note.m4a", "name": "note.m4a", "mime": "audio/mp4",
             "size": 99.0, "transcript": "call the bank"],
            ["key": "users/u/fin/attachments/fin/z/raw.bin"],
        ]))
        let files = try XCTUnwrap(full.attachments)
        XCTAssertEqual(files.map(\.kind), [.image, .audio, .file])
        XCTAssertEqual(files[0].url?.host, "s3.example.com")
        XCTAssertEqual(files[1].size, 99)
        XCTAssertEqual(files[1].transcript, "call the bank")
        XCTAssertEqual(files[2].name, "raw.bin")
        XCTAssertEqual(files[2].mime, "application/octet-stream")
    }

    func testThreadDetailAndTimelineCarryAttachments() throws {
        let detailJSON: [String: Any] = [
            "thread": ["threadId": "m-1", "title": "costs", "status": "working"],
            "messages": [row("m-1", text: "", source: "voice", attachments: [
                ["key": "users/u/fin/attachments/fin/x/Q3.xlsx", "name": "Q3.xlsx", "mime": "application/vnd.ms-excel", "size": 5],
            ])],
            "events": [],
        ]
        let detail = try ControlPlaneClient.decoder.decode(
            ControlPlaneClient.ThreadDetail.self, from: JSONSerialization.data(withJSONObject: detailJSON))
        let items = XanaduTimeline.items(usesControlPlane: true, selectedThreadID: "m-1", detail: detail, sentRows: [], records: [])
        XCTAssertEqual(items.count, 1, "a files-only message still renders")
        XCTAssertEqual(items[0].attachments.map(\.name), ["Q3.xlsx"])
        XCTAssertEqual(items[0].messageID, "m-1")
        XCTAssertEqual(XanaduTimeline.originLabel(items[0].origin), "via Siri")
    }

    func testANewThreadShowsNothingUntilSentAndASentRowShowsAtOnce() throws {
        XCTAssertTrue(XanaduTimeline.items(usesControlPlane: true, selectedThreadID: nil, detail: nil, sentRows: [], records: []).isEmpty)
        let sent = try decodeMessage(row("m-5"))
        let items = XanaduTimeline.items(usesControlPlane: true, selectedThreadID: "m-5", detail: nil, sentRows: [sent], records: [])
        XCTAssertEqual(items.map(\.id), ["m:m-5"])
    }

    func testStepsFoldBetweenWhatWasSaid() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ id: String, _ kind: ThreadItem.Kind) -> ThreadItem {
            ThreadItem(id: id, party: .system, kind: kind, text: id, timestamp: t, status: [], source: .record, sequence: 0)
        }
        let rows = XanaduTimeline.rows(from: [item("p", .prompt), item("s1", .step), item("s2", .relaySent), item("r", .reply)])
        XCTAssertEqual(rows.map(\.id), ["p", "steps:s1", "r"])
        if case .steps(_, let steps) = rows[1] { XCTAssertEqual(steps.count, 2) } else { XCTFail("expected a steps row") }
    }

    // MARK: - Text

    func testTheDaemonsAttachedLineIsDroppedFromTheText() {
        XCTAssertEqual(XanaduText.displayText("break down costs by quarter\n[Attached: Q3.xlsx (spreadsheet, 47 KB)]"),
                       "break down costs by quarter")
        XCTAssertEqual(XanaduText.displayText("[Attached: note.m4a (audio, 1.2 MB), a.png (image, 3 KB)]"), "")
        XCTAssertEqual(XanaduText.displayText("hello\n\nAttached files (saved on this machine — …):\n- /x"), "hello")
        XCTAssertEqual(XanaduText.displayText("[Attached] is just a word here\nok"), "[Attached] is just a word here\nok")
    }

    func testLinksAreFoundAndThreadMentionsLinkForward() {
        let thread = "m-0a1b2c3d-1111-2222-3333-444455556666"
        let links = XanaduText.links(in: "see https://example.com/report and \(thread)")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].url.host, "example.com")
        XCTAssertEqual(XanaduText.threadID(fromLink: links[1].url), thread)
        let attributed = XanaduText.attributed("go to https://example.com now")
        XCTAssertTrue(attributed.runs.contains { $0.link?.host == "example.com" })
    }

    func testSafeNameMirrorsTheControlPlane() {
        XCTAssertEqual(MessageAttachment.safeName("Q3 costs.xlsx"), "Q3_costs.xlsx")
        XCTAssertEqual(MessageAttachment.safeName("ü"), "file")
        let long = MessageAttachment.safeName(String(repeating: "a", count: 200) + ".pdf")
        XCTAssertEqual(long.count, 96)
        XCTAssertTrue(long.hasSuffix(".pdf"))
    }

    // MARK: - Upload + send flow (mocked client)

    private final class Recorder {
        var slots: [(String, String, Int)] = []
        var puts: [(ControlPlaneClient.AttachmentUpload, Data)] = []
        var sends: [(String, String, [MessageAttachment], String?)] = []
    }

    private func client(_ recorder: Recorder, failPutFor badName: String? = nil) -> XanaduSend.Client {
        var client = XanaduSend.Client(
            requestUpload: { _, name, mime, size in
                recorder.slots.append((name, mime, size))
                return .success(.init(key: "users/u/fin/attachments/fin/\(recorder.slots.count)/\(name)",
                                      putUrl: "https://s3.example.com/\(name)", headers: ["Content-Type": mime]))
            },
            put: { upload, data in
                recorder.puts.append((upload, data))
                return upload.key.hasSuffix("/\(badName ?? "\u{0}")") ? .failure(.http(403, "denied")) : .success(())
            },
            send: { _, text, messageID, context, attachments in
                recorder.sends.append((text, messageID, attachments, context.threadID))
                let json: [String: Any] = ["messageId": messageID, "state": "queued", "threadId": context.threadID ?? messageID]
                return .success(try! ControlPlaneClient.decoder.decode(
                    ControlPlaneClient.Message.self, from: JSONSerialization.data(withJSONObject: json)))
            }
        )
        client.readFile = { url in Data(repeating: 7, count: Int(url.lastPathComponent.count)) }
        return client
    }

    private func draft(_ name: String, mime: String = "application/pdf", size: Int = 10) -> AttachmentDraft {
        AttachmentDraft(name: name, mime: mime, size: size, fileURL: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testEveryFileUploadsBeforeTheMessageIsSent() async throws {
        let recorder = Recorder()
        var states: [String] = []
        let result = await XanaduSend.send(
            text: " costs by quarter ", drafts: [draft("a.pdf"), draft("b.xlsx")], agent: "Fin", messageID: "m-1",
            context: .init(threadID: "m-0"), client: client(recorder)
        ) { _, state in states.append("\(state)") }
        let row = try result.get()
        XCTAssertEqual(row.resolvedThreadID, "m-0")
        XCTAssertEqual(recorder.slots.map(\.0), ["a.pdf", "b.xlsx"])
        XCTAssertEqual(recorder.puts.count, 2)
        XCTAssertEqual(recorder.puts[0].0.headers["Content-Type"], "application/pdf")
        XCTAssertEqual(recorder.sends.count, 1)
        XCTAssertEqual(recorder.sends[0].0, "costs by quarter")
        XCTAssertEqual(recorder.sends[0].2.map(\.key), recorder.slots.indices.map { "users/u/fin/attachments/fin/\($0 + 1)/\(recorder.slots[$0].0)" })
        XCTAssertEqual(recorder.sends[0].3, "m-0")
        XCTAssertEqual(states.filter { $0 == "uploading" }.count, 2)
    }

    func testAFailedUploadNeverSendsTheMessageAndARetrySkipsWhatMadeIt() async {
        let recorder = Recorder()
        var drafts = [draft("good.pdf"), draft("bad.pdf")]
        let first = await XanaduSend.send(
            text: "x", drafts: drafts, agent: "Fin", messageID: "m-1", context: .init(),
            client: client(recorder, failPutFor: "bad.pdf")
        ) { id, state in
            if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].state = state }
        }
        guard case .failure(.upload(let name, _)) = first else { return XCTFail("expected an upload failure") }
        XCTAssertEqual(name, "bad.pdf")
        XCTAssertTrue(recorder.sends.isEmpty, "a message must never name a key that wasn't uploaded")
        XCTAssertNotNil(drafts[0].uploaded)
        if case .failed = drafts[1].state {} else { XCTFail("the failed file is marked") }

        let retry = Recorder()
        let second = await XanaduSend.send(text: "x", drafts: drafts, agent: "Fin", messageID: "m-1", context: .init(),
                                           client: client(retry))
        XCTAssertNoThrow(try second.get())
        XCTAssertEqual(retry.slots.map(\.0), ["bad.pdf"], "the already-uploaded file is not uploaded again")
        XCTAssertEqual(retry.sends.first?.1, "m-1", "a retry is the same message")
        XCTAssertEqual(retry.sends.first?.2.count, 2)
    }

    func testRefusalsHappenBeforeTheNetwork() async {
        let recorder = Recorder()
        XCTAssertEqual(XanaduSend.validate(text: "  ", drafts: []), .empty)
        XCTAssertNil(XanaduSend.validate(text: "", drafts: [draft("a.pdf")]), "files alone are a message")
        XCTAssertEqual(XanaduSend.validate(text: "", drafts: (0..<9).map { draft("\($0).pdf") }), .tooMany)
        let huge = draft("huge.mov", mime: "video/quicktime", size: MessageAttachment.maxBytes + 1)
        let result = await XanaduSend.send(text: "", drafts: [huge], agent: "Fin", messageID: "m-1", context: .init(),
                                           client: client(recorder))
        XCTAssertEqual(result.failureValue, .tooLarge(name: "huge.mov"))
        XCTAssertTrue(recorder.slots.isEmpty && recorder.sends.isEmpty)
    }

    func testAudioKeepsItsTranscriptAndOtherFilesDont() async {
        var note = draft("note.m4a", mime: "audio/mp4")
        note.transcript = "pick up milk"
        var doc = draft("doc.pdf")
        doc.transcript = "stray"
        let recorder = Recorder()
        _ = await XanaduSend.send(text: "", drafts: [note, doc], agent: "Fin", messageID: "m-1", context: .init(),
                                  client: client(recorder))
        XCTAssertEqual(recorder.sends.first?.2.map(\.transcript), ["pick up milk", nil])
    }

    // MARK: - Images for the model

    func testHEICIsReencodedAsJPEGAndModelReadableImagesPassThrough() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let kept = XanaduImageNormalizer.normalize(data: png, name: "a.png", type: .png)
        XCTAssertEqual(kept.mime, "image/png")
        XCTAssertEqual(kept.data, png)
        let pdf = XanaduImageNormalizer.normalize(data: Data([1]), name: "a.pdf", type: .pdf)
        XCTAssertEqual(pdf.mime, "application/pdf")
    }

    // MARK: - Siri

    func testThreadEntitySummaries() throws {
        let messages = [
            try decodeMessage(row("m-1", text: "check the deploy")),
            try decodeMessage(row("m-2", thread: "m-1", text: "", attachments: [["key": "k/x/log.txt", "name": "log.txt"]])),
        ]
        let transcript = FinThreadEntity.recentTranscript(from: messages)
        XCTAssertEqual(transcript, "You: check the deploy\nYou: [files: log.txt]")
        XCTAssertEqual(FinThreadEntity.transcriptText(["abcdef"], limit: 3), "…def")
        let threads = [
            FinThreadEntity(id: "a", agentName: "Fin", title: "Deploy the site", status: "working"),
            FinThreadEntity(id: "b", agentName: "Fin", title: "Q3 costs", status: "answered"),
        ]
        XCTAssertEqual(FinThreadDirectory.matching("the deploy thread", in: threads).map(\.id), ["a"])
        XCTAssertEqual(FinThreadDirectory.matching("costs", in: threads).map(\.id), ["b"])
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let failure) = self { return failure } else { return nil } }
}

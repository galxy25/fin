import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore

/// Xanadu attachments on the site side (docs/XANADU.md, "Site (fin-agentd)"):
/// offer/claim decoding, the held ledger, safe names and clashes, the prompt
/// block, the transcript line, and the download — all without a network.
final class DaemonAttachmentsTests: XCTestCase {
    private var scratch: String!

    override func setUp() {
        super.setUp()
        scratch = NSTemporaryDirectory() + "fin-attachments-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    private let xlsx = MessageAttachment(
        key: "users/u/fin/attachments/fin/1234/Q3_costs.xlsx", name: "Q3 costs.xlsx",
        mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 48_213,
        url: "https://s3.example/Q3_costs.xlsx?sig=1"
    )

    // MARK: Decoding

    func testOfferDecodesAttachmentsAndAFilesOnlyMessage() {
        let json = #"""
        {"messages":[
          {"id":"m-1","text":"breakdown by quarter","attachments":[
            {"key":"users/u/fin/attachments/fin/1/Q3_costs.xlsx","name":"Q3 costs.xlsx","mime":"application/vnd.ms-excel","size":48213,"url":"https://s3/x"},
            {"key":"users/u/fin/attachments/fin/2/voice-note.m4a","name":"voice-note.m4a","mime":"audio/mp4","size":1258291,"transcript":"what did it cost","url":"https://s3/y"},
            {"bogus":true}
          ]},
          {"id":"m-2","attachments":[{"key":"users/u/fin/attachments/fin/3/a.png","name":"a.png","mime":"image/png","size":10,"url":"https://s3/z"}]},
          {"id":"m-3"},
          {"id":"m-4","text":"plain","attachments":"nonsense"}
        ]}
        """#
        let messages = DaemonSiteClient.decodeHeartbeat(Data(json.utf8)).messages
        XCTAssertEqual(messages.map(\.id), ["m-1", "m-2", "m-4"], "a message with neither text nor files is nothing")
        XCTAssertEqual(messages[0].attachments.count, 2, "an entry with no key and no name is skipped")
        XCTAssertEqual(messages[0].attachments[1].transcript, "what did it cost")
        XCTAssertEqual(messages[0].attachments[1].size, 1_258_291)
        XCTAssertEqual(messages[1].text, "", "files-only: text may be absent")
        XCTAssertEqual(messages[2].attachments, [])
    }

    func testHeldMessageKeepsAttachmentsAndOldLedgersStillDecode() throws {
        let held = DaemonSiteClient.Ledger.HeldMessage(id: "m-1", text: "x", source: "app", threadID: "t-1", attachments: [xlsx])
        let data = try JSONEncoder().encode(DaemonSiteClient.Ledger(held: [held]))
        XCTAssertEqual(try JSONDecoder().decode(DaemonSiteClient.Ledger.self, from: data).held.first?.attachmentList, [xlsx])

        let old = #"{"held":[{"id":"m-9","text":"hi","source":"app"}],"unacked":[]}"#
        let ledger = try JSONDecoder().decode(DaemonSiteClient.Ledger.self, from: Data(old.utf8))
        XCTAssertEqual(ledger.held.first?.attachmentList, [])
        // No attachments: nothing new is written into the ledger file at all.
        let plain = String(decoding: try JSONEncoder().encode(DaemonSiteClient.Ledger.HeldMessage(id: "a", text: "b", source: "app")), as: UTF8.self)
        XCTAssertFalse(plain.contains("attachments"))
    }

    // MARK: Names

    func testSafeName() {
        XCTAssertEqual(DaemonAttachments.safeName("Q3 costs.xlsx"), "Q3_costs.xlsx")
        XCTAssertEqual(DaemonAttachments.safeName("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(DaemonAttachments.safeName(".."), "file")
        XCTAssertEqual(DaemonAttachments.safeName(""), "file")
        XCTAssertEqual(DaemonAttachments.safeName("日本.pdf"), "__.pdf")
        let long = DaemonAttachments.safeName(String(repeating: "a", count: 200) + ".xlsx")
        XCTAssertEqual(long.count, 96)
        XCTAssertTrue(long.hasSuffix(".xlsx"), "the extension survives truncation")
        XCTAssertEqual(DaemonAttachments.fileName(for: xlsx), "Q3_costs.xlsx", "the key's own safeName wins")
    }

    func testClashGetsNumberedBeforeTheExtension() {
        var taken: Set<String> = ["a.pdf", "a (2).pdf", "notes"]
        XCTAssertEqual(DaemonAttachments.uniqueFileName("b.pdf") { taken.contains($0) }, "b.pdf")
        XCTAssertEqual(DaemonAttachments.uniqueFileName("a.pdf") { taken.contains($0) }, "a (3).pdf")
        XCTAssertEqual(DaemonAttachments.uniqueFileName("notes") { taken.contains($0) }, "notes (2)")
        taken.insert("notes (2)")
        XCTAssertEqual(DaemonAttachments.uniqueFileName("notes") { taken.contains($0) }, "notes (3)")
    }

    // MARK: Prompt and transcript

    func testSizesAndKinds() {
        XCTAssertEqual(DaemonAttachments.formattedSize(812), "812 bytes")
        XCTAssertEqual(DaemonAttachments.formattedSize(48_213), "47 KB")
        XCTAssertEqual(DaemonAttachments.formattedSize(1_258_291), "1.2 MB")
        XCTAssertEqual(DaemonAttachments.kind(mime: xlsx.mime, name: xlsx.name), "spreadsheet")
        XCTAssertEqual(DaemonAttachments.kind(mime: "audio/mp4", name: "v.m4a"), "audio")
        XCTAssertEqual(DaemonAttachments.kind(mime: "application/pdf", name: "x"), "PDF")
        XCTAssertEqual(DaemonAttachments.kind(mime: "application/octet-stream", name: "deck.pptx"), "presentation")
        XCTAssertEqual(DaemonAttachments.kind(mime: "application/octet-stream", name: "blob"), "file")
    }

    func testPromptBlockMatchesTheContract() {
        let audio = MessageAttachment(key: "k/voice-note.m4a", name: "voice-note.m4a", mime: "audio/mp4", size: 1_258_291, transcript: "what did Q3 cost")
        let block = DaemonAttachments.promptBlock([
            .init(attachment: xlsx, path: "/Users/l/Fin/Attachments/m-1/Q3_costs.xlsx", bytes: 48_213),
            .init(attachment: audio, path: "/Users/l/Fin/Attachments/m-1/voice-note.m4a", bytes: 1_258_291),
            .init(attachment: xlsx, failure: "HTTP 403"),
        ])
        XCTAssertEqual(block, """
        Attached files (saved on this machine — work with them using your terminal tools):
        - /Users/l/Fin/Attachments/m-1/Q3_costs.xlsx (spreadsheet, 47 KB)
        - /Users/l/Fin/Attachments/m-1/voice-note.m4a (audio, 1.2 MB) — transcript: "what did Q3 cost"
        - Q3 costs.xlsx (spreadsheet, 47 KB) (download failed: HTTP 403)
        """)
        XCTAssertNil(DaemonAttachments.promptBlock([]))
    }

    func testUserTurnPromptAppendsTheBlockAndIsUnchangedWithoutFiles() {
        XCTAssertEqual(Daemon.userTurnPrompt("hi", source: "app"), Daemon.userTurnPrompt("hi", source: "app", attachments: []))
        let fetched = [FetchedAttachment(attachment: xlsx, path: "/p/Q3_costs.xlsx", bytes: 48_213)]
        let prompt = Daemon.userTurnPrompt("break down cost by quarter", source: "voice", attachments: fetched)
        XCTAssertTrue(prompt.hasSuffix("Message from the user:\nbreak down cost by quarter\n\n"
            + DaemonAttachments.promptHeader + "\n- /p/Q3_costs.xlsx (spreadsheet, 47 KB)"))
        let filesOnly = Daemon.userTurnPrompt("", source: "app", attachments: fetched)
        XCTAssertTrue(filesOnly.contains("(no text — the user sent only the attached files"))
    }

    func testDisplayTextIsTheUsersWordsPlusOneCompactLine() {
        XCTAssertEqual(DaemonAttachments.displayText("  hi ", attachments: []), "hi")
        XCTAssertEqual(DaemonAttachments.displayText("cost by quarter", attachments: [xlsx]),
                       "cost by quarter\n[Attached: Q3 costs.xlsx (spreadsheet, 47 KB)]")
        XCTAssertEqual(DaemonAttachments.displayText("", attachments: [xlsx]), "[Attached: Q3 costs.xlsx (spreadsheet, 47 KB)]")
    }

    func testOnlySmallCommonImagesBecomeImageParts() {
        func image(_ mime: String) -> MessageAttachment { .init(key: "k/x", name: "x", mime: mime) }
        let refs = DaemonAttachments.imageReferences([
            .init(attachment: image("image/png"), path: "/a.png", bytes: 100),
            .init(attachment: image("image/jpg"), path: "/b.jpg", bytes: 100),
            .init(attachment: image("image/heic"), path: "/c.heic", bytes: 100),
            .init(attachment: image("image/png"), path: "/d.png", bytes: AgentImageReference.maxBytes + 1),
            .init(attachment: image("image/png"), failure: "HTTP 403"),
            .init(attachment: xlsx, path: "/e.xlsx", bytes: 100),
        ])
        XCTAssertEqual(refs, [.init(path: "/a.png", mimeType: "image/png"), .init(path: "/b.jpg", mimeType: "image/jpeg")])
    }

    // MARK: Download

    func testDownloadSavesNumbersClashesAndReportsFailuresWithoutThrowing() async throws {
        let failing = MessageAttachment(key: "k/gone.pdf", name: "gone.pdf", mime: "application/pdf", url: "https://s3.example/gone")
        let noURL = MessageAttachment(key: "k/nourl.txt", name: "nourl.txt", mime: "text/plain")
        let message = DaemonSiteClient.Ledger.HeldMessage(
            id: "m-1", text: "", source: "app", threadID: "m-root", attachments: [xlsx, xlsx, failing, noURL]
        )
        let fetch = Daemon.attachmentFetcher(root: scratch) { request in
            let gone = request.url!.path == "/gone"
            let response = HTTPURLResponse(url: request.url!, statusCode: gone ? 403 : 200, httpVersion: nil, headerFields: nil)!
            return (Data(gone ? "denied".utf8 : "sheet-bytes".utf8), response)
        }
        let fetched = await fetch(message)
        let folder = scratch + "/m-root"
        XCTAssertEqual(fetched.map(\.path), [folder + "/Q3_costs.xlsx", folder + "/Q3_costs (2).xlsx", nil, nil])
        XCTAssertEqual(fetched.map(\.failure), [nil, nil, "HTTP 403", "no download link"])
        XCTAssertEqual(fetched[0].bytes, 11)
        XCTAssertEqual(try String(contentsOfFile: folder + "/Q3_costs.xlsx", encoding: .utf8), "sheet-bytes")

        // No thread from the claim: the message is its own folder.
        let rootless = DaemonSiteClient.Ledger.HeldMessage(id: "m-2", text: "x", source: "app", attachments: [xlsx])
        let second = await fetch(rootless)
        XCTAssertEqual(second.first?.path, scratch + "/m-2/Q3_costs.xlsx")

        // A thrown transport error is a failure line too.
        struct Boom: LocalizedError { var errorDescription: String? { "timed out" } }
        let throwing = Daemon.attachmentFetcher(root: scratch) { _ in throw Boom() }
        let third = await throwing(rootless)
        XCTAssertEqual(third.first?.failure, "timed out")
    }

    @MainActor
    func testClaimResponseAttachmentsWinAndDownloadStartsAtClaim() async {
        let ledgerPath = scratch + "-ledger.json"
        defer { try? FileManager.default.removeItem(atPath: ledgerPath) }
        let client = DaemonSiteClient(
            siteID: "A4A1D987-0000-4000-8000-000000000000", displayName: "Mac", token: "t",
            heartbeatSeconds: 20, endpointURL: "https://cp.example", ledgerPath: ledgerPath, audit: { _ in }
        )
        await client.configure(
            runID: nil,
            transport: { request in
                let body: String
                if request.url!.path.hasSuffix("/claim") {
                    body = #"{"threadId":"t-7","attachments":[{"key":"users/u/fin/attachments/f/1/a.pdf","name":"a.pdf","mime":"application/pdf","size":3,"url":"https://s3/fresh"}]}"#
                } else {
                    body = #"{"role":"primary","messages":[{"id":"m-1","text":"read it","attachments":[{"key":"users/u/fin/attachments/f/1/a.pdf","name":"a.pdf","mime":"application/pdf","size":3,"url":"https://s3/stale"}]}]}"#
                }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            state: { "idle" }, capabilities: { [:] }, onCommand: { _ in }
        )
        let root = scratch!
        await client.setAttachmentFetcher { message in
            [FetchedAttachment(attachment: message.attachmentList[0], path: root + "/" + (message.threadID ?? "?"), bytes: 3)]
        }
        await client.beat()
        let held = await client.ledger.held.first
        XCTAssertEqual(held?.threadID, "t-7")
        XCTAssertEqual(held?.attachmentList.first?.url, "https://s3/fresh", "the claim's freshly signed url wins")
        let fetched = await client.fetchedAttachments(for: "m-1")
        XCTAssertEqual(fetched?.first?.path, root + "/t-7")
        let again = await client.fetchedAttachments(for: "m-1")
        XCTAssertNil(again, "handed out once")
    }
}

import XCTest
@testable import FinAgentCore

/// Image parts on a user message (docs/XANADU.md): the wire form, the token
/// estimate, and history trimming that drops pixels before it drops words.
final class AgentImagePartsTests: XCTestCase {
    private var imagePath: String!

    override func setUp() {
        super.setUp()
        imagePath = NSTemporaryDirectory() + "fin-image-\(UUID().uuidString).png"
        FileManager.default.createFile(atPath: imagePath, contents: Data([0x89, 0x50, 0x4E, 0x47]))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: imagePath)
        super.tearDown()
    }

    func testPlainMessageStaysAStringAndAnImageMessageBecomesParts() {
        let plain = AgentEndpointClient.wireMessage(AgentMessage(role: .user, text: "hi"))
        XCTAssertEqual(plain["content"] as? String, "hi")

        let image = AgentImageReference(path: imagePath, mimeType: "image/png")
        let wire = AgentEndpointClient.wireMessage(AgentMessage(role: .user, text: "what is this", images: [image]))
        let parts = wire["content"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?[0]["type"] as? String, "text")
        XCTAssertEqual(parts?[0]["text"] as? String, "what is this")
        XCTAssertEqual(parts?[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts?[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,iVBORw==")
    }

    func testAMissingImageFileFallsBackToTheStringForm() {
        let gone = AgentImageReference(path: imagePath + ".gone", mimeType: "image/png")
        let wire = AgentEndpointClient.wireMessage(AgentMessage(role: .user, text: "hi", images: [gone]))
        XCTAssertEqual(wire["content"] as? String, "hi")
    }

    func testImagesCountTowardTheEstimate() {
        var transcript = AgentTranscript()
        transcript.append(AgentMessage(role: .user, text: "hi"))
        let before = transcript.estimatedTokenCount
        var withImage = AgentTranscript()
        withImage.append(AgentMessage(role: .user, text: "hi", images: [.init(path: imagePath, mimeType: "image/png")]))
        XCTAssertEqual(withImage.estimatedTokenCount - before, AgentTranscript.estimatedTokensPerImage)
    }

    func testTrimmingDropsOldImagesBeforeAnyText() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "system")
        let image = AgentImageReference(path: imagePath, mimeType: "image/png")
        transcript.append(AgentMessage(role: .user, text: "old question", images: [image, image]))
        transcript.append(AgentMessage(role: .assistant, text: "old answer"))
        transcript.append(AgentMessage(role: .user, text: "new question", images: [image]))
        let budget = AgentTranscript.estimatedTokensPerImage + 100
        XCTAssertTrue(transcript.compactIfNeeded(budget: budget))
        XCTAssertEqual(transcript.messages.map(\.text), ["system", "old question", "old answer", "new question"],
                       "stripping the old images was enough — no text was dropped")
        XCTAssertEqual(transcript.messages[1].images, [])
        XCTAssertEqual(transcript.messages[3].images, [image], "the newest user message keeps its image")
        XCTAssertEqual(transcript.droppedMessageCount, 0)
    }

    func testTrimmingFallsThroughToTextOnceImagesAreGone() {
        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "system")
        let image = AgentImageReference(path: imagePath, mimeType: "image/png")
        transcript.append(AgentMessage(role: .user, text: String(repeating: "a", count: 4_000), images: [image]))
        transcript.append(AgentMessage(role: .assistant, text: "ok"))
        transcript.append(AgentMessage(role: .user, text: "now"))
        XCTAssertTrue(transcript.compactIfNeeded(budget: 200))
        XCTAssertFalse(transcript.messages.contains { $0.text.hasPrefix("aaaa") })
        XCTAssertEqual(transcript.messages.last?.text, "now")
    }

    func testReferenceIsCodable() throws {
        let image = AgentImageReference(path: "/x.png", mimeType: "image/png")
        let data = try JSONEncoder().encode(image)
        XCTAssertEqual(try JSONDecoder().decode(AgentImageReference.self, from: data), image)
    }
}

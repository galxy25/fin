import XCTest
@testable import fin

/// Pure-logic coverage for the app's artifacts browser: path validation (what the "New
/// File" prompt accepts) and path-segment encoding (must agree with the daemon's own
/// `DaemonArtifactClient` and the Lambda's `ARTIFACT_PATH` regex — a drift on either
/// side fails loudly in exactly one place, same reasoning `DaemonArtifactClientTests`
/// documents for the wire contract on the daemon side).
final class ArtifactsClientTests: XCTestCase {

    // MARK: - ArtifactsView.isValidNewPath

    func testValidPathsAreAccepted() {
        XCTAssertTrue(ArtifactsView.isValidNewPath("todo.txt"))
        XCTAssertTrue(ArtifactsView.isValidNewPath("notes/todo.txt"))
        XCTAssertTrue(ArtifactsView.isValidNewPath("a1B2_3-4.5/6"))
    }

    func testEmptyPathIsRejected() {
        XCTAssertFalse(ArtifactsView.isValidNewPath(""))
    }

    func testPathMustStartWithAnAlphanumeric() {
        XCTAssertFalse(ArtifactsView.isValidNewPath("/notes/todo.txt"))
        XCTAssertFalse(ArtifactsView.isValidNewPath(".hidden"))
        XCTAssertFalse(ArtifactsView.isValidNewPath("-dash.txt"))
    }

    func testPathWithADotDotSegmentIsRejected() {
        XCTAssertFalse(ArtifactsView.isValidNewPath("notes/../secrets.txt"))
        XCTAssertFalse(ArtifactsView.isValidNewPath(".."))
    }

    func testPathWithDisallowedCharactersIsRejected() {
        XCTAssertFalse(ArtifactsView.isValidNewPath("notes/a b.txt"), "spaces must be rejected client-side too")
        XCTAssertFalse(ArtifactsView.isValidNewPath("notes/a?b.txt"))
    }

    func testPathOverTheLengthLimitIsRejected() {
        let tooLong = "a" + String(repeating: "b", count: 301)
        XCTAssertFalse(ArtifactsView.isValidNewPath(tooLong))
        let atLimit = "a" + String(repeating: "b", count: 300)
        XCTAssertTrue(ArtifactsView.isValidNewPath(atLimit))
    }

    // MARK: - ArtifactsClient.encodedPath

    func testEncodedPathPercentEncodesEachSegmentIndividually() {
        XCTAssertEqual(ArtifactsClient.encodedPath("notes/a b.txt"), "notes/a%20b.txt")
    }

    func testEncodedPathLeavesOrdinaryPathsUnchanged() {
        XCTAssertEqual(ArtifactsClient.encodedPath("notes/todo.txt"), "notes/todo.txt")
    }
}

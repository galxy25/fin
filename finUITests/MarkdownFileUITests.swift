import XCTest

/// Drives the Files tab against a real running macOS app. The system file-open/
/// save panels (`fileImporter`/`fileExporter`) can't be driven by XCUITest, so
/// these tests rely on `MarkdownListView.seedUITestFileIfNeeded()` — a fixture
/// document written straight into the sandbox and bookmarked directly, gated on
/// the same `FIN_UI_TESTING` launch environment flag `launchFinApp()` sets.
///
/// The regression this suite pins: opening a file rendered as a narrow, centered
/// rectangle of the theme's background color instead of filling the window,
/// until switching to Edit (`TextEditor` is inherently greedy about the space
/// it's given; the plain `ScrollView` wrapping the read-only `Text` was not).
final class MarkdownFileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openFilesTab(_ app: XCUIApplication) -> XCUIElement {
        let filesPicker = element(app, id: "homeMode_Files")
        XCTAssertTrue(filesPicker.waitForExistence(timeout: 5), "Files tab picker segment never appeared")
        filesPicker.tapCenter()

        let fileList = element(app, id: "fileListView")
        XCTAssertTrue(fileList.waitForExistence(timeout: 5), "File list never appeared")
        return fileList
    }

    private func openSeededFile(_ app: XCUIApplication) {
        _ = openFilesTab(app)
        let fileRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fileRow_"))
            .firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "Expected the seeded UI-test fixture file to appear")
        fileRow.tapCenter()
    }

    /// The exact live-reported bug: the read pane's background should span the
    /// full window width, matching the editor's, rather than collapsing to a
    /// narrow centered rectangle.
    func testReaderFillsWindowWidth() throws {
        let app = launchFinApp()
        openSeededFile(app)

        let scroll = element(app, id: "markdownReaderScroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "Reader scroll view never appeared")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Not exact equality — the window has padding/insets — but a regression
        // back to a narrow centered rectangle would show a scroll view a small
        // fraction of the window's width, not something close to filling it.
        let widthRatio = scroll.frame.width / window.frame.width
        XCTAssertGreaterThan(
            widthRatio, 0.85,
            "Reader pane should fill the window width, not render as a narrow centered rectangle (ratio: \(widthRatio))"
        )
    }

    /// Round-trips into Edit and back, confirming the read pane keeps filling
    /// the window after an edit — not just on first open.
    func testEditingThenReturningToReadKeepsFullWidth() throws {
        let app = launchFinApp()
        openSeededFile(app)

        let editToggle = element(app, id: "markdownEditToggle")
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.tapCenter()

        let editor = element(app, id: "markdownEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Editor never appeared after toggling Edit")

        editToggle.tapCenter()

        let scroll = element(app, id: "markdownReaderScroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "Reader scroll view never reappeared after leaving Edit")

        let window = app.windows.firstMatch
        let widthRatio = scroll.frame.width / window.frame.width
        XCTAssertGreaterThan(
            widthRatio, 0.85,
            "Reader pane should still fill the window width after round-tripping Edit (ratio: \(widthRatio))"
        )
    }
}

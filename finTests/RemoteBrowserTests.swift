import XCTest
import ImageIO
@testable import fin

/// The app's half of Remote Browser (docs/REMOTE-BROWSER.md): where a tap lands on the
/// page, and whether a site says it serves the feature. The wire protocol itself is
/// tested once, in the daemon package (RemoteBrowserProtocolTests), because both ends
/// compile that same file.
final class RemoteBrowserTests: XCTestCase {
    // MARK: - Tap geometry

    func testATapOnAFrameThatFillsTheViewMapsDirectly() {
        let point = RemoteBrowserSession.normalizedPoint(
            CGPoint(x: 100, y: 50), in: CGSize(width: 400, height: 200), imageSize: CGSize(width: 1280, height: 640)
        )
        XCTAssertEqual(point?.x ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 0.0001)
    }

    /// A landscape page on a portrait phone: letterboxed top and bottom. The same tap
    /// point must land relative to the SHOWN page, not the view.
    func testLetterboxingIsAccountedFor() {
        // 1280x640 page (2:1) aspect-fit into 400x400 → shown 400x200, bars of 100 above/below.
        let view = CGSize(width: 400, height: 400), image = CGSize(width: 1280, height: 640)
        let center = RemoteBrowserSession.normalizedPoint(CGPoint(x: 200, y: 200), in: view, imageSize: image)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.0001)
        let topOfPage = RemoteBrowserSession.normalizedPoint(CGPoint(x: 200, y: 100), in: view, imageSize: image)
        XCTAssertEqual(topOfPage?.y ?? -1, 0, accuracy: 0.0001)
    }

    func testATapOnTheLetterboxIsNotAClick() {
        // A tap in the bar above the page must not become a click at the page's top edge.
        XCTAssertNil(RemoteBrowserSession.normalizedPoint(
            CGPoint(x: 200, y: 40), in: CGSize(width: 400, height: 400), imageSize: CGSize(width: 1280, height: 640)
        ))
    }

    func testDegenerateSizesAreNotADivideByZero() {
        XCTAssertNil(RemoteBrowserSession.normalizedPoint(.zero, in: .zero, imageSize: CGSize(width: 10, height: 10)))
        XCTAssertNil(RemoteBrowserSession.normalizedPoint(.zero, in: CGSize(width: 10, height: 10), imageSize: .zero))
    }

    // MARK: - Frames

    func testAFrameDecodesToAnImage() throws {
        // A real JPEG encoded here, so this exercises ImageIO end to end rather than a
        // hand-typed byte string that might not be a valid JPEG at all.
        let jpeg = try XCTUnwrap(Self.makeJPEG(width: 4, height: 3)).base64EncodedString()
        let image = try XCTUnwrap(RemoteBrowserSession.decodeJPEG(base64: jpeg))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        XCTAssertNil(RemoteBrowserSession.decodeJPEG(base64: "not base64!"))
    }

    private static func makeJPEG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Capability

    func testTheCapabilityDecodesAndAbsenceMeansNo() throws {
        let with = try JSONDecoder().decode(FinSite.Capabilities.self, from: Data(#"{"remote_browser": true, "vnc_proxy": false}"#.utf8))
        XCTAssertEqual(with.remoteBrowser, true)
        XCTAssertEqual(with.vncProxy, false)
        let older = try JSONDecoder().decode(FinSite.Capabilities.self, from: Data(#"{"daemon_version": "1.11.3"}"#.utf8))
        XCTAssertNil(older.remoteBrowser, "a daemon that predates the feature omits it — nil, never a false yes")
    }

    // MARK: - Browser tabs (iPhone / iPad)

    @MainActor
    func testOpeningTheSameSiteTwiceBringsItsTabForwardInsteadOfASecondSession() {
        let manager = SessionManager()
        manager.openBrowserTab(siteID: "s1", displayName: "Work laptop")
        let first = manager.browserTabs.first?.session
        manager.openBrowserTab(siteID: "s1", displayName: "Work laptop")
        XCTAssertEqual(manager.browserTabs.count, 1)
        XCTAssertTrue(manager.browserTabs.first?.session === first, "the live session survives — no re-wake, no second Face ID")
        XCTAssertEqual(manager.activeBrowserTab?.siteID, "s1")
    }

    @MainActor
    func testClosingTheBrowserTabHandsFocusBackToTheTerminals() {
        // (Terminal-tab gestures clearing browser focus isn't asserted here: a
        // SessionManager restores the HOST's saved terminal tabs, so what `selectTab`
        // lands on depends on the machine running the test.)
        let manager = SessionManager()
        manager.openBrowserTab(siteID: "s1", displayName: "Work laptop")
        manager.closeBrowserTab("s1")
        XCTAssertNil(manager.activeBrowserSiteID)
        XCTAssertTrue(manager.browserTabs.isEmpty)
    }
}

import XCTest
@testable import FinAgentCore

/// `RemoteBrowserProtocol` — the shared wire format and the CDP translation. Both ends
/// compile this file, so a round-trip test here is a test of the actual contract between
/// the app and the daemon, not of two copies that merely agree today.
final class RemoteBrowserProtocolTests: XCTestCase {
    typealias P = RemoteBrowserProtocol

    // MARK: - Round trips through a relay frame

    func testEveryInputRoundTripsThroughTheRelayFrame() throws {
        let inputs: [P.Input] = [
            .tap(x: 0.25, y: 0.75),
            .scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: 400),
            .text("hunter2 with spaces & symbols !@#"),
            .key(.enter),
            .navigate("github.com/login"),
            .selectTab("TAB-1"),
        ]
        for input in inputs {
            let frame = P.inputFrame(sessionId: "s-1", input: input)
            XCTAssertEqual(frame["action"] as? String, "input", "the relay only forwards app→site on `input`")
            // Through real JSON, the way it actually crosses the relay.
            let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: frame)) as! [String: Any]
            XCTAssertEqual(P.input(fromRelayFrame: wire), input)
        }
    }

    func testFramesRoundTripAndRideTheOutputAction() throws {
        let original = P.Frame(jpegBase64: "AAAA", width: 1280, height: 800, url: "https://github.com/login", title: "Sign in")
        let frame = original.relayFrame(sessionId: "s-1")
        XCTAssertEqual(frame["action"] as? String, "output", "the relay only forwards site→app on `output`")
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: frame)) as! [String: Any]
        XCTAssertEqual(P.Frame(relayFrame: wire), original)
    }

    func testTabsRoundTrip() throws {
        let tabs = [P.Tab(id: "a", title: "GitHub", url: "https://github.com"), P.Tab(id: "b", title: "Gmail", url: "https://mail.google.com")]
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(
            withJSONObject: P.tabsFrame(sessionId: "s", tabs: tabs, selected: "b"))) as! [String: Any]
        let decoded = try XCTUnwrap(P.tabs(fromRelayFrame: wire))
        XCTAssertEqual(decoded.tabs, tabs)
        XCTAssertEqual(decoded.selected, "b")
    }

    func testAFrameWithNoSizeIsRejectedRatherThanDividingByZeroLater() {
        XCTAssertNil(P.Frame(relayFrame: ["kind": P.frameKind, "data": "AA", "width": 0, "height": 800]))
    }

    func testForeignOrMalformedInputIsIgnored() {
        XCTAssertNil(P.input(fromRelayFrame: ["action": "input", "data": "bHM="]), "a terminal input frame is not browser input")
        XCTAssertNil(P.input(fromRelayFrame: ["kind": P.inputKind, "event": ["type": "tap", "x": 0.5]]))
        XCTAssertNil(P.input(fromRelayFrame: ["kind": P.inputKind, "event": ["type": "key", "key": "f13"]]))
        XCTAssertNil(P.input(fromRelayFrame: ["kind": P.inputKind, "event": ["type": "text", "text": ""]]))
    }

    func testTapCoordinatesAreClampedNotTrusted() {
        let frame: [String: Any] = ["kind": P.inputKind, "event": ["type": "tap", "x": 1.4, "y": -0.2]]
        XCTAssertEqual(P.input(fromRelayFrame: frame), .tap(x: 1, y: 0))
    }

    // MARK: - CDP translation

    func testATapIsAMovePressAndReleaseAtViewportPixels() {
        let commands = P.cdpCommands(for: .tap(x: 0.5, y: 0.25), viewportWidth: 1000, viewportHeight: 800)
        XCTAssertEqual(commands.map { $0.params["type"] }, ["mouseMoved", "mousePressed", "mouseReleased"])
        XCTAssertTrue(commands.allSatisfy { $0.method == "Input.dispatchMouseEvent" })
        XCTAssertEqual(commands[1].params["x"], 500.0)
        XCTAssertEqual(commands[1].params["y"], 200.0)
        XCTAssertEqual(commands[1].params["button"], "left")
    }

    func testTextIsInsertedWholeNotTypedKeyByKey() {
        XCTAssertEqual(
            P.cdpCommands(for: .text("p@ss w0rd"), viewportWidth: 1, viewportHeight: 1),
            [P.CDPCommand("Input.insertText", ["text": "p@ss w0rd"])]
        )
    }

    func testEnterCarriesTextSoFormsActuallySubmit() {
        let commands = P.cdpCommands(for: .key(.enter), viewportWidth: 1, viewportHeight: 1)
        XCTAssertEqual(commands.map { $0.params["type"] }, ["keyDown", "keyUp"])
        XCTAssertEqual(commands[0].params["text"], "\r")
        XCTAssertEqual(commands[0].params["windowsVirtualKeyCode"], 13)
    }

    func testNonCharacterKeysCarryNoText() {
        let commands = P.cdpCommands(for: .key(.backspace), viewportWidth: 1, viewportHeight: 1)
        XCTAssertNil(commands[0].params["text"])
        XCTAssertEqual(commands[0].params["key"], "Backspace")
    }

    func testSelectingATabIsNotAPageCommand() {
        XCTAssertTrue(P.cdpCommands(for: .selectTab("x"), viewportWidth: 1, viewportHeight: 1).isEmpty)
    }

    func testNavigationNormalizesABareHost() {
        XCTAssertEqual(P.normalizedURL("github.com/login"), "https://github.com/login")
        XCTAssertEqual(P.normalizedURL("  http://localhost:3000 "), "http://localhost:3000")
        XCTAssertEqual(P.normalizedURL("about:blank"), "about:blank")
    }

    // MARK: - Tab selection

    private let targets: [P.Target] = [
        .init(id: "dt", type: "page", title: "DevTools", url: "devtools://devtools/x", webSocketDebuggerUrl: "ws://d"),
        .init(id: "gmail", type: "page", title: "Gmail", url: "https://mail.google.com", webSocketDebuggerUrl: "ws://g"),
        .init(id: "sw", type: "service_worker", title: "", url: "https://x/sw.js", webSocketDebuggerUrl: "ws://s"),
        .init(id: "gh", type: "page", title: "GitHub", url: "https://github.com", webSocketDebuggerUrl: "ws://h"),
        .init(id: "ext", type: "page", title: "Ext", url: "chrome-extension://abc/bg.html", webSocketDebuggerUrl: "ws://e"),
    ]

    func testOnlyRealPagesAreViewable() {
        XCTAssertEqual(P.viewableTabs(targets).map(\.id), ["gmail", "gh"])
    }

    func testThePreferredTabWinsWhileItExistsElseTheMostRecent() {
        XCTAssertEqual(P.pickTab(targets, preferring: "gh")?.id, "gh")
        XCTAssertEqual(P.pickTab(targets, preferring: "closed-tab")?.id, "gmail", "Chrome lists most-recently-active first")
        XCTAssertEqual(P.pickTab(targets, preferring: nil)?.id, "gmail")
        XCTAssertNil(P.pickTab([], preferring: nil))
    }

    func testParsesChromesJSONList() {
        let json = #"[{"id":"A","type":"page","title":"t","url":"https://a","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/A"},{"type":"page"}]"#
        let parsed = P.targets(fromJSONList: Data(json.utf8))
        XCTAssertEqual(parsed.map(\.id), ["A"], "an entry with no id is skipped, not a crash")
        XCTAssertEqual(parsed.first?.webSocketDebuggerUrl, "ws://127.0.0.1:9222/devtools/page/A")
    }

    // MARK: - Finding a browser

    func testRealChromeWinsOverPlaywrightsBrowser() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let found = RemoteBrowserProtocol.findBrowser(
            configured: nil, home: "/Users/x",
            isExecutable: { _ in true }, listDirectory: { _ in ["chromium-1181"] }
        )
        XCTAssertEqual(found, chrome)
    }

    /// The work laptop's actual shape (2026-09-23): no Chrome in /Applications, only
    /// Playwright's cache — newest revision first, numerically.
    func testFallsBackToTheNewestPlaywrightBrowser() {
        let newest = "/Users/x/Library/Caches/ms-playwright/chromium-1000/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let older = "/Users/x/Library/Caches/ms-playwright/chromium-999/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
        let found = RemoteBrowserProtocol.findBrowser(
            configured: nil, home: "/Users/x",
            isExecutable: { $0 == newest || $0 == older },
            listDirectory: { _ in ["chromium-999", "ffmpeg-1011", "chromium-1000"] }
        )
        XCTAssertEqual(found, newest)
    }

    func testAConfiguredPathIsNeverSecondGuessed() {
        XCTAssertEqual(RemoteBrowserProtocol.findBrowser(
            configured: "/opt/b", home: "/Users/x", isExecutable: { _ in true }, listDirectory: { _ in [] }
        ), "/opt/b")
        XCTAssertNil(RemoteBrowserProtocol.findBrowser(
            configured: "/opt/missing", home: "/Users/x", isExecutable: { $0 != "/opt/missing" }, listDirectory: { _ in [] }
        ), "a broken explicit path is reported, not silently swapped for another browser")
    }

    func testNoBrowserAnywhereIsNil() {
        XCTAssertNil(RemoteBrowserProtocol.findBrowser(
            configured: nil, home: "/Users/x", isExecutable: { _ in false }, listDirectory: { _ in [] }
        ))
    }
}

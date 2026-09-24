import XCTest
@testable import FinAgentCore

final class RemoteDesktopProtocolTests: XCTestCase {
    let laptop = CGRectLike(x: 0, y: 0, width: 1512, height: 982)

    func testATapClicksAtThePointOnTheDisplay() {
        let events = RemoteDesktopProtocol.events(for: .tap(x: 0.5, y: 0.25), display: laptop)
        XCTAssertEqual(events, [
            .mouseMove(x: 756, y: 245.5), .mouseDown(x: 756, y: 245.5), .mouseUp(x: 756, y: 245.5),
        ])
    }

    /// A display that isn't the main one sits at an offset in global coordinates.
    func testASecondaryDisplaysOriginIsRespected() {
        let external = CGRectLike(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(RemoteDesktopProtocol.events(for: .tap(x: 0, y: 0), display: external).first,
                       .mouseMove(x: 1512, y: -200))
    }

    /// The app sends CDP's convention (positive deltaY = page moves down, like a wheel
    /// turned toward you); CGEvent's wheel is the opposite sign. Getting this wrong makes
    /// every drag scroll backwards.
    func testScrollMovesThePointerThenFlipsToTheWheelConvention() {
        let events = RemoteDesktopProtocol.events(for: .scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: 120), display: laptop)
        XCTAssertEqual(events, [.mouseMove(x: 756, y: 491), .scroll(dx: 0, dy: -120)])
    }

    func testLongTextIsChunkedWithoutSplittingACharacter() {
        let text = String(repeating: "a", count: 19) + "😀" + "bc"  // the emoji is 2 UTF-16 units
        let events = RemoteDesktopProtocol.events(for: .text(text), display: laptop)
        XCTAssertEqual(events, [.text(String(repeating: "a", count: 19)), .text("😀bc")])
        for case .text(let chunk) in events {
            XCTAssertLessThanOrEqual(chunk.utf16.count, RemoteDesktopProtocol.maxUnicodeChunk)
        }
    }

    func testSpecialKeysUseLayoutIndependentKeyCodes() {
        XCTAssertEqual(RemoteDesktopProtocol.events(for: .key(.enter), display: laptop), [.key(virtualKeyCode: 36, modifiers: [])])
        XCTAssertEqual(RemoteDesktopProtocol.events(for: .key(.backspace), display: laptop), [.key(virtualKeyCode: 51, modifiers: [])])
        XCTAssertEqual(
            RemoteDesktopProtocol.events(for: .key(.tab, modifiers: [.command]), display: laptop),
            [.key(virtualKeyCode: 48, modifiers: [.command])]
        )
        // The four new navigation keys carry codes distinct from the originals.
        XCTAssertEqual(RemoteDesktopProtocol.virtualKeyCode(for: .home), 115)
        XCTAssertEqual(RemoteDesktopProtocol.virtualKeyCode(for: .pageDown), 121)
        // Every key has a code — a new SpecialKey case can't silently map to nothing.
        let codes = Set(RemoteBrowserProtocol.SpecialKey.allCases.map(RemoteDesktopProtocol.virtualKeyCode(for:)))
        XCTAssertEqual(codes.count, RemoteBrowserProtocol.SpecialKey.allCases.count)
    }

    func testBrowserOnlyInputsDoNothingOnADesktop() {
        XCTAssertTrue(RemoteDesktopProtocol.events(for: .navigate("https://github.com"), display: laptop).isEmpty)
        XCTAssertTrue(RemoteDesktopProtocol.events(for: .selectTab("t1"), display: laptop).isEmpty)
        XCTAssertTrue(RemoteDesktopProtocol.events(for: .selectDisplay("1"), display: laptop).isEmpty)
    }

    /// Mission Control (Ctrl+↑), Spaces (Ctrl+←/→) and Spotlight (Cmd+Space) are
    /// all just chords over primitives this file already maps — no protocol change
    /// needed for the carousel's system-shortcut buttons, only for `.space` itself.
    func testShowDesktopAndScreenshotHaveTheirOwnKeyCodes() {
        // Show Desktop: bare F11, no modifier. Screenshot: Cmd+Shift+5.
        XCTAssertEqual(RemoteDesktopProtocol.virtualKeyCode(for: .f11), 103)
        XCTAssertEqual(
            RemoteDesktopProtocol.events(for: .key(.digit5, modifiers: [.command, .shift]), display: laptop),
            [.key(virtualKeyCode: 23, modifiers: [.command, .shift])]
        )
    }

    func testSystemShortcutsAreOrdinaryChordsOverExistingPrimitives() {
        XCTAssertEqual(
            RemoteDesktopProtocol.events(for: .key(.space, modifiers: [.command]), display: laptop),
            [.key(virtualKeyCode: 49, modifiers: [.command])]
        )
        XCTAssertEqual(
            RemoteDesktopProtocol.events(for: .key(.arrowUp, modifiers: [.control]), display: laptop),
            [.key(virtualKeyCode: 126, modifiers: [.control])]
        )
    }

    func testCaptureIsInPointsAndCappedToTheMaxWidth() {
        XCTAssertTrue(RemoteDesktopProtocol.captureSize(displayWidth: 1512, displayHeight: 982, maxWidth: 1600) == (1512, 982))
        XCTAssertTrue(RemoteDesktopProtocol.captureSize(displayWidth: 2560, displayHeight: 1440, maxWidth: 1600) == (1600, 900))
        XCTAssertTrue(RemoteDesktopProtocol.captureSize(displayWidth: 0, displayHeight: 0, maxWidth: 1600) == (0, 0))
    }
}

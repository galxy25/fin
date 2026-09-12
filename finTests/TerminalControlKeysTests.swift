import XCTest
@testable import fin

final class TerminalControlKeysTests: XCTestCase {
    func testControlCodesFollowTheASCIIRule() {
        XCTAssertEqual(TerminalControlKeys.controlCode(for: "c"), 0x03)
        XCTAssertEqual(TerminalControlKeys.controlCode(for: "C"), 0x03)
        XCTAssertEqual(TerminalControlKeys.controlCode(for: "["), 0x1B)
        XCTAssertEqual(TerminalControlKeys.controlCode(for: "@"), 0x00)
        XCTAssertNil(TerminalControlKeys.controlCode(for: "1"))
        XCTAssertNil(TerminalControlKeys.controlCode(for: "é"))
    }

    func testArrowsHonorApplicationCursorMode() {
        XCTAssertEqual(TerminalControlKeys.arrow(.up, applicationCursor: false), Array("\u{1B}[A".utf8))
        XCTAssertEqual(TerminalControlKeys.arrow(.left, applicationCursor: true), Array("\u{1B}OD".utf8))
        XCTAssertEqual(TerminalControlKeys.pageUp, Array("\u{1B}[5~".utf8))
        XCTAssertEqual(TerminalControlKeys.pageDown, Array("\u{1B}[6~".utf8))
    }

    func testSubmittedCommandBytes() {
        XCTAssertEqual(TerminalControlKeys.bytes(forSubmittedCommand: "ls -la", ctrlLatched: false), Array("ls -la".utf8) + [0x0D])
        XCTAssertEqual(TerminalControlKeys.bytes(forSubmittedCommand: "c", ctrlLatched: true), [0x03], "Ctrl + a single letter is that control code")
        XCTAssertEqual(TerminalControlKeys.bytes(forSubmittedCommand: "", ctrlLatched: true), [])
        XCTAssertEqual(TerminalControlKeys.bytes(forSubmittedCommand: "make", ctrlLatched: true), Array("make".utf8) + [0x0D], "the latch cannot apply to a word; it is sent plainly")
        XCTAssertEqual(TerminalControlKeys.bytes(forSubmittedCommand: "", ctrlLatched: false), [0x0D], "a bare Enter is still Enter")
    }

    func testSharedTurnGroupingStillReachableFromTheConsole() {
        let now = Date()
        let records = [
            AgentMirrorRecord(id: "u", kind: .userMessage, text: "hi", timestamp: now, sequence: 1, runID: "r"),
            AgentMirrorRecord(id: "a", kind: .assistantMessage, text: "hello", timestamp: now, sequence: 2, runID: "r"),
        ]
        XCTAssertEqual(TranscriptTurns.turns(from: records).map(\.id), AgentRemoteConsoleView.turns(from: records).map(\.id))
        XCTAssertEqual(MirrorRecords.merge([records]).count, AgentMirrorReader.merge([records]).count)
    }
}

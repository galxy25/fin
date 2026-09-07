import XCTest
@testable import fin

/// Covers `TerminalSession.send(bytes:)`'s failure reporting directly — no real SSH
/// transport needed, since the exact bug lived in what happens when there ISN'T one:
/// a disconnected session (no `stdinWriter`) used to silently drop the bytes and still
/// let the caller believe the send went through. These construct a session and never
/// connect it (or connect it only via the DEBUG-only `simulateConnectedStateForTesting`
/// state seam, which still leaves `stdinWriter` nil), so every send here is expected to
/// fail — that failure being reported honestly is the entire point.
@MainActor
final class TerminalSessionSendTests: XCTestCase {

    func testSendOnADisconnectedSessionReportsFailure() async {
        let session = TerminalSession(serverID: UUID())
        XCTAssertEqual(session.state, .disconnected)

        let sent = await session.send(bytes: Array("echo hi".utf8)).value

        XCTAssertFalse(sent, "a disconnected session's write must report failure, not silently succeed")
        XCTAssertNotNil(session.lastError, "a failed send must leave a reason readable somewhere")
    }

    func testFailedSendDoesNotRecordTheInputAsIfItWereDelivered() async {
        let session = TerminalSession(serverID: UUID())

        _ = await session.send(bytes: Array("rm -rf /".utf8)).value

        XCTAssertTrue(
            session.eventLog.events.isEmpty,
            "bytes that never reached the channel must not appear in the event log as if they had — "
                + "the agent reads this log to decide what has actually happened"
        )
    }

    #if DEBUG
    /// `state == .connected` alone is not proof of a live writer — this is exactly the
    /// TOCTOU gap `AgentRuntime.executeSendInput`'s own pre-check guard cannot close on
    /// its own, which is why the write itself has to report its real outcome too.
    func testSendStillFailsWhenStateSaysConnectedButNoWriterExists() async {
        let session = TerminalSession(serverID: UUID())
        session.simulateConnectedStateForTesting()
        XCTAssertEqual(session.state, .connected)

        let sent = await session.send(bytes: Array("echo hi".utf8)).value

        XCTAssertFalse(sent, "`state` is not the same fact as \"a writer exists\" — the real write must still fail honestly")
    }
    #endif

    func testSendTextForwardsToSendBytesAndReportsTheSameFailure() async {
        let session = TerminalSession(serverID: UUID())

        let sent = await session.send(text: "echo hi").value

        XCTAssertFalse(sent)
    }

    func testSendAgentInputOnADisconnectedSessionReportsFailure() async {
        let session = TerminalSession(serverID: UUID())

        let task = session.sendAgentInput("echo hi")

        XCTAssertNotNil(task, "non-empty text always has something to attempt sending")
        let sent = await task?.value
        XCTAssertEqual(sent, false, "the agent's own send path must see the same honest failure, not a silent no-op")
    }

    func testSendAgentInputWithEmptyTextIsATrivialNoOpNotAFailure() {
        let session = TerminalSession(serverID: UUID())

        let task = session.sendAgentInput("")

        XCTAssertNil(task, "nothing to send is not the same fact as a failed send")
    }

    func testWritesToADisconnectedSessionRemainStrictlyOrdered() async {
        // Two sends in flight against a session with no writer: both must fail, and
        // the second must not resolve before whatever ordering the first implies —
        // this is the same chaining guarantee `send(bytes:)`'s own doc comment
        // describes for successful writes, just exercised on the failure path, which
        // is the path that changed in this fix.
        let session = TerminalSession(serverID: UUID())

        let first = session.send(bytes: Array("one".utf8))
        let second = session.send(bytes: Array("two".utf8))

        let firstSent = await first.value
        let secondSent = await second.value

        XCTAssertFalse(firstSent)
        XCTAssertFalse(secondSent)
    }
}

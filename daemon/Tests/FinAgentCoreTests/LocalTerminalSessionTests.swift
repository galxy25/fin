import XCTest
@testable import FinAgentCore

/// The local-PTY transport, exercised against REAL child processes.
///
/// Unlike `TmuxSessionReadTests` — which deliberately starts nothing, because what it
/// checks is a pure validator — everything worth knowing about this file is in the
/// syscalls: whether `forkpty` actually gave the child a controlling terminal, whether a
/// write lands, whether the reader keeps byte order, whether a dead child is noticed. None
/// of that can be asserted about a mock. So these tests spawn `/bin/sh`, which is on every
/// machine this daemon runs on, and never tmux — the tmux behaviour is the same connect
/// command the SSH transport already uses, and proving it needs a tmux server, which
/// belongs in the live shakedown rather than here.
@MainActor
final class LocalTerminalSessionTests: XCTestCase {

    private func makeSession(
        command: String = "exec /bin/sh",
        environment: [String: String] = [:]
    ) -> LocalTerminalSession {
        LocalTerminalSession(configuration: LocalSessionConfiguration(
            connectCommand: command,
            environment: environment
        ))
    }

    // MARK: - Connect

    /// The whole point of `forkpty` over `posix_spawn`: the child must be a session leader
    /// with the slave side as its CONTROLLING terminal. A shell without one runs in a
    /// degraded mode — no job control — and tmux refuses outright ("open terminal failed:
    /// not a terminal"), which is precisely the failure this transport exists to avoid.
    /// `tty` naming a real device is the proof.
    func testChildGetsAControllingTerminal() async throws {
        let session = makeSession()
        session.connect()
        try await session.waitForConnection(timeout: 10)
        try await session.waitForShellReady(timeout: 15)

        session.sendAgentInput("tty\r")
        let answer = try await waitForOutput(session, containing: "/dev/tty", timeout: 10)
        XCTAssertTrue(answer.contains("/dev/tty"), "the child has no controlling terminal: \(answer)")
        session.disconnect()
    }

    /// A connect command is a COMMAND, not a line typed into a shell that already exists:
    /// the child IS the command. (The SSH transport has to wait for a prompt and then type
    /// it, which is where its whole auto-attach hazard comes from.)
    func testConnectCommandIsTheChildProcess() async throws {
        let session = makeSession(command: "exec /bin/sh -c 'echo I_AM_THE_CHILD; exec /bin/sh'")
        session.connect()
        try await session.waitForConnection(timeout: 10)
        let answer = try await waitForOutput(session, containing: "I_AM_THE_CHILD", timeout: 10)
        XCTAssertTrue(answer.contains("I_AM_THE_CHILD"))
        session.disconnect()
    }

    /// An empty connect command is a config error, not a session that silently does
    /// nothing: under this transport there would be no process at all.
    func testEmptyConnectCommandFailsLoudly() async {
        let session = makeSession(command: "   ")
        session.connect()
        XCTAssertFalse(session.isSessionConnected)
        XCTAssertNotNil(session.lastError)
    }

    /// The environment reaches the child. This is how `LC_FIN_AGENT` travels without an
    /// `AcceptEnv` line in anyone's sshd config — the daemon sets it directly.
    func testEnvironmentReachesTheChild() async throws {
        let session = makeSession(environment: ["LC_FIN_AGENT": "1", "FIN_TEST_VALUE": "marker-9182"])
        session.connect()
        try await session.waitForConnection(timeout: 10)
        try await session.waitForShellReady(timeout: 15)

        let value = await session.probeEnvironment("FIN_TEST_VALUE", timeout: 10)
        XCTAssertEqual(value, "marker-9182")
        let marker = await session.probeEnvironment("LC_FIN_AGENT", timeout: 10)
        XCTAssertEqual(marker, "1")
        session.disconnect()
    }

    /// A child that exits takes the session with it, and the transport notices — the
    /// engine's `isSessionConnected` check depends on this being true promptly rather than
    /// at the next write.
    func testChildExitDisconnectsTheSession() async throws {
        let session = makeSession(command: "exec /bin/sh -c 'exit 0'")
        session.connect()
        XCTAssertTrue(session.isSessionConnected, "the session is connected the moment the child exists")

        let deadline = Date().addingTimeInterval(10)
        while session.isSessionConnected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(session.isSessionConnected, "a dead child left the session looking alive")
        session.disconnect()
    }

    /// Writes to a session that is not up must REPORT the failure rather than vanish. The
    /// SSH transport learned this the hard way: a dropped write that still appeared in the
    /// event log had everything reading the log believing bytes were delivered.
    func testWriteToADeadSessionReportsFailure() async throws {
        let session = makeSession()
        session.connect()
        try await session.waitForConnection(timeout: 10)
        session.disconnect()

        let landed = await session.sendAgentInput("echo nope\r")?.value
        XCTAssertEqual(landed, false)
        XCTAssertNotNil(session.lastError)
    }

    /// Byte ORDER across many small writes. The reader hands bytes to the main actor
    /// through a lock-protected buffer rather than one hop per chunk precisely because task
    /// enqueue order is not a guarantee, and terminal output is the one thing here that
    /// must never be reordered.
    func testOutputKeepsByteOrderAcrossManyWrites() async throws {
        let session = makeSession()
        session.connect()
        try await session.waitForConnection(timeout: 10)
        try await session.waitForShellReady(timeout: 15)

        for index in 1...12 {
            session.sendAgentInput("echo LINE_\(index)\r")
        }
        let text = try await waitForOutput(session, containing: "LINE_12", timeout: 15)
        let positions = (1...12).compactMap { index -> Int? in
            text.range(of: "LINE_\(index)\n").map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        }
        XCTAssertEqual(positions.count, 12, "not every line came back: \(text)")
        XCTAssertEqual(positions, positions.sorted(), "the shell's output came back out of order")
        session.disconnect()
    }

    // MARK: - runFixedCommand

    /// stdout and stderr stay APART. Merging them is how `tmux capture-pane -t nope` —
    /// exit 1, "can't find session" on stderr — came back to the model as the CONTENTS of a
    /// pane called `nope`.
    func testFixedCommandKeepsStreamsApart() async throws {
        let session = makeSession()
        let result = try await session.runFixedCommand("echo to-stdout; echo to-stderr >&2")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "to-stdout")
        XCTAssertEqual(result.diagnostics.trimmingCharacters(in: .whitespacesAndNewlines), "to-stderr")
        XCTAssertEqual(result.truncation, .none)
    }

    /// A non-zero exit is a FAILURE carrying the command's own first line, never text the
    /// caller could frame as pane content.
    func testFixedCommandNonZeroExitThrows() async {
        let session = makeSession()
        do {
            _ = try await session.runFixedCommand("echo 'can''t find session: nope' >&2; exit 1")
            XCTFail("a non-zero exit must throw")
        } catch let error as HeadlessSessionError {
            guard case .commandFailed(let status, let detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(detail.contains("find session"), "lost the command's own words: \(detail)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Past the byte cap the OLDEST bytes go and the newest survive — "the last N lines of
    /// a pane" means the bottom of it. Keeping the oldest handed the model the top of a long
    /// capture under a label promising the bottom.
    func testFixedCommandDropsOldestBytesPastTheCap() async throws {
        let session = makeSession()
        let result = try await session.runFixedCommand(
            "i=0; while [ $i -lt 400 ]; do echo \"line-$i\"; i=$((i+1)); done",
            maxResponseBytes: 512
        )
        XCTAssertEqual(result.truncation, .oldestDropped)
        XCTAssertTrue(result.output.contains("line-399"), "the newest output was dropped")
        XCTAssertFalse(result.output.contains("line-0\n"), "the oldest output survived the cap")
        XCTAssertLessThanOrEqual(result.output.utf8.count, 512)
    }

    /// A command that never finishes is abandoned on the caller's clock — and, unlike the
    /// SSH transport, leaves nothing behind to account for: the child is killed and its
    /// descriptors are reclaimed, so there is no session slot to exhaust and no connection
    /// to recycle.
    func testFixedCommandTimesOut() async {
        let session = makeSession()
        let started = Date()
        do {
            _ = try await session.runFixedCommand("sleep 30", maxResponseBytes: 4096, timeout: 1)
            XCTFail("a hung command must time out")
        } catch let error as HeadlessSessionError {
            guard case .commandTimedOut(let seconds) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(seconds, 1)
            XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout did not actually fire")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// `read_session` reads the DEFAULT socket's sessions, so the fixed command must not
    /// inherit a `$TMUX` that would send a socket-less tmux to Fin's own server instead —
    /// the exact confusion the tool exists to resolve.
    func testFixedCommandDoesNotInheritTMUX() async throws {
        let session = makeSession(environment: ["TMUX": "/tmp/fake,123,0"])
        let result = try await session.runFixedCommand("echo \"TMUX=[${TMUX:-}]\"")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "TMUX=[]")
    }

    // MARK: - The locale, which is not a cosmetic concern

    /// tmux replaces every character it considers unprintable in the current locale with
    /// `_` — and in the C locale that includes TAB and all non-ASCII. A LaunchAgent has no
    /// locale unless its plist sets one, so the daemon's own children had none, and
    /// `list-panes -F` output arrived as one underscore-joined field instead of five
    /// tab-separated ones. Nothing errored; the inventory just silently parsed to nothing
    /// (the work laptop, 2026-09-15).
    func testAChildWithNoInheritedLocaleStillGetsAUTF8CharacterType() {
        let fixed = LocalTerminalSession.withUTF8CharacterType([:])
        XCTAssertEqual(fixed["LC_CTYPE"], "UTF-8")
    }

    /// A locale the operator actually chose is never overridden — including one that names
    /// UTF-8 through any of the three variables POSIX consults, in precedence order.
    func testAnExistingUTF8LocaleIsLeftAlone() {
        for variable in ["LC_ALL", "LC_CTYPE", "LANG"] {
            let given = [variable: "en_GB.UTF-8"]
            XCTAssertEqual(LocalTerminalSession.withUTF8CharacterType(given), given, "\(variable) was overridden")
        }
        // Spelling variants of the same thing.
        for spelling in ["C.utf8", "en_US.UTF8", "ja_JP.utf-8"] {
            let given = ["LANG": spelling]
            XCTAssertEqual(LocalTerminalSession.withUTF8CharacterType(given), given, "\(spelling) was overridden")
        }
    }

    /// A non-UTF-8 locale keeps its collation, messages and number formats — only the
    /// character type is corrected, because that is the only category tmux's sanitizing
    /// depends on.
    func testANonUTF8LocaleKeepsEverythingButTheCharacterType() {
        let fixed = LocalTerminalSession.withUTF8CharacterType(["LANG": "de_DE.ISO8859-1"])
        XCTAssertEqual(fixed["LANG"], "de_DE.ISO8859-1")
        XCTAssertEqual(fixed["LC_CTYPE"], "UTF-8")
    }

    /// The end-to-end version of the bug, against a real tmux if one is running: the exact
    /// inventory command, through the real transport, must come back as tab-separated
    /// fields the real parser accepts.
    func testTheInventoryCommandParsesThroughThisTransport() async throws {
        let session = makeSession()
        let commandLine = TmuxSessionRead.commandLine(TmuxSessionInventory.paneTitlesArguments())
        let result: FixedCommandOutput
        do {
            result = try await session.runFixedCommand(commandLine, maxResponseBytes: 64 * 1024)
        } catch {
            throw XCTSkip("no tmux server on the default socket here: \(error.localizedDescription)")
        }
        try XCTSkipIf(result.output.isEmpty, "a tmux server with no panes")
        let panes = TmuxSessionInventory.parseTitledPanes(result.output)
        XCTAssertFalse(
            panes.isEmpty,
            "tmux printed \(result.output.utf8.count) bytes and the inventory parsed none of it — "
                + "the classic shape of a lost locale: \(result.output.prefix(120).debugDescription)"
        )
    }

    // MARK: - Helpers

    /// Polls the event log until the text shows up, so a slow machine fails on the clock
    /// rather than on a fixed sleep that was tuned on a fast one.
    private func waitForOutput(
        _ session: LocalTerminalSession,
        containing needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline {
            text = session.eventLog.events.filter { $0.kind == .output }.map(\.text).joined()
            if text.contains(needle) { return text }
            try await Task.sleep(for: .milliseconds(100))
        }
        return text
    }
}

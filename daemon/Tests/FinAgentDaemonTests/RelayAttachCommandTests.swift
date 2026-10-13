import XCTest
@testable import FinAgentDaemon

/// `TerminalRelayClient.attachCommand` run for real under `/bin/sh` against a throwaway
/// tmux server: `tmux` on PATH is a stub that forwards to `tmux -L <private socket>`, and
/// `attach-session`/`new-session -A` are swapped for lines that print which session
/// they would have landed on — no PTY needed.
final class RelayAttachCommandTests: XCTestCase {
    private var socket = ""
    private var binDir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            && !FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux"), "no tmux")
        socket = "finrelaytest\(getpid())"
        binDir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let real = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            ? "/opt/homebrew/bin/tmux" : "/usr/local/bin/tmux"
        let stub = """
        #!/bin/sh
        case "$1" in
          attach-session) exec \(real) -L \(socket) display -p 'attached:#{session_name}' ;;
          new-session) [ "$2" = "-A" ] && { echo "new-or-attached:$4"; exit; }; exec \(real) -L \(socket) "$@" ;;
          *) exec \(real) -L \(socket) "$@" ;;
        esac
        """
        let path = binDir.appendingPathComponent("tmux")
        try stub.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    override func tearDown() {
        _ = run("tmux kill-server 2>/dev/null")
        try? FileManager.default.removeItem(at: binDir)
    }

    @discardableResult
    private func run(_ line: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":/usr/bin:/bin"
        env.removeValue(forKey: "TMUX")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testMissingMainAttachesTheExistingSessionInsteadOfMintingOne() {
        run("tmux new-session -d -s pocketdj")
        XCTAssertEqual(run(TerminalRelayClient.attachCommand(tmuxSession: "main")), "attached:pocketdj")
        XCTAssertEqual(run("tmux list-sessions -F '#{session_name}'"), "pocketdj")
    }

    func testExistingMainIsAttachedEvenWhenOtherSessionsAreNewer() {
        run("tmux new-session -d -s main")
        run("tmux new-session -d -s pocketdj")
        XCTAssertEqual(run(TerminalRelayClient.attachCommand(tmuxSession: "main")), "new-or-attached:main")
    }

    func testEmptyServerCreatesMain() {
        XCTAssertEqual(run(TerminalRelayClient.attachCommand(tmuxSession: "main")), "new-or-attached:main")
    }

    func testAnExplicitNameIsNeverRedirected() {
        run("tmux new-session -d -s pocketdj")
        XCTAssertEqual(
            TerminalRelayClient.attachCommand(tmuxSession: "build"), "exec tmux new-session -A -s 'build'")
    }
}

// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the daemon needs of a terminal, whichever way it reaches one.
///
/// `HeadlessTerminalSession` reaches a tmux server by SSHing to a host — `127.0.0.1` for a
/// resident site, which needs an `sshd` listening on the site's own machine. On a managed
/// Mac where Remote Login cannot be switched on there is nothing to connect to, and a site
/// that cannot attach a terminal is not a site. `LocalTerminalSession` is the same contract
/// over a PTY the daemon opens itself: no sshd, no key, no `authorized_keys` line, no
/// network stack at all between the daemon and the tmux it drives.
///
/// The engine above this never learns which one it is driving (`AgentSessionDriving`), and
/// neither does `TmuxCommandGuard` — the boundary that matters is still the private tmux
/// socket named in the connect command, and that is transport-independent.
@MainActor
public protocol AgentTerminalTransport: AgentSessionDriving {
    /// Kicks off (or restarts) the session. Non-blocking.
    func connect()
    /// Tears it down without reconnecting.
    func disconnect()
    /// Blocks until the session is usable, throwing on failure or timeout.
    func waitForConnection(timeout: TimeInterval) async throws
    /// Blocks until the shell inside the session demonstrably executes a command.
    func waitForShellReady(timeout: TimeInterval) async throws
    /// Runs a command somewhere the agent cannot type — see `read_session`.
    func runFixedCommand(
        _ commandLine: String,
        maxResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> FixedCommandOutput
}

public extension AgentTerminalTransport {
    /// The call shape every caller actually uses; the timeout is the transport's business.
    func runFixedCommand(
        _ commandLine: String,
        maxResponseBytes: Int = 64 * 1024
    ) async throws -> FixedCommandOutput {
        try await runFixedCommand(commandLine, maxResponseBytes: maxResponseBytes, timeout: 20)
    }
}

extension HeadlessTerminalSession: AgentTerminalTransport {}

public struct LocalSessionConfiguration: Sendable {
    /// The connect command, verbatim — the SAME string the SSH transport types into its
    /// shell (`exec tmux -L fin new-session -A -s fin \; set status off`). It is handed to
    /// `sh -c` rather than parsed into an argv here: `\;` is a shell escape that tmux
    /// depends on receiving as a literal `;`, and a hand-rolled argv splitter would be one
    /// more parser to get wrong in a file whose whole history is about parsers being the
    /// wrong tool. `sh` is a plain POSIX shell run NON-interactively, so no login profile
    /// and no auto-attach block is evaluated on the way in; the shell the agent actually
    /// types at is the one tmux spawns in the pane, which is unchanged.
    public var connectCommand: String
    /// Merged over the daemon's own environment for the child. The `LC_FIN_AGENT` marker
    /// rides along for the pane shell's benefit even though nothing here needs it.
    public var environment: [String: String]
    public var terminalColumns: Int
    public var terminalRows: Int
    /// The interpreter the connect command is handed to. `/bin/sh`, not the login shell:
    /// nothing here wants the user's rc files.
    public var shellPath: String

    public init(
        connectCommand: String,
        environment: [String: String] = [:],
        terminalColumns: Int = 120,
        terminalRows: Int = 40,
        shellPath: String = "/bin/sh"
    ) {
        self.connectCommand = connectCommand
        self.environment = environment
        self.terminalColumns = terminalColumns
        self.terminalRows = terminalRows
        self.shellPath = shellPath
    }
}

/// A PTY on this machine, with no SSH under it.
///
/// Structurally a mirror of `HeadlessTerminalSession` — same states, same generation
/// counter, same serialized write chain, same short-life backoff, same probe-based
/// readiness — so the two can be read side by side. What differs is only the pipe:
/// `forkpty` + `execve` instead of a handshake, `write(2)` instead of a channel, and a
/// `Process` instead of a second SSH session for `runFixedCommand`.
///
/// **What this transport deletes.** The SSH path's largest hazard was never the crypto: it
/// was that sshd hands an INTERACTIVE LOGIN SHELL to the daemon, and a login shell that
/// auto-attaches the human's tmux does so before the daemon can type anything (the
/// 2026-09-05 incident, and the `LC_FIN_AGENT` marker that exists to prevent it). Here the
/// daemon execs its connect command itself, non-interactively: there is no login shell in
/// the path to attach anything. It also deletes the site key, the `authorized_keys` line,
/// the `AcceptEnv` dependency, and — in `runFixedCommand` — the abandoned-exec-channel
/// accounting that exists only because an SSH channel whose command has not exited cannot
/// be closed.
///
/// **What it does not change.** The agent's shell still runs as the daemon's own uid, and
/// the boundary keeping it off the human's sessions is still topological: the connect
/// command puts it on Fin's own tmux server (`-L fin`), and `TmuxCommandGuard` still
/// demands that every tmux command name that server. The residual list in
/// `daemon/README.md` applies here unchanged — with one addition worth stating plainly:
/// the SSH transport could in principle be pointed at a DIFFERENT UNIX user (the "airtight
/// version" in docs/SITES.md §9, where a `0700` socket directory is enforced by the
/// kernel), and this one cannot. Under a local PTY the agent is whoever the daemon is, so
/// that hardening becomes a question of which user runs `fin-agentd`.
@MainActor
public final class LocalTerminalSession: AgentTerminalTransport {
    public let eventLog = TerminalEventLog()
    public private(set) var state: HeadlessSessionState = .disconnected
    public private(set) var lastError: String?

    private let configuration: LocalSessionConfiguration

    /// The PTY master. -1 when there is no child.
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    /// Bumped on every connect()/disconnect(); a superseded child's handlers check their
    /// captured generation before touching shared state. Same device as the SSH path.
    private var generation = 0
    private var connectedAt: Date?
    private var consecutiveShortLives = 0
    private var didDispatchConnectCommand = false

    /// Tail of the outbound write chain — writes are chained rather than each getting its
    /// own detached Task, so two sends in quick succession cannot reach the PTY out of
    /// order and corrupt a multi-byte programmatic send. Resolves to whether ITS write
    /// actually landed.
    private var writeChain: Task<Bool, Never>?

    /// Writes happen on their own serial queue: a PTY whose reader is not draining will
    /// block `write(2)`, and blocking the main actor on that would stop the whole daemon.
    private let writeQueue = DispatchQueue(label: "dev.levischoen.fin.localpty.write")
    private let readQueue = DispatchQueue(label: "dev.levischoen.fin.localpty.read")

    /// Bytes read off the PTY, waiting to be folded into the event log on the main actor.
    ///
    /// A buffer rather than "hop to the main actor per chunk": the read handler runs on a
    /// serial queue but the hop is a `Task`, and task ENQUEUE order is not a guarantee that
    /// two tasks run in the order they were created. Terminal output is the one thing in
    /// this file that must never be reordered, so ordering is enforced by the buffer (the
    /// lock serializes append and drain) rather than by the scheduler.
    private let pendingLock = NSLock()
    private var pendingOutput: [UInt8] = []

    public init(configuration: LocalSessionConfiguration) {
        self.configuration = configuration
    }

    public var isSessionConnected: Bool { state == .connected }

    // MARK: - Lifecycle

    public func connect() {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil

        generation += 1
        let myGeneration = generation
        teardownChild()
        didDispatchConnectCommand = false

        let command = configuration.connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            lastError = "no connectCommand: a local session has nothing to run."
            state = .disconnected
            return
        }

        // Everything the child needs is built HERE, in the parent. Between `fork` and
        // `execve` a child of a multithreaded process may call only async-signal-safe
        // functions — `malloc` in particular can deadlock on a lock another thread held at
        // fork time — so argv and envp are fully materialized before the fork and the child
        // does nothing but exec.
        let argv = [configuration.shellPath, "-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        for (key, value) in configuration.environment { environment[key] = value }
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var window = winsize(
            ws_row: UInt16(max(configuration.terminalRows, 1)),
            ws_col: UInt16(max(configuration.terminalColumns, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = -1
        let pid = Self.withCStrings(argv) { cArgv in
            Self.withCStrings(envp) { cEnvp in
                // forkpty, not posix_spawn: the child must be a session leader with the
                // slave side as its CONTROLLING terminal, which is what makes job control,
                // window size and the tmux client work at all. posix_spawn cannot do the
                // `setsid` + `TIOCSCTTY` dance; forkpty does exactly it.
                let pid = forkpty(&master, nil, nil, &window)
                if pid == 0 {
                    execve(cArgv[0], cArgv, cEnvp)
                    // Only reachable if execve failed. `_exit`, not `exit`: atexit handlers
                    // inherited from the parent must not run in this half-built child.
                    _exit(127)
                }
                return pid
            }
        }

        guard pid > 0, master >= 0 else {
            lastError = "could not start a local terminal: \(String(cString: strerror(errno)))"
            state = .disconnected
            return
        }

        masterFD = master
        childPID = pid
        connectedAt = Date()
        // The connect command IS the child here, rather than a line typed into a shell that
        // was already up — so it is dispatched the moment the child exists, and
        // `waitForShellReady` can start probing immediately.
        didDispatchConnectCommand = true
        state = .connected

        startReading(fd: master, generation: myGeneration)
        watchForExit(pid: pid, generation: myGeneration)
    }

    public func disconnect() {
        generation += 1
        writeChain?.cancel()
        writeChain = nil
        teardownChild()
        state = .disconnected
    }

    /// Cancels the sources, hangs up the child, closes the master. Reaping is left to the
    /// exit source when there is one; a `SIGHUP` to a tmux CLIENT detaches it and leaves
    /// the tmux server — and therefore Fin's session and everything running in it —
    /// untouched, which is exactly the SSH path's behaviour when its channel closes.
    private func teardownChild() {
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        if childPID > 0 {
            kill(childPID, SIGHUP)
            // Reap without blocking; if it has not exited yet the exit source (already
            // cancelled) will not, so a short non-blocking sweep avoids a zombie.
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
            childPID = -1
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        pendingLock.lock()
        pendingOutput.removeAll()
        pendingLock.unlock()
    }

    private func startReading(fd: Int32, generation myGeneration: Int) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            // 0 = the child closed its end; EIO on a PTY master is the same event on
            // Darwin. Either way the exit source is what handles it — this side just stops.
            guard count > 0 else { return }
            self.pendingLock.lock()
            self.pendingOutput.append(contentsOf: buffer[0..<count])
            self.pendingLock.unlock()
            Task { @MainActor [weak self] in
                self?.drainPendingOutput(generation: myGeneration)
            }
        }
        source.resume()
        readSource = source
    }

    private func drainPendingOutput(generation myGeneration: Int) {
        guard myGeneration == generation else { return }
        pendingLock.lock()
        let bytes = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        guard !bytes.isEmpty else { return }
        eventLog.recordOutput(bytes)
    }

    private func watchForExit(pid: pid_t, generation myGeneration: Int) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            Task { @MainActor [weak self] in
                self?.handleChildExit(generation: myGeneration)
            }
        }
        source.resume()
        exitSource = source
    }

    private func handleChildExit(generation myGeneration: Int) {
        guard myGeneration == generation else { return }
        // Whatever the child printed before dying belongs in the log before the state
        // change — the last line is usually the reason (`tmux: command not found`).
        drainPendingOutput(generation: myGeneration)

        let wasConnected = state == .connected
        let lifetime = connectedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        connectedAt = nil
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        childPID = -1
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        state = .disconnected

        guard wasConnected else { return }
        // BACKOFF, for the same reason the SSH path has one: with `exec tmux …` the child
        // IS the tmux client, so a tmux that cannot start (not installed, no server, a
        // socket it may not open) exits immediately, and an unconditional respawn would
        // fork-bomb for as long as the daemon runs. A child that lived a while resets the
        // counter, so an ordinary detach reconnects at once.
        consecutiveShortLives = lifetime < 10 ? consecutiveShortLives + 1 : 0
        let delay = min(30.0, pow(2.0, Double(consecutiveShortLives)) - 1)
        state = .reconnecting
        if delay <= 0 {
            connect()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard let self, myGeneration == self.generation else { return }
                self.connect()
            }
        }
    }

    // MARK: - Readiness

    public func waitForConnection(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .connected { return }
            if let lastError, state == .disconnected {
                throw HeadlessSessionError.connectFailed(lastError)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HeadlessSessionError.connectTimeout(seconds: Int(timeout))
    }

    /// Identical in shape and in reasoning to the SSH transport's: type `echo FIN_READY_<n>`
    /// and wait for a line that carries the token WITHOUT carrying the word `echo` (which
    /// would be the keystrokes coming back, not the shell's answer). A passive settle
    /// heuristic declares readiness early on a loaded machine; an answered probe cannot lie.
    public func waitForShellReady(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !didDispatchConnectCommand || state != .connected {
            guard Date() < deadline else {
                throw HeadlessSessionError.connectTimeout(seconds: Int(timeout))
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        while Date() < deadline {
            let token = "FIN_READY_\(UInt32.random(in: 100_000...999_999))"
            let baseline = eventLog.events.last?.id
            let sentAt = Date()
            sendAgentInput("echo \(token)\r")

            let probeDeadline = min(deadline, sentAt.addingTimeInterval(4))
            while Date() < probeDeadline {
                let response = eventLog.outputText(after: baseline, orRecordedAfter: sentAt)
                let answered = response.split(separator: "\n").contains { line in
                    line.contains(token) && !line.contains("echo")
                }
                if answered { return }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw HeadlessSessionError.connectTimeout(seconds: Int(timeout))
    }

    /// See `HeadlessTerminalSession.probeEnvironment` for why this is a log line and never
    /// a gate: the answer is read out of the same PTY the model writes to, so a filter left
    /// running in the pane can author it. `TmuxCommandGuard`'s R1 is the real boundary.
    public func probeEnvironment(_ name: String, timeout: TimeInterval = 8) async -> String? {
        guard state == .connected else { return nil }
        let token = "FIN_ENV_\(UInt32.random(in: 100_000...999_999))"
        let baseline = eventLog.events.last?.id
        let sentAt = Date()
        sendAgentInput("echo \(token)=$\(name)\r")

        let deadline = sentAt.addingTimeInterval(timeout)
        while Date() < deadline {
            let response = eventLog.outputText(after: baseline, orRecordedAfter: sentAt)
            for line in response.split(separator: "\n") where line.contains(token) && !line.contains("echo") {
                guard let range = line.range(of: "\(token)=") else { continue }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    // MARK: - Writing

    @discardableResult
    public func sendAgentInput(_ text: String) -> Task<Bool, Never>? {
        guard !text.isEmpty else { return nil }
        return send(bytes: Array(text.utf8))
    }

    @discardableResult
    private func send(bytes: [UInt8]) -> Task<Bool, Never> {
        let fd = masterFD
        let previousWrite = writeChain
        let queue = writeQueue
        let thisWrite = Task<Bool, Never> {
            // Wait for whatever was queued before this — regardless of ITS outcome — so
            // the writes themselves stay strictly ordered.
            await previousWrite?.value
            guard fd >= 0, self.state == .connected else {
                self.lastError = "Input was not sent: the terminal session is not connected."
                return false
            }
            let failure: String? = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.writeAll(fd: fd, bytes: bytes))
                }
            }
            if let failure {
                self.lastError = "Input was not sent: \(failure)"
                return false
            }
            // Recorded only after a CONFIRMED write, never before: a dropped write that
            // still showed up in the log had everything reading the log believing bytes
            // were delivered that never were.
            self.eventLog.recordInput(bytes)
            return true
        }
        writeChain = thisWrite
        return thisWrite
    }

    /// A full write, partial writes and `EINTR` included. `write(2)` on a PTY whose reader
    /// is slow returns short rather than failing, and a short write in the middle of a
    /// multi-byte send is a corrupted keystroke.
    /// Returns nil on success, or the reason it failed.
    private nonisolated static func writeAll(fd: Int32, bytes: [UInt8]) -> String? {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return String(cString: strerror(errno))
        }
        return nil
    }

    // MARK: - Fixed commands (read_session)

    /// Runs a command in a SEPARATE PROCESS — not the PTY, not the agent's shell.
    ///
    /// Same contract as the SSH transport's: the `commandLine` is the caller's byte for
    /// byte (`TmuxSessionRead` builds it from a fixed argv plus one validated session
    /// name), stdout and stderr stay APART so a tmux error is never framed as the contents
    /// of a pane, a non-zero exit is a failure, and the output is bounded in both bytes and
    /// time. What is absent by construction is the SSH version's session-slot accounting: a
    /// timed-out child is killed and every descriptor is reclaimed, so there is nothing to
    /// leak and no connection to recycle.
    public func runFixedCommand(
        _ commandLine: String,
        maxResponseBytes: Int = 64 * 1024,
        timeout: TimeInterval = 20
    ) async throws -> FixedCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.shellPath)
        process.arguments = ["-c", commandLine]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment { environment[key] = value }
        // Deliberately NOT inside tmux: this command reads the DEFAULT socket's sessions,
        // and an inherited $TMUX would make a socket-less `tmux` in the command line
        // resolve to Fin's own server instead — the very confusion `read_session` exists to
        // avoid. The daemon is not inside tmux either, so this is belt and braces.
        environment.removeValue(forKey: "TMUX")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Both pipes are drained CONCURRENTLY with the child running. Reading one to EOF
        // first deadlocks the moment the other fills its 64 KB buffer — and a pane capture
        // that prints a warning per line is exactly that shape.
        let collector = FixedOutputCollector(maxResponseBytes: maxResponseBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.appendOutput([UInt8](data)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.appendDiagnostics([UInt8](data)) }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw HeadlessSessionError.connectFailed("could not run \(configuration.shellPath): \(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else {
                // SIGTERM then SIGKILL: a tmux blocked on a wedged server ignores the first.
                process.terminate()
                try? await Task.sleep(for: .milliseconds(200))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw HeadlessSessionError.commandTimedOut(seconds: Int(timeout))
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        // The handlers are asynchronous: the child can exit with bytes still queued in the
        // pipe. Drain what is left before tearing them down, or the tail of a capture goes
        // missing — intermittently, and only on fast commands.
        collector.appendOutput([UInt8](outPipe.fileHandleForReading.readDataToEndOfFile()))
        collector.appendDiagnostics([UInt8](errPipe.fileHandleForReading.readDataToEndOfFile()))
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let result = collector.result()
        guard process.terminationStatus == 0 else {
            throw HeadlessSessionError.commandFailed(
                status: Int(process.terminationStatus),
                detail: Self.firstLine(result.diagnostics.isEmpty ? result.output : result.diagnostics)
            )
        }
        return result
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
    }

    /// Materializes Swift strings as a NULL-terminated C array for `execve`, and frees it
    /// on the way out. Allocation happens in the PARENT, before the fork.
    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return body(pointers)
    }
}

/// The two output buffers, behind one lock, with the caps applied as bytes arrive.
///
/// A class with a lock rather than actor isolation because `Pipe`'s readability handlers
/// are called on an arbitrary queue and cannot await anything. The cap semantics match the
/// SSH transport exactly, including the distinction between the two ways a result can be
/// short — which is the difference between "the top of your pane was dropped" and "we
/// stopped reading halfway up it".
private final class FixedOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxResponseBytes: Int
    private let readCeiling: Int
    private var output: [UInt8] = []
    private var diagnostics: [UInt8] = []
    private var truncation = FixedCommandTruncation.none
    private var bytesSeen = 0

    init(maxResponseBytes: Int) {
        self.maxResponseBytes = maxResponseBytes
        // A ceiling on how much we keep READING, not just how much we keep: the sliding
        // window bounds memory, not time, and a command that prints forever would otherwise
        // only ever be stopped by the caller's clock.
        self.readCeiling = maxResponseBytes * 8
    }

    func appendOutput(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bytesSeen += bytes.count
        guard truncation != .stoppedAtCeiling else { return }
        output.append(contentsOf: bytes)
        if output.count > maxResponseBytes {
            output = HeadlessTerminalSession.keepingLastBytes(output, maxResponseBytes)
            if truncation == .none { truncation = .oldestDropped }
        }
        if bytesSeen > readCeiling { truncation = .stoppedAtCeiling }
    }

    func appendDiagnostics(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bytesSeen += bytes.count
        guard truncation != .stoppedAtCeiling else { return }
        diagnostics.append(contentsOf: bytes)
        if diagnostics.count > maxResponseBytes {
            diagnostics = HeadlessTerminalSession.keepingLastBytes(diagnostics, maxResponseBytes)
            if truncation == .none { truncation = .oldestDropped }
        }
        if bytesSeen > readCeiling { truncation = .stoppedAtCeiling }
    }

    func result() -> FixedCommandOutput {
        lock.lock(); defer { lock.unlock() }
        return FixedCommandOutput(
            output: String(decoding: output, as: UTF8.self),
            diagnostics: String(decoding: diagnostics, as: UTF8.self),
            truncation: truncation
        )
    }
}

// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
import Citadel
import NIO
import NIOSSH
import Crypto

/// What one `runFixedCommand` produced. The two streams stay apart so a caller can frame
/// pane CONTENT and a tmux ERROR differently; `truncated` says a cap was hit, so the
/// caller can say so rather than silently shortening someone's screen.
public struct FixedCommandOutput: Sendable, Equatable {
    public var output: String
    public var diagnostics: String
    public var truncated: Bool

    public init(output: String, diagnostics: String = "", truncated: Bool = false) {
        self.output = output
        self.diagnostics = diagnostics
        self.truncated = truncated
    }
}

/// The one mutable cell `runFixedCommand`'s timeout races over. Main-actor isolated, so
/// the two tasks touching it are serialized by the actor rather than by a lock.
@MainActor
private final class FixedCommandBox {
    var value: Result<FixedCommandOutput, Error>?
}

public enum HeadlessSessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

public struct HeadlessSessionConfiguration {
    public var host: String
    public var port: Int
    public var username: String
    /// The private key PEM text itself — the caller reads the file; a headless daemon
    /// process is not sandboxed and can read `~/.ssh` directly.
    public var privateKeyPEM: String
    public var passphrase: String?
    /// Written to the shell the moment the PTY is up — e.g. a `tmux new-session -A …`
    /// attach so the agent lands in a durable session that survives daemon restarts.
    public var connectCommand: String
    /// Sent as SSH env requests with the PTY; sshd only honors names its AcceptEnv
    /// allows (macOS default: LANG and LC_*).
    public var environment: [String: String]
    /// Fixed PTY dimensions — there is no view to resize from.
    public var terminalColumns: Int
    public var terminalRows: Int

    public init(
        host: String,
        port: Int = 22,
        username: String,
        privateKeyPEM: String,
        passphrase: String? = nil,
        connectCommand: String = "",
        environment: [String: String] = [:],
        terminalColumns: Int = 120,
        terminalRows: Int = 40
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
        self.connectCommand = connectCommand
        self.environment = environment
        self.terminalColumns = terminalColumns
        self.terminalRows = terminalRows
    }
}

/// A Citadel-based SSH + PTY session with no view layer: inbound bytes feed a
/// `TerminalEventLog` (the agent's actual window onto the session) and writes are
/// serialized onto a chain, mirroring the app's `TerminalSession` connect/run structure —
/// generation counter, IdleStateHandler keepalive, write chaining — minus SwiftTerm.
@MainActor
public final class HeadlessTerminalSession: AgentSessionDriving {
    public let eventLog = TerminalEventLog()
    public private(set) var state: HeadlessSessionState = .disconnected
    public private(set) var lastError: String?

    private let configuration: HeadlessSessionConfiguration
    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    /// Tail of the outbound write chain — writes are chained rather than each getting its
    /// own detached Task: unstructured tasks are scheduled independently, so two calls in
    /// quick succession could reach the channel out of order, corrupting a programmatic
    /// multi-byte send.
    private var writeChain: Task<Void, Never>?
    /// Bumped on every connect()/disconnect(); a superseded run() checks its captured
    /// generation before touching shared state.
    private var generation = 0
    /// How long the last connection lived, so a session that dies immediately backs off
    /// instead of spinning. With `exec tmux …` as the connect command, a shell that cannot
    /// start tmux exits at once, and the auto-reconnect below would otherwise re-handshake
    /// in a tight loop for as long as the daemon runs.
    private var connectedAt: Date?
    private var consecutiveShortLives = 0
    /// True once the configured connectCommand has been typed into the shell (or when
    /// none is configured). `waitForShellReady` gates on it so the readiness probe can
    /// never validate the pre-attach shell.
    private var didDispatchConnectCommand = false

    public init(configuration: HeadlessSessionConfiguration) {
        self.configuration = configuration
    }

    public var isSessionConnected: Bool { state == .connected }

    /// Kicks off (or restarts) the connection. Non-blocking, like the app's `connect`;
    /// use `waitForConnection` to block until it is usable.
    public func connect() {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil

        generation += 1
        let myGeneration = generation
        runTask?.cancel()

        if let staleClient = client {
            Task { try? await staleClient.close() }
        }
        client = nil
        stdinWriter = nil
        writeChain?.cancel()
        writeChain = nil
        didDispatchConnectCommand = false

        runTask = Task { [weak self] in
            await self?.run(generation: myGeneration)
        }
    }

    /// Blocks until the session is connected, throwing on failure or timeout.
    public func waitForConnection(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .connected { return }
            if let error = lastError, state == .disconnected {
                throw HeadlessSessionError.connectFailed(error)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HeadlessSessionError.connectTimeout(seconds: Int(timeout))
    }

    /// Blocks until the remote shell is DEMONSTRABLY executing commands, by probing it:
    /// types `echo FIN_READY_<n>` and waits for the token to come back as the command's
    /// own output (a line carrying the token but not the `echo` keystrokes). A probe
    /// that goes unanswered is retried with a fresh token — keystrokes typed into a
    /// still-spawning shell (outer fish, or the pane shell inside a fresh tmux attach)
    /// are flushed on its startup, so passive settle heuristics were observed to declare
    /// readiness seconds early on a loaded machine; an answered probe cannot lie.
    ///
    /// The probe lines land in the terminal and its event log. That is deliberate — one
    /// visible `echo FIN_READY_…` per connect is a fair price for never typing the real
    /// task into a shell that isn't there.
    public func waitForShellReady(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        // The connectCommand (tmux attach) must have been dispatched first, or the probe
        // would validate the outer shell and the attach could still eat later input.
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

    /// Asks the LIVE SHELL what one environment variable holds, by typing an echo and
    /// reading the answer back out of the event log. Nil means the shell never answered.
    ///
    /// This exists to prove the `connectCommand` actually took effect. The private-socket
    /// design rests entirely on the agent's shell being INSIDE its own tmux server, and
    /// that is a fact about a command typed into a PTY, which can fail quietly — tmux not
    /// installed, a startup flush that ate the line, a server that refused to start. If it
    /// did fail, the shell is a plain login shell whose `$TMUX` is empty, and from there a
    /// bare `tmux send-keys -t main …` names no socket at all and would reach the human's
    /// server. So the daemon asks, and treats "no proof" as "not confined".
    ///
    /// Same probe shape as `waitForShellReady`: a random token, and a line that carries the
    /// token without carrying the word `echo` is the shell's own output rather than the
    /// echoed keystrokes.
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

    public func disconnect() {
        generation += 1
        runTask?.cancel()
        writeChain?.cancel()
        writeChain = nil
        let closingClient = client
        client = nil
        stdinWriter = nil
        state = .disconnected
        Task { try? await closingClient?.close() }
    }

    /// Input originating from the agent. Recorded in the event log and written to the
    /// channel in send order.
    public func sendAgentInput(_ text: String) {
        guard !text.isEmpty else { return }
        send(bytes: Array(text.utf8))
    }

    /// Runs a command on a SEPARATE SSH exec channel — not the PTY, not the agent's shell.
    ///
    /// This exists for exactly one caller: `read_session`. The agent's shell lives on its
    /// own tmux socket, so a `capture-pane` typed into it can only ever see the agent's own
    /// server; reading the machine's real sessions has to happen somewhere the agent cannot
    /// type. A second channel on the same authenticated connection is that somewhere.
    ///
    /// The `commandLine` is the CALLER's, byte for byte — `TmuxSessionRead` builds it from
    /// a fixed argv plus one validated session name — and this function adds nothing to it.
    /// Deliberately no `inShell:`, so sshd runs it directly rather than through an
    /// interactive shell path; the login shell still expands the string (that is what an
    /// SSH exec request is), which is why the name that goes into it is validated to a
    /// charset with no shell meaning at all.
    ///
    /// STDOUT AND STDERR STAY APART, and a non-zero exit is a FAILURE. Merging them meant
    /// `tmux capture-pane -t nope` — exit 1, `can't find session: nope` on stderr — came
    /// back as `.text`, and the model read that sentence as the CONTENT of a pane called
    /// `nope`. A warning tmux printed during a successful capture was likewise spliced into
    /// the middle of the terminal text. The caller decides how to frame each half; this
    /// function only refuses to blur them.
    ///
    /// BOUNDED IN TIME AND IN BYTES. Every other remote wait in this file takes a timeout,
    /// and this one is model-callable: an exec stream that never EOFs (a wedged tmux
    /// server, a half-dead TCP connection) would otherwise hang the agent's turn forever,
    /// because Citadel's own 15s bound covers channel creation and not the stream. Output
    /// is capped at `maxResponseBytes` keeping the NEWEST bytes, which is what "the last N
    /// lines of a pane" means — keeping the oldest handed the model the top of a long
    /// capture under a label promising the bottom.
    public func runFixedCommand(
        _ commandLine: String,
        maxResponseBytes: Int = 64 * 1024,
        timeout: TimeInterval = 20
    ) async throws -> FixedCommandOutput {
        guard let client else { throw HeadlessSessionError.notConnected }
        // An unstructured Task, deliberately: a task GROUP awaits its children on the way
        // out, so a child blocked on a stream that never yields would swallow the timeout
        // it is supposed to enforce. This one is abandoned (and cancelled) on timeout.
        let box = FixedCommandBox()
        let work = Task { @MainActor in
            do {
                box.value = .success(
                    try await Self.collect(
                        commandLine, on: client, maxResponseBytes: maxResponseBytes
                    )
                )
            } catch {
                box.value = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while box.value == nil {
            guard Date() < deadline else {
                work.cancel()
                throw HeadlessSessionError.commandTimedOut(seconds: Int(timeout))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try box.value!.get()
    }

    /// The streaming half, split out so the timeout above has something to abandon.
    private static func collect(
        _ commandLine: String,
        on client: SSHClient,
        maxResponseBytes: Int
    ) async throws -> FixedCommandOutput {
        var output = ""
        var diagnostics = ""
        var truncated = false
        var bytesSeen = 0
        // A ceiling on how much we will read at all: the sliding window below bounds
        // MEMORY, not time, and a command that prints forever would otherwise only be
        // stopped by the caller's clock.
        let readCeiling = maxResponseBytes * 8
        do {
            for try await chunk in try await client.executeCommandStream(commandLine) {
                switch chunk {
                case .stdout(let value):
                    output += String(buffer: value)
                    bytesSeen += value.readableBytes
                    if output.utf8.count > maxResponseBytes {
                        output = keepingLastBytes(output, maxResponseBytes)
                        truncated = true
                    }
                case .stderr(let value):
                    diagnostics += String(buffer: value)
                    bytesSeen += value.readableBytes
                    if diagnostics.utf8.count > maxResponseBytes {
                        diagnostics = keepingLastBytes(diagnostics, maxResponseBytes)
                        truncated = true
                    }
                }
                if bytesSeen > readCeiling {
                    truncated = true
                    break
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            throw HeadlessSessionError.commandFailed(
                status: failure.exitCode,
                detail: firstLine(diagnostics.isEmpty ? output : diagnostics)
            )
        }
        return FixedCommandOutput(output: output, diagnostics: diagnostics, truncated: truncated)
    }

    /// Keeps the last `limit` BYTES (not Characters — the budget is a byte budget), cut
    /// forward to the next newline so the result starts on a whole line and on a whole
    /// UTF-8 scalar.
    static func keepingLastBytes(_ text: String, _ limit: Int) -> String {
        var bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        bytes = Array(bytes.suffix(limit))
        if let newline = bytes.firstIndex(of: 0x0A) {
            bytes = Array(bytes[(newline + 1)...])
        } else {
            // No line break in the window: drop any leading UTF-8 continuation bytes so
            // the first scalar is whole.
            while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
    }

    private func send(bytes: [UInt8]) {
        guard let stdinWriter else { return }
        eventLog.recordInput(bytes)
        let previousWrite = writeChain
        writeChain = Task {
            await previousWrite?.value
            try? await stdinWriter.write(ByteBuffer(bytes: bytes))
        }
    }

    private func run(generation myGeneration: Int) async {
        let configuration = self.configuration
        do {
            let authMethod = try Self.authenticationMethod(configuration: configuration)
            // Citadel has no SSH-level keepalive; a 90-second read-idle threshold plus
            // tmux's own periodic traffic catches a silently dead connection without
            // false-positiving on a quiet-but-alive one (same reasoning as the app).
            let client = try await SSHClient.connect(
                host: configuration.host,
                port: configuration.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                channelHandlers: [IdleStateHandler(readTimeout: .seconds(90)), IdleConnectionCloser()]
            )

            guard myGeneration == self.generation else {
                try? await client.close()
                return
            }
            self.client = client

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: max(configuration.terminalColumns, 1),
                terminalRowHeight: max(configuration.terminalRows, 1),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            let environmentRequests = configuration.environment.map {
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: $0.key, value: $0.value)
            }

            try await client.withPTY(ptyRequest, environment: environmentRequests) { [weak self] inbound, outbound in
                guard let self, myGeneration == self.generation else { return }
                self.stdinWriter = outbound
                self.state = .connected
                self.connectedAt = Date()
                // Written after the first MEANINGFUL inbound output (a banner or prompt —
                // something with alphanumeric content) rather than immediately: on a
                // loaded machine the remote shell can take seconds to spawn, and input
                // written before it exists gets discarded by the shell's startup input
                // flush. The app connects fast enough in practice to get away with the
                // immediate write; an unattended daemon must not depend on that. Plain
                // "first output" isn't enough either — sshd emits control-sequence-only
                // chunks before the shell is alive, which was observed to trigger a
                // too-early dispatch that lost the tmux attach entirely.
                var pendingConnectCommand: String? = {
                    let trimmed = configuration.connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                if pendingConnectCommand == nil { self.didDispatchConnectCommand = true }
                for try await chunk in inbound {
                    guard myGeneration == self.generation else { break }
                    switch chunk {
                    case .stdout(let buffer):
                        self.feed(buffer)
                    case .stderr(let buffer):
                        self.feed(buffer)
                    }
                    if let command = pendingConnectCommand,
                       let lastEvent = self.eventLog.events.last,
                       lastEvent.kind == .output,
                       lastEvent.text.rangeOfCharacter(from: .alphanumerics) != nil {
                        pendingConnectCommand = nil
                        self.didDispatchConnectCommand = true
                        try await outbound.write(ByteBuffer(string: command + "\n"))
                    }
                }
            }
        } catch {
            if myGeneration == generation {
                lastError = String(describing: error)
            }
        }

        guard myGeneration == generation else { return }
        // A working session that dropped unexpectedly gets one silent auto-reconnect;
        // a failed handshake does not (retrying bad credentials immediately just spins).
        let shouldAutoReconnect = state == .connected
        let lifetime = connectedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        connectedAt = nil
        client = nil
        stdinWriter = nil
        if state != .disconnected {
            state = .disconnected
        }
        if shouldAutoReconnect {
            // BACKOFF, because the connect command can now END the session. With
            // `exec tmux …` the shell IS the tmux client: leaving tmux (or failing to
            // start it) closes the channel immediately, and an unconditional reconnect
            // would re-handshake in a tight loop against sshd for as long as the daemon
            // runs. A connection that lived a while resets the counter, so an ordinary
            // network drop still reconnects at once.
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
    }

    private func feed(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        eventLog.recordOutput(bytes)
    }

    /// Tries Ed25519 first (the overwhelmingly common modern key), then RSA — the PEM
    /// itself is the source of truth, so no key-type field is needed in the config.
    private static func authenticationMethod(
        configuration: HeadlessSessionConfiguration
    ) throws -> SSHAuthenticationMethod {
        let decryptionKey = configuration.passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(
            sshEd25519: configuration.privateKeyPEM,
            decryptionKey: decryptionKey
        ) {
            return .ed25519(username: configuration.username, privateKey: key)
        }
        let key = try Insecure.RSA.PrivateKey(
            sshRsa: configuration.privateKeyPEM,
            decryptionKey: decryptionKey
        )
        return .rsa(username: configuration.username, privateKey: key)
    }
}

public enum HeadlessSessionError: Error, LocalizedError {
    case connectFailed(String)
    case connectTimeout(seconds: Int)
    case notConnected
    case commandFailed(status: Int, detail: String)
    case commandTimedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let detail):
            return "SSH connection failed: \(detail)"
        case .connectTimeout(let seconds):
            return "SSH connection didn't come up within \(seconds)s."
        case .notConnected:
            return "the SSH session is not connected."
        case .commandFailed(let status, let detail):
            return detail.isEmpty
                ? "the command exited \(status) without printing anything."
                : "\(detail) (exit \(status))"
        case .commandTimedOut(let seconds):
            return "the command produced no result within \(seconds)s and was abandoned."
        }
    }
}

/// Turns `IdleStateHandler`'s idle event into an actual channel close, so a silently dead
/// connection cascades through Citadel's close path like any other disconnect. Duplicated
/// from the app's `TerminalSession` (where it is `private`) because it is four lines of
/// NIO plumbing with no behavior worth unifying across module boundaries.
private final class IdleConnectionCloser: ChannelInboundHandler {
    typealias InboundIn = Any

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

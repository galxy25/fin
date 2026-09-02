// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
import Citadel
import NIO
import NIOSSH
import Crypto

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
        client = nil
        stdinWriter = nil
        if state != .disconnected {
            state = .disconnected
        }
        if shouldAutoReconnect {
            state = .reconnecting
            connect()
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

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let detail):
            return "SSH connection failed: \(detail)"
        case .connectTimeout(let seconds):
            return "SSH connection didn't come up within \(seconds)s."
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

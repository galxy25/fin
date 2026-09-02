// tvOS terminal session: the app's TerminalSession state machine (generation
// counter, write chaining, idle-close keepalive, one silent auto-reconnect)
// married to SwiftTerm's headless Terminal engine instead of the UIKit
// TerminalView, which does not exist on tvOS. Structure deliberately mirrors
// fin/Session/TerminalSession.swift and FinAgentCore/HeadlessTerminalSession.swift —
// same reasoning applies at every commented decision point there.
import Foundation
import Citadel
import NIO
import NIOSSH
import Crypto

enum TVSessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

@MainActor
final class TVTerminalSession: ObservableObject, Identifiable {
    let id: UUID
    /// The headless emulator. Fed from SSH inbound; queried by the canvas renderer.
    let terminal: Terminal
    let eventLog = TerminalEventLog()

    @Published private(set) var state: TVSessionState = .disconnected
    @Published private(set) var lastError: String?

    /// Fired (coalesced by the canvas) whenever the screen contents may have changed.
    var onScreenUpdate: () -> Void = {}
    /// Terminal title reported by the remote (OSC 0/2), surfaced in the UI strip.
    @Published private(set) var remoteTitle: String = ""

    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    private var lastServer: Server?
    private var lastCredentials: ServerCredentials?
    private var generation = 0
    private let delegateProxy = EngineDelegateProxy()

    init(serverID: UUID) {
        self.id = serverID
        let options = TerminalOptions(cols: 120, rows: 34, termName: "xterm-256color", scrollback: 1000)
        self.terminal = Terminal(delegate: delegateProxy, options: options)
        delegateProxy.owner = self
    }

    var isConnected: Bool { client?.isConnected ?? false }

    func connect(server: Server, credentials: ServerCredentials) {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil
        lastServer = server
        lastCredentials = credentials

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

        runTask = Task { [weak self] in
            await self?.run(server: server, credentials: credentials, generation: myGeneration)
        }
    }

    func markNeedsReconnect() {
        guard state == .connected else { return }
        state = .reconnecting
    }

    func reportMissingCredentials() {
        lastError = "No private key on this Apple TV for this server. Send it from the Fin iOS app (Remote Keyboard → Send Key)."
    }

    func disconnect() {
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

    /// Transport-level write; every producer (Bluetooth keyboard, iPhone companion,
    /// the fallback text field, engine auto-replies) funnels through here, chained
    /// so multi-byte sequences can never interleave out of order.
    func send(bytes: [UInt8]) {
        guard let stdinWriter else { return }
        eventLog.recordInput(bytes)
        let previousWrite = writeChain
        writeChain = Task {
            await previousWrite?.value
            try? await stdinWriter.write(ByteBuffer(bytes: bytes))
        }
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    /// True when the remote has switched the terminal into application cursor-key
    /// mode (DECCKM) — arrows then send SS3 (`ESC O A`) instead of CSI (`ESC [ A`).
    var applicationCursorKeys: Bool { terminal.applicationCursor }

    /// Resize from the canvas once its geometry is known: the engine reflows and the
    /// PTY learns the new dimensions.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
            onScreenUpdate()
        }
        guard let stdinWriter else { return }
        Task {
            try? await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    private func run(server: Server, credentials: ServerCredentials, generation myGeneration: Int) async {
        do {
            let authMethod = try Self.authenticationMethod(credentials: credentials)
            let client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                channelHandlers: [IdleStateHandler(readTimeout: .seconds(90)), TVIdleConnectionCloser()]
            )

            guard myGeneration == generation else {
                try? await client.close()
                return
            }
            self.client = client

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: max(terminal.cols, 1),
                terminalRowHeight: max(terminal.rows, 1),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            try await client.withPTY(ptyRequest, environment: []) { [weak self] inbound, outbound in
                guard let self, myGeneration == self.generation else { return }
                self.stdinWriter = outbound
                self.state = .connected
                let connectCommand = server.connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                if !connectCommand.isEmpty {
                    try await outbound.write(ByteBuffer(string: connectCommand + "\n"))
                }
                for try await chunk in inbound {
                    guard myGeneration == self.generation else { break }
                    switch chunk {
                    case .stdout(let buffer):
                        self.feed(buffer)
                    case .stderr(let buffer):
                        self.feed(buffer)
                    }
                }
            }
        } catch {
            if myGeneration == generation {
                lastError = String(describing: error)
            }
        }

        guard myGeneration == generation else { return }
        let shouldAutoReconnect = state == .connected
        client = nil
        stdinWriter = nil
        if state != .disconnected {
            state = .disconnected
        }
        if shouldAutoReconnect, let server = lastServer, let credentials = lastCredentials {
            state = .reconnecting
            connect(server: server, credentials: credentials)
        }
    }

    private func feed(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        eventLog.recordOutput(bytes)
        terminal.feed(byteArray: bytes)
        onScreenUpdate()
    }

    fileprivate func engineSend(_ data: ArraySlice<UInt8>) {
        send(bytes: Array(data))
    }

    fileprivate func engineSetTitle(_ title: String) {
        remoteTitle = title
    }

    private static func authenticationMethod(credentials: ServerCredentials) throws -> SSHAuthenticationMethod {
        let decryptionKey = credentials.passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
        switch credentials.keyType {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: credentials.keyPEM, decryptionKey: decryptionKey)
            return .ed25519(username: credentials.username, privateKey: key)
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: credentials.keyPEM, decryptionKey: decryptionKey)
            return .rsa(username: credentials.username, privateKey: key)
        }
    }
}

/// Same struct the iOS session layer uses (fin/Session/TerminalSession.swift defines
/// it there; that file isn't compiled into fin-tv, so the definition lives here too).
struct ServerCredentials {
    let username: String
    let keyPEM: String
    let keyType: SSHKeyType
    let passphrase: String?
}

/// SwiftTerm's engine calls its delegate synchronously on whatever thread feeds it —
/// here always the main actor (feed/resize run there). The proxy exists because the
/// engine holds its delegate strongly-typed and non-isolated; it forwards the two
/// callbacks the session cares about. Every other TerminalDelegate requirement has a
/// default implementation in the engine's own extension.
private final class EngineDelegateProxy: TerminalDelegate {
    weak var owner: TVTerminalSession?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { owner?.engineSend(data) }
    }

    func setTerminalTitle(source: Terminal, title: String) {
        MainActor.assumeIsolated { owner?.engineSetTitle(title) }
    }
}

/// Identical four-line NIO shim as the app's and daemon's (private in both).
private final class TVIdleConnectionCloser: ChannelInboundHandler {
    typealias InboundIn = Any

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

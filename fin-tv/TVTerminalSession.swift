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
    /// Live only on the `.siteRelay` path (SSH tunnelled over HTTPS through Fin's relay):
    /// the pinned WebSocket and the session id both ends of the relay pair on. Mutually
    /// exclusive with `client`/`stdinWriter` — one server, one transport.
    private var relaySocket: RelayWebSocket?
    private var relaySessionId: String?
    private var lastRelay: RelayTarget?
    /// How long the relay gets to come up: it is on-demand, and the first open after a
    /// quiet spell pays an EC2 boot (about a minute). 45 tries, two seconds apart.
    private let relayConnectAttempts = 45

    struct RelayTarget {
        let server: Server
        let siteID: String
        let endpoint: String
        let token: String
    }
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

    var isConnected: Bool {
        if let client { return client.isConnected }
        return relaySocket != nil && state == .connected
    }

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

    /// The `.siteRelay` counterpart to `connect(server:credentials:)`: no SSH dial and no key —
    /// the control plane wakes the named computer's daemon to attach a PTY to the tmux
    /// session and both ends meet at the relay. Needs only the Sign in with Apple session.
    func connectSiteRelay(_ target: RelayTarget) {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil
        lastServer = target.server
        lastRelay = target
        lastCredentials = nil

        generation += 1
        let myGeneration = generation
        runTask?.cancel()

        if let staleClient = client {
            Task { try? await staleClient.close() }
        }
        client = nil
        stdinWriter = nil
        relaySocket?.cancel()
        relaySocket = nil
        relaySessionId = nil
        writeChain?.cancel()
        writeChain = nil

        let sessionId = UUID().uuidString
        runTask = Task { [weak self] in
            await self?.runSiteRelay(target, sessionId: sessionId, generation: myGeneration)
        }
    }

    func reportRelayUnavailable(_ message: String) {
        lastError = message
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
        let closingSocket = relaySocket
        let closingSessionId = relaySessionId
        relaySocket = nil
        relaySessionId = nil
        lastRelay = nil
        state = .disconnected
        Task { try? await closingClient?.close() }
        if let closingSocket {
            Task {
                // Tell the relay (and through it the daemon) to end the PTY, then drop the socket.
                if let closingSessionId,
                   let payload = try? JSONSerialization.data(withJSONObject: ["action": "close", "sessionId": closingSessionId]) {
                    try? await closingSocket.send(payload)
                }
                closingSocket.cancel()
            }
        }
    }

    /// Transport-level write; every producer (Bluetooth keyboard, iPhone companion,
    /// the fallback text field, engine auto-replies) funnels through here, chained
    /// so multi-byte sequences can never interleave out of order.
    func send(bytes: [UInt8]) {
        if let stdinWriter {
            eventLog.recordInput(bytes)
            let previousWrite = writeChain
            writeChain = Task {
                await previousWrite?.value
                try? await stdinWriter.write(ByteBuffer(bytes: bytes))
            }
        } else if let relaySocket, let relaySessionId,
                  let payload = try? JSONSerialization.data(withJSONObject: [
                      "action": "input", "sessionId": relaySessionId, "data": Data(bytes).base64EncodedString(),
                  ]) {
            eventLog.recordInput(bytes)
            let previousWrite = writeChain
            writeChain = Task {
                await previousWrite?.value
                try? await relaySocket.send(payload)
            }
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
        if let stdinWriter {
            Task {
                try? await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
            }
        } else {
            sendCurrentSizeToRelay()
        }
    }

    private func sendCurrentSizeToRelay() {
        guard let relaySocket, let relaySessionId,
              let payload = try? JSONSerialization.data(withJSONObject: [
                  "action": "resize", "sessionId": relaySessionId, "cols": terminal.cols, "rows": terminal.rows,
              ]) else { return }
        Task { try? await relaySocket.send(payload) }
    }

    // MARK: - Relay transport

    /// Asks the control plane to wake the site and returns the relay's address. The call can
    /// LAUNCH the relay (about ten seconds), so it gets a long timeout — the same lesson as
    /// ControlPlaneClient.relayOpenTimeout on the other platforms.
    private static func openRelay(_ target: RelayTarget, sessionId: String) async -> Result<(host: String, port: Int), RelayOpenFailure> {
        let base = KeyVaultClient.normalizedBase(target.endpoint)
        guard !base.isEmpty, let url = URL(string: base + "/sites/\(target.siteID)/commands") else {
            return .failure(.message("Fin's control plane isn't set up on this Apple TV yet. Open Fin on your iPhone or Mac once so iCloud can deliver it."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "kind": "terminal-open",
            "args": ["sessionId": sessionId, "tmuxSession": target.server.tmuxSessionName],
        ])
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                switch status {
                case 401, 403: return .failure(.message("This Apple TV's Fin sign-in has expired. Sign in with Apple again from the server list."))
                case 404: return .failure(.message("That computer is no longer enrolled with Fin."))
                default: return .failure(.message("Fin's control plane answered \(status)."))
                }
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = object["relayHost"] as? String, let port = object["relayPort"] as? Int else {
                return .failure(.message("Fin's control plane answered without a relay address."))
            }
            return .success((host, port))
        } catch {
            let ns = error as NSError
            return .failure(.message("Could not reach Fin's control plane (\(ns.domain) \(ns.code) after \(Int(Date().timeIntervalSince(started) * 1000)) ms)."))
        }
    }

    private enum RelayOpenFailure: Error { case message(String) }

    private func runSiteRelay(_ target: RelayTarget, sessionId: String, generation myGeneration: Int) async {
        switch await Self.openRelay(target, sessionId: sessionId) {
        case .failure(.message(let message)):
            if myGeneration == generation { lastError = message }
        case .success(let address):
            await pumpRelay(target, sessionId: sessionId, address: address, generation: myGeneration)
        }

        guard myGeneration == generation else { return }
        // Only a session that reached `.connected` and then dropped retries itself: a wake
        // that never produced a frame is left for the user rather than spinning against a
        // computer that may not be reachable at all.
        let shouldAutoReconnect = state == .connected
        relaySocket = nil
        relaySessionId = nil
        if state != .disconnected {
            state = .disconnected
        }
        if shouldAutoReconnect, let target = lastRelay {
            state = .reconnecting
            connectSiteRelay(target)
        }
    }

    private func pumpRelay(_ target: RelayTarget, sessionId: String, address: (host: String, port: Int),
                           generation myGeneration: Int) async {
        guard let openFrame = try? JSONSerialization.data(withJSONObject: [
            "action": "open", "sessionId": sessionId, "siteId": target.siteID, "tmuxSession": target.server.tmuxSessionName,
        ]) else { return }

        var socket: RelayWebSocket?
        var attemptsRemaining = relayConnectAttempts
        while myGeneration == generation, attemptsRemaining > 0 {
            attemptsRemaining -= 1
            let candidate = RelayWebSocket(host: address.host, port: address.port)
            do {
                try await candidate.connect()
                try await candidate.send(openFrame)
                socket = candidate
                break
            } catch {
                candidate.cancel()
                if attemptsRemaining == 0 {
                    if myGeneration == generation { lastError = "The terminal relay did not come up in time." }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let socket, myGeneration == generation else {
            socket?.cancel()
            return
        }
        relaySocket = socket
        relaySessionId = sessionId
        // The canvas sized the terminal before this socket existed, so its resize call found
        // nothing to tell; without this the remote PTY keeps its default size.
        sendCurrentSizeToRelay()

        while myGeneration == generation {
            let frame: Data
            do {
                frame = try await socket.receive()
            } catch {
                if myGeneration == generation { lastError = String(describing: error) }
                return
            }
            guard myGeneration == generation,
                  let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
                  let action = object["action"] as? String else { continue }
            switch action {
            case "attached":
                if state != .connected { state = .connected }
                sendCurrentSizeToRelay()
            case "output":
                guard let encoded = object["data"] as? String, let bytes = Data(base64Encoded: encoded) else { continue }
                if state != .connected { state = .connected }
                let byteArray = [UInt8](bytes)
                eventLog.recordOutput(byteArray)
                terminal.feed(byteArray: byteArray)
                onScreenUpdate()
            case "close":
                socket.cancel()
            default:
                break
            }
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

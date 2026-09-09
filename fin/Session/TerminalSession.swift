import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftTerm
import Citadel
import NIO
import NIOSSH
import Crypto

enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

struct ServerCredentials {
    let username: String
    let keyPEM: String
    let keyType: SSHKeyType
    let passphrase: String?
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let terminalView: FinTerminalView
    /// Timestamped, chunked record of everything typed and received — the agent's actual
    /// window onto the session; see `TerminalEventLog` for why this exists alongside
    /// SwiftTerm's own buffer rather than replacing the tail-of-buffer read with more of
    /// the same thing.
    let eventLog = TerminalEventLog()

    @Published private(set) var state: SessionState = .disconnected {
        didSet {
            // Lifecycle audit in one place so no transition site can forget it:
            // entering .connected, and leaving it for any reason (an explicit
            // disconnect, a drop, or a wake-forced reconnect), each audit once.
            guard oldValue != state else { return }
            let name = lastServer?.name ?? ""
            if state == .connected {
                onConnectionAudit("[session] connected to \(name)")
            } else if oldValue == .connected {
                onConnectionAudit("[session] disconnected from \(name)")
            }
        }
    }
    @Published private(set) var lastError: String?

    /// Fired with a ready-made audit line on connect/disconnect transitions; wired
    /// by `SessionManager` to the lifecycle recorder.
    var onConnectionAudit: (String) -> Void = { _ in }

    #if DEBUG
    /// Test seam: the watchdog's connected-session gate must be table-testable
    /// without a live SSH transport.
    func simulateConnectedStateForTesting() {
        state = .connected
    }

    /// Separate, explicit opt-in seam: `simulateConnectedStateForTesting()` deliberately
    /// leaves `stdinWriter` nil, so `state == .connected` alone is never enough for a
    /// write to succeed (`TerminalSessionSendTests.testSendStillFailsWhenStateSaysConnectedButNoWriterExists`
    /// guards exactly this). A test that needs a write to actually resolve delivered —
    /// e.g. proving `AgentRuntime`'s "confirmed, not merely attempted" delivery signal —
    /// calls this too, on top of the connected-state seam, never instead of it.
    func simulateDeliveredWritesForTesting() {
        simulatedWriteOutcome = true
    }

    private var simulatedWriteOutcome: Bool?
    #endif
    #if os(iOS) || os(visionOS)
    /// Whether the on-screen keyboard (and its accessory row) is currently showing.
    /// Starts false — the terminal isn't first responder until tapped or explicitly shown.
    @Published private(set) var isKeyboardVisible = false
    #endif

    var onCapturedClipping: (String) -> Void = { _ in }

    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    /// Tail of the outbound write chain — see `send(bytes:)` for why writes are serialized.
    private var writeChain: Task<Bool, Never>?
    /// The most recently created write, readable outside `send(bytes:)` — this is how
    /// `sendAgentInput` (which triggers a write indirectly, through SwiftTerm's
    /// synchronous delegate callback, and so cannot itself return one) hands its own
    /// caller the real outcome. Always the same value as `writeChain` at the instant a
    /// `send(bytes:)` call returns; kept as a separate property only so its name reads
    /// right from that call site rather than exposing the chain's own bookkeeping.
    private var lastSendTask: Task<Bool, Never>?
    /// Cached so an unexpected drop (see `run()`'s cleanup) can reconnect itself without
    /// waiting for `SessionManager` to be told to do so via a foreground/wake trigger.
    private var lastServer: Server?
    private var lastCredentials: ServerCredentials?
    private var lastEnvironment: [String: String] = [:]
    /// Bumped on every connect()/disconnect(). A `run()` invocation checks its captured
    /// generation before touching shared state, so a superseded (stale) connection attempt
    /// can never clobber a newer one's `client`/`stdinWriter`/`state` once it finally unwinds.
    private var generation = 0

    init(serverID: UUID) {
        self.id = serverID
        self.terminalView = FinTerminalView(frame: .zero)
        terminalView.terminalDelegate = self
        terminalView.onCopy = { [weak self] text in
            self?.captureCopiedText(text, alsoWriteToPasteboard: false)
        }

        #if os(iOS) || os(visionOS)
        // Mac has a real keyboard (physical Esc/Tab/arrows/Ctrl) — this on-screen
        // accessory row only exists where there isn't one.
        let accessory = KeyboardAccessoryRow(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        accessory.onSendBytes = { [weak self] bytes in
            self?.send(bytes: bytes)
        }
        accessory.onToggleCtrl = { [weak terminalView] in
            guard let terminalView else { return false }
            terminalView.ctrlArmed.toggle()
            return terminalView.ctrlArmed
        }
        terminalView.inputAccessoryView = accessory

        terminalView.onFirstResponderChange = { [weak self] visible in
            self?.isKeyboardVisible = visible
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
    func hideKeyboard() {
        // Neither calling terminalView.resignFirstResponder() directly, nor
        // sendAction(#selector(resignFirstResponder), to: nil, ...), reliably
        // dismissed the keyboard in practice. Walking the key window's own view
        // hierarchy via endEditing(true) is the more forceful, standard fallback —
        // it doesn't depend on responder-chain lookup semantics at all.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .endEditing(true)
    }

    func showKeyboard() {
        terminalView.becomeFirstResponder()
    }
    #endif

    var isConnected: Bool {
        client?.isConnected ?? false
    }

    /// `environment` is sent as SSH env requests with the PTY; the server's sshd only
    /// honors names its AcceptEnv allows (macOS default: LANG and LC_*). Used by the test
    /// harness to mark its sessions so the dev machine's shell profile can tell them apart
    /// from a real interactive login.
    func connect(server: Server, credentials: ServerCredentials, environment: [String: String] = [:]) {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil
        lastServer = server
        lastCredentials = credentials
        lastEnvironment = environment

        generation += 1
        let myGeneration = generation
        runTask?.cancel()

        // A previous attempt may still be holding a client that's dead-but-not-yet-detected
        // (e.g. resumeActiveSessionIfNeeded reconnecting while the old run() loop is still
        // suspended awaiting a channel that already dropped). Close it now rather than
        // leaving two connections to the same server alive, and to unblock the old loop
        // promptly so its stale post-loop cleanup runs (and no-ops via the generation check)
        // instead of hanging indefinitely.
        if let staleClient = client {
            Task { try? await staleClient.close() }
        }
        client = nil
        stdinWriter = nil
        // Queued writes belong to the connection being replaced; letting them drain into
        // the new one would deliver stale keystrokes to a fresh shell.
        writeChain?.cancel()
        writeChain = nil
        lastSendTask = nil

        runTask = Task { [weak self] in
            await self?.run(server: server, credentials: credentials, environment: environment, generation: myGeneration)
        }
    }

    func markNeedsReconnect() {
        guard state == .connected else { return }
        state = .reconnecting
    }

    func reportMissingCredentials() {
        lastError = "No private key configured for this server."
    }

    func disconnect() {
        generation += 1
        runTask?.cancel()
        writeChain?.cancel()
        writeChain = nil
        lastSendTask = nil
        let closingClient = client
        client = nil
        stdinWriter = nil
        state = .disconnected
        Task { try? await closingClient?.close() }
    }

    /// Transport-level write. Every caller — keystrokes, the accessory row, pasted
    /// clippings, the agent — funnels through here.
    ///
    /// Writes are chained rather than each getting its own detached `Task`: unstructured
    /// tasks are scheduled independently, so two calls in quick succession could reach the
    /// channel out of order. With a human typing that's a rare cosmetic glitch; with
    /// something writing programmatically (the agent sending a command, or a multi-line
    /// paste) reordering corrupts the command itself, so ordering has to be guaranteed.
    ///
    /// Returns a `Task` resolving to whether the bytes actually reached the channel —
    /// `false` for a disconnected session (no `stdinWriter`) or a write that threw.
    /// `@discardableResult` so keystrokes and other fire-and-forget callers are unchanged;
    /// a caller that needs to know the real outcome (the agent's send path in particular)
    /// awaits it. The event log records the input only AFTER a confirmed successful
    /// write, not before: previously a disconnected session silently dropped the bytes
    /// while the log — and anything reading it, including the agent — still showed them
    /// as delivered. `lastError` carries the failure for the same reason `connect()`
    /// already uses it for a failed handshake, so both are one published surface.
    @discardableResult
    func send(bytes: [UInt8]) -> Task<Bool, Never> {
        let writer = stdinWriter
        let previousWrite = writeChain
        #if DEBUG
        let simulatedOutcome = simulatedWriteOutcome
        #endif
        let thisWrite = Task<Bool, Never> {
            // Always wait for whatever was queued before this — regardless of ITS
            // outcome — so the actual writes stay strictly ordered even when this call
            // (or an earlier one) turns out to have nothing to send to.
            await previousWrite?.value
            #if DEBUG
            if let simulatedOutcome {
                if simulatedOutcome {
                    self.eventLog.recordInput(bytes)
                } else {
                    self.lastError = "Input was not sent: simulated failure."
                }
                return simulatedOutcome
            }
            #endif
            guard let writer else {
                self.lastError = "Input was not sent: the terminal session is not connected."
                return false
            }
            do {
                try await writer.write(ByteBuffer(bytes: bytes))
                self.eventLog.recordInput(bytes)
                return true
            } catch {
                self.lastError = "Input was not sent: \(error)"
                return false
            }
        }
        writeChain = thisWrite
        lastSendTask = thisWrite
        return thisWrite
    }

    @discardableResult
    func send(text: String) -> Task<Bool, Never> {
        send(bytes: Array(text.utf8))
    }

    /// Input originating from the agent rather than the keyboard.
    ///
    /// Routed through SwiftTerm's `sendUserInput` instead of straight to `send(bytes:)`
    /// so the terminal's own OSC 133 interaction state advances exactly as it does for
    /// typed input. `sendUserInput` calls back through the view delegate into
    /// `send(bytes:)` above SYNCHRONOUSLY (confirmed against the vendored
    /// `Terminal.sendUserInput` — it calls `tdel?.send` directly, no queueing), so by the
    /// time this returns, `send(bytes:)` has already run and set `lastSendTask` — that's
    /// what lets this hand back the real outcome despite not calling `send(bytes:)`
    /// itself. Nil only when there was nothing to send (`text` empty) — a no-op, not a
    /// failure, and callers should treat it as trivially successful.
    @discardableResult
    func sendAgentInput(_ text: String) -> Task<Bool, Never>? {
        guard !text.isEmpty else { return nil }
        terminalView.getTerminal().sendUserInput(Array(text.utf8)[...])
        return lastSendTask
    }

    func resize(cols: Int, rows: Int) {
        guard let stdinWriter, cols > 0, rows > 0 else { return }
        Task {
            try? await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    private func run(server: Server, credentials: ServerCredentials, environment: [String: String], generation myGeneration: Int) async {
        do {
            let authMethod = try Self.authenticationMethod(credentials: credentials)
            // Citadel has no SSH-level keepalive, so a session that goes silently dead
            // (network drop, NAT/router idle timeout — not just macOS sleep, which is
            // handled separately via RootView's wake observer) never tells anyone it died;
            // the channel's `isActive`/close events just never fire. tmux's default
            // 15-second status-bar chatter means a genuinely healthy connection almost
            // always has some server->client traffic, so a 90-second read-idle threshold
            // catches a truly dead connection without false-positiving on a quiet-but-alive
            // one. Closing the channel here is what lets the existing reconnect logic (and
            // the auto-reconnect below) actually detect and recover instead of trusting a
            // stale `isConnected` flag.
            let client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                channelHandlers: [IdleStateHandler(readTimeout: .seconds(90)), IdleConnectionCloser()]
            )

            guard myGeneration == generation else {
                // Superseded (a newer connect() or a disconnect() happened while this was
                // handshaking) — don't adopt this connection, just close it.
                try? await client.close()
                return
            }
            self.client = client

            let dims = terminalView.getTerminal().getDims()
            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: max(dims.cols, 1),
                terminalRowHeight: max(dims.rows, 1),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            let environmentRequests = environment.map {
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: $0.key, value: $0.value)
            }
            try await client.withPTY(ptyRequest, environment: environmentRequests) { [weak self] inbound, outbound in
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

        // A superseded attempt must not clobber whatever a newer connect()/disconnect()
        // has since done to `client`/`stdinWriter`/`state`.
        guard myGeneration == generation else { return }
        // `.connected` here (as opposed to `.connecting`, meaning the initial handshake
        // itself failed) means this was a working session that dropped unexpectedly —
        // worth one silent auto-reconnect. A failed handshake is not: retrying a bad host/
        // credentials immediately would just spin, so that case is left for the user or an
        // explicit foreground/wake trigger to retry.
        let shouldAutoReconnect = state == .connected
        client = nil
        stdinWriter = nil
        if state != .disconnected {
            state = .disconnected
        }
        if shouldAutoReconnect, let server = lastServer, let credentials = lastCredentials {
            connect(server: server, credentials: credentials, environment: lastEnvironment)
        }
    }

    private func feed(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        eventLog.recordOutput(bytes)
        terminalView.feed(byteArray: bytes[...])
    }

    private func captureCopiedText(_ text: String, alsoWriteToPasteboard: Bool) {
        guard !text.isEmpty else { return }
        if alsoWriteToPasteboard {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
        onCapturedClipping(text)
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

// SwiftTerm always invokes `TerminalViewDelegate` callbacks on the main thread
// (either directly from UIKit input handling, or via its own `DispatchQueue.main.async`
// wrapping), so `assumeIsolated` here is a safe, zero-cost assertion of that fact rather
// than a real hop — it just satisfies the protocol's `nonisolated` requirement without
// making these calls actually cross actors at runtime.
extension TerminalSession: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { resize(cols: newCols, rows: newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { _ = send(bytes: Array(data)) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        MainActor.assumeIsolated {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { captureCopiedText(text, alsoWriteToPasteboard: true) }
    }

    nonisolated func clipboardRead(source: TerminalView) -> Data? {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
            #else
            UIPasteboard.general.string?.data(using: .utf8)
            #endif
        }
    }
}

/// Turns `IdleStateHandler`'s idle event into an actual channel close. `IdleStateHandler`
/// only fires a `userInboundEventTriggered` notification on idle — on its own it does
/// nothing observable to the rest of the app, so nothing would ever learn the connection is
/// suspect without this closing the channel and letting the resulting close cascade through
/// Citadel's `SSHClient` and this file's `run()` loop the same way any other disconnect does.
private final class IdleConnectionCloser: ChannelInboundHandler {
    typealias InboundIn = Any

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

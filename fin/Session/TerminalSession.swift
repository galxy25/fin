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

    @Published private(set) var state: SessionState = .disconnected
    @Published private(set) var lastError: String?
    #if os(iOS) || os(visionOS)
    /// Whether the on-screen keyboard (and its accessory row) is currently showing.
    /// Starts false — the terminal isn't first responder until tapped or explicitly shown.
    @Published private(set) var isKeyboardVisible = false
    #endif

    var onCapturedClipping: (String) -> Void = { _ in }

    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
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

    func connect(server: Server, credentials: ServerCredentials) {
        guard state == .disconnected || state == .reconnecting else { return }
        state = state == .reconnecting ? .reconnecting : .connecting
        lastError = nil

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

        runTask = Task { [weak self] in
            await self?.run(server: server, credentials: credentials, generation: myGeneration)
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
        let closingClient = client
        client = nil
        stdinWriter = nil
        state = .disconnected
        Task { try? await closingClient?.close() }
    }

    func send(bytes: [UInt8]) {
        guard let stdinWriter else { return }
        Task { try? await stdinWriter.write(ByteBuffer(bytes: bytes)) }
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard let stdinWriter, cols > 0, rows > 0 else { return }
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
                reconnect: .never
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

            try await client.withPTY(ptyRequest) { [weak self] inbound, outbound in
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
        client = nil
        stdinWriter = nil
        if state != .disconnected {
            state = .disconnected
        }
    }

    private func feed(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
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
        MainActor.assumeIsolated { send(bytes: Array(data)) }
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

// The iPhone/iPad side of the Apple TV remote-keyboard channel: browse for the
// TV's Bonjour service on the local network, seal every frame with the CloudKit-
// distributed pairing secret (same-iCloud-account gate — see RemoteInputPairing),
// then stream keystrokes and, on request, provision SSH keys the TV can't get
// any other way (tvOS is excluded from iCloud Keychain).
//
// iOS-only: browsing the local network prompts the user here (the TV side never
// prompts), and the key-capture surface is UIKit. NSBonjourServices in the app's
// Info.plist must list RemoteInput.serviceType for the browser to work.
#if os(iOS)
import SwiftUI
import SwiftData
import Network
import UIKit

@MainActor
final class RemoteKeyboardClient: NSObject, ObservableObject {
    enum ClientState: Equatable {
        case idle
        case browsing
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    @Published private(set) var state: ClientState = .idle
    @Published private(set) var discovered: [NWBrowser.Result] = []
    @Published var lastProvisionResult: String?

    var pairingSecret: () -> Data? = { nil }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var cipher: RemoteInputCipher?
    private var framer = RemoteInputFramer()
    private var localSalt = Data()
    private let queue = DispatchQueue(label: "fin.remote-input.client")

    func startBrowsing() {
        guard browser == nil else { return }
        state = .browsing
        let browser = NWBrowser(
            for: .bonjour(type: RemoteInput.serviceType, domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discovered = results.sorted { Self.name(of: $0) < Self.name(of: $1) }
            }
        }
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                if case .failed(let error) = browserState {
                    self?.state = .failed(String(describing: error))
                    self?.browser = nil
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        disconnect()
        state = .idle
        discovered = []
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        cipher = nil
        if case .connected = state { state = .browsing }
        if case .connecting = state { state = .browsing }
    }

    static func name(of result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return "Apple TV"
    }

    func connect(to result: NWBrowser.Result) {
        disconnect()
        let peerName = Self.name(of: result)
        state = .connecting(peerName)
        framer = RemoteInputFramer()
        localSalt = RemoteInputCipher.randomSalt()

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch connectionState {
                case .ready:
                    connection.send(content: self.localSalt, completion: .contentProcessed { _ in })
                    self.receiveSalt(on: connection, peerName: peerName)
                case .failed(let error):
                    self.state = .failed(String(describing: error))
                    self.disconnect()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveSalt(on connection: NWConnection, peerName: String) {
        connection.receive(minimumIncompleteLength: RemoteInputCipher.saltLength,
                           maximumLength: RemoteInputCipher.saltLength) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                guard error == nil, let data, data.count == RemoteInputCipher.saltLength else {
                    self.state = .failed("The Apple TV closed the connection during setup.")
                    self.disconnect(); return
                }
                guard let secret = self.pairingSecret() else {
                    self.state = .failed(RemoteInputError.pairingKeyUnavailable.localizedDescription)
                    self.disconnect(); return
                }
                self.cipher = RemoteInputCipher(
                    pairingSecret: secret, isListener: false,
                    listenerSalt: data, clientSalt: self.localSalt
                )
                self.send(.hello(deviceName: UIDevice.current.name, version: RemoteInput.protocolVersion))
                self.state = .connected(peerName)
                self.receiveLoop(on: connection)
            }
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.consume(data)
                }
                if isComplete || error != nil {
                    self.disconnect()
                } else {
                    self.receiveLoop(on: connection)
                }
            }
        }
    }

    private func consume(_ data: Data) {
        do {
            let payloads = try framer.feed(data)
            for payload in payloads {
                guard var cipher else { return }
                let message = try cipher.open(payload)
                self.cipher = cipher
                handle(message)
            }
        } catch {
            // Wrong or not-yet-synced pairing key (AEAD failure), or stream damage.
            state = .failed("Couldn't authenticate with the Apple TV. Make sure both devices use the same iCloud account and have synced recently, then try again.")
            disconnect()
        }
    }

    private func handle(_ message: RemoteInputMessage) {
        switch message {
        case .provisionAck(_, let accepted):
            lastProvisionResult = accepted
                ? "Key stored on the Apple TV."
                : "The Apple TV couldn't store that key."
        case .hello, .bytes, .text, .provisionKey, .ping:
            break
        }
    }

    func send(_ message: RemoteInputMessage) {
        guard let connection, var cipher else { return }
        guard let frame = try? cipher.sealFrame(message) else { return }
        self.cipher = cipher
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendBytes(_ bytes: [UInt8]) {
        send(.bytes(Data(bytes)))
    }
}

/// Hidden first responder that turns the software (or attached hardware) keyboard
/// into terminal bytes, with the same one-shot Ctrl arming the terminal's own
/// on-screen keyboard uses, and the existing KeyboardAccessoryRow above it.
private final class KeyCaptureUIView: UIView, UIKeyInput {
    var onBytes: (([UInt8]) -> Void)?
    var ctrlArmed = false

    private var accessory: KeyboardAccessoryRow?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }

    override var inputAccessoryView: UIView? { accessory }

    func installAccessory() {
        let row = KeyboardAccessoryRow(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        row.onSendBytes = { [weak self] bytes in self?.onBytes?(bytes) }
        row.onToggleCtrl = { [weak self] in
            guard let self else { return false }
            self.ctrlArmed.toggle()
            return self.ctrlArmed
        }
        accessory = row
    }

    func insertText(_ text: String) {
        if ctrlArmed {
            ctrlArmed = false
            if text.count == 1, let scalar = text.unicodeScalars.first,
               let ascii = Character(Character(scalar).uppercased()).asciiValue,
               (64...95).contains(ascii) {
                onBytes?([ascii - 64])
                return
            }
        }
        onBytes?(Array((text == "\n" ? "\r" : text).utf8))
    }

    func deleteBackward() {
        onBytes?([0x7F])
    }
}

private struct KeyCaptureArea: UIViewRepresentable {
    let client: RemoteKeyboardClient
    @Binding var wantsFocus: Bool

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.installAccessory()
        view.onBytes = { bytes in client.sendBytes(bytes) }
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        if wantsFocus, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !wantsFocus, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }
}

struct RemoteKeyboardView: View {
    @StateObject private var client = RemoteKeyboardClient()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KeyMetadata.importedAt) private var keys: [KeyMetadata]
    @State private var typingActive = false

    var body: some View {
        NavigationStack {
            List {
                switch client.state {
                case .connected(let peerName):
                    connectedSection(peerName: peerName)
                default:
                    discoverySection
                }
            }
            .navigationTitle("TV Remote Keyboard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            client.pairingSecret = { [modelContext] in
                RemoteInputPairingStore.resolve(context: modelContext, deviceName: UIDevice.current.name)
            }
            client.startBrowsing()
        }
        .onDisappear {
            typingActive = false
            client.stop()
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if client.discovered.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for Fin on your Apple TV…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(client.discovered.enumerated()), id: \.offset) { _, result in
                Button {
                    client.connect(to: result)
                } label: {
                    Label(RemoteKeyboardClient.name(of: result), systemImage: "appletv")
                }
            }
        } footer: {
            Text("Open Fin on your Apple TV first. Both devices must be on the same network and signed into the same iCloud account.")
        }
        if case .failed(let message) = client.state {
            Section {
                Text(message).foregroundStyle(.red)
            }
        }
        if case .connecting(let name) = client.state {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(name)…")
                }
            }
        }
    }

    @ViewBuilder
    private func connectedSection(peerName: String) -> some View {
        Section {
            HStack {
                Label(peerName, systemImage: "appletv.fill")
                Spacer()
                Button("Disconnect", role: .destructive) {
                    typingActive = false
                    client.disconnect()
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(typingActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                VStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.title2)
                    Text(typingActive ? "Keyboard active — typing goes to the TV" : "Tap to type on the TV")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
                KeyCaptureArea(client: client, wantsFocus: $typingActive)
                    .frame(width: 1, height: 1)
                    .opacity(0.02)
            }
            .contentShape(Rectangle())
            .onTapGesture { typingActive = true }
        } footer: {
            Text("The accessory row above the keyboard has Ctrl, Esc, Tab, and arrows — same as the terminal.")
        }

        Section("Send an SSH Key to the Apple TV") {
            if keys.isEmpty {
                Text("No keys imported on this device yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                Button {
                    sendKey(key)
                } label: {
                    HStack {
                        Label(key.name, systemImage: "key.fill")
                        Spacer()
                        Text(key.keyType.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let result = client.lastProvisionResult {
                Text(result)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sendKey(_ key: KeyMetadata) {
        guard let keyData = KeychainStore.loadPrivateKey(for: key.id),
              let pem = String(data: keyData, encoding: .utf8) else {
            client.lastProvisionResult = "Couldn't read that key from the Keychain on this device."
            return
        }
        let passphrase = KeychainStore.loadPassphrase(for: key.id)
            .flatMap { String(data: $0, encoding: .utf8) }
        client.send(.provisionKey(
            keyID: key.id,
            name: key.name,
            keyType: key.keyType.rawValue,
            pem: pem,
            passphrase: passphrase
        ))
        client.lastProvisionResult = "Sending \(key.name)…"
    }
}
#endif

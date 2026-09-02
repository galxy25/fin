// The Apple TV side of the iPhone-as-keyboard channel: advertises a Bonjour
// service on the local network and accepts frames sealed with the CloudKit-
// distributed pairing secret. tvOS has no local-network privacy prompt (TN3179),
// so the listener runs silently; the iOS companion is the side that prompts.
// Trust model: the secret only ever syncs through the user's private CloudKit
// database, so a peer that can seal a valid frame is signed into the same
// iCloud account — the required gate. Wrong-secret peers fail AEAD on their
// first frame and are dropped.
import Foundation
import Network

@MainActor
final class RemoteInputService: ObservableObject {
    enum ServiceState: Equatable {
        case idle
        case advertising
        case connected(peerName: String)
        case failed(String)
    }

    @Published private(set) var state: ServiceState = .idle

    /// The CloudKit-synced pairing secret; re-read per connection so a key that
    /// syncs in after launch (or a converged duplicate-mint race) is picked up.
    var pairingSecret: () -> Data? = { nil }
    /// Where keystrokes land: the active session, resolved at frame time.
    var sendToSession: ([UInt8]) -> Void = { _ in }
    /// SSH key provisioning from the companion (tvOS can't get keys any other way).
    var provisionKey: (UUID, String, String, String, String?) -> Bool = { _, _, _, _, _ in false }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var cipher: RemoteInputCipher?
    private var framer = RemoteInputFramer()
    private var localSalt = Data()
    private var remoteSalt = Data()
    private let queue = DispatchQueue(label: "fin.remote-input.listener")

    func start(deviceName: String) {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: deviceName, type: RemoteInput.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    switch newState {
                    case .ready: if case .idle = self?.state ?? .idle { self?.state = .advertising }
                    case .failed(let error): self?.state = .failed(String(describing: error))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.adopt(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        state = .idle
    }

    /// One companion at a time; a new connection replaces the old (the common case
    /// is the same phone reconnecting after the app was backgrounded).
    private func adopt(_ newConnection: NWConnection) {
        connection?.cancel()
        cipher = nil
        framer = RemoteInputFramer()
        remoteSalt = Data()
        localSalt = RemoteInputCipher.randomSalt()
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                switch connectionState {
                case .ready:
                    self?.sendSaltAndReceive(on: newConnection)
                case .failed, .cancelled:
                    if self?.connection === newConnection { self?.dropConnection() }
                default:
                    break
                }
            }
        }
        newConnection.start(queue: queue)
    }

    private func sendSaltAndReceive(on connection: NWConnection) {
        connection.send(content: localSalt, completion: .contentProcessed { _ in })
        receiveSalt(on: connection)
    }

    private func receiveSalt(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: RemoteInputCipher.saltLength,
                           maximumLength: RemoteInputCipher.saltLength) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                guard error == nil, let data, data.count == RemoteInputCipher.saltLength else {
                    self.dropConnection(); return
                }
                guard let secret = self.pairingSecret() else {
                    // No key synced yet — nothing to authenticate against.
                    self.dropConnection(); return
                }
                self.remoteSalt = data
                self.cipher = RemoteInputCipher(
                    pairingSecret: secret, isListener: true,
                    listenerSalt: self.localSalt, clientSalt: data
                )
                self.sendMessage(.hello(deviceName: self.currentDeviceName, version: RemoteInput.protocolVersion))
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
                    self.dropConnection()
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
            // AEAD failure = wrong key (different iCloud account, or key not yet
            // converged) or a tampered stream; either way the peer is untrusted.
            dropConnection()
        }
    }

    private func handle(_ message: RemoteInputMessage) {
        switch message {
        case .hello(let deviceName, _):
            state = .connected(peerName: deviceName)
        case .bytes(let data):
            sendToSession(Array(data))
        case .text(let string):
            sendToSession(Array(string.utf8))
        case .provisionKey(let keyID, let name, let keyType, let pem, let passphrase):
            let accepted = provisionKey(keyID, name, keyType, pem, passphrase)
            sendMessage(.provisionAck(keyID: keyID, accepted: accepted))
        case .provisionAck, .ping:
            break
        }
    }

    private func sendMessage(_ message: RemoteInputMessage) {
        guard let connection, var cipher else { return }
        guard let frame = try? cipher.sealFrame(message) else { return }
        self.cipher = cipher
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        cipher = nil
        if case .connected = state { state = .advertising }
    }

    private var currentDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Apple TV"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

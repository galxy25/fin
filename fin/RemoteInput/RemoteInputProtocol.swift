// Shared by the tvOS listener (RemoteInputService) and the iOS companion
// (RemoteKeyboardView). Pure Foundation + Crypto — no UI, no platform gates.
import Foundation
import Crypto

enum RemoteInput {
    /// Bonjour service the Apple TV advertises and the iOS companion browses for.
    /// The iOS Info.plist must list this exact type under NSBonjourServices.
    static let serviceType = "_fin-input._tcp"
    static let protocolVersion = 1
    /// Sanity ceiling on a single sealed frame (a provisioned RSA key is ~4 KB;
    /// nothing legitimate approaches this).
    static let maxFrameLength = 1 << 20
}

/// Everything that crosses the wire after the salt exchange, sealed.
enum RemoteInputMessage: Codable, Equatable {
    /// First sealed frame in each direction. Decrypting it at all proves the peer
    /// holds the CloudKit-distributed pairing secret (the same-iCloud-account gate).
    case hello(deviceName: String, version: Int)
    /// Raw terminal input bytes (keystrokes, control sequences).
    case bytes(Data)
    /// Convenience for whole strings (pastes, the tvOS fallback text field).
    case text(String)
    /// SSH key provisioning: tvOS is excluded from iCloud Keychain, so the paired
    /// channel is how private-key material reaches the TV. Stored in the TV's own
    /// Keychain under the same KeyMetadata id the synced model row references.
    case provisionKey(keyID: UUID, name: String, keyType: String, pem: String, passphrase: String?)
    case provisionAck(keyID: UUID, accepted: Bool)
    case ping
}

/// Frame crypto. Wire format per connection:
///
///     [16-byte random salt, cleartext]            — sent immediately by BOTH ends
///     [4-byte BE length][sealed frame] ...        — everything else
///
/// sessionKey = HKDF-SHA256(ikm: pairing secret,
///                          salt: listenerSalt || clientSalt,
///                          info: "fin-remote-input-v1", 32 bytes)
///
/// Sealed frame = ChaChaPoly.combined with a deterministic 12-byte nonce:
/// [direction byte][3 zero bytes][8-byte BE counter]. Directions differ (listener
/// 0x02, client 0x01) so the two ends can never collide on a nonce, and receivers
/// require strictly increasing counters, which kills replays within a connection.
/// Cross-connection replay dies with the salts: a new connection derives a new key.
struct RemoteInputCipher {
    static let saltLength = 16

    private let sessionKey: SymmetricKey
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private var sendCounter: UInt64 = 0
    private var lastReceivedCounter: UInt64 = 0

    init(pairingSecret: Data, isListener: Bool, listenerSalt: Data, clientSalt: Data) {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingSecret),
            salt: listenerSalt + clientSalt,
            info: Data("fin-remote-input-v1".utf8),
            outputByteCount: 32
        )
        self.sessionKey = key
        self.sendDirection = isListener ? 0x02 : 0x01
        self.receiveDirection = isListener ? 0x01 : 0x02
    }

    static func randomSalt() -> Data {
        var salt = Data(count: saltLength)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        return salt
    }

    private static func nonce(direction: UInt8, counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data([direction, 0, 0, 0])
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// Returns a complete wire frame: 4-byte BE length prefix + sealed box.
    mutating func sealFrame(_ message: RemoteInputMessage) throws -> Data {
        let plaintext = try JSONEncoder().encode(message)
        sendCounter += 1
        let box = try ChaChaPoly.seal(
            plaintext, using: sessionKey,
            nonce: Self.nonce(direction: sendDirection, counter: sendCounter)
        )
        let payload = box.combined
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Opens one sealed payload (length prefix already stripped by the framer).
    mutating func open(_ payload: Data) throws -> RemoteInputMessage {
        let box = try ChaChaPoly.SealedBox(combined: payload)
        // The nonce is authenticated as part of the box; enforce direction + monotonic counter.
        let nonceData = box.nonce.withUnsafeBytes { Data($0) }
        guard nonceData.count == 12, nonceData[nonceData.startIndex] == receiveDirection else {
            throw RemoteInputError.badNonce
        }
        let counter = nonceData.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter > lastReceivedCounter else { throw RemoteInputError.replayedFrame }
        let plaintext = try ChaChaPoly.open(box, using: sessionKey)
        lastReceivedCounter = counter
        return try JSONDecoder().decode(RemoteInputMessage.self, from: plaintext)
    }
}

enum RemoteInputError: Error, LocalizedError {
    case badNonce
    case replayedFrame
    case frameTooLarge
    case pairingKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .badNonce: return "Frame arrived with an invalid nonce."
        case .replayedFrame: return "Frame counter went backward (replay?)."
        case .frameTooLarge: return "Frame exceeds the protocol's size ceiling."
        case .pairingKeyUnavailable:
            return "No pairing key is available yet — open Fin on both devices and give iCloud a moment to sync."
        }
    }
}

/// Incremental parser for the framed stream: feed raw received chunks, get out
/// complete sealed payloads (length prefix stripped). The 16-byte salt that leads
/// the stream is the caller's job — hand this parser only what follows it.
struct RemoteInputFramer {
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= RemoteInput.maxFrameLength else { throw RemoteInputError.frameTooLarge }
            guard buffer.count >= 4 + Int(length) else { break }
            frames.append(buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + Int(length)))
            buffer.removeFirst(4 + Int(length))
        }
        return frames
    }
}

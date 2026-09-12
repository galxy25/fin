// The device key vault: how SSH private keys reach the devices iCloud Keychain
// never does (tvOS is excluded from it) without a local network in the loop.
//
// Every Fin device that has iCloud Keychain (iPhone, iPad, Mac, Vision Pro)
// seals each key it holds with the account's VAULT KEY and PUTs the ciphertext
// to the control plane (`PUT /vault/keys/{keyId}`). The vault key is 32 random
// bytes that live only in the user's private CloudKit database
// (`RemoteInputPairing` — the record name is frozen for CloudKit schema
// reasons; see that file), so the control plane stores nothing it can open, and
// a device that can read the user's private database can open everything.
//
// The Apple TV signs in with Apple, which mints it a session token for the same
// account (`POST /auth/apple`), then lists the vault and opens each entry with
// the vault key CloudKit delivered. No Bonjour, no VPN/mesh/Private Relay
// sensitivity — two cloud reads, both gated by the user's Apple ID.
//
// Shared by both app targets (fin, fin-tv). Pure Foundation + Crypto — no UI.
import Foundation
import Crypto

enum KeyVault {
    /// The iCloud Key-Value Storage key the control-plane endpoint rides under
    /// (`CloudControlPlaneConfig.endpointURLKey` is defined as this). It lives
    /// here so the tvOS target, which compiles none of `fin/Agent`, reads the
    /// same slot the iPhone wrote.
    static let endpointURLKey = "fin.cloudcp.endpointURL"

    /// iCloud Key-Value Storage mirror of the account's vault key (base64).
    /// The CloudKit record (`RemoteInputPairing`) stays the source of truth for
    /// sealing devices; the mirror exists because a device that only OPENS
    /// entries may hold a stale or partial view of the CloudKit records, while
    /// KVS delivers in seconds. Same trust level as the record it mirrors: the
    /// user's iCloud, never the control plane.
    static let vaultKeyMirrorKey = "fin.vault.key"

    /// Short digest of a vault key for watermarks and diagnostics — never the key.
    static func fingerprint(_ vaultKey: Data) -> String {
        String(SHA256.hash(data: vaultKey).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Domain separation for the HKDF derivation; bump with the wire format.
    static let hkdfInfo = "fin-key-vault-v1"

    struct Entry: Codable, Equatable {
        var keyId: String
        var name: String
        var keyType: String
        var ciphertext: String
        var updatedAt: String?
        /// `KeyVault.fingerprint` of the vault key that sealed this entry, so an
        /// opener can say which key it lacks instead of "couldn't open".
        var vaultKeyFingerprint: String?
    }

    /// What one sealed entry holds. The passphrase rides alongside the PEM so an
    /// encrypted key is usable on arrival, not just present.
    struct Secret: Codable, Equatable {
        var pem: String
        var passphrase: String?
    }

    enum VaultError: Error, LocalizedError {
        case badCiphertext
        case badPlaintext

        var errorDescription: String? {
            switch self {
            case .badCiphertext: return "That vault entry could not be opened with this account's vault key."
            case .badPlaintext: return "That vault entry did not contain a key."
            }
        }
    }

    private static func symmetricKey(vaultKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: vaultKey),
            info: Data(hkdfInfo.utf8),
            outputByteCount: 32
        )
    }

    /// ChaChaPoly over the JSON-encoded secret, with the key's id as associated
    /// data so an entry copied under another id fails to open rather than
    /// silently becoming that other key.
    static func seal(_ secret: Secret, keyID: UUID, vaultKey: Data) throws -> String {
        let plaintext = try JSONEncoder().encode(secret)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: symmetricKey(vaultKey: vaultKey),
            authenticating: Data(keyID.uuidString.uppercased().utf8)
        )
        return sealed.combined.base64EncodedString()
    }

    static func open(_ ciphertext: String, keyID: UUID, vaultKey: Data) throws -> Secret {
        guard let combined = Data(base64Encoded: ciphertext),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plaintext = try? ChaChaPoly.open(
                  box,
                  using: symmetricKey(vaultKey: vaultKey),
                  authenticating: Data(keyID.uuidString.uppercased().utf8)
              )
        else { throw VaultError.badCiphertext }
        guard let secret = try? JSONDecoder().decode(Secret.self, from: plaintext), !secret.pem.isEmpty else {
            throw VaultError.badPlaintext
        }
        return secret
    }
}

/// The three vault routes, against a fixed endpoint + session token. Transport
/// is injectable so the request shapes are testable without a server.
struct KeyVaultClient {
    var endpoint: String
    var token: String
    var transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    enum ClientError: Error, LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No control plane configured."
            case .http(let status, let message): return message.isEmpty ? "HTTP \(status)" : message
            }
        }
    }

    static func normalizedBase(_ endpoint: String) -> String {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    func request(_ method: String, path: String, body: [String: Any]? = nil) throws -> URLRequest {
        let base = Self.normalizedBase(endpoint)
        guard !base.isEmpty, !token.isEmpty, let url = URL(string: base + path) else {
            throw ClientError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ClientError.http(status, (fields?["error"] as? String) ?? "")
        }
        return data
    }

    func list() async throws -> [KeyVault.Entry] {
        let data = try await send(try request("GET", path: "/vault/keys"))
        struct Envelope: Decodable { var keys: [KeyVault.Entry] }
        return try JSONDecoder().decode(Envelope.self, from: data).keys
    }

    func put(keyID: UUID, name: String, keyType: String, ciphertext: String, vaultKeyFingerprint: String? = nil) async throws {
        var body: [String: Any] = ["name": name, "keyType": keyType, "ciphertext": ciphertext]
        if let vaultKeyFingerprint { body["vaultKeyFingerprint"] = vaultKeyFingerprint }
        _ = try await send(try request("PUT", path: "/vault/keys/\(keyID.uuidString)", body: body))
    }

    func delete(keyID: UUID) async throws {
        _ = try await send(try request("DELETE", path: "/vault/keys/\(keyID.uuidString)"))
    }
}

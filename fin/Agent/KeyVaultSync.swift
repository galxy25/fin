import Foundation
import SwiftData
import Crypto

/// The keychain-holding side of the key vault (see `KeyVault`): every SSH key
/// this device can read is sealed with the account's vault key and pushed to
/// the control plane, once, so a device without iCloud Keychain (the Apple TV)
/// can fetch it after Sign in with Apple. Pushes are idempotent per key id —
/// key material never changes after import — and the watermark lives in
/// UserDefaults so a reinstall simply re-pushes.
@MainActor
enum KeyVaultSync {
    static var transport: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private static func watermarkKey(_ keyID: UUID) -> String { "fin.vault.pushed.\(keyID.uuidString)" }

    /// The watermark records WHICH vault key sealed the push (a short digest,
    /// never the key), so a device whose minted key lost the CloudKit race
    /// re-seals with the winner on its next launch instead of leaving entries
    /// nobody can open.
    nonisolated static func fingerprint(_ vaultKey: Data) -> String {
        String(SHA256.hash(data: vaultKey).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Launch-time sweep: anything imported before the vault existed, or pushed
    /// while the control plane was unconfigured, goes now. Silent on failure —
    /// the next launch retries, and the user never sees a spinner for a
    /// background convenience.
    /// `force` ignores the watermark (the "Send keys to my Fin account" button):
    /// re-seals and re-pushes every key this device can read. Returns
    /// (pushed, total keys with readable material here).
    @discardableResult
    static func pushAll(context: ModelContext, force: Bool = false) async -> (pushed: Int, readable: Int) {
        guard CloudControlPlaneConfig.isConfigured else { return (0, 0) }
        guard let vaultKey = DeviceVaultKeyStore.resolve(context: context, deviceName: "device-" + DeviceIdentity.short) else { return (0, 0) }
        let current = fingerprint(vaultKey)
        let keys = (try? context.fetch(FetchDescriptor<KeyMetadata>())) ?? []
        var pushed = 0, readable = 0
        for key in keys {
            guard KeychainStore.loadPrivateKey(for: key.id) != nil else { continue }
            readable += 1
            guard force || UserDefaults.standard.string(forKey: watermarkKey(key.id)) != current else { continue }
            if await push(key, context: context) { pushed += 1 }
        }
        return (pushed, readable)
    }

    /// Push one key right after import/generation. Returns whether it landed.
    @discardableResult
    static func push(_ metadata: KeyMetadata, context: ModelContext) async -> Bool {
        guard CloudControlPlaneConfig.isConfigured,
              let pemData = KeychainStore.loadPrivateKey(for: metadata.id),
              let pem = String(data: pemData, encoding: .utf8),
              let vaultKey = DeviceVaultKeyStore.resolve(context: context, deviceName: "device-" + DeviceIdentity.short)
        else { return false }
        let passphrase = KeychainStore.loadPassphrase(for: metadata.id).flatMap { String(data: $0, encoding: .utf8) }
        do {
            let ciphertext = try KeyVault.seal(
                KeyVault.Secret(pem: pem, passphrase: passphrase), keyID: metadata.id, vaultKey: vaultKey
            )
            var client = KeyVaultClient(endpoint: CloudControlPlaneConfig.endpointURL, token: CloudControlPlaneConfig.token)
            client.transport = transport
            try await client.put(keyID: metadata.id, name: metadata.name, keyType: metadata.keyType.rawValue, ciphertext: ciphertext)
            UserDefaults.standard.set(fingerprint(vaultKey), forKey: watermarkKey(metadata.id))
            return true
        } catch {
            return false
        }
    }
}

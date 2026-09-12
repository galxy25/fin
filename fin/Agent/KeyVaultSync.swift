import Foundation
import SwiftData

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

    /// Launch-time sweep: anything imported before the vault existed, or pushed
    /// while the control plane was unconfigured, goes now. Silent on failure —
    /// the next launch retries, and the user never sees a spinner for a
    /// background convenience.
    static func pushAll(context: ModelContext) async {
        guard CloudControlPlaneConfig.isConfigured else { return }
        let keys = (try? context.fetch(FetchDescriptor<KeyMetadata>())) ?? []
        for key in keys where !UserDefaults.standard.bool(forKey: watermarkKey(key.id)) {
            await push(key, context: context)
        }
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
            UserDefaults.standard.set(true, forKey: watermarkKey(metadata.id))
            return true
        } catch {
            return false
        }
    }
}

import Foundation
import SwiftData

/// The account's VAULT KEY: 32 random bytes distributed through the user's private
/// CloudKit database, with which every key-vault entry is sealed (see `KeyVault`).
/// Possession is the entire same-iCloud-account gate: the record syncs only to
/// devices signed into the same account, so a device that can open a vault entry
/// has, by construction, read access to this user's private database. The control
/// plane holds ciphertext only. The key itself never leaves CloudKit.
///
/// The class (= CloudKit record type) name is frozen: it was minted for the retired
/// Apple TV remote-keyboard channel, and renaming a synced model means a Production
/// schema deploy plus every device re-minting — for zero user-visible gain. The
/// store below carries the honest name.
///
/// CloudKit mirroring rules (same as every synced model): every property has a
/// default, no unique constraints. Both devices may race to mint a key before the
/// first sync lands; `DeviceVaultKeyStore.resolve` converges on the record with
/// the lexicographically lowest id and ignores the rest, so the race settles without
/// coordination once sync catches up.
@Model
final class RemoteInputPairing {
    var id: UUID = UUID()
    var secretData: Data = Data()
    /// Name of the device that minted the key — diagnostic only.
    var mintedByDeviceName: String = ""
    var createdAt: Date = Date()

    init(secretData: Data, mintedByDeviceName: String) {
        self.id = UUID()
        self.secretData = secretData
        self.mintedByDeviceName = mintedByDeviceName
        self.createdAt = Date()
    }
}

enum DeviceVaultKeyStore {
    /// The canonical vault key if CloudKit has delivered one — never mints.
    /// For devices that only OPEN entries (the Apple TV): a key minted there could
    /// only ever lose the race to the sealing devices' key, and would leave every
    /// entry unopenable until sync sorted it out.
    @MainActor
    static func existing(context: ModelContext) -> Data? {
        candidates(context: context).first
    }

    /// Every vault key this device can see — the CloudKit records in canonical
    /// order, then the iCloud KVS mirror — for an opener to try in turn. A
    /// device's CloudKit view can lag or differ from the sealing device's; the
    /// entries themselves say which key sealed them (`vaultKeyFingerprint`).
    @MainActor
    static func candidates(context: ModelContext) -> [Data] {
        let all = (try? context.fetch(FetchDescriptor<RemoteInputPairing>())) ?? []
        var keys = all.filter { $0.secretData.count == 32 }
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
            .map(\.secretData)
        if let mirrored = NSUbiquitousKeyValueStore.default.string(forKey: KeyVault.vaultKeyMirrorKey),
           let data = Data(base64Encoded: mirrored), data.count == 32, !keys.contains(data) {
            keys.append(data)
        }
        return keys
    }

    /// Sealing devices call this after `resolve`: the canonical key rides KVS as
    /// well, so openers converge in seconds rather than at CloudKit's pace.
    static func mirror(_ vaultKey: Data) {
        let store = NSUbiquitousKeyValueStore.default
        let encoded = vaultKey.base64EncodedString()
        if store.string(forKey: KeyVault.vaultKeyMirrorKey) != encoded {
            store.set(encoded, forKey: KeyVault.vaultKeyMirrorKey)
            store.synchronize()
        }
    }

    /// Returns the canonical vault key, minting one if none exists yet.
    ///
    /// Canonical = the record with the lowest id string, so two devices that both
    /// minted before their first sync converge on the same winner afterward (the
    /// loser's record is simply never read again; it is cleaned up lazily here).
    @MainActor
    static func resolve(context: ModelContext, deviceName: String) -> Data? {
        let all = (try? context.fetch(FetchDescriptor<RemoteInputPairing>())) ?? []
        let valid = all.filter { $0.secretData.count == 32 }
        if let winner = valid.min(by: { $0.id.uuidString < $1.id.uuidString }) {
            // Lazy cleanup: anything that lost the race (or is malformed) goes.
            for record in all where record !== winner {
                context.delete(record)
            }
            return winner.secretData
        }
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        context.insert(RemoteInputPairing(secretData: secret, mintedByDeviceName: deviceName))
        return secret
    }
}

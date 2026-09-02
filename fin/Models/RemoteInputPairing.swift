import Foundation
import SwiftData

/// The shared secret behind the Apple TV remote-input channel, distributed through
/// the user's private CloudKit database. Possession of this key is the entire
/// same-iCloud-account gate: the record syncs only to devices signed into the same
/// account, so a peer that can seal a valid frame has, by construction, read access
/// to this user's private database. The key never travels over the local network —
/// both ends derive a per-connection session key from it (see `RemoteInputCipher`).
///
/// CloudKit mirroring rules (same as every synced model): every property has a
/// default, no unique constraints. Both devices may race to mint a key before the
/// first sync lands; `RemoteInputPairingStore.resolve` converges on the record with
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

enum RemoteInputPairingStore {
    /// Returns the canonical pairing secret, minting one if none exists yet.
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

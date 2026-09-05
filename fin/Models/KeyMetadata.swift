import Foundation
import SwiftData

enum SSHKeyType: String, Codable {
    case ed25519
    case rsa
}

@Model
final class KeyMetadata {
    var id: UUID = UUID()
    var name: String = ""
    var keyType: SSHKeyType = SSHKeyType.ed25519
    var importedAt: Date = Date()
    /// True for the key FIN itself owns — generated in-app under "Fin's Key" so
    /// the user can grant their agent access to a computer without ever running
    /// ssh-keygen. False for every key the user imported. Schema-additive with a
    /// default (CloudKit-safe): records synced by earlier builds decode as
    /// user-owned, which is exactly what they are.
    var agentOwned: Bool = false

    init(name: String, keyType: SSHKeyType, agentOwned: Bool = false) {
        self.id = UUID()
        self.name = name
        self.keyType = keyType
        self.importedAt = Date()
        self.agentOwned = agentOwned
    }
}

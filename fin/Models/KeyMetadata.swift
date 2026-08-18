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

    init(name: String, keyType: SSHKeyType) {
        self.id = UUID()
        self.name = name
        self.keyType = keyType
        self.importedAt = Date()
    }
}

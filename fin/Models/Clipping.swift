import Foundation
import SwiftData

enum ClippingDirection: String, Codable {
    case to
    case from
}

@Model
final class Clipping {
    var id: UUID
    var name: String
    var text: String
    var direction: ClippingDirection
    var createdAt: Date

    init(name: String? = nil, text: String, direction: ClippingDirection) {
        self.id = UUID()
        self.name = name ?? String(Int(Date().timeIntervalSince1970))
        self.text = text
        self.direction = direction
        self.createdAt = Date()
    }
}

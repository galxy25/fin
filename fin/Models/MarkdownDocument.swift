import Foundation
import SwiftData

@Model
final class MarkdownDocument {
    var id: UUID
    var name: String
    /// Security-scoped bookmark so the file (picked from outside the app's
    /// sandbox via the Files/iCloud picker) stays reachable across launches.
    var bookmarkData: Data
    var lastOpenedAt: Date

    init(name: String, bookmarkData: Data) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = Date()
    }
}

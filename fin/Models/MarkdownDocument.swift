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

extension URL {
    /// The bookmark data every `MarkdownDocument` stores. A plain
    /// `bookmarkData()` resolves fine but does NOT restore sandbox file
    /// access outside the app's container once the file picker's own
    /// temporary grant expires (a fresh launch, or reopening the document in
    /// a new window) — it silently produces a bookmark that *looks* valid but
    /// reads/writes fail with a permission error. `.withSecurityScope` is
    /// what actually persists the grant; it's macOS-only (unavailable/
    /// unnecessary on iOS, whose sandbox model doesn't need it).
    func fin_markdownBookmarkData() throws -> Data {
        #if os(macOS)
        try bookmarkData(options: .withSecurityScope)
        #else
        try bookmarkData()
        #endif
    }

    /// Resolves a `MarkdownDocument.bookmarkData` back to a URL, mirroring
    /// `fin_markdownBookmarkData()`'s options so resolution matches creation.
    static func fin_resolveMarkdownBookmark(_ data: Data, isStale: inout Bool) -> URL? {
        #if os(macOS)
        try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #endif
    }
}

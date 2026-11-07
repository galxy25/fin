import Foundation
import UniformTypeIdentifiers

/// docs/XANADU.md "Share extension (v1.1)": the pure half of turning what the
/// system share sheet hands `fin-share` into one Xanadu message. Compiled into
/// the app too, so finTests pins it; Foundation/UTType only.
enum ShareIntake {
    /// `POST /messages`' text cap — the share extension cannot see
    /// `AgentRelayApplier`, so this mirrors it (a test pins the two equal).
    static let messageTextLimit = 8000

    /// How one shared item is read.
    enum Route: Equatable {
        /// Real content (an image, a movie, audio, a PDF, a spreadsheet…):
        /// load a file representation of this type identifier.
        case file(String)
        /// A file handed over by URL (Files, Finder): copy it.
        case fileURL
        /// A web link: it rides in the message text, not as a file.
        case webURL
        /// Plain text: into the message, or a `.txt` file when it is too long.
        case text
    }

    /// Pure: the route for an item provider's registered type identifiers.
    /// Content beats links beats text, so a photo Safari also offers as a URL
    /// arrives as the photo, and a `.txt` from Files arrives as the file.
    static func route(for typeIdentifiers: [String]) -> Route? {
        let types = typeIdentifiers.compactMap { UTType($0) }
        let content = types.first { type in
            if type.conforms(to: .text) || type.conforms(to: .url) { return false }
            return type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .data)
        }
        if let content { return .file(content.identifier) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
        if types.contains(where: { $0.conforms(to: .url) }) { return .webURL }
        if types.contains(where: { $0.conforms(to: .text) }) { return .text }
        return nil
    }

    /// Pure: the file name an attachment gets. The provider's suggested name
    /// first (Photos gives `IMG_1234` with no extension), then the loaded
    /// file's own name, then `shared-N`; the type's extension is added when the
    /// name has none.
    static func fileName(suggested: String?, loadedName: String?, typeIdentifier: String?, index: Int) -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        var name = clean(suggested) ?? clean(loadedName) ?? "shared-\(index + 1)"
        if (name as NSString).pathExtension.isEmpty,
           let type = typeIdentifier.flatMap({ UTType($0) }), let ext = type.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }

    /// Pure: the message text — the note, then links, then shared text, each
    /// block separated by a blank line. When that is over `limit`, the shared
    /// text moves into a file (`overflow`) and the message keeps the note and
    /// the links.
    static func messageText(note: String, urls: [String], texts: [String], limit: Int = messageTextLimit)
        -> (text: String, overflow: String?) {
        func trimmed(_ items: [String]) -> [String] {
            items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let noteBlock = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkBlock = trimmed(urls).joined(separator: "\n")
        let textBlock = trimmed(texts).joined(separator: "\n\n")
        let all = [noteBlock, linkBlock, textBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard all.count > limit, !textBlock.isEmpty else { return (all, nil) }
        let kept = [noteBlock, linkBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (kept, textBlock)
    }

    static let overflowFileName = "shared-text.txt"
}

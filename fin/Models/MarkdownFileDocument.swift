import SwiftUI
import UniformTypeIdentifiers

/// Bridges a brand-new markdown file into SwiftUI's `.fileExporter`, which
/// hands the user the standard save-to-Files/iCloud picker (location + name)
/// and gives us back a URL we can treat exactly like an imported one.
struct MarkdownFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static let writableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

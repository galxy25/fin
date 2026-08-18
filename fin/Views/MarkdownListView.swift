import SwiftUI
import SwiftData

struct MarkdownListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MarkdownDocument.lastOpenedAt, order: .reverse) private var documents: [MarkdownDocument]

    @State private var isImporting = false
    @State private var isCreatingNew = false
    @State private var importErrorMessage: String?
    @State private var newlyCreatedDocument: MarkdownDocument?

    var body: some View {
        List {
            ForEach(documents) { document in
                NavigationLink {
                    MarkdownReaderView(document: document)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.name).font(.headline)
                        Text(document.lastOpenedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    modelContext.delete(documents[index])
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isCreatingNew = true
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                    Button {
                        isImporting = true
                    } label: {
                        Label("Open Existing File\u{2026}", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if documents.isEmpty {
                ContentUnavailableView(
                    "No Markdown Files",
                    systemImage: "doc.text",
                    description: Text("Tap + to open one.")
                )
            }
        }
        .alert(
            "Couldn't Open File",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            handlePicked(result)
        }
        .fileExporter(
            isPresented: $isCreatingNew,
            document: MarkdownFileDocument(),
            contentType: .plainText,
            defaultFilename: "Untitled"
        ) { result in
            handleCreated(result)
        }
        .sheet(item: $newlyCreatedDocument) { document in
            NavigationStack {
                MarkdownReaderView(document: document, startInEditMode: true)
            }
        }
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmarkData = try url.bookmarkData()
                if let existing = documents.first(where: { sameFile($0, as: url) }) {
                    existing.lastOpenedAt = Date()
                } else {
                    let document = MarkdownDocument(name: url.lastPathComponent, bookmarkData: bookmarkData)
                    modelContext.insert(document)
                }
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleCreated(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmarkData = try url.bookmarkData()
                let document = MarkdownDocument(name: url.lastPathComponent, bookmarkData: bookmarkData)
                modelContext.insert(document)
                newlyCreatedDocument = document
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func sameFile(_ document: MarkdownDocument, as url: URL) -> Bool {
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: document.bookmarkData, bookmarkDataIsStale: &isStale) else {
            return false
        }
        return resolved.path == url.path
    }
}

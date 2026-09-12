import SwiftUI
import SwiftData

struct MarkdownListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MarkdownDocument.lastOpenedAt, order: .reverse) private var documents: [MarkdownDocument]

    @State private var isImporting = false
    @State private var isCreatingNew = false
    @State private var importErrorMessage: String?
    @State private var newlyCreatedDocument: MarkdownDocument?
    #if os(macOS) || os(visionOS)
    @Environment(\.openWindow) private var openWindow
    // Same reasoning and pattern as AgentListView's `selectedAgentID`: a file
    // opens as its own resizable window here (there's real value in reading a
    // file next to a terminal session or another file, the way the agent hub
    // already does), and selection-driven navigation is what reliably fires
    // `openWindow` under XCUITest automation — a Button nested in a List row
    // does not.
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDocumentID: UUID?
    #endif

    var body: some View {
        list
        .accessibilityIdentifier("fileListView")
        .task { seedUITestFileIfNeeded() }
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
                    "No Files",
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
        #if !os(macOS) && !os(visionOS)
        .sheet(item: $newlyCreatedDocument) { document in
            NavigationStack {
                MarkdownReaderView(document: document, startInEditMode: true)
            }
        }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS) || os(visionOS)
        List(selection: $selectedDocumentID) {
            fileRows
        }
        .onChange(of: selectedDocumentID) { _, newValue in
            guard let newValue else { return }
            openWindow(id: FinScene.markdownReader, value: newValue)
            // Reset so selecting the SAME file again after closing its window
            // still triggers onChange (a value "changing" to what it already was
            // wouldn't fire otherwise).
            selectedDocumentID = nil
            dismiss()
        }
        .listStyle(.plain)
        #else
        List {
            fileRows
        }
        .listStyle(.plain)
        #endif
    }

    @ViewBuilder
    private var fileRows: some View {
        ForEach(documents) { document in
            #if os(macOS) || os(visionOS)
            fileRowLabel(document)
                .tag(document.id)
                .accessibilityIdentifier("fileRow_\(document.id.uuidString)")
            #else
            NavigationLink {
                MarkdownReaderView(document: document)
            } label: {
                fileRowLabel(document)
            }
            .accessibilityIdentifier("fileRow_\(document.id.uuidString)")
            #endif
        }
        .onDelete { offsets in
            for index in offsets {
                modelContext.delete(documents[index])
            }
        }
    }

    private func fileRowLabel(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.name).font(.headline)
            Text(document.lastOpenedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                let bookmarkData = try url.fin_markdownBookmarkData()
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
                let bookmarkData = try url.fin_markdownBookmarkData()
                let document = MarkdownDocument(name: url.lastPathComponent, bookmarkData: bookmarkData)
                modelContext.insert(document)
                #if os(macOS) || os(visionOS)
                // A brand-new file opens as its own window too, same as any other
                // file — just without the sheet's forced edit mode (there's no
                // per-window way to request that through `openWindow`'s plain UUID
                // payload); it's empty either way, so hitting Edit once costs
                // nothing a fresh sheet wouldn't have.
                openWindow(id: FinScene.markdownReader, value: document.id)
                #else
                newlyCreatedDocument = document
                #endif
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    /// XCUITest can't drive the system file-open/save panels
    /// (`fileImporter`/`fileExporter`), so there's no automatable path to a real
    /// document through this view's own UI — a file written straight into the
    /// sandbox container and bookmarked directly stands in for one. Gated on the
    /// same `FIN_UI_TESTING` launch environment flag `launchFinApp()` sets, so it
    /// never runs for a real user.
    private func seedUITestFileIfNeeded() {
        guard ProcessInfo.processInfo.environment["FIN_UI_TESTING"] != nil else { return }
        // Screenshot capture runs with both flags set; its own richer fixtures
        // (ScreenshotFixtures) stand in, and this bare test file has no business
        // appearing on a product page.
        guard !ScreenshotFixtures.isEnabled else { return }
        guard !documents.contains(where: { $0.name == "ui-test-fixture.md" }) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-fixture.md")
        let fixtureText = """
        # UI Test Fixture

        Seeded once per launch under `FIN_UI_TESTING` so the Files tab has a real,
        readable document to drive without needing the system file picker.

        ## Section Two

        Enough content to exercise both the read pane and the editor.
        """
        try? fixtureText.write(to: url, atomically: true, encoding: .utf8)
        guard let bookmarkData = try? url.bookmarkData() else { return }
        modelContext.insert(MarkdownDocument(name: url.lastPathComponent, bookmarkData: bookmarkData))
    }

    private func sameFile(_ document: MarkdownDocument, as url: URL) -> Bool {
        var isStale = false
        guard let resolved = URL.fin_resolveMarkdownBookmark(document.bookmarkData, isStale: &isStale) else {
            return false
        }
        return resolved.path == url.path
    }
}

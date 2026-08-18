import SwiftUI

struct MarkdownReaderView: View {
    let document: MarkdownDocument
    var isRoot: Bool = false

    @EnvironmentObject private var sessionManager: SessionManager

    @AppStorage("themeBackgroundHex") private var backgroundHex = AppTheme.default.backgroundHex
    @AppStorage("themeForegroundHex") private var foregroundHex = AppTheme.default.foregroundHex

    @State private var rawText = ""
    @State private var content: AttributedString?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showingTheme = false
    @State private var isEditing: Bool

    init(document: MarkdownDocument, isRoot: Bool = false, startInEditMode: Bool = false) {
        self.document = document
        self.isRoot = isRoot
        _isEditing = State(initialValue: startInEditMode)
    }

    private var theme: AppTheme {
        AppTheme(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $rawText)
                    .scrollContentBackground(.hidden)
                    .background(theme.backgroundColor)
                    .foregroundStyle(theme.foregroundColor)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .padding(4)
            } else {
                ScrollView {
                    Group {
                        if let content {
                            Text(content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else if let loadError {
                            Text(loadError)
                                .foregroundStyle(.red)
                                .padding()
                        } else {
                            ProgressView()
                                .padding()
                        }
                    }
                }
            }
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .foregroundStyle(theme.foregroundColor)
        .navigationTitle(document.name)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .navigation) {
                    Button {
                        if isEditing {
                            save()
                            isEditing = false
                        }
                        UserDefaults.standard.removeObject(forKey: "lastActiveMarkdownDocumentID")
                        UserDefaults.standard.removeObject(forKey: "lastActiveMarkdownTouchedAt")
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if isEditing {
                        save()
                    }
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingTheme = true
                } label: {
                    Image(systemName: "paintpalette")
                }
            }
        }
        .sheet(isPresented: $showingTheme) {
            ThemeSettingsView()
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onDisappear {
            // Safety net for navigating away (e.g. the back button) without
            // tapping the checkmark first — don't silently lose edits.
            if isEditing {
                save()
            }
        }
        .task {
            load()
        }
    }

    private func load() {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: document.bookmarkData, bookmarkDataIsStale: &isStale) else {
            loadError = "This file's location can no longer be resolved. It may have moved."
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            loadError = "Couldn't read this file."
            return
        }
        document.lastOpenedAt = Date()
        // Only record this as the app's overall "resume to" target when there's no
        // active terminal session — otherwise a quick peek at a file from the
        // control strip's sheet (while a session is live underneath) would hijack
        // what launches next time, ahead of the session that's actually still going.
        if sessionManager.activeServerID == nil {
            UserDefaults.standard.set(document.id.uuidString, forKey: "lastActiveMarkdownDocumentID")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastActiveMarkdownTouchedAt")
        }
        rawText = text
        render(text)
    }

    private func render(_ text: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        content = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func save() {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: document.bookmarkData, bookmarkDataIsStale: &isStale) else {
            saveError = "Couldn't resolve this file's location to save."
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = rawText.data(using: .utf8) else {
            saveError = "Couldn't encode the edited text."
            return
        }
        do {
            try data.write(to: url)
            render(rawText)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

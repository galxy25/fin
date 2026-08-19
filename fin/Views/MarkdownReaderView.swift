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
    #if os(macOS)
    @FocusState private var isRenderFocused: Bool
    #endif

    init(document: MarkdownDocument, isRoot: Bool = false, startInEditMode: Bool = false) {
        self.document = document
        self.isRoot = isRoot
        _isEditing = State(initialValue: startInEditMode)
    }

    private var theme: AppTheme {
        AppTheme(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]

    private var isMarkdownFile: Bool {
        Self.markdownExtensions.contains(URL(fileURLWithPath: document.name).pathExtension.lowercased())
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
                    #if os(macOS)
                    .onKeyPress(.escape) {
                        save()
                        isEditing = false
                        return .handled
                    }
                    #endif
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
                .contentShape(Rectangle())
                // Best-effort: on macOS, .textSelection's own double-click-to-select-word
                // handling appears to claim the event ahead of SwiftUI's gesture system
                // regardless of gesture priority, so this isn't reliable there — Cmd+E
                // below is the dependable path on Mac. May still work for iOS/visionOS touch.
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        isEditing = true
                    }
                )
                #if os(macOS)
                .focusable()
                .focusEffectDisabled()
                .focused($isRenderFocused)
                .onAppear { isRenderFocused = true }
                .onKeyPress("e", phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    isEditing = true
                    return .handled
                }
                #endif
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
        guard isMarkdownFile else {
            content = AttributedString(text)
            return
        }
        // AttributedString(markdown:) discards the blank-line gaps between blocks —
        // parsing "# Title\n\nBody" as one call yields "TitleBody" with no separator
        // when Text renders it flat. Splitting on blank lines and parsing each block
        // on its own, then rejoining with an explicit paragraph break, keeps blocks
        // (headers, paragraphs, fenced code) visually distinct the way the source is.
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        var result = AttributedString()
        let blocks = text.components(separatedBy: "\n\n")
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result += AttributedString("\n\n")
            }
            result += (try? AttributedString(markdown: block, options: options)) ?? AttributedString(block)
        }
        styleBlocks(&result)
        content = result
    }

    // AttributedString(markdown:) with .full syntax only attaches semantic
    // PresentationIntent metadata for block structure (headers, code blocks,
    // block quotes) — Text doesn't turn that into visual styling on its own, so
    // headers/code blocks render as plain body text unless we apply fonts/colors
    // per run ourselves based on that metadata.
    private func styleBlocks(_ attributed: inout AttributedString) {
        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            for component in intent.components {
                switch component.kind {
                case .header(let level):
                    let font: Font = switch level {
                    case 1: .title.bold()
                    case 2: .title2.bold()
                    case 3: .title3.bold()
                    default: .headline
                    }
                    attributed[run.range].font = font
                case .codeBlock:
                    attributed[run.range].font = .system(.body, design: .monospaced)
                    attributed[run.range].backgroundColor = theme.foregroundColor.opacity(0.12)
                case .blockQuote:
                    attributed[run.range].font = (attributed[run.range].font ?? .body).italic()
                    attributed[run.range].foregroundColor = theme.foregroundColor.opacity(0.7)
                default:
                    break
                }
            }
        }
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

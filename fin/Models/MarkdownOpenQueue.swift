#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The de facto Markdown type, imported in project.yml so it resolves even on a
    /// Mac where nothing else declares it.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// Files handed to Fin by Finder (double-click with Fin as the default app, Open With,
/// drag onto the Dock icon). They arrive at the main window's `.onOpenURL`, which parks
/// them here, and whichever Fin window is on screen drains the queue
/// (`drainsMarkdownOpens()`): each file joins the Files list as a normal
/// `MarkdownDocument` and opens in the same reader window the Files tab uses.
/// (An `NSApplicationDelegate.application(_:open:)` is never called under the SwiftUI
/// lifecycle — SwiftUI routes the open to a scene itself; verified 2026-10-07.)
@MainActor
final class MarkdownOpenQueue: ObservableObject {
    static let shared = MarkdownOpenQueue()

    @Published private(set) var pending: [URL] = []

    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
    }

    /// Takes everything queued, so two windows draining at once never open a file twice.
    func take() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

extension MarkdownDocument {
    /// The Files-list entry for `url`: the existing one if this file is already listed,
    /// otherwise a new one inserted into `context`. nil if no bookmark can be made.
    @MainActor
    static func findOrInsert(for url: URL, in context: ModelContext) -> MarkdownDocument? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let existing = (try? context.fetch(FetchDescriptor<MarkdownDocument>())) ?? []
        if let match = existing.first(where: { document in
            var isStale = false
            return URL.fin_resolveMarkdownBookmark(document.bookmarkData, isStale: &isStale)?.path == url.path
        }) {
            match.lastOpenedAt = Date()
            return match
        }
        guard let bookmark = try? url.fin_markdownBookmarkData() else { return nil }
        let document = MarkdownDocument(name: url.lastPathComponent, bookmarkData: bookmark)
        context.insert(document)
        return document
    }
}

private struct MarkdownOpenDrain: ViewModifier {
    @ObservedObject private var queue = MarkdownOpenQueue.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .onAppear(perform: drain)
            .onChange(of: queue.pending) { drain() }
    }

    private func drain() {
        for url in queue.take() {
            guard let document = MarkdownDocument.findOrInsert(for: url, in: modelContext) else {
                NSLog("Fin: could not open \(url.path) — no bookmark could be made for it")
                continue
            }
            openWindow(id: FinScene.markdownReader, value: document.id)
        }
    }
}

/// Every reader window joins ONE tabbed window instead of scattering windows (Levi,
/// 2026-10-07: "by default files open as a separate tab"). AppKit's automatic tabbing
/// only applies when the user's "Prefer tabs" setting says so, and SwiftUI windows share
/// a default tabbing identifier — left alone, a file could land as a tab of the terminal
/// window. So: a reader-only identifier, plus an explicit `addTabbedWindow` onto an
/// existing reader window when one is open.
private struct MarkdownTabJoiner: NSViewRepresentable {
    static let tabbingIdentifier = "dev.levischoen.fin.markdown-reader"

    func makeNSView(context: Context) -> NSView { TabJoinView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TabJoinView: NSView {
        private var joined = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !joined else { return }
            joined = true
            window.tabbingIdentifier = MarkdownTabJoiner.tabbingIdentifier
            window.tabbingMode = .preferred
            // One turn later, so the window is on screen before it moves into another
            // window's tab group.
            DispatchQueue.main.async {
                let host = NSApp.windows.first { other in
                    other !== window && other.isVisible
                        && other.tabbingIdentifier == MarkdownTabJoiner.tabbingIdentifier
                }
                guard let host, !(host.tabbedWindows?.contains(window) ?? false) else { return }
                host.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

extension View {
    /// Opens any Finder-handed Markdown files queued in `MarkdownOpenQueue`.
    func drainsMarkdownOpens() -> some View { modifier(MarkdownOpenDrain()) }

    /// Makes this window a tab of the shared reader window.
    func joinsMarkdownReaderTabs() -> some View { background(MarkdownTabJoiner()) }
}

/// Fin ▸ "Make Fin the Default Markdown Viewer": asks Launch Services to send .md files
/// here (macOS shows its own confirmation). Finder's Get Info ▸ Open with ▸ Fin ▸
/// Change All does the same by hand.
struct MarkdownDefaultAppCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Make Fin the Default Markdown Viewer") {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .markdown) { error in
                    if let error {
                        NSLog("Fin: could not become the default Markdown viewer: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
#endif

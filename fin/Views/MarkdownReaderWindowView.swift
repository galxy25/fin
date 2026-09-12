#if os(macOS) || os(visionOS)
import SwiftUI
import SwiftData

/// A file opens as its own resizable window on macOS/visionOS instead of pushing
/// over whatever's already on screen — the same reasoning as `AgentHubWindowView`:
/// a file is worth reading next to a terminal session, an agent's settings, or
/// another file, not one-at-a-time behind a single shared view. Opened via
/// `openWindow(id: FinScene.markdownReader, value: document.id)`.
struct MarkdownReaderWindowView: View {
    /// From `WindowGroup(for: UUID.self)`'s binding — optional for the same
    /// reason `AgentHubWindowView.agentID` is: state restoration can recreate a
    /// window before the value round-trips.
    let documentID: UUID?

    @Query private var documents: [MarkdownDocument]

    private var document: MarkdownDocument? {
        guard let documentID else { return nil }
        return documents.first { $0.id == documentID }
    }

    var body: some View {
        if let document {
            NavigationStack {
                MarkdownReaderView(document: document)
            }
        } else {
            // Reachable if the file was deleted (on this or another synced
            // device) while this window was still open.
            OrphanedWindowView(
                title: "File Not Found",
                description: "This file may have been removed from Fin."
            )
        }
    }
}
#endif

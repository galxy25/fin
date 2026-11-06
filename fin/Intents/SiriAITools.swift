import AppIntents
import SwiftUI

// ── SIRI AI TOOLS (Siri AI Developer Preview, iOS / macOS / visionOS 27.3) ─────────────────────
//
// docs/XANADU.md decision 3: ships exactly like PocketDJ 1.0.4 (pocketdj
// apple/PocketDJ/Intents/SiriAITools.swift). Conforming an intent to `ToolIntent` makes it a tool
// Siri AI can call from natural language — "share this file with Fin and give me a breakdown of
// cost by quarter", "ask Fin in the deploy thread whether it's done" — no fixed phrase. Apple's
// spelling is the `@AppIntent(.tool)` macro, whose only expansion is this same conformance; it's
// written out as availability-annotated extensions because `ToolIntent` is `@available(27.3)`
// while these intents deploy back to iOS 17 / macOS 15.
//
// COMPILE GATE: `canImport(AppIntents, _version: 301.2)`. The release Xcode 27.2 SDK ships
// AppIntents 301.1.x and has no `ToolIntent`; the Xcode 27.3 beta SDK ships 301.2.x and does. The
// App Store build (Xcode 27.2) compiles none of this — Xanadu, attachments and the thread-aware
// intents still ship through App Shortcuts, Shortcuts and Spotlight — and the internal-TestFlight
// build (Xcode 27.3 beta) compiles it in. (Swift is the same version in both, so `#if compiler`
// can't tell them apart.) tvOS has no ToolIntent at all (and no intents in fin-tv).
//
// WHICH intents are tools: the four actions — Ask, Tell, Share files, Start a thread. NOT tools:
// `SearchFinIntent` (already Siri's `.system.search` schema), the open intents (navigation, not
// an action).

#if canImport(AppIntents, _version: 301.2) && !os(tvOS)

@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension AskFinIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension SendToFinIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension ShareFilesWithFinIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension StartFinThreadIntent: ToolIntent {}

/// The thread as a card when Siri shows one ("what did Fin say in the deploy
/// thread?"): title, status, the last reply.
@available(anyAppleOS 27.3, *)
extension FinThreadEntity: SnippetRepresentableEntity {
    static var snippet: some EntitySnippetContent<FinThreadEntity> {
        CardSnippet(supportedFamilies: [.standard]) { entity, _ in
            FinThreadSnippetView(entity: entity)
        }
    }
}

@available(anyAppleOS 27.3, *)
private struct FinThreadSnippetView: View {
    let entity: FinThreadEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text(entity.title).font(.headline).lineLimit(2)
            }
            Text(entity.status).font(.caption).foregroundStyle(.secondary)
            if let reply = entity.lastReply, !reply.isEmpty {
                Text(reply).font(.callout).lineLimit(6)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// True in the build that carries the Siri AI tools (diagnostics / tests read it).
let siriAIToolsCompiledIn = true

#else

let siriAIToolsCompiledIn = false

#endif

import AppIntents
import SwiftUI

/// "Search Fin for …" / "Ask Fin about …" — the one Siri entry point that hands
/// FREE TEXT to an app in a single breath. App Shortcut phrases cannot carry a
/// free-form parameter, so "Ask Fin, are the evals green?" said in one go never
/// matched "Ask Fin" and Siri fell back to "I can't search within Fin" (Levi,
/// in the car, 2026-09-12). Adopting the system in-app-search intent claims that
/// fallback: the "search" is the question, it goes to the agent like any voice
/// message, and the answer arrives as a Fin message that Announce reads aloud
/// (the system intent must open the app, so nothing is spoken inline).
@available(iOS 17.2, macOS 14.2, visionOS 1.1, *)
struct SearchFinIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Ask Fin about"
    static let description = IntentDescription(
        "Turns a search in Fin into a question for your agent and reads the answer back.",
        categoryName: "Agent"
    )
    static let searchScopes: [StringSearchScope] = [.general]
    /// The system search intent REQUIRES the app to open (the build refuses
    /// `false`). The phone comes forward to the conversation; the CarPlay screen
    /// is unaffected, and the answer still reaches the driver as a Fin message
    /// that Announce reads aloud.
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        switch FinVoiceIntentCore.prepare(message: criteria.term, container: FinSharedState.modelContainer) {
        case .failure:
            return .result()
        case .ready(let agentID, let agentName, let text):
            _ = await FinVoiceIntentCore.deliver(agentID: agentID, agentName: agentName, text: text)
            return .result()
        }
    }
}

import AppIntents
import SwiftData

/// Process-global bridge from the app's one `ModelContainer` (built in
/// `FinApp.init`) to in-app App Intents. Intents in the app target run in the
/// app's own process, so by the time the system invokes `perform()` the app has
/// launched (possibly in the background) and `FinApp.init` has already run —
/// construction there `fatalError`s rather than limping, so a nil here means
/// "invoked impossibly early", not "store is broken". Kept as a one-field enum
/// rather than exposing `FinApp` itself: the intent needs the container, not the
/// app struct's SwiftUI machinery.
enum FinSharedState {
    @MainActor static var modelContainer: ModelContainer?
}

/// "Hey Siri, message Fin" → dictated text lands in the cloud agent's inbox.
///
/// This is the voice pillar's smallest end-to-end slice: widgets can't record
/// audio and the inbox document is JSON text, so the voice layer IS Siri
/// dictation — the intent takes a plain-text parameter that Siri fills by
/// asking "What should I tell Fin?", then delivers it through the exact same
/// `CloudAgentChannel.sendMessage` path the in-app composer uses (presigned-URL
/// refresh and all). No new transport, no audio payloads.
struct SendToFinIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message to Fin"
    // NOTE: Apple rejects binaries whose App Intent metadata mentions "Siri"
    // (ITMS-90626, learned on build 42) — keep that word out of every
    // user-facing string here; code comments are fine.
    static let description = IntentDescription(
        "Sends a message to your cloud-hosted Fin agent. Trigger it by voice, the Action button, or a Home Screen shortcut — dictate or type the message and it lands in the agent's inbox.",
        categoryName: "Agent"
    )
    /// Background delivery is the whole point — a voice message shouldn't yank
    /// the user into the app. The dialog result is the feedback.
    static let openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What should I tell Fin?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to Fin")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = FinSharedState.modelContainer else {
            return .result(dialog: "Fin isn't ready yet — open the app once and try again.")
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing to send.")
        }
        guard trimmed.count <= CloudAgentChannel.maxTextLength else {
            return .result(dialog: "That message is too long to send.")
        }
        // Target resolution, deliberately dumb for v1: the user's cloud-hosted
        // agent, preferring one literally named "Fin" if several exist. A picker
        // parameter (AppEntity over agents) is the obvious v2 once more than one
        // cloud agent is a real configuration.
        let cloudRaw = AgentHostingMode.cloud.rawValue
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.hostingModeRaw == cloudRaw }
        )
        let cloudAgents = (try? container.mainContext.fetch(descriptor)) ?? []
        let target = cloudAgents.first { $0.name.caseInsensitiveCompare("Fin") == .orderedSame }
            ?? cloudAgents.first
        guard let agent = target else {
            return .result(dialog: "No cloud-hosted agent is set up. In Fin, set an agent's hosting to Cloud Harness first.")
        }
        let delivered = await CloudAgentChannel.sendMessage(
            agentID: agent.id, agentName: agent.name, text: trimmed
        )
        return .result(
            dialog: delivered
                ? IntentDialog("Sent to \(agent.name).")
                : IntentDialog("Couldn't reach \(agent.name) — check the app's cloud settings and try again.")
        )
    }
}

/// Registers the Siri phrases. `\(.applicationName)` resolves to "Fin"
/// (CFBundleDisplayName), so these read as "Message Fin" / "Tell Fin" —
/// Siri then prompts for the message text and dictation does the rest.
struct FinAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToFinIntent(),
            // "Tell X"/"Message X" collide with the built-in Messages domain —
            // Siri hunts for a CONTACT named Fin and the shortcut loses. Keep
            // them (they work when Siri disambiguates) but lead with phrasings
            // the texting domain doesn't claim.
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) agent",
                "Message \(.applicationName)",
                "Tell \(.applicationName)",
                "Send a message to \(.applicationName)",
            ],
            shortTitle: "Message Fin",
            systemImageName: "waveform.badge.mic"
        )
    }
}

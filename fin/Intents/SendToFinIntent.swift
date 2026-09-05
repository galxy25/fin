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

/// The shared spine of the voice intents. `SendToFinIntent` (fire-and-forget)
/// and `AskFinIntent` (waits and reads the reply back) resolve the SAME target
/// and push through the SAME `CloudAgentChannel.sendMessage` path the in-app
/// composer uses — the only thing that differs is whether they wait for an
/// answer. Everything reusable (validation, target resolution, error phrasings,
/// reply detection) lives here so the two intents can't drift apart, and the
/// genuinely pure bits (`preferredTargetIndex`, `newReply`, `spokenSummary`) are
/// unit-testable without a `ModelContainer` or S3.
enum FinVoiceIntentCore {
    /// The result of readying a dictated message for delivery: either a resolved
    /// target plus cleaned text, or a spoken explanation of why it can't send.
    enum Prepared {
        case ready(agentID: UUID, agentName: String, text: String)
        case failure(IntentDialog)
    }

    /// Validates the dictated text and resolves the delivery target once, for
    /// whichever intent asked. Returns plain value types (never the `@Model`
    /// itself) so a caller can hop off the main actor to poll S3 afterward.
    @MainActor
    static func prepare(message: String, container: ModelContainer?) -> Prepared {
        guard let container else {
            return .failure("Fin isn't ready yet — open the app once and try again.")
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Nothing to send.")
        }
        guard trimmed.count <= CloudAgentChannel.maxTextLength else {
            return .failure("That message is too long to send.")
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
        guard let index = preferredTargetIndex(cloudAgentNames: cloudAgents.map(\.name)) else {
            return .failure("No cloud-hosted agent is set up. In Fin, set an agent's hosting to Cloud Harness first.")
        }
        let agent = cloudAgents[index]
        return .ready(agentID: agent.id, agentName: agent.name, text: trimmed)
    }

    /// Which cloud agent wins delivery: the one literally named "Fin" if present,
    /// else the first. Pure — the SwiftData fetch that produces the names lives in
    /// `prepare`, so this rule is testable on a plain `[String]`.
    static func preferredTargetIndex(cloudAgentNames: [String]) -> Int? {
        if let exact = cloudAgentNames.firstIndex(where: {
            $0.caseInsensitiveCompare("Fin") == .orderedSame
        }) {
            return exact
        }
        return cloudAgentNames.isEmpty ? nil : 0
    }

    /// The newest assistant line in `transcript` that wasn't already present in
    /// `knownIDs` — i.e. the reply to the message we just sent, skipping any
    /// empty (tool-call-only) assistant turns. Pure so the poll loop's "did an
    /// answer arrive?" decision is testable without hitting S3. Returns nil when
    /// nothing new has landed yet.
    static func newReply(in transcript: [AgentMirrorRecord], knownIDs: Set<String>) -> String? {
        let fresh = transcript
            .filter { $0.kind == .assistantMessage && !knownIDs.contains($0.id) }
            .sorted {
                $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.sequence < $1.sequence
            }
        for record in fresh.reversed() {
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Trims a reply to something a voice assistant can speak without droning:
    /// cut at a word boundary and mark the elision. Pure and total.
    static func spokenSummary(_ text: String, limit: Int = 320) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let head = collapsed.prefix(limit)
        if let lastSpace = head.lastIndex(of: " ") {
            return head[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return head + "…"
    }
}

/// "Talk to Fin" → dictated text lands in the cloud agent's inbox.
///
/// This is the voice pillar's smallest end-to-end slice: widgets can't record
/// audio and the inbox document is JSON text, so the voice layer IS dictation —
/// the intent takes a plain-text parameter that the assistant fills by asking
/// "What should I tell Fin?", then delivers it through the exact same
/// `CloudAgentChannel.sendMessage` path the in-app composer uses (presigned-URL
/// refresh and all). No new transport, no audio payloads. Fire-and-forget: the
/// dialog result is the confirmation, and the app is never opened.
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
        switch FinVoiceIntentCore.prepare(message: message, container: FinSharedState.modelContainer) {
        case .failure(let dialog):
            return .result(dialog: dialog)
        case .ready(let agentID, let agentName, let text):
            let delivered = await CloudAgentChannel.sendMessage(
                agentID: agentID, agentName: agentName, text: text
            )
            return .result(
                dialog: delivered
                    ? IntentDialog("Sent to \(agentName).")
                    : IntentDialog("Couldn't reach \(agentName) — check the app's cloud settings and try again.")
            )
        }
    }
}

/// "Ask Fin …" → dictated question in, spoken answer out.
///
/// The send half is identical to `SendToFinIntent` (same `FinVoiceIntentCore`
/// prepare + `CloudAgentChannel`); the difference is it then WAITS briefly for a
/// reply and reads it back — the fuller "ask a question, hear the answer" voice
/// loop. Honest limit: the cloud harness is on-demand and asynchronous, so a
/// warm agent answers in a few seconds while a cold one can take minutes. We
/// poll a bounded window and, if no reply lands in time, hand off to the app
/// rather than letting the assistant session hang. `openAppWhenRun = false` for
/// the same reason as the send intent — the answer is spoken, not opened.
struct AskFinIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Fin"
    static let description = IntentDescription(
        "Asks your cloud-hosted Fin agent a question by voice and reads the answer back. If Fin is still starting up, the question is queued and its reply shows in the app.",
        categoryName: "Agent"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Fin?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Fin \(\.$message)")
    }

    /// ~8s total (4 × 2s). Long enough that a warm agent's reply is spoken back;
    /// short enough that the assistant session never appears to stall.
    private static let replyPollCount = 4
    private static let replyPollInterval: UInt64 = 2_000_000_000

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch FinVoiceIntentCore.prepare(message: message, container: FinSharedState.modelContainer) {
        case .failure(let dialog):
            return .result(dialog: dialog)
        case .ready(let agentID, let agentName, let text):
            // Snapshot the assistant lines already in the transcript so the poll
            // below only reads back a GENUINELY new reply, not whatever Fin last
            // said before this question.
            let knownIDs = Set(
                (await CloudAgentChannel.fetchTranscript(agentID: agentID, agentName: agentName))
                    .filter { $0.kind == .assistantMessage }
                    .map(\.id)
            )
            let delivered = await CloudAgentChannel.sendMessage(
                agentID: agentID, agentName: agentName, text: text
            )
            guard delivered else {
                return .result(dialog: IntentDialog(
                    "Couldn't reach \(agentName) — check the app's cloud settings and try again."
                ))
            }
            for _ in 0..<Self.replyPollCount {
                try? await Task.sleep(nanoseconds: Self.replyPollInterval)
                let transcript = await CloudAgentChannel.fetchTranscript(
                    agentID: agentID, agentName: agentName
                )
                if let reply = FinVoiceIntentCore.newReply(in: transcript, knownIDs: knownIDs) {
                    // Interpolate (not `IntentDialog(_:)`) — IntentDialog builds from
                    // a runtime String only via string interpolation, not a plain init.
                    return .result(dialog: IntentDialog("\(FinVoiceIntentCore.spokenSummary(reply))"))
                }
            }
            return .result(dialog: IntentDialog("Sent to \(agentName). It'll reply in the app."))
        }
    }
}

// NOTE — assistant-schema / `.search` App Intent domains are deliberately NOT
// adopted here: the `@AssistantIntent(schema:)` surface (and the "type to Siri"
// free-form entry point) is iOS 18.2+, and this app's floor is iOS 17.0 (see
// project.yml). At the floor, the supported way to get free-form voice into an
// intent is exactly what's above — a required `String` parameter the assistant
// fills by dictation via `requestValueDialog`. Revisit if the iOS floor rises.

/// Registers the voice phrases. `\(.applicationName)` resolves to "Fin"
/// (CFBundleDisplayName), so these read as "Talk to Fin" / "Ask Fin" — the
/// system then prompts for the message text and dictation does the rest.
struct FinAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // "Ask" implies the user wants an answer, so it maps to the reply-reading
        // intent; "Talk to"/"Tell … to" imply an instruction, so they map to the
        // fire-and-forget send. A phrase can't capture the message inline (App
        // Intents only inlines AppEnum/AppEntity parameters, never free-form
        // String), so every phrase below just triggers the intent and the message
        // arrives as the dictated follow-up.
        AppShortcut(
            intent: AskFinIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Fin",
            systemImageName: "waveform.badge.mic"
        )
        AppShortcut(
            intent: SendToFinIntent(),
            // Message-domain phrasings ("Message Fin", "Send a message to Fin",
            // bare "Tell Fin") lose to the built-in Messages domain — Siri hunts
            // for a CONTACT named Fin and the shortcut loses — so they're dropped.
            // "Tell Fin to" survives because the trailing "to" reads as an
            // instruction to the app, not "text my contact Fin"; the rest are
            // phrasings the texting domain never claims.
            phrases: [
                "Talk to \(.applicationName)",
                "Tell \(.applicationName) to",
                "Hey \(.applicationName)",
                "\(.applicationName) agent",
                "\(.applicationName)",
            ],
            shortTitle: "Talk to Fin",
            systemImageName: "waveform.badge.mic"
        )
    }
}

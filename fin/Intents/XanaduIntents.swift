import AppIntents
import Foundation
import UniformTypeIdentifiers

// docs/XANADU.md "Siri": the intents that make Siri a participant in the
// current thread. Every one of them follows the current-thread rule
// (`XanaduCurrentThread`), and every one that opens the app lands in Xanadu on
// the thread it touched (`XanaduNavigator`).
//
// NOTE: never put the word "Siri" in a user-facing string here — Apple rejects
// binaries whose App Intent metadata mentions it (ITMS-90626, build 42).

/// "Give Fin a file" / Siri AI: "share this file with Fin and give me a
/// breakdown of cost by quarter". Uploads every file, sends them with the
/// request into the current thread, opens Xanadu on it.
struct ShareFilesWithFinIntent: AppIntent {
    static let title: LocalizedStringResource = "Share Files with Fin"
    static let description = IntentDescription(
        "Hands files to Fin with an optional request — Fin saves them on its computer and works on them in your current conversation.",
        categoryName: "Agent"
    )
    /// The reply arrives in the conversation, so that is where this lands.
    static let openAppWhenRun = true

    // Any file type (no `supportedContentTypes`: that initializer is iOS 18+).
    @Parameter(title: "Files", requestValueDialog: "Which files should Fin get?")
    var files: [IntentFile]

    @Parameter(title: "Request", requestValueDialog: "What should Fin do with them?")
    var request: String?

    @Parameter(title: "Thread", description: "The conversation to share into. Leave empty for the current one.")
    var thread: FinThreadEntity?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Share \(\.$files) with Fin") {
            \.$request
            \.$thread
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard CloudControlPlaneConfig.isConfigured else {
            return .result(dialog: "Sharing files with Fin needs Fin's cloud — sign in to Fin in the app first.")
        }
        guard !files.isEmpty else { return .result(dialog: "There were no files to share.") }
        guard files.count <= MessageAttachment.maxPerMessage else {
            return .result(dialog: "Fin takes up to \(MessageAttachment.maxPerMessage) files at a time.")
        }
        guard let agent = FinVoiceIntentCore.resolveAgent(
            container: FinSharedState.modelContainer, preferringAgent: thread?.agentName
        ) else {
            return .result(dialog: "No agent is set up yet. Open Fin and add one first.")
        }
        var drafts: [AttachmentDraft] = []
        for file in files {
            let name = file.filename.isEmpty ? "file" : file.filename
            let mime = file.type?.preferredMIMEType ?? AttachmentDraft.mime(forFileName: name)
            do {
                drafts.append(try AttachmentDraft.stage(data: file.data, name: name, mime: mime))
            } catch {
                return .result(dialog: "Couldn't read \(name).")
            }
        }
        let text = (request ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = XanaduCurrentThread.target(explicit: thread?.id, startNewThread: false, agent: agent.name)
        let messageID = ControlPlaneClient.newMessageID()
        var context = ControlPlaneClient.MessageContext(source: "voice")
        context.threadID = target
        let result = await XanaduSend.send(
            text: text, drafts: drafts, agent: agent.name, messageID: messageID, context: context
        )
        switch result {
        case .success(let row):
            let landed = XanaduCurrentThread.adoptSend(messageID: messageID, sentThreadID: target, row: row, agent: agent.name)
            XanaduNavigator.shared.open(agentName: agent.name, threadID: landed)
            let count = drafts.count
            return .result(dialog: count == 1 ? "Sent the file to \(agent.name)." : "Sent \(count) files to \(agent.name).")
        case .failure(let problem):
            XanaduNavigator.shared.open(agentName: agent.name, threadID: target)
            return .result(dialog: "\(problem.message)")
        }
    }
}

/// "Start a new Fin thread": the one way to ask for a fresh conversation by
/// voice — everything else follows up in the current one. The new thread
/// becomes current, so the next "Tell Fin…" continues it.
struct StartFinThreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a New Fin Thread"
    static let description = IntentDescription(
        "Starts a new conversation with Fin. Follow-ups by voice go into it until you open another.",
        categoryName: "Agent"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What's the new thread about?")
    var message: String

    init() {}

    init(message: String) { self.message = message }

    static var parameterSummary: some ParameterSummary {
        Summary("Start a new Fin thread: \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch FinVoiceIntentCore.prepare(message: message, container: FinSharedState.modelContainer) {
        case .failure(let dialog):
            return .result(dialog: dialog)
        case .ready(let agentID, let agentName, let text):
            guard CloudControlPlaneConfig.isConfigured else {
                // No control plane, no threads: it is still a message.
                let delivered = await FinVoiceIntentCore.deliver(agentID: agentID, agentName: agentName, text: text).delivered
                return .result(dialog: delivered ? "Sent to \(agentName)." : "Couldn't reach \(agentName).")
            }
            let sent = await FinVoiceIntentCore.deliver(
                agentID: agentID, agentName: agentName, text: text, startNewThread: true
            )
            return .result(dialog: sent.delivered
                ? "Started a new thread with \(agentName)."
                : "Couldn't reach \(agentName) — check the app's cloud settings and try again.")
        }
    }
}

/// "Show my Fin conversation": the app, on Xanadu, on the current thread (or
/// the one named).
struct OpenXanaduIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Fin Conversation"
    static let description = IntentDescription(
        "Opens Fin on the current conversation, or on the thread you name.",
        categoryName: "Agent"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Thread")
    var thread: FinThreadEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        XanaduNavigator.shared.open(agentName: thread?.agentName, threadID: thread?.id)
        return .result()
    }
}

/// Opening a `FinThreadEntity` from Shortcuts / Spotlight / Siri.
struct OpenFinThreadIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Fin Thread"

    @Parameter(title: "Thread")
    var target: FinThreadEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        XanaduNavigator.shared.open(agentName: target.agentName, threadID: target.id)
        return .result()
    }
}

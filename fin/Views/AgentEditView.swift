import SwiftUI
import SwiftData

struct AgentEditView: View {
    @Bindable var agent: Agent

    @State private var apiKey: String = ""
    @State private var didLoadAPIKey = false
    @State private var probeState: ProbeState = .idle
    @State private var discoveredModels: [String] = []
    @State private var remoteEnabled = RemoteSupervisionConfig.isEnabled
    @State private var directiveURLDraft = ""
    @State private var statusURLDraft = ""
    @State private var shareRatings = FeedbackSettings.shareRatings()
    @State private var shareActivity = FeedbackSettings.shareActivity()
    @State private var showsFeedbackComposer = false

    private enum ProbeState: Equatable {
        case idle
        case probing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $agent.name)
            }
            providerSection
            if agent.provider == .openAICompatible {
                endpointSection
                modelSection
            }
            hostingSection
            modeSection
            limitsSection
            remoteSupervisionSection
            helpImproveSection
            promptSection
        }
        .navigationTitle(agent.name.isEmpty ? "Agent" : agent.name)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            apiKey = KeychainStore.loadAgentAPIKey(for: agent.id) ?? ""
            didLoadAPIKey = true
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            Picker("Runs on", selection: providerBinding) {
                ForEach(AgentProvider.allCases) { provider in
                    Label(provider.label, systemImage: provider.systemImage).tag(provider)
                }
            }
            if agent.provider == .appleOnDevice,
               let unavailable = AppleOnDeviceBackend.availability.message {
                Label(unavailable, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text(agent.provider.explanation)
        }
    }

    private var providerBinding: Binding<AgentProvider> {
        Binding(get: { agent.provider }, set: { agent.provider = $0 })
    }

    // MARK: - Hosting

    /// Where the RUNTIME lives (the provider above is where the MODEL lives).
    /// Cloud shows the two per-device capability URLs the remote experience
    /// rides on; both are presigned S3 URLs, so like the supervision URLs they
    /// render redacted and are replaced by pasting, never edited.
    private var hostingSection: some View {
        Section {
            Picker("Hosted by", selection: hostingBinding) {
                ForEach(AgentHostingMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            if agent.hostingMode == .cloud {
                cloudURLField(
                    label: "Transcript URL (GET)",
                    get: { CloudAgentConfig.transcriptURL(agentID: agent.id) },
                    set: { CloudAgentConfig.setTranscriptURL($0, agentID: agent.id) }
                )
                cloudURLField(
                    label: "Inbox URL (GET)",
                    get: { CloudAgentConfig.inboxGetURL(agentID: agent.id) },
                    set: { CloudAgentConfig.setInboxGetURL($0, agentID: agent.id) }
                )
                cloudURLField(
                    label: "Inbox URL (PUT)",
                    get: { CloudAgentConfig.inboxPutURL(agentID: agent.id) },
                    set: { CloudAgentConfig.setInboxPutURL($0, agentID: agent.id) }
                )
                cloudURLField(
                    label: "Control Plane URL",
                    get: { CloudControlPlaneConfig.endpointURL },
                    set: { CloudControlPlaneConfig.setEndpointURL($0) }
                )
                cloudURLField(
                    label: "Control Plane Token",
                    get: { CloudControlPlaneConfig.token },
                    set: { CloudControlPlaneConfig.setToken($0) },
                    redact: CloudControlPlaneConfig.redactedToken
                )
            }
        } header: {
            Text("Hosting")
        } footer: {
            Text(agent.hostingMode == .cloud
                ? "An isolated fin-agentd harness owns this agent's conversation. "
                    + "This device only views its transcript and sends it messages — "
                    + "no local runtime, heartbeat, or watchdog runs anywhere. "
                    + "Switch back to This Device at any time to restore local hosting. "
                    + "The two control plane fields are device-wide — one control "
                    + "plane launches workers for every cloud agent on this device — "
                    + "and let the console start a harness on demand."
                : "This device (or whichever device arms monitoring) runs the "
                    + "conversation loop — the standard path.")
        }
    }

    private var hostingBinding: Binding<AgentHostingMode> {
        // Routed through the mutator: moving to cloud must disarm any persisted
        // local monitor (same contract as mode edits).
        Binding(get: { agent.hostingMode }, set: { agent.updateHostingMode($0) })
    }

    @State private var cloudURLDrafts: [String: String] = [:]

    /// Paste-to-replace field for one cloud capability secret, in the supervision
    /// URLs' style: shows a redacted display of what's stored, saves on commit.
    /// `redact` is overridable because not every secret here is URL-shaped — a
    /// bearer token has no host to show.
    private func cloudURLField(
        label: String,
        get: @escaping () -> String,
        set: @escaping (String) -> Void,
        redact: @escaping (String) -> String = RemoteSupervisionConfig.redactedDisplay
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: Binding(
                get: { cloudURLDrafts[label] ?? "" },
                set: { cloudURLDrafts[label] = $0 }
            ))
            .autocapitalizationNeverIfAvailable()
            .disableAutocorrection(true)
            .onSubmit {
                let draft = (cloudURLDrafts[label] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !draft.isEmpty else { return }
                set(draft)
                cloudURLDrafts[label] = ""
            }
            Text("\(label): \(redact(get()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section {
            TextField("http://100.64.0.1:1234/v1", text: $agent.endpointURL)
                .autocapitalizationNeverIfAvailable()
                .disableAutocorrection(true)
            SecureField("API key (optional)", text: $apiKey)
                .onChange(of: apiKey) { _, newValue in
                    // Skipped until the initial load finishes, so an empty field on first
                    // render never overwrites a stored key with "".
                    guard didLoadAPIKey else { return }
                    try? KeychainStore.saveAgentAPIKey(newValue, for: agent.id)
                }
            testConnectionButton
            probeResult
        } header: {
            Text("Endpoint")
        } footer: {
            Text("Any OpenAI-compatible chat endpoint. For LM Studio, turn on "
                + "\"Serve on Local Network\" and use your Tailscale address with port 1234.")
        }
    }

    private var testConnectionButton: some View {
        Button {
            probeEndpoint()
        } label: {
            HStack {
                Text("Test Connection")
                if probeState == .probing {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(agent.endpointURL.trimmingCharacters(in: .whitespaces).isEmpty
            || probeState == .probing)
    }

    @ViewBuilder
    private var probeResult: some View {
        switch probeState {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle, .probing:
            EmptyView()
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            TextField("Model identifier", text: $agent.modelIdentifier)
                .autocapitalizationNeverIfAvailable()
                .disableAutocorrection(true)
            ForEach(discoveredModels, id: \.self) { model in
                Button {
                    agent.modelIdentifier = model
                } label: {
                    HStack {
                        Text(model)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if agent.modelIdentifier == model {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if discoveredModels.isEmpty {
                Text("Test the connection to list the models this endpoint has loaded.")
            }
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        Section {
            Picker("Default mode", selection: modeBinding) {
                ForEach(AgentMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            Toggle("Notify on Response", isOn: notifyBinding)
            Toggle("Mirror Logs to iCloud", isOn: mirrorBinding)
        } header: {
            Text("Mode")
        } footer: {
            Text("Auto lets the agent run its own commands. Manual asks you to approve "
                + "each one. Commands that look destructive always ask, in either mode. "
                + "Notify on Response posts a notification when this agent finishes a "
                + "turn while your screen is locked or the app is in the background. "
                + "Mirror Logs to iCloud copies this agent's activity log, with secrets "
                + "redacted, into iCloud Drive → Fin → AgentLogs so your other devices "
                + "can read it.")
        }
    }

    private var notifyBinding: Binding<Bool> {
        Binding(get: { agent.notifyOnResponse }, set: { agent.notifyOnResponse = $0 })
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(get: { agent.mirrorLogsToICloud }, set: { agent.mirrorLogsToICloud = $0 })
    }

    private var modeBinding: Binding<AgentMode> {
        Binding(get: { agent.defaultMode }, set: { agent.updateDefaultMode($0) })
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section {
            LabeledStepper(
                title: "Context window",
                value: $agent.contextWindowTokens,
                range: 2048...200_000,
                step: 2048
            ) { "\($0) tokens" }
            LabeledStepper(
                title: "Max reply",
                value: $agent.maxOutputTokens,
                range: 128...8192,
                step: 128
            ) { "\($0) tokens" }
            LabeledStepper(
                title: "Terminal context",
                value: $agent.terminalContextLines,
                range: 20...400,
                step: 20
            ) { "\($0) lines" }
            LabeledStepper(
                title: "Heartbeat",
                value: $agent.heartbeatSeconds,
                range: 0...600,
                step: 30
            ) { $0 == 0 ? "Off" : "every \($0)s" }
            LabeledStepper(
                title: "Memory lookback",
                value: $agent.memoryViewDays,
                range: 7...365,
                step: 7
            ) { "\($0) days" }
            temperatureRow
        } header: {
            Text("Limits")
        } footer: {
            Text("Older turns are trimmed automatically as the conversation approaches "
                + "the context window. Heartbeat lets an auto-mode agent check a "
                + "long-running task on its own: while monitoring is armed in the "
                + "console, it reads the terminal at this interval, sends input if the "
                + "task is waiting, and stops when the task is complete. This interval "
                + "is the agent's monitoring cadence (default 60s) unless the model "
                + "picks its own; Off disables the heartbeat and stays off.")
        }
    }

    private var temperatureRow: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", agent.temperature))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $agent.temperature, in: 0...1, step: 0.05)
        }
    }

    // MARK: - Remote Supervision

    private var remoteSupervisionSection: some View {
        Section {
            Toggle("Enabled", isOn: $remoteEnabled)
                .onChange(of: remoteEnabled) { _, newValue in
                    RemoteSupervisionConfig.setEnabled(newValue)
                }
            remoteURLField(
                title: "Directive URL",
                current: RemoteSupervisionConfig.directiveURL,
                draft: $directiveURLDraft,
                save: RemoteSupervisionConfig.setDirectiveURL
            )
            remoteURLField(
                title: "Status URL",
                current: RemoteSupervisionConfig.statusURL,
                draft: $statusURLDraft,
                save: RemoteSupervisionConfig.setStatusURL
            )
            LabeledContent("Last poll", value: lastPollDescription)
        } header: {
            Text("Remote Supervision")
        } footer: {
            Text("Device-wide — these settings apply to every agent on this device "
                + "and never sync. A supervisor process leaves directives at, and "
                + "reads status from, presigned S3 URLs. URLs are shown truncated "
                + "because the link itself is the credential; paste a new one to "
                + "replace it.")
        }
    }

    /// The stored URL is never rendered in full — its query string is a bearer
    /// credential — so the row shows host + truncated path and takes replacements
    /// by paste-and-return only.
    private func remoteURLField(
        title: String,
        current: String,
        draft: Binding<String>,
        save: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title): \(RemoteSupervisionConfig.redactedDisplay(current))")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Paste new \(title.lowercased())", text: draft)
                .autocapitalizationNeverIfAvailable()
                .disableAutocorrection(true)
                .onSubmit {
                    let value = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    save(value)
                    draft.wrappedValue = ""
                }
        }
    }

    private var lastPollDescription: String {
        guard let at = UserDefaults.standard
            .object(forKey: RemoteSupervisionConfig.lastPollAtKey) as? Date else {
            return "never"
        }
        let status = UserDefaults.standard
            .string(forKey: RemoteSupervisionConfig.lastPollStatusKey) ?? ""
        let time = at.formatted(date: .omitted, time: .standard)
        return status.isEmpty ? time : "\(time) — \(status)"
    }

    // MARK: - Help Improve Fin

    /// Device-wide like Remote Supervision above it (one opt-in covers every agent
    /// on this device, and it never syncs). Two independent consents, both default
    /// OFF — the footer says exactly what each one sends, because the toggles ARE
    /// the privacy policy here.
    private var helpImproveSection: some View {
        Section {
            Toggle("Share Ratings & Comments", isOn: $shareRatings)
                .onChange(of: shareRatings) { _, newValue in
                    FeedbackSettings.setShareRatings(newValue)
                }
            Toggle("Share Redacted Activity Summaries", isOn: $shareActivity)
                .onChange(of: shareActivity) { _, newValue in
                    FeedbackSettings.setShareActivity(newValue)
                }
            Button("Send Feedback…") {
                showsFeedbackComposer = true
            }
        } header: {
            Text("Help Improve Fin")
        } footer: {
            Text("Both are off by default — nothing leaves this device until you turn "
                + "one on, and these settings apply device-wide and never sync. "
                + "Share Ratings & Comments sends only what you write in a feedback "
                + "card: thumbs up or down, your comment, the app version, and the "
                + "platform. Comments are scrubbed of secret-shaped text before "
                + "they're stored. Share Redacted Activity Summaries sends counts "
                + "about finished agent conversations — turns, tool calls per tool, "
                + "duration, outcome, transcript length, model, and hosting mode — "
                + "plus a random conversation ID, the app version, the platform, "
                + "and a timestamp. "
                + "Your messages and terminal output never leave the device: terminal "
                + "content is redacted before anything is stored, and summaries are "
                + "built from counts alone, quoting none of it.")
        }
        .sheet(isPresented: $showsFeedbackComposer) {
            FeedbackComposerView()
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        Section("System prompt") {
            TextEditor(text: $agent.systemPrompt)
                .frame(minHeight: 160)
                .font(.system(.caption, design: .monospaced))
            Button("Reset to default") {
                agent.systemPrompt = Agent.defaultSystemPrompt
            }
        }
    }

    // MARK: - Probe

    private func probeEndpoint() {
        probeState = .probing
        let url = agent.endpointURL
        let key = apiKey.isEmpty ? nil : apiKey
        Task {
            do {
                let models = try await AgentEndpointClient.listModels(baseURL: url, apiKey: key)
                discoveredModels = models
                probeState = .success(
                    models.isEmpty
                        ? "Connected, but no models are loaded."
                        : "Connected — \(models.count) model(s) available."
                )
            } catch {
                discoveredModels = []
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                probeState = .failure(message)
            }
        }
    }
}

/// Stepper with the value rendered as text, since a bare `Stepper` shows no number.
///
/// Two macOS-specific hazards are handled here, both of which crashed the editor outright:
///
/// 1. A `Spacer()` inside a `Stepper`'s *label*, inside a `Form`, makes AppKit's
///    Update-Constraints pass diverge — the window grows without bound (observed at
///    ~32,000pt) until AppKit raises `NSGenericException` and the process dies. So on Mac
///    the value and the stepper are siblings in a `LabeledContent` rather than the label
///    being an `HStack` that wants infinite width.
/// 2. `Stepper(value:in:)` traps if the bound value starts outside `range`, so it is
///    clamped on the way in and out.
private struct LabeledStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: (Int) -> String

    var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Stepper("", value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        }
        #else
        Stepper(value: clamped, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        #endif
    }

    private var clamped: Binding<Int> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

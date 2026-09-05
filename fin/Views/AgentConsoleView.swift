import SwiftUI
import SwiftData

/// The agent conversation. Presented as a sheet where width is scarce and as an inline
/// side panel where it isn't, so on a Mac or iPad the transcript can sit beside the
/// terminal it's talking about rather than covering it.
struct AgentConsoleView: View {
    @ObservedObject var runtime: AgentRuntime
    /// Set when hosted inline; the sheet presentation supplies its own dismiss instead.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var draft = ""
    @State private var exportURL: URL?
    @State private var showsFeedbackCard = false

    private var isInline: Bool { onClose != nil }

    private func exportTranscript() {
        let markdown = runtime.transcript.markdownExport(
            agent: runtime.agent,
            serverName: runtime.serverName
        )
        let safeName = runtime.agent.name.isEmpty
            ? "agent"
            : runtime.agent.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-transcript.md")
        guard (try? markdown.write(to: url, atomically: true, encoding: String.Encoding.utf8)) != nil else { return }
        exportURL = url
    }

    private var exportButton: some View {
        Button {
            exportTranscript()
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(runtime.transcript.messages.allSatisfy { $0.role == .system })
    }

    var body: some View {
        if isInline {
            panel
        } else {
            NavigationStack { panel }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if isInline { inlineHeader }
            modeBar
            Divider()
            transcriptList
            if let pending = runtime.pendingApproval {
                approvalBar(call: pending.call, reason: pending.reason)
            }
            if !runtime.queuedPrompts.isEmpty {
                queuedPromptsBar
            }
            if showsFeedbackCard {
                FeedbackCardView(onDone: { showsFeedbackCard = false })
            }
            Divider()
            composer
        }
        .navigationTitle(runtime.agent.name.isEmpty ? "Agent" : runtime.agent.name)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { if !isInline { sheetToolbar } }
        .sheet(item: $exportURL) { url in
            TranscriptExportSheet(url: url)
        }
        // A turn just finished on screen — the one moment the user is provably
        // present AND has something fresh to rate. The gate keeps it rare (3+
        // finished conversations, once per 7 days, never after "Don't Ask Again");
        // the sweep piggybacks here because a completed turn is also when an older
        // conversation may have crossed the quiet gap into "finished".
        .onChange(of: runtime.state) { oldState, newState in
            guard oldState == .thinking, newState == .idle else { return }
            FeedbackService.shared.sweepTrajectories(context: modelContext)
            if !showsFeedbackCard, FeedbackService.shared.gate.shouldPrompt() {
                // Appearing is what spends the 7-day budget — ignoring the card
                // costs the same quiet week answering it does.
                FeedbackService.shared.gate.notePrompted()
                showsFeedbackCard = true
            }
        }
    }

    /// Clearing is the explicit end of a conversation: sweep with the agent marked
    /// ended so its trajectory digest doesn't wait out the quiet-gap heuristic.
    private func clearConversation() {
        runtime.clearConversation()
        FeedbackService.shared.sweepTrajectories(
            context: modelContext, endingAgentID: runtime.agent.id
        )
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            exportButton
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                clearConversation()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(runtime.isBusy)
        }
    }

    private var inlineHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(runtime.agent.name.isEmpty ? "Agent" : runtime.agent.name)
                .font(.headline)
            Spacer()
            exportButton
                .buttonStyle(.plain)
            Button {
                clearConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(runtime.isBusy)
            Button {
                onClose?()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Mode

    private var modeBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $runtime.mode) {
                ForEach(AgentMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            monitorToggle
            if runtime.isAutoResumePending {
                // An armed monitor waiting for the session to connect: without this,
                // the toggle reads off and then silently flips itself on.
                Text("resuming monitor…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Lives in the mode bar so both presentations (sheet and inline panel)
            // get it without duplicating toolbar/header plumbing.
            RemoteSupervisionBadge()

            Text(contextSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var monitorToggle: some View {
        Button {
            // Through the runtime's mediator, not a bare toggle, so the audit trail
            // records the console (vs the monitor tool) as who armed it.
            runtime.toggleMonitoringFromConsole()
        } label: {
            Image(systemName: runtime.isMonitoring ? "binoculars.fill" : "binoculars")
        }
        .buttonStyle(.plain)
        .disabled(runtime.mode != .auto || runtime.agent.heartbeatSeconds <= 0)
        .help("Monitor the running task: check it every \(runtime.agent.heartbeatSeconds)s until it reports TASK COMPLETE")
        .accessibilityLabel(runtime.isMonitoring ? "Stop monitoring" : "Start monitoring")
    }

    private var contextSummary: String {
        let used = runtime.transcript.estimatedTokenCount
        let total = max(runtime.agent.contextWindowTokens, 1)
        return "~\(used)/\(total)"
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if runtime.transcript.messages.allSatisfy({ $0.role == .system }) {
                        emptyState
                    }
                    ForEach(visibleMessages) { message in
                        messageRow(message)
                            .id(message.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    copyToPasteboard(copyText(for: message))
                                } label: {
                                    Label("Copy Turn", systemImage: "doc.on.doc")
                                }
                                Button {
                                    copyToPasteboard(
                                        runtime.transcript.markdownExport(
                                            agent: runtime.agent,
                                            serverName: runtime.serverName
                                        )
                                    )
                                } label: {
                                    Label("Copy Whole Transcript", systemImage: "doc.on.clipboard")
                                }
                            }
                    }
                    if case .thinking = runtime.state {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding()
            }
            .onChange(of: runtime.transcript.messages.count) { _, _ in
                if let last = visibleMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// The system prompt is configuration, not conversation — it stays out of the log.
    private var visibleMessages: [AgentMessage] {
        runtime.transcript.messages.filter { $0.role != .system || $0.isLocalOnly }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about this session")
                .font(.headline)
            Text("The agent can read the terminal and, with your approval, type into it. "
                + "It can't see anything you haven't connected it to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func messageRow(_ message: AgentMessage) -> some View {
        switch message.role {
        case .user where message.isHeartbeat:
            Label("heartbeat check", systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .user:
            VStack(alignment: .leading, spacing: 2) {
                Text("You").font(.caption2).foregroundStyle(.secondary)
                Text(message.text)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                }
                ForEach(message.toolCalls) { call in
                    toolCallRow(call)
                }
                if let turnMS = message.turnDurationMS {
                    Text(Self.durationLabel(turnMS))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        case .tool:
            DisclosureGroup {
                Text(message.text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Result", systemImage: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .system where message.text.hasPrefix(Self.thoughtPrefix):
            DisclosureGroup {
                Text(String(message.text.dropFirst(Self.thoughtPrefix.count)))
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Trace", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .system:
            // Only local notices reach here — see `visibleMessages`.
            Text(message.text)
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    /// Matches the runtime's reasoning notices (`appendLocalNotice("Thought: …")`).
    private static let thoughtPrefix = "Thought: "

    private func toolCallRow(_ call: AgentToolCall) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: call.name == AgentToolSpec.sendInput.name
                ? "arrow.right.square"
                : "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(call.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let durationMS = call.durationMS {
                        Text(Self.durationLabel(durationMS))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let input = call.argument("input") {
                    Text(input.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// "480ms", "2.4s", "1m 12s" — the shortest form that stays honest at each scale.
    static func durationLabel(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return "\(minutes)m \(Int(seconds) % 60)s"
    }

    // MARK: - Approval

    private func approvalBar(call: AgentToolCall, reason: AgentRuntime.ApprovalReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reason.explanation, systemImage: reason == .destructiveCommand
                ? "exclamationmark.triangle.fill"
                : "hand.raised.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(reason == .destructiveCommand ? .red : .primary)

            if let input = call.argument("input") {
                Text(input.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Don't Send") { runtime.rejectPendingCall() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Send") { runtime.approvePendingCall() }
                    .buttonStyle(.borderedProminent)
                    .tint(reason == .destructiveCommand ? .red : .accentColor)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Queued prompts

    /// Prompts submitted while a turn was in flight, waiting their turn — rendered
    /// as secondary-styled pending rows above the input, in run order. Each
    /// converts into a normal user message when the runtime dequeues it; Stop
    /// discards them all (visibly — the rows disappear with the queue).
    private var queuedPromptsBar: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(runtime.queuedPrompts.enumerated()), id: \.offset) { _, prompt in
                VStack(alignment: .leading, spacing: 2) {
                    Label("queued", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(prompt)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Composer

    /// The input stays live while the agent is busy: sending then ENQUEUES the
    /// prompt (the runtime runs it, in order, when the current turn finishes)
    /// instead of silently dropping it — the field-observed failure mode when
    /// back-to-back heartbeat turns never left an idle gap to type into.
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .onSubmit(submit)

            if runtime.isBusy {
                Button {
                    runtime.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
            }
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func submit() {
        let text = draft
        draft = ""
        runtime.submit(text)
    }

    // MARK: - Copying

    /// A turn copied on its own carries its tool calls with it — the command an agent ran
    /// is usually the part worth pasting somewhere else.
    private func copyText(for message: AgentMessage) -> String {
        var parts: [String] = []
        if !message.text.isEmpty { parts.append(message.text) }
        for call in message.toolCalls {
            let argument = call.argument("input") ?? call.arguments
            parts.append("\(call.name): \(argument.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parts.joined(separator: "\n")
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private struct TranscriptExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "doc.text")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                Text("Markdown transcript of this conversation, including tool calls and results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Share Transcript", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.top, 40)
            .padding()
            .navigationTitle("Export")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

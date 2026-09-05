import SwiftUI
import SwiftData

/// Read-only window onto a conversation whose runtime lives on another device,
/// rebuilt from the iCloud log mirror (`AgentMirrorReader` merges the recent day
/// files across every device), with a compose bar that relays a message to the
/// hosting device through a synced `AgentRelayMessage`.
///
/// Deliberately simpler than `AgentConsoleView`: no mode bar, no approval bar, no
/// export — those belong to the device that owns the runtime. Rows reuse the
/// console's visual vocabulary (user/assistant/tool) in reduced form; lifecycle
/// notices are filtered out entirely (see `refresh`).
struct AgentRemoteConsoleView: View {
    private let agentID: UUID
    private let agentName: String
    private let reader: AgentMirrorReader
    /// Cloud-hosted agents read their transcript from the harness's S3 object
    /// (`CloudAgentChannel`) instead of the iCloud mirror, and compose into the
    /// harness's inbox instead of a synced relay — no device hosts them, so
    /// there is no relay claimant and no mirror writer.
    private let isCloudHosted: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var relayMessages: [AgentRelayMessage]

    @State private var records: [AgentMirrorRecord] = []
    @State private var hasLoaded = false
    @State private var isRefreshing = false
    @State private var draft = ""

    /// This device's in-flight inbox messages (cloud agents only): state lives in
    /// the view because inbox sends are plain S3 PUTs with no synced record — the
    /// transcript itself is the durable confirmation, exactly like the relay
    /// rows' mirror handoff.
    @State private var cloudPending: [CloudPendingMessage] = []

    /// Last on-demand worker launch (cloud agents only). View state, like the
    /// pending rows: the request leaves no durable record, and the transcript
    /// arriving is what actually confirms the worker booted.
    @State private var isStartingWorker = false
    @State private var workerOutcome: CloudWorkerClient.Outcome?

    struct CloudPendingMessage: Identifiable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date
        var state: State

        enum State { case sending, sent, failed }
    }

    init(agent: Agent, reader: AgentMirrorReader = AgentMirrorReader()) {
        self.agentID = agent.id
        self.agentName = agent.name
        self.reader = reader
        self.isCloudHosted = !agent.hostsLocally
        let id = agent.id
        _relayMessages = Query(
            filter: #Predicate<AgentRelayMessage> { $0.agentID == id },
            sort: \AgentRelayMessage.createdAt
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                composer
            }
            .navigationTitle(agentName.isEmpty ? "Agent" : agentName)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            // Cross-device banners are the whole point of this screen, so this is
            // the in-context moment to ask for notification permission on a device
            // that has never submitted a local prompt.
            AgentNotificationService.shared.requestAuthorizationIfNeeded()
            await refresh()
            // Auto-refresh while visible; cancelled with the view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isCloudHosted ? "cloud" : "antenna.radiowaves.left.and.right")
                    .font(.caption)
                Text(isCloudHosted
                    ? "Cloud conversation — the agent runs on its own cloud harness. Rebuilt from the harness's transcript; may lag by a flush cycle."
                    : "Remote conversation — the agent runs on another device. Rebuilt from its synced log mirror; may lag by a sync cycle.")
                    .font(.caption2)
                Spacer(minLength: 0)
                if isCloudHosted {
                    // The empty state's button disappears the moment a transcript
                    // exists; a worker that has since exited still needs a way back.
                    startWorkerButton(title: "Start Worker")
                        // The header sentence wraps rather than squeezing the
                        // button down to an unreadable "Start…".
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(.secondary)
            // The result lives here, not next to either button: both affordances
            // launch the same worker, and the header is on screen in both states.
            if let workerOutcome {
                workerResultLine(workerOutcome)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func startWorkerButton(title: String) -> some View {
        Button {
            startWorker()
        } label: {
            Label(title, systemImage: "bolt.horizontal.circle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(isStartingWorker)
    }

    @ViewBuilder
    private func workerResultLine(_ outcome: CloudWorkerClient.Outcome) -> some View {
        switch outcome {
        case .started(let instanceType):
            Label("worker starting (\(instanceType)) — transcript will appear once it boots",
                  systemImage: "bolt.horizontal.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .alreadyRunning:
            Label("a worker is already running", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .notConfigured:
            Label("control plane not configured — set it in Hosting settings",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func startWorker() {
        guard !isStartingWorker else { return }
        isStartingWorker = true
        workerOutcome = nil
        let agentName = self.agentName
        Task {
            workerOutcome = await CloudWorkerClient.requestWorker(agentName: agentName)
            isStartingWorker = false
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if records.isEmpty {
                        emptyState
                    }
                    ForEach(records) { record in
                        recordRow(record)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(record.id)
                    }
                    ForEach(visibleRelayRows) { message in
                        relayRow(message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(message.id)
                    }
                    ForEach(visibleCloudPending) { message in
                        cloudPendingRow(message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: records.count) { _, _ in scrollToLatest(proxy) }
            // A just-composed relay row appended below the fold must scroll into
            // view too — records.count alone never changes on compose.
            .onChange(of: visibleRelayRows.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: visibleCloudPending.count) { _, _ in scrollToLatest(proxy) }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if let last = visibleRelayRows.last.map({ AnyHashable($0.id) })
            ?? records.last.map({ AnyHashable($0.id) }) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    /// Never a blank screen: a freshly-tapped notification routinely beats the
    /// origin device's mirror files here by a sync cycle (the load pass has
    /// already asked iCloud to download any undownloaded placeholders, and the
    /// 10s auto-refresh will pick them up), so an empty merged transcript reads
    /// as "syncing" — with the honest caveat for the case that never fills in.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCloudHosted, CloudAgentConfig.transcriptURL(agentID: agentID).isEmpty,
               !CloudControlPlaneConfig.isConfigured {
                // Not a syncing problem and nothing to auto-vend from — the control
                // plane is unset, so a hand-pasted URL is the only source.
                Label("No transcript URL configured", systemImage: "cloud.slash")
                    .font(.headline)
                Text("Paste the harness's Transcript URL in this agent's Hosting settings, or set the control plane so Fin can fetch it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(hasLoaded ? "Syncing conversation…" : "Loading transcript…")
                        .font(.headline)
                }
                Text(cloudOrMirrorEmptyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isCloudHosted {
                // An empty cloud transcript most often means no worker is up
                // yet — this is the screen where starting one belongs.
                startWorkerButton(title: "Start Cloud Worker")
                    .padding(.top, 2)
                Text("Asks the control plane to launch this agent's harness, if one isn't already running.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var cloudOrMirrorEmptyCaption: String {
        if isCloudHosted {
            return hasLoaded
                ? "Waiting for the cloud harness's transcript — retried every few seconds. If nothing appears, the harness may not be running yet."
                : "Fetching the harness's transcript."
        }
        return hasLoaded
            ? "Waiting for the hosting device's mirrored log files to arrive from iCloud Drive — retried every few seconds. If nothing appears, the hosting device may have mirroring off or no activity in the last two days."
            : "Reading the agent's mirrored logs from iCloud Drive."
    }

    @ViewBuilder
    private func recordRow(_ record: AgentMirrorRecord) -> some View {
        switch record.kind {
        case .userMessage where record.text.hasPrefix("[heartbeat]"):
            Label("heartbeat check", systemImage: "waveform.path.ecg")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .userMessage:
            VStack(alignment: .leading, spacing: 2) {
                Text("You").font(.caption2).foregroundStyle(.secondary)
                Text(record.text)
            }
        case .assistantMessage:
            Text(record.text)
        case .toolCall:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: record.toolName == "send_input" ? "arrow.right.square" : "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.text)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        case .toolResult:
            DisclosureGroup {
                Text(record.text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Result", systemImage: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .reasoning:
            Label(record.text, systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error:
            Label(record.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notice, .approval:
            // .notice never reaches here — refresh() filters the audit trail
            // out of the remote transcript; the case stays for exhaustiveness.
            Text(record.text)
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Relay

    /// This device's outbound messages, for as long as their rows exist (the
    /// launch sweep is what removes them): "sending…" until the hosting device's
    /// stamp syncs back, then a visible "sent" — no vanish window, so a stamp
    /// arriving hours after composition still flips the row rather than hiding
    /// it. A rejected stamp renders as "not delivered"; a row pending past the
    /// sweep's unapplied hard floor renders as "expired".
    private var pendingRelayRows: [AgentRelayMessage] {
        relayMessages.filter { $0.authorDeviceID8 == DeviceIdentity.short }
    }

    /// The relay rows the transcript actually renders: a row disappears once
    /// BOTH the hosting device's applied stamp came back AND the merged mirror
    /// carries the applied prompt as a user message — at that point the
    /// transcript proper shows the text and the relay row would be a duplicate
    /// (live-observed: every sent message rendered twice). Either signal alone
    /// keeps the row: a stamp without the mirror record is the sync-lag window
    /// where hiding would make the message vanish, and a matching mirror record
    /// without a stamp belongs to an earlier identical send, not this one.
    private var visibleRelayRows: [AgentRelayMessage] {
        pendingRelayRows.filter { message in
            Self.relayState(
                appliedAt: message.appliedAt,
                appliedByDeviceID8: message.appliedByDeviceID8,
                createdAt: message.createdAt
            ) != .sent
                || !Self.relayRowIsMirrored(
                    text: message.text, createdAt: message.createdAt, records: records
                )
        }
    }

    /// Whether the merged mirror transcript already shows a relay message as an
    /// applied user prompt: same trimmed text, logged no earlier than shortly
    /// before the relay was composed (five minutes of clock-skew tolerance —
    /// the hosting device applies AFTER composition, so an older match is some
    /// previous identical message, and hiding against it would drop a row the
    /// transcript isn't showing).
    static func relayRowIsMirrored(
        text: String, createdAt: Date, records: [AgentMirrorRecord]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.contains { record in
            record.kind == .userMessage
                && record.timestamp >= createdAt.addingTimeInterval(-300)
                && record.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    /// Sender-side render state for one of this device's relay rows.
    static func relayState(
        appliedAt: Date?, appliedByDeviceID8: String?, createdAt: Date, now: Date = Date()
    ) -> RelayRowState {
        if appliedAt != nil {
            return appliedByDeviceID8?.hasPrefix(AgentRelayApplier.rejectedPrefix) == true
                ? .rejected
                : .sent
        }
        let floor = TimeInterval(AgentRelayApplier.unappliedRetentionDays) * 86_400
        return now.timeIntervalSince(createdAt) > floor ? .expired : .sending
    }

    enum RelayRowState {
        case sending, sent, rejected, expired
    }

    /// Cloud pending rows, with the same mirror handoff as relay rows: once the
    /// harness's transcript shows the applied prompt, the local row retires.
    private var visibleCloudPending: [CloudPendingMessage] {
        cloudPending.filter { message in
            message.state != .sent
                || !Self.relayRowIsMirrored(
                    text: message.text, createdAt: message.createdAt, records: records
                )
        }
    }

    private func cloudPendingRow(_ message: CloudPendingMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("You").font(.caption2).foregroundStyle(.secondary)
                switch message.state {
                case .sending:
                    Label("sending…", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .sent:
                    Label("sent to cloud", systemImage: "checkmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .failed:
                    Label("not delivered — check the inbox URLs in Hosting settings",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(message.text)
        }
    }

    private func relayRow(_ message: AgentRelayMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("You").font(.caption2).foregroundStyle(.secondary)
                switch Self.relayState(
                    appliedAt: message.appliedAt,
                    appliedByDeviceID8: message.appliedByDeviceID8,
                    createdAt: message.createdAt
                ) {
                case .sending:
                    Label("sending…", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                case .sent:
                    Label("sent", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .rejected:
                    Label("not delivered (too long)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .expired:
                    Label("expired", systemImage: "clock.badge.xmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(message.text)
        }
    }

    /// Same cap the hosting applier enforces (`AgentRelayApplier.maxTextLength`),
    /// enforced here too so an over-long paste is stopped at the composer with a
    /// visible counter instead of being rejected after a sync round-trip.
    private var draftOverflow: Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count
            - AgentRelayApplier.maxTextLength
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draftOverflow > 0 {
                Text("\(draftOverflow) characters over the \(AgentRelayApplier.maxTextLength)-character limit")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                TextField(
                    isCloudHosted
                        ? "Message (delivered to the cloud harness)"
                        : "Message (delivered to the hosting device)",
                    text: $draft, axis: .vertical
                )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draftOverflow > 0
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= AgentRelayApplier.maxTextLength else { return }
        draft = ""
        guard isCloudHosted else {
            modelContext.insert(AgentRelayMessage(
                agentID: agentID,
                text: text,
                authorDeviceID8: DeviceIdentity.short
            ))
            return
        }
        let pending = CloudPendingMessage(
            id: UUID(), text: text, createdAt: Date(), state: .sending
        )
        cloudPending.append(pending)
        let agentID = self.agentID
        let agentName = self.agentName
        Task {
            let delivered = await CloudAgentChannel.sendMessage(
                agentID: agentID,
                agentName: agentName,
                text: text
            )
            if let index = cloudPending.firstIndex(where: { $0.id == pending.id }) {
                cloudPending[index].state = delivered ? .sent : .failed
            }
        }
    }

    // MARK: - Loading

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let loaded: [AgentMirrorRecord]
        if isCloudHosted {
            loaded = await CloudAgentChannel.fetchTranscript(
                agentID: agentID, agentName: agentName
            )
        } else {
            let reader = self.reader
            let name = agentName
            let id = agentID
            // Detached: ubiquity-container resolution and file I/O must stay off the
            // MainActor (same rule AgentLogMirror follows on its own queue).
            loaded = await Task.detached(priority: .utility) {
                reader.loadRecent(agentName: name, agentID: id)
            }.value
        }
        // Notices are the lifecycle audit trail ("[app] launched…",
        // "[signals]…", "[relay] applied…") — written for the remote
        // SUPERVISOR reading the raw mirror files, not for a person jumping
        // into the conversation. They stay in the mirror; they just don't
        // render here. Approvals and errors still do: both can be the very
        // reason the agent is waiting.
        records = loaded.filter { $0.kind != .notice }
        hasLoaded = true
    }
}

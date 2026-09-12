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

    /// Cloud-hosted only, "load earlier" support. `latestWindowRecords` is whatever the
    /// periodic refresh's default fetch returns (the latest hour, merged with the
    /// previous one when it exists — see `CloudAgentChannel.fetchTranscriptChunks`);
    /// `earlierRecords` accumulates hours paged in explicitly, oldest-fetched merged in
    /// first. `records` is always `merge([earlierRecords, latestWindowRecords])` —
    /// recomputed after either changes, so a periodic refresh never undoes paging.
    @State private var latestWindowRecords: [AgentMirrorRecord] = []
    @State private var earlierRecords: [AgentMirrorRecord] = []
    /// The full set of hour keys the control plane knows about for this agent, oldest
    /// first (as the route returns them) — what "load earlier" pages backward through.
    @State private var allTranscriptHours: [String] = []
    /// Index into `allTranscriptHours` of the oldest hour already represented in
    /// `latestWindowRecords`/`earlierRecords`. nil until the first successful fetch.
    @State private var oldestLoadedHourIndex: Int?
    @State private var isLoadingEarlier = false

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

    /// This device hosts no runtime for the agent shown here (that's the whole point
    /// of this screen), so `SessionManager`'s turn-finish/watchdog triggers never fire
    /// for it — this view's own 10s refresh loop is the only cadence available to keep
    /// its memory synced too. View-owned rather than shared: `AgentMemorySyncService`'s
    /// per-agent pacing lives in-memory, so a fresh instance per view just means the
    /// first sync isn't throttled — harmless.
    @State private var memorySync: AgentMemorySyncService?

    struct CloudPendingMessage: Identifiable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date
        var state: State
        /// The control-plane message id when the send went through `POST
        /// /messages` (nil for the legacy presigned-inbox path). It is minted
        /// BEFORE the send so a retry is a no-op server-side, and it is what
        /// `refreshPendingStates` polls.
        var messageID: String?
        /// Progress reported by the control plane: queued → claimed → applied →
        /// answered, plus who has it. Nil until the first poll.
        var siteName: String?
        var routedBy: String?
        var clarifyCandidates: [String] = []
        /// True for a row this device learned about from the control plane rather
        /// than composed itself — a voice message, or one sent from another device.
        /// Without these, a message you spoke to Fin is invisible everywhere until
        /// it lands in the transcript, which on a busy body can be minutes.
        var isRemote = false
        var source: String?
        /// The thread the row belongs to: what it was sent with, or what the
        /// control plane reported. nil = unknown (shown under every selection).
        var threadID: String?

        enum State { case sending, sent, failed, queued, claimed, applied, answered }
    }

    /// Presence across every site, shared with the servers list and the memory
    /// view through one cache. The header folds it to one line.
    @ObservedObject private var sites = SiteDirectory.shared
    /// Control-plane rows by id, for provenance: which device sent a prompt, by
    /// what input, and when — joined to transcript user lines via in_reply_to.
    @State private var remoteMessages: [String: ControlPlaneClient.Message] = [:]
    /// Turns whose steps (reasoning, tool calls, results) are expanded. Default
    /// view is input and output only; tap a reply to open its steps.
    @State private var expandedTurns: Set<String> = []
    /// docs/THREADS.md §4: the thread list, the selection, and the selected
    /// thread's detail (its rows and events). Polled on this view's cadence.
    @StateObject private var threadStore: ThreadStore
    /// A thread to open on (a notification tap, the hub sidebar); nil = default rule.
    private let initialThreadID: String?

    init(agent: Agent, reader: AgentMirrorReader = AgentMirrorReader(), initialThreadID: String? = nil) {
        self.agentID = agent.id
        self.agentName = agent.name
        self.reader = reader
        self.initialThreadID = initialThreadID
        _threadStore = StateObject(wrappedValue: ThreadStore(agentName: agent.name))
        // With a control plane, THE conversation is the cloud transcript (every body
        // writes to it), merged with this device's own mirror — whatever the agent's
        // hosting mode says. Without one, the old rule: cloud-hosted reads the cloud.
        self.isCloudHosted = !agent.hostsLocally || CloudControlPlaneConfig.isConfigured
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
            if memorySync == nil {
                memorySync = AgentMemorySyncService(context: modelContext)
            }
            threadStore.preselect(initialThreadID)
            await refresh()
            await refreshPresenceAndPending()
            await refreshThreads()
            memorySync?.syncIfDue(agentID: agentID, agentName: agentName)
            // Auto-refresh while visible; cancelled with the view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await refresh()
                await refreshPresenceAndPending()
                await refreshThreads()
                memorySync?.syncIfDue(agentID: agentID, agentName: agentName)
            }
        }
    }

    /// The thread list on the console cadence, plus the selected thread's
    /// detail — its rows fill the `messageId → threadId` map a legacy
    /// `in_reply_to` line is resolved through, its events interleave below.
    private func refreshThreads() async {
        guard usesControlPlane, threadStore.isAvailable else { return }
        await threadStore.refresh()
        if let selected = threadStore.selectedThreadID {
            await threadStore.loadDetail(selected)
        }
    }

    /// With a control plane, the header is ONE line about Fin — never a per-site
    /// strip, never a worker button. "Wake a cloud computer" appears only when no
    /// body is reachable: that is the one moment a cloud launch is the answer.
    private var usesControlPlane: Bool { isCloudHosted && CloudControlPlaneConfig.isConfigured }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesControlPlane {
                let presence = sites.presence
                HStack(spacing: 6) {
                    Image(systemName: presence.glyph)
                        .font(.caption)
                    Text(presence.headline)
                        .font(.caption.weight(.medium))
                    if let detail = presence.detail {
                        Text(detail)
                            .font(.caption2)
                    }
                    Spacer(minLength: 0)
                    if presence == .asleep {
                        startWorkerButton(title: "Wake a cloud computer")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("finPresenceHeader")
                HStack(spacing: 8) {
                    ThreadPicker(store: threadStore, compact: true)
                    if let thread = threadStore.selectedThread {
                        ThreadChipView(chip: thread.status.chip)
                        if let goal = thread.openGoal {
                            Label("follow-up \(goal.suffix(6))", systemImage: "flag")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
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
            }
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
                    if hasEarlierTranscriptHours {
                        loadEarlierButton
                    }
                    if records.isEmpty {
                        emptyState
                    } else if turns.isEmpty, threadStore.selectedThreadID != nil, threadEventItems.isEmpty {
                        Label("Nothing in this thread has reached the transcript yet.", systemImage: "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(consoleRows) { row in
                        switch row {
                        case .turn(let turn):
                            turnView(turn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(turn.id)
                        case .event(let item):
                            threadEventRow(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(item.id)
                        }
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
            ?? turns.last.map({ AnyHashable($0.id) }) {
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
            if isCloudHosted, !CloudControlPlaneConfig.isConfigured {
                // Not a syncing problem — the control plane is what the harness's
                // transcript chunks are fetched through; nothing to read without it.
                Label("Control plane not configured", systemImage: "cloud.slash")
                    .font(.headline)
                Text("Set the control plane in this agent's Hosting settings so Fin can fetch the harness's transcript.")
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
            if isCloudHosted, !usesControlPlane {
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

    private var loadEarlierButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                loadEarlier()
            } label: {
                if isLoadingEarlier {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Load earlier", systemImage: "arrow.up.circle")
                        .font(.caption)
                }
            }
            .disabled(isLoadingEarlier)
            Spacer(minLength: 0)
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

    // MARK: - Turns

    typealias Turn = TranscriptTurns.Turn

    /// See `TranscriptTurns.turns(from:)`. With a thread selected the turns are
    /// filtered to that thread's `thread_id` / `in_reply_to` set (docs/THREADS.md
    /// §4) — `threadOfMessage` resolves a legacy prompt through its row.
    static func turns(
        from records: [AgentMirrorRecord], threadID: String? = nil, threadOfMessage: [String: String] = [:]
    ) -> [Turn] {
        ThreadMembership.turns(TranscriptTurns.turns(from: records), in: threadID, threadOfMessage: threadOfMessage)
    }

    /// `messageId → threadId` from every control-plane row this view has seen:
    /// the open-message poll plus the selected thread's detail.
    private var threadOfMessage: [String: String] {
        var map = threadStore.threadOfMessage
        for (id, row) in remoteMessages { map[id] = row.resolvedThreadID }
        return map
    }

    private var turns: [Turn] {
        Self.turns(from: records, threadID: threadStore.selectedThreadID, threadOfMessage: threadOfMessage)
    }

    /// The selected thread's notify / relay / follow-up events that no transcript
    /// line already shows — interleaved between turns by time.
    private var threadEventItems: [ThreadItem] {
        guard let selected = threadStore.selectedThreadID, let detail = threadStore.detail(for: selected) else { return [] }
        let threadRecords = turns.flatMap { [$0.prompt].compactMap { $0 } + $0.steps + [$0.reply].compactMap { $0 } }
        return ThreadTimeline.build(thread: detail.thread, messages: [], records: threadRecords, events: detail.events)
            .filter { $0.source == .event }
    }

    enum ConsoleRow: Identifiable {
        case turn(Turn)
        case event(ThreadItem)
        var id: String {
            switch self { case .turn(let turn): return "t:" + turn.id; case .event(let item): return item.id }
        }
        var timestamp: Date {
            switch self {
            case .turn(let turn): return turn.prompt?.timestamp ?? turn.steps.first?.timestamp ?? turn.reply?.timestamp ?? .distantPast
            case .event(let item): return item.timestamp
            }
        }
    }

    /// Turns and thread events in one time order. Pure so the interleave is testable.
    static func interleave(turns: [Turn], events: [ThreadItem]) -> [ConsoleRow] {
        let rows = turns.map(ConsoleRow.turn) + events.map(ConsoleRow.event)
        // Stable: a turn and an event in the same second keep source order (turn first).
        return rows.enumerated().sorted { a, b in
            if a.element.timestamp != b.element.timestamp { return a.element.timestamp < b.element.timestamp }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var consoleRows: [ConsoleRow] { Self.interleave(turns: turns, events: threadEventItems) }

    private func threadEventRow(_ item: ThreadItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.kind == .notify ? "bell" : item.party.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.party.label)
                    ForEach(item.status, id: \.self) { chip in
                        Text(chip)
                            .padding(.horizontal, 5)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(item.text)
                    .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(item.kind == .notify ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("threadEventRow")
    }

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        if turn.isHeartbeat {
            Button {
                toggle(turn)
            } label: {
                Label("heartbeat check · \(turn.steps.count) steps", systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if expandedTurns.contains(turn.id) {
                turnSteps(turn)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let prompt = turn.prompt {
                    promptRow(prompt)
                }
                if expandedTurns.contains(turn.id) {
                    turnSteps(turn)
                }
                if let reply = turn.reply {
                    Button { toggle(turn) } label: {
                        recordRow(reply)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("turnReply")
                } else if !turn.steps.isEmpty {
                    Button { toggle(turn) } label: {
                        Label(expandedTurns.contains(turn.id) ? "working…" : "working… · \(turn.steps.count) steps so far",
                              systemImage: "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if !turn.steps.isEmpty, turn.reply != nil {
                    Button {
                        toggle(turn)
                    } label: {
                        Text(expandedTurns.contains(turn.id) ? "hide \(turn.steps.count) steps" : "\(turn.steps.count) steps — reasoning, tool calls, results")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("turnStepsToggle")
                }
            }
        }
    }

    private func turnSteps(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turn.steps) { record in
                recordRow(record)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
    }

    private func toggle(_ turn: Turn) {
        if expandedTurns.contains(turn.id) { expandedTurns.remove(turn.id) } else { expandedTurns.insert(turn.id) }
    }

    /// "You · voice · from Levi's iPhone · 4:27 PM": when, from which device, and
    /// by what input — joined to the control-plane row via in_reply_to; a line
    /// with no row still shows its time and the body that applied it.
    private func promptRow(_ record: AgentMirrorRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.provenance(for: record, messages: remoteMessages, sites: sites.sites))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(record.text)
        }
        .accessibilityIdentifier("promptRow")
    }

    static func provenance(for record: AgentMirrorRecord, messages: [String: ControlPlaneClient.Message],
                           sites: [FinSite], now: Date = Date()) -> String {
        var parts = ["You"]
        let row = record.inReplyTo.flatMap { messages[$0] }
        if let source = row?.source {
            parts.append(source == "voice" ? "voice" : (source == "app" ? "in app" : source))
        }
        if let author = row?.authorSiteId8 {
            let name = sites.first { $0.siteId8 == author }?.displayName ?? "device \(author)"
            parts.append("from \(name)")
        } else if let site = record.siteName {
            parts.append("applied on \(site)")
        }
        let sent = row?.createdAt ?? record.timestamp
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = Calendar.current.isDateInToday(sent) ? .none : .short
        formatter.timeStyle = .short
        parts.append(formatter.string(from: sent))
        return parts.joined(separator: " · ")
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
            if let siteName = record.siteName ?? record.siteID8 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: Self.siteGlyph(record))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .help("on \(siteName) · \(record.timestamp.formatted(.relative(presentation: .named)))")
                    Text(record.text)
                }
            } else {
                Text(record.text)
            }
        case .toolCall where record.toolName == "notify":
            // A notification the agent sent the owner is the whole point of this
            // screen for a "what's the cloud agent up to" check-in — plain
            // readable prose (the text is already "notify: <title> — <body>",
            // not code) with a bell, not a generic gray monospaced tool blob.
            Label(record.text, systemImage: "bell")
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .toolCall where PaneRelay.target(of: record) != nil:
            // The pane is its own party in a thread (docs/THREADS.md §1): what
            // Fin sent into it, labelled with the pane, not a generic tool blob.
            let target = PaneRelay.target(of: record) ?? ""
            let isRead = PaneRelay.readTools.contains(record.toolName ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Label(isRead ? "read pane \(target)" : "→ pane \(target)", systemImage: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(record.text)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("paneRelayRow")
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
        case .toolResult where record.toolName == "notify":
            // The delivery outcome ("Sent to the owner." / "Queued…" / "Delivery
            // failed…") is short and exactly what a notification check-in needs
            // to see at a glance — shown plainly, not buried in a collapsed
            // DisclosureGroup like an arbitrary tool result.
            Label(record.text, systemImage: "checkmark.bubble")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        case .turnStarted:
            // The whole point of this kind: a visible "received" the instant a headless
            // daemon records the user message, seconds before any tool call or reply —
            // not just exhaustiveness filler like the two cases above.
            Label("received", systemImage: "bolt.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .turnProgress:
            // No emitter exists yet anywhere (see `AgentLogKind.turnProgress`'s doc
            // comment) — handled here only so this switch stays exhaustive the day one
            // is added, mirroring the .notice/.approval case above.
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

    /// Sender-side render state for one of this device's relay rows. The two
    /// rejection sentinels (`rejectedLength`, `rejectedSubmit`) are distinguished
    /// by EXACT match — checked before the generic `rejectedPrefix` fallback so
    /// a future sentinel that only shares the prefix still renders as "rejected"
    /// (via `.rejectedLength`'s catch-all role below) rather than silently
    /// falling through to "sent".
    static func relayState(
        appliedAt: Date?, appliedByDeviceID8: String?, createdAt: Date, now: Date = Date()
    ) -> RelayRowState {
        if appliedAt != nil {
            if appliedByDeviceID8 == AgentRelayApplier.rejectedSubmit {
                return .rejectedSubmit
            }
            return appliedByDeviceID8?.hasPrefix(AgentRelayApplier.rejectedPrefix) == true
                ? .rejectedLength
                : .sent
        }
        let floor = TimeInterval(AgentRelayApplier.unappliedRetentionDays) * 86_400
        return now.timeIntervalSince(createdAt) > floor ? .expired : .sending
    }

    enum RelayRowState {
        case sending, sent, rejectedLength, rejectedSubmit, expired
    }

    /// Cloud pending rows, with the same mirror handoff as relay rows: once the
    /// harness's transcript shows the applied prompt, the local row retires.
    private var visibleCloudPending: [CloudPendingMessage] {
        Self.pendingRows(cloudPending, inThread: threadStore.selectedThreadID).filter { message in
            message.state != .sent
                || !Self.relayRowIsMirrored(
                    text: message.text, createdAt: message.createdAt, records: records
                )
        }
    }

    /// With a thread selected, a pending row shows only when it belongs to that
    /// thread — or when its thread is not known yet (just composed, no row back).
    static func pendingRows(_ rows: [CloudPendingMessage], inThread threadID: String?) -> [CloudPendingMessage] {
        guard let threadID else { return rows }
        return rows.filter { $0.threadID == nil || $0.threadID == threadID }
    }

    private func cloudPendingRow(_ message: CloudPendingMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.source == "voice" ? "You (voice)" : "You").font(.caption2).foregroundStyle(.secondary)
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
                case .queued:
                    Label(message.routedBy == "clarify"
                          ? "which computer? \(message.clarifyCandidates.joined(separator: " / "))"
                          : (message.siteName.map { "queued for \($0)" } ?? "queued — waiting for a computer"),
                          systemImage: "tray")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .claimed:
                    Label(message.siteName.map { "\($0) has it — next in line after its current turn" } ?? "picked up",
                          systemImage: "hand.raised")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .applied:
                    Label(message.siteName.map { "\($0) is on it" } ?? "working on it", systemImage: "gearshape.2")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .answered:
                    Label("answered", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(message.text)
        }
        .accessibilityIdentifier("pendingMessageRow")
    }

    /// Fold one control-plane row into a pending row's render state. Pure.
    static func pendingState(for remote: ControlPlaneClient.Message) -> CloudPendingMessage.State {
        switch remote.state {
        case "claimed": return .claimed
        case "applied": return .applied
        case "answered": return .answered
        default: return .queued
        }
    }

    static func siteGlyph(_ record: AgentMirrorRecord) -> String {
        // The transcript line carries no kind; the directory does. Cloud
        // workers get the cloud, phones the phone, everything else a desktop.
        let sites = SiteDirectory.shared.sites
        if let site = sites.first(where: { $0.siteId8 == record.siteID8 }) { return site.kindGlyph }
        return "desktopcomputer"
    }

    /// Refresh presence, poll every pending row that has a control-plane id, and
    /// surface every OPEN row for this agent the control plane knows about — sent
    /// from any device, by voice or by hand — as a pending row here too.
    private func refreshPresenceAndPending() async {
        guard usesControlPlane, !TestHost.isUnitTest else { return }
        await sites.refresh()
        guard case .success(let remote) = await ControlPlaneClient.listMessages(agent: agentName) else { return }
        let byID = Dictionary(remote.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })
        remoteMessages = byID
        for index in cloudPending.indices {
            guard let id = cloudPending[index].messageID, let row = byID[id] else { continue }
            cloudPending[index].state = Self.pendingState(for: row)
            cloudPending[index].siteName = row.targetSiteName
            cloudPending[index].routedBy = row.routedBy
            cloudPending[index].clarifyCandidates = row.clarifyCandidates ?? []
            cloudPending[index].threadID = row.resolvedThreadID
        }
        let known = Set(cloudPending.compactMap { $0.messageID })
        for row in remote where !known.contains(row.messageId) && Self.isOpen(row) {
            guard let text = row.text, !text.isEmpty else { continue }
            let createdAt = row.createdAt ?? Date()
            // Already in the transcript (applied and mirrored): nothing to show.
            if Self.relayRowIsMirrored(text: text, createdAt: createdAt, records: records) { continue }
            var pending = CloudPendingMessage(id: UUID(), text: text, createdAt: createdAt, state: Self.pendingState(for: row))
            pending.messageID = row.messageId
            pending.siteName = row.targetSiteName
            pending.routedBy = row.routedBy
            pending.clarifyCandidates = row.clarifyCandidates ?? []
            pending.isRemote = true
            pending.source = row.source
            pending.threadID = row.resolvedThreadID
            cloudPending.append(pending)
        }
        cloudPending.sort { $0.createdAt < $1.createdAt }
        // Answered rows retire once the transcript shows the applied prompt —
        // same handoff as the relay rows; until then "answered" is the state.
        cloudPending.removeAll { message in
            message.state == .answered
                && Self.relayRowIsMirrored(text: message.text, createdAt: message.createdAt, records: records)
        }
    }

    /// A control-plane row that has not been answered yet, or was answered so
    /// recently the transcript may not show it — worth a pending row.
    static func isOpen(_ row: ControlPlaneClient.Message, now: Date = Date()) -> Bool {
        switch row.state {
        case "queued", "claimed", "applied": return true
        case "answered": return (row.answeredAt.map { now.timeIntervalSince($0) } ?? .infinity) < 120
        default: return false
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
                case .rejectedLength:
                    Label("not delivered (too long)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .rejectedSubmit:
                    Label("not delivered", systemImage: "exclamationmark.triangle")
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
        var pending = CloudPendingMessage(
            id: UUID(), text: text, createdAt: Date(), state: .sending
        )
        let agentID = self.agentID
        let agentName = self.agentName
        if usesControlPlane {
            // docs/SITES.md §6.3 step 1: the id is minted here so a retry is a
            // server-side no-op, and the row can poll its own progress.
            let messageID = ControlPlaneClient.newMessageID()
            pending.messageID = messageID
            // docs/THREADS.md §2: a reply composed inside a thread view joins
            // that thread explicitly; "All activity" roots a new one.
            let threadID = threadStore.selectedThreadID
            pending.threadID = threadID
            cloudPending.append(pending)
            Task {
                var context = ControlPlaneClient.MessageContext(
                    source: "app", activeSessionNames: Self.activeSessionNames()
                )
                context.threadID = threadID
                let result = await ControlPlaneClient.sendMessage(
                    agent: agentName, text: text, messageID: messageID, context: context
                )
                guard let index = cloudPending.firstIndex(where: { $0.id == pending.id }) else { return }
                switch result {
                case .success(let row):
                    cloudPending[index].state = Self.pendingState(for: row)
                    cloudPending[index].siteName = row.targetSiteName
                    cloudPending[index].routedBy = row.routedBy
                    cloudPending[index].clarifyCandidates = row.clarifyCandidates ?? []
                    cloudPending[index].threadID = row.resolvedThreadID
                    remoteMessages[row.messageId] = row
                case .failure:
                    cloudPending[index].state = .failed
                }
            }
            return
        }
        cloudPending.append(pending)
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

    /// The tmux sessions this device currently has open, as routing context:
    /// a message composed while looking at "main" is probably about "main".
    private static func activeSessionNames() -> [String] {
        // The remote console has no terminal of its own; the control strip's
        // sessions are the app's. Kept as a seam for when that context is
        // plumbed through — an empty list routes by text and primary alone.
        []
    }

    // MARK: - Loading

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let loaded: [AgentMirrorRecord]
        if isCloudHosted {
            let page = await CloudAgentChannel.fetchTranscriptChunks(agentName: agentName)
            allTranscriptHours = page.hours
            latestWindowRecords = page.records
            if oldestLoadedHourIndex == nil {
                // First successful fetch: the default window covers the latest hour,
                // merged with the previous one when it exists — record which of
                // `allTranscriptHours` that oldest-covered hour is, so "load earlier"
                // knows where to page from next.
                oldestLoadedHourIndex = Self.initialOldestLoadedHourIndex(hourCount: page.hours.count)
            }
            let reader = self.reader
            let name = agentName
            let id = agentID
            // On-device turns (this phone hosting Fin for a while) live only in the
            // mirror; the merged conversation is both, deduped by id.
            let mirrored = await Task.detached(priority: .utility) {
                reader.loadRecent(agentName: name, agentID: id, days: 2)
            }.value
            loaded = AgentMirrorReader.merge([earlierRecords, latestWindowRecords, mirrored])
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

    /// The default fetch's oldest-covered-hour index into an hour list of `hourCount`
    /// entries: the default window covers the latest hour, merged with the previous one
    /// when it exists (see `CloudAgentChannel.fetchTranscriptChunks`). Pure so the
    /// boundary (0 or 1 known hour) is directly testable.
    static func initialOldestLoadedHourIndex(hourCount: Int) -> Int {
        max(0, hourCount - 2)
    }

    /// Whether an hour older than `oldestLoadedHourIndex` exists to page into. Pure so
    /// the nil/zero boundary is directly testable without constructing the view.
    static func hasEarlierHour(oldestLoadedHourIndex: Int?) -> Bool {
        guard let index = oldestLoadedHourIndex else { return false }
        return index > 0
    }

    private var hasEarlierTranscriptHours: Bool {
        isCloudHosted && Self.hasEarlierHour(oldestLoadedHourIndex: oldestLoadedHourIndex)
    }

    /// Pages in the next-older hour chunk, merges it into `earlierRecords`, and
    /// recomputes `records` immediately — no need to wait for the next periodic poll.
    private func loadEarlier() {
        guard !isLoadingEarlier, Self.hasEarlierHour(oldestLoadedHourIndex: oldestLoadedHourIndex),
              let index = oldestLoadedHourIndex
        else { return }
        isLoadingEarlier = true
        let targetIndex = index - 1
        let targetHour = allTranscriptHours[targetIndex]
        let name = agentName
        Task {
            defer { isLoadingEarlier = false }
            let page = await CloudAgentChannel.fetchTranscriptChunks(agentName: name, hour: targetHour)
            earlierRecords = AgentMirrorReader.merge([page.records, earlierRecords])
            oldestLoadedHourIndex = targetIndex
            records = AgentMirrorReader.merge([earlierRecords, latestWindowRecords])
                .filter { $0.kind != .notice }
        }
    }
}

import AppIntents
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// docs/XANADU.md: the landing pane — one current thread, its whole
/// transcript, a composer that takes text, photos, files and voice notes, and
/// Siri as a peer in the same thread. Every item is a link forward: a file
/// opens its content, a URL the in-app browser, a thread id that thread.
///
/// This view picks the agent (the user's primary — the one a voice message
/// goes to — switchable when there are several) and hands it to
/// `XanaduThreadPane`, re-created per agent so each gets its own store.
struct XanaduView: View {
    static let activityType = "dev.levischoen.fin.xanadu-thread"

    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @AppStorage("xanadu.agentID") private var chosenAgentID = ""
    @ObservedObject private var navigator = XanaduNavigator.shared

    var body: some View {
        Group {
            if let agent = currentAgent {
                XanaduThreadPane(agent: agent, agents: agents) { chosenAgentID = $0.id.uuidString }
                    .id(agent.id)
            } else {
                ContentUnavailableView(
                    "No agent yet",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Add Fin in the Agents tab, then talk to it here.")
                )
            }
        }
        .onChange(of: navigator.request) { _, request in
            guard let name = request?.agentName,
                  let match = agents.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            chosenAgentID = match.id.uuidString
        }
    }

    /// The chosen agent, else the voice rule's primary (the one named "Fin",
    /// else the first).
    private var currentAgent: Agent? {
        if let chosen = agents.first(where: { $0.id.uuidString == chosenAgentID }) { return chosen }
        return FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: agents.map(\.name)).map { agents[$0] }
    }

    /// The UI's send, donated so Siri learns the user's habits (Tell Fin in
    /// this thread / start a thread). Synchronous on purpose: the async and
    /// sync `donate` overloads are ambiguous from an async context.
    static func donate(text: String, startedNewThread: Bool, thread: FinThreadEntity?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !TestHost.isUnitTest else { return }
        if startedNewThread {
            _ = IntentDonationManager.shared.donate(intent: StartFinThreadIntent(message: trimmed))
        } else {
            _ = IntentDonationManager.shared.donate(intent: SendToFinIntent(message: trimmed, thread: thread))
        }
    }
}

/// One agent's current thread.
struct XanaduThreadPane: View {
    private let agent: Agent
    private let agentID: UUID
    private let agentName: String
    private let agents: [Agent]
    private let selectAgent: (Agent) -> Void
    /// The cloud transcript (with the device mirror) when there is a control
    /// plane or the agent is cloud-hosted; the iCloud mirror otherwise.
    private let isCloudHosted: Bool

    @Environment(\.modelContext) private var modelContext
    @StateObject private var threadStore: ThreadStore
    @ObservedObject private var sites = SiteDirectory.shared
    @ObservedObject private var navigator = XanaduNavigator.shared
    @StateObject private var recorder = XanaduVoiceRecorder()

    @State private var records: [AgentMirrorRecord] = []
    @State private var sentRows: [String: ControlPlaneClient.Message] = [:]
    @State private var rows: [XanaduTimeline.Row] = []
    @State private var items: [ThreadItem] = []
    @State private var expandedSteps: Set<String> = []
    @State private var outbox: [OutboxItem] = []
    @State private var isRefreshing = false

    @State private var draft = ""
    @State private var drafts: [AttachmentDraft] = []
    @State private var composerNotice: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFileImporter = false
    @State private var webLink: XanaduWebLink?

    struct OutboxItem: Identifiable, Equatable {
        enum State: Equatable { case sending, failed(String) }
        let id = UUID()
        let messageID: String
        let text: String
        var drafts: [AttachmentDraft]
        let threadID: String?
        let createdAt = Date()
        var state: State = .sending
    }

    init(agent: Agent, agents: [Agent] = [], selectAgent: @escaping (Agent) -> Void = { _ in }) {
        self.agent = agent
        self.agentID = agent.id
        self.agentName = agent.name
        self.agents = agents
        self.selectAgent = selectAgent
        self.isCloudHosted = !agent.hostsLocally || CloudControlPlaneConfig.isConfigured
        _threadStore = StateObject(wrappedValue: ThreadStore(agentName: agent.name))
    }

    private var usesControlPlane: Bool { CloudControlPlaneConfig.isConfigured }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .userActivity(XanaduView.activityType, isActive: onscreenEntity != nil) { activity in
            // Onscreen context: "reply to this" / "what did Fin say" resolve
            // to the thread on screen.
            guard let entity = onscreenEntity else { return }
            activity.title = entity.title
            if #available(iOS 18.2, macOS 15.2, visionOS 2.2, *) {
                activity.appEntityIdentifier = EntityIdentifier(for: entity)
            }
        }
        .sheet(item: $webLink) { link in
            XanaduLinkBrowser(url: link.url)
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { stageFiles(urls) }
        }
        .onChange(of: photoItems) { _, picked in
            guard !picked.isEmpty else { return }
            photoItems = []
            Task { await stagePhotos(picked) }
        }
        .onChange(of: threadStore.selectedThreadID) { _, selected in
            // Whatever Xanadu shows IS the current thread.
            if let selected { XanaduCurrentThread.set(selected, agent: agentName) }
            expandedSteps = []
            rebuild()
            Task { await refreshSelectedDetail() }
        }
        .onChange(of: mergeSignature) { _, _ in rebuild() }
        .onChange(of: navigator.request) { _, request in
            guard let request else { return }
            if let name = request.agentName, name.caseInsensitiveCompare(agentName) != .orderedSame { return }
            if let thread = request.threadID ?? XanaduCurrentThread.get(agent: agentName) {
                threadStore.select(thread)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: XanaduCurrentThread.changedNotification)) { note in
            // A Siri send (or a thread opened elsewhere) moved the current
            // thread: follow it.
            guard (note.object as? String) == agentName,
                  let current = XanaduCurrentThread.get(agent: agentName),
                  current != threadStore.selectedThreadID else { return }
            threadStore.select(current)
        }
        .task {
            if let current = XanaduCurrentThread.get(agent: agentName) {
                threadStore.preselect(current)
            } else if let selected = threadStore.selectedThreadID {
                XanaduCurrentThread.set(selected, agent: agentName)
            }
            threadStore.start(agentName: agentName)
            rebuild()
            await refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await refreshRecords()
                // Presence too (cache-limited inside SiteDirectory): one failed
                // fetch at appear must not pin the header on "asleep".
                if usesControlPlane { await sites.refresh() }
                await refreshSelectedDetail()
            }
        }
        .onDisappear { threadStore.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if agents.count > 1 {
                    Menu {
                        ForEach(agents) { other in
                            Button {
                                selectAgent(other)
                            } label: {
                                Label(other.name, systemImage: other.id == agentID ? "checkmark" : "sparkles")
                            }
                        }
                    } label: {
                        Label(agentName, systemImage: "sparkles").font(.caption.weight(.medium))
                    }
                    .fixedSize()
                    .accessibilityIdentifier("xanaduAgentPicker")
                }
                if usesControlPlane {
                    ThreadPicker(store: threadStore, compact: true, allowsAllActivity: false)
                    if let thread = threadStore.selectedThread {
                        ThreadChipView(chip: thread.status.chip)
                    }
                } else {
                    Label(agentName.isEmpty ? "Fin" : agentName, systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
                Button {
                    Task { await refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh")
                if usesControlPlane {
                    Button(action: startNewThread) {
                        Label("New thread", systemImage: "plus.bubble")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New thread")
                    .accessibilityIdentifier("xanaduNewThread")
                }
            }
            if usesControlPlane {
                let presence = sites.presence
                Label(presence.headline, systemImage: presence.glyph)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func startNewThread() {
        threadStore.select(nil)
        XanaduCurrentThread.set(nil, agent: agentName)
        rebuild()
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty && outbox.isEmpty {
                        emptyState
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .said(let item): saidRow(item).id(row.id)
                        case .steps(let id, let steps): stepsRow(id: id, steps: steps).id(row.id)
                        }
                    }
                    ForEach(outbox) { item in
                        outboxRow(item).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("xanadu-bottom")
                }
                .padding()
            }
            .refreshable { await refreshAll() }
            .environment(\.openURL, OpenURLAction { url in handleLink(url) })
            .onChange(of: rows.last?.id) { _, _ in scrollToBottom(proxy) }
            .onChange(of: outbox.count) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
        .accessibilityIdentifier("xanaduTranscript")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("xanadu-bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesControlPlane && threadStore.selectedThreadID == nil {
                Label("New thread", systemImage: "plus.bubble").font(.headline)
                Text("Say something, or attach a photo, a file or a voice note. Siri's follow-ups land here too.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isRefreshing || threadStore.selectedThreadID != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the conversation…").font(.headline)
                }
            } else {
                Label("Nothing here yet", systemImage: "bubble.left").font(.headline)
                Text("Talk to \(agentName.isEmpty ? "Fin" : agentName) below.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func saidRow(_ item: ThreadItem) -> some View {
        switch item.kind {
        case .prompt:
            bubble(item, mine: true)
        case .reply:
            bubble(item, mine: false)
        case .notify:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "bell").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(XanaduText.attributed(XanaduText.displayText(item.text))).font(.callout)
                    if !item.attachments.isEmpty {
                        XanaduAttachmentList(attachments: item.attachments) { Task { await refreshSelectedDetail() } }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        default:
            Label(item.text, systemImage: item.party.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bubble(_ item: ThreadItem, mine: Bool) -> some View {
        let text = XanaduText.displayText(item.text)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !mine { Image(systemName: "sparkles").font(.caption2) }
                Text(byline(item, mine: mine))
                if let origin = XanaduTimeline.originLabel(item.origin) {
                    Label(origin, systemImage: item.origin == "voice" ? "waveform" : "arrow.down.forward")
                        .labelStyle(.titleAndIcon)
                }
                ForEach(item.status, id: \.self) { chip in
                    Text(chip)
                        .padding(.horizontal, 5)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !text.isEmpty {
                Text(XanaduText.attributed(text))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        mine ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            if !item.attachments.isEmpty {
                XanaduAttachmentList(attachments: item.attachments) { Task { await refreshSelectedDetail() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityIdentifier(mine ? "xanaduPrompt" : "xanaduReply")
    }

    private func byline(_ item: ThreadItem, mine: Bool) -> String {
        let time = item.timestamp == .distantPast ? "" : " · " + item.timestamp.formatted(date: .omitted, time: .shortened)
        return (mine ? "You" : (agentName.isEmpty ? "Fin" : agentName)) + time
    }

    private func stepsRow(id: String, steps: [ThreadItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expandedSteps.contains(id) { expandedSteps.remove(id) } else { expandedSteps.insert(id) }
            } label: {
                Label(expandedSteps.contains(id) ? "hide \(steps.count) steps" : "\(steps.count) steps",
                      systemImage: "gearshape.2")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if expandedSteps.contains(id) {
                ForEach(steps) { step in
                    Label {
                        Text(step.text).font(.system(.caption2, design: .monospaced)).lineLimit(12)
                    } icon: {
                        Image(systemName: step.party.systemImage).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
            }
        }
    }

    private func outboxRow(_ item: OutboxItem) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                switch item.state {
                case .sending:
                    ProgressView().controlSize(.mini)
                    Text(item.drafts.contains { $0.uploaded == nil } ? "uploading…" : "sending…")
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(reason).foregroundStyle(.orange)
                    Button("Retry") { deliver(item.id) }.buttonStyle(.borderless)
                    Button("Discard", role: .destructive) { outbox.removeAll { $0.id == item.id } }.buttonStyle(.borderless)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !item.text.isEmpty {
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(item.drafts) { draft in draftChip(draft, removable: false) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("xanaduOutboxRow")
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !drafts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(drafts) { draft in draftChip(draft, removable: true) }
                    }
                }
            }
            if !usesControlPlane {
                Label("Photos, files and voice notes need Fin's cloud — sign in under Agents. Text still works.",
                      systemImage: "icloud.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let notice = composerNotice {
                Text(notice).font(.caption2).foregroundStyle(.orange)
            }
            recorderLine
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: MessageAttachment.maxPerMessage,
                             matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo")
                }
                .buttonStyle(.borderless)
                .disabled(!usesControlPlane)
                .accessibilityLabel("Attach photos")
                Button { showsFileImporter = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .disabled(!usesControlPlane)
                    .accessibilityLabel("Attach files")
                Button(action: toggleRecording) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                        .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(!usesControlPlane || recorder.phase == .transcribing)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record a voice note")
                TextField(threadStore.selectedThreadID == nil && usesControlPlane ? "Start a new thread" : "Message Fin",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                    .accessibilityIdentifier("xanaduComposerField")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("xanaduSend")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var recorderLine: some View {
        switch recorder.phase {
        case .recording(let started):
            HStack(spacing: 6) {
                Image(systemName: "record.circle").foregroundStyle(.red)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(String(format: "Recording %d:%02d — tap stop to attach", seconds / 60, seconds % 60))
                }
                Spacer()
                Button("Cancel", role: .cancel) { recorder.cancel() }.buttonStyle(.borderless)
            }
            .font(.caption)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transcribing on this device…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .denied(let reason):
            Text(reason).font(.caption2).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func draftChip(_ draft: AttachmentDraft, removable: Bool) -> some View {
        HStack(spacing: 6) {
            switch draft.state {
            case .uploading: ProgressView().controlSize(.mini)
            case .uploaded: Image(systemName: "checkmark.icloud").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .staged: Image(systemName: MessageAttachment.kind(ofMIME: draft.mime) == .image ? "photo"
                                : (draft.kind == .audio ? "waveform" : "doc"))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(draft.name).lineLimit(1)
                if case .failed(let reason) = draft.state {
                    Text(reason).foregroundStyle(.orange).lineLimit(2)
                } else if draft.isTooLarge {
                    Text("over 25 MB").foregroundStyle(.orange)
                } else if let transcript = draft.transcript {
                    Text("\u{201C}\(transcript)\u{201D}").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(draft.size), countStyle: .file)).foregroundStyle(.secondary)
                }
            }
            if removable {
                Button { drafts.removeAll { $0.id == draft.id } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(draft.name)")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 240, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("xanaduDraftChip")
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !drafts.isEmpty) && !recorder.isRecording
            && XanaduSend.validate(text: draft, drafts: drafts) == nil
    }

    // MARK: - Staging

    private func addDrafts(_ new: [AttachmentDraft]) {
        let room = MessageAttachment.maxPerMessage - drafts.count
        drafts += new.prefix(max(0, room))
        composerNotice = new.count > room ? "At most \(MessageAttachment.maxPerMessage) files per message." : nil
        if let big = new.first(where: \.isTooLarge) { composerNotice = "\(big.name) is over the 25 MB limit." }
    }

    private func stageFiles(_ urls: [URL]) {
        var staged: [AttachmentDraft] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let draft = try? AttachmentDraft.stage(copying: url) {
                // Photos dragged in from Files are photos too: HEIC → JPEG.
                if draft.kind == .image, let data = try? Data(contentsOf: draft.fileURL) {
                    let normal = XanaduImageNormalizer.normalize(data: data, name: draft.name, type: UTType(mimeType: draft.mime))
                    if normal.mime != draft.mime, let converted = try? AttachmentDraft.stage(data: normal.data, name: normal.name, mime: normal.mime) {
                        staged.append(converted)
                        continue
                    }
                }
                staged.append(draft)
            } else {
                composerNotice = "Couldn't read \(url.lastPathComponent)."
            }
        }
        addDrafts(staged)
    }

    private func stagePhotos(_ picked: [PhotosPickerItem]) async {
        var staged: [AttachmentDraft] = []
        for (index, item) in picked.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                composerNotice = "Couldn't load a photo."
                continue
            }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) }
                ?? item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let isVideo = type?.conforms(to: .movie) == true
            let name = (isVideo ? "video" : "photo") + "-\(index + 1).\(ext)"
            let normal = XanaduImageNormalizer.normalize(data: data, name: name, type: type)
            if let draft = try? AttachmentDraft.stage(data: normal.data, name: normal.name, mime: normal.mime) {
                staged.append(draft)
            }
        }
        addDrafts(staged)
    }

    private func toggleRecording() {
        Task {
            if recorder.isRecording {
                if let note = await recorder.stop() { addDrafts([note]) }
            } else {
                await recorder.start()
            }
        }
    }

    // MARK: - Sending

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = drafts
        guard usesControlPlane else {
            guard files.isEmpty else {
                composerNotice = "Attachments need Fin's cloud."
                return
            }
            draft = ""
            sendWithoutControlPlane(text)
            return
        }
        draft = ""
        drafts = []
        composerNotice = nil
        // Xanadu's thread is explicit: the one on screen, or none (a new thread).
        let target = XanaduCurrentThread.target(explicit: threadStore.selectedThreadID, startNewThread: true, current: nil)
        let item = OutboxItem(messageID: ControlPlaneClient.newMessageID(), text: text, drafts: files, threadID: target)
        outbox.append(item)
        deliver(item.id)
    }

    /// Upload + send one outbox item (first try or Retry: same message id, so
    /// the control plane treats a retry as the same message; uploaded files
    /// are not uploaded again).
    private func deliver(_ id: UUID) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].state = .sending
        let item = outbox[index]
        let agentName = self.agentName
        let entity = onscreenEntity
        Task {
            var context = ControlPlaneClient.MessageContext(source: "app")
            context.threadID = item.threadID
            let result = await XanaduSend.send(
                text: item.text, drafts: item.drafts, agent: agentName, messageID: item.messageID, context: context
            ) { draftID, state in
                guard let row = outbox.firstIndex(where: { $0.id == id }),
                      let slot = outbox[row].drafts.firstIndex(where: { $0.id == draftID }) else { return }
                outbox[row].drafts[slot].state = state
            }
            switch result {
            case .success(let row):
                sentRows[row.messageId] = row
                let landed = XanaduCurrentThread.adoptSend(
                    messageID: item.messageID, sentThreadID: item.threadID, row: row, agent: agentName
                )
                outbox.removeAll { $0.id == id }
                if threadStore.selectedThreadID != landed { threadStore.select(landed) }
                rebuild()
                XanaduView.donate(text: item.text, startedNewThread: item.threadID == nil,
                                  thread: item.threadID == nil ? nil : entity)
                await refreshSelectedDetail()
                await threadStore.refresh()
            case .failure(let problem):
                if let row = outbox.firstIndex(where: { $0.id == id }) { outbox[row].state = .failed(problem.message) }
            }
        }
    }

    /// No control plane: the legacy paths, text only (docs/XANADU.md "Not in
    /// v1": the local runtime path says attachments need the cloud).
    private func sendWithoutControlPlane(_ text: String) {
        guard isCloudHosted else {
            modelContext.insert(AgentRelayMessage(agentID: agentID, text: text, authorDeviceID8: DeviceIdentity.short))
            return
        }
        let item = OutboxItem(messageID: ControlPlaneClient.newMessageID(), text: text, drafts: [], threadID: nil)
        outbox.append(item)
        let agentID = self.agentID, agentName = self.agentName
        Task {
            let delivered = await CloudAgentChannel.sendMessage(agentID: agentID, agentName: agentName, text: text)
            if delivered {
                outbox.removeAll { $0.id == item.id }
                await refreshRecords()
            } else if let index = outbox.firstIndex(where: { $0.id == item.id }) {
                outbox[index].state = .failed("not delivered")
            }
        }
    }

    // MARK: - Links

    private func handleLink(_ url: URL) -> OpenURLAction.Result {
        if let thread = XanaduText.threadID(fromLink: url) {
            threadStore.select(thread)
            return .handled
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            webLink = XanaduWebLink(url: url)
            return .handled
        }
        return .systemAction
    }

    // MARK: - Loading

    private var mergeSignature: String {
        let selected = threadStore.selectedThreadID ?? "-"
        let detail = threadStore.selectedThreadID.flatMap { threadStore.detail(for: $0) }
        let attachmentURLs = detail?.messages.compactMap { $0.attachments?.first?.url?.absoluteString }.joined() ?? ""
        return [
            String(records.count), records.last?.id ?? "-", selected,
            String(detail?.events.count ?? 0), String(detail?.messages.count ?? 0),
            detail?.messages.map(\.state).joined() ?? "", String(attachmentURLs.hashValue),
            String(sentRows.count),
        ].joined(separator: "|")
    }

    private func rebuild() {
        let selected = threadStore.selectedThreadID
        let built = XanaduTimeline.items(
            usesControlPlane: usesControlPlane,
            selectedThreadID: selected,
            detail: selected.flatMap { threadStore.detail(for: $0) },
            sentRows: Array(sentRows.values),
            records: records
        )
        items = built
        rows = XanaduTimeline.rows(from: built)
    }

    private var onscreenEntity: FinThreadEntity? {
        guard usesControlPlane, let selected = threadStore.selectedThreadID else { return nil }
        let summary = threadStore.selectedThread
        let said = items.filter { $0.kind == .prompt || $0.kind == .reply }
        let lastReply = said.last { $0.kind == .reply }.map { XanaduText.displayText($0.text) }
        let lines = said.suffix(8).map { ($0.kind == .prompt ? "You: " : "Fin: ") + XanaduText.displayText($0.text) }
        return FinThreadEntity(
            id: selected, agentName: agentName,
            title: summary?.displayTitle ?? "Fin thread",
            status: summary?.status.chip.label ?? "unknown",
            lastReply: lastReply,
            recentTranscript: FinThreadEntity.transcriptText(lines)
        )
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshRecords()
        if usesControlPlane {
            await sites.refresh()
            await threadStore.refresh()
            await refreshSelectedDetail()
        }
        rebuild()
    }

    private func refreshSelectedDetail() async {
        guard usesControlPlane, let selected = threadStore.selectedThreadID else { return }
        await threadStore.loadDetail(selected)
    }

    private func refreshRecords() async {
        guard !TestHost.isUnitTest else { return }
        let reader = AgentMirrorReader()
        let name = agentName, id = agentID
        let loaded: [AgentMirrorRecord]
        if isCloudHosted {
            let page = await CloudAgentChannel.fetchTranscriptChunks(agentName: name)
            let mirrored = await Task.detached(priority: .utility) {
                reader.loadRecent(agentName: name, agentID: id, days: 2)
            }.value
            loaded = AgentMirrorReader.merge([page.records, mirrored])
        } else {
            loaded = await Task.detached(priority: .utility) {
                reader.loadRecent(agentName: name, agentID: id)
            }.value
        }
        records = loaded.filter { $0.kind != .notice }
    }
}

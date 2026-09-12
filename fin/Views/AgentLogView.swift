import SwiftUI
import SwiftData

// MARK: - Visual vocabulary

/// One consistent color per event type, used for the icon, the timeline dot, and any
/// chip on the row — so a trajectory can be read by color before any text is parsed.
private extension AgentLogKind {
    var tint: Color {
        switch self {
        case .userMessage: return .blue
        case .assistantMessage: return .indigo
        case .reasoning: return .purple
        case .toolCall: return .teal
        case .toolResult: return .secondary
        case .approval: return .green
        case .notice: return .secondary
        case .error: return .red
        case .turnStarted: return .cyan
        case .turnProgress: return .secondary
        }
    }
}

// MARK: - Root

struct AgentLogView: View {
    let agent: Agent

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [AgentLogEntry]

    @State private var kindFilter: AgentLogKind?
    /// The mission's traces from every body Fin runs in — the cloud transcript's
    /// reasoning, tool calls, results and replies — merged with this device's own
    /// runtime log. Live, 2026-09-12: Logs read only this device's SwiftData rows,
    /// so every filter answered "no matching events" for a mission the iMac
    /// daemon had just run. Never inserted into the store: display-only objects.
    @StateObject private var cloudTraces = CloudTraceStore()
    /// docs/THREADS.md §4: the picker filters runs to those whose lines carry
    /// the selected thread.
    @StateObject private var threadStore = ThreadStore()
    @State private var expandedRuns: Set<UUID> = []
    @State private var didSetInitialExpansion = false
    @State private var exportURL: URL?
    @State private var showingClearConfirmation = false

    init(agent: Agent) {
        self.agent = agent
        let agentID = agent.id
        _entries = Query(
            filter: #Predicate<AgentLogEntry> { $0.agentID == agentID },
            sort: [SortDescriptor(\AgentLogEntry.timestamp, order: .reverse)]
        )
    }

    /// Local runtime rows plus the cloud transcript's, newest first.
    private var allEntries: [LogItem] {
        (entries.map(LogItem.init) + cloudTraces.records.map(LogItem.init(record:)))
            .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if !allEntries.isEmpty {
                    SummaryPanel(runs: runs, entries: allEntries)
                    filterBar
                }
                ForEach(runs) { run in
                    RunCard(
                        run: run,
                        isExpanded: expandedRuns.contains(run.id),
                        toggle: { toggle(run.id) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 14)
        }
        .background(Color.groupedBackground)
        .navigationTitle("Logs")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .overlay { emptyOverlay }
        .confirmationDialog(
            "Clear all logs for this agent?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) { clearLogs() }
        } message: {
            Text("This deletes \(entries.count) recorded event(s). It can't be undone.")
        }
        .sheet(item: $exportURL) { ExportSheet(url: $0) }
        .onAppear { cloudTraces.start(agentName: agent.name); threadStore.start(agentName: agent.name) }
        .onDisappear { cloudTraces.stop(); threadStore.stop() }
        .task {
            guard !didSetInitialExpansion else { return }
            didSetInitialExpansion = true
            // Most recent trajectory open, older ones collapsed — the common case is
            // checking what just happened.
            if let newest = runs.first { expandedRuns.insert(newest.id) }
        }
        .onChange(of: cloudTraces.records.count) { _, _ in
            if expandedRuns.isEmpty, let newest = runs.first { expandedRuns.insert(newest.id) }
        }
    }

    /// The transcript's run id is a string (a UUID from the daemon, "BACKFILL-16"
    /// from a backfill); the log groups by UUID. Deterministic so a refresh keeps
    /// the same run cards.
    static func runUUID(_ raw: String) -> UUID {
        if let uuid = UUID(uuidString: raw) { return uuid }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hi = hash, lo = hash &* 0x9E3779B97F4A7C15
        return UUID(uuid: (
            UInt8(hi >> 56), UInt8(truncatingIfNeeded: hi >> 48), UInt8(truncatingIfNeeded: hi >> 40), UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24), UInt8(truncatingIfNeeded: hi >> 16), UInt8(truncatingIfNeeded: hi >> 8), UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48), UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16), UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: lo)
        ))
    }

    // MARK: Data shaping

    /// Entries grouped into trajectories, newest run first, steps within a run in the
    /// order they actually happened.
    private var runs: [AgentRun] {
        let source = kindFilter.map { filter in allEntries.filter { $0.kind == filter } } ?? allEntries
        var order: [UUID] = []
        var grouped: [UUID: [LogItem]] = [:]
        for entry in source {
            if grouped[entry.runID] == nil { order.append(entry.runID) }
            grouped[entry.runID, default: []].append(entry)
        }
        let all = order.map { id in
            AgentRun(id: id, entries: (grouped[id] ?? []).sorted { $0.sequence < $1.sequence })
        }
        guard let threadID = threadStore.selectedThreadID else { return all }
        let threadOfMessage = threadStore.threadOfMessage
        return all.filter { Self.runCarries(threadID: threadID, entries: $0.entries, threadOfMessage: threadOfMessage) }
    }

    /// A run belongs to a thread when any of its lines names it (`thread_id`),
    /// or its user line's `in_reply_to` resolves to it — the same rule as
    /// `ThreadMembership`, over log rows. Pure.
    static func runCarries(threadID: String, entries: [LogItem], threadOfMessage: [String: String]) -> Bool {
        entries.contains { entry in
            if let explicit = entry.threadID { return explicit == threadID }
            guard let reply = entry.inReplyTo else { return false }
            return (threadOfMessage[reply] ?? reply) == threadID
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedRuns.contains(id) {
                expandedRuns.remove(id)
            } else {
                expandedRuns.insert(id)
            }
        }
    }

    // MARK: Chrome

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if CloudControlPlaneConfig.isConfigured {
                    ThreadPicker(store: threadStore, compact: true)
                        .padding(.trailing, 4)
                }
                FilterChip(title: "All", isOn: kindFilter == nil) { kindFilter = nil }
                ForEach(AgentLogKind.allCases, id: \.self) { kind in
                    FilterChip(
                        title: kind.label,
                        systemImage: kind.systemImage,
                        tint: kind.tint,
                        isOn: kindFilter == kind
                    ) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    expandAll()
                } label: {
                    Label("Expand All", systemImage: "chevron.down.square")
                }
                Button {
                    withAnimation { expandedRuns.removeAll() }
                } label: {
                    Label("Collapse All", systemImage: "chevron.right.square")
                }
                Divider()
                Button {
                    exportJSONL()
                } label: {
                    Label("Export JSONL", systemImage: "square.and.arrow.up")
                }
                .disabled(allEntries.isEmpty)
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(allEntries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if allEntries.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Runs from this agent are recorded here.")
            )
        } else if runs.isEmpty {
            ContentUnavailableView(
                "No Matching Events",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
    }

    private func expandAll() {
        withAnimation { expandedRuns = Set(runs.map(\.id)) }
    }

    private func clearLogs() {
        for entry in entries { modelContext.delete(entry) }
        expandedRuns.removeAll()
    }

    /// Oldest-first, which is the order a training pipeline reads a trajectory in.
    private func exportJSONL() {
        let ordered = allEntries.sorted {
            $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp
        }
        let body = ordered.compactMap(\.jsonl).joined(separator: "\n")
        guard !body.isEmpty else { return }

        let safeName = agent.name.isEmpty
            ? "agent"
            : agent.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-log.jsonl")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
    }
}

// MARK: - Run model

/// One log row for display — a plain value, never a SwiftData object. Both
/// sources map onto it: this device's `AgentLogEntry` rows and the cloud
/// transcript's records. Live, 2026-09-12: holding cloud rows as un-inserted
/// `AgentLogEntry` @Model objects trapped inside SwiftData's @Query observer on
/// the next context save (test host crash, and the same hazard in the app).
struct LogItem: Identifiable {
    let id: UUID
    let runID: UUID
    let sequence: Int
    let timestamp: Date
    let kind: AgentLogKind
    let text: String
    let toolName: String?
    let toolArguments: String?
    let disposition: AgentToolDisposition?
    let serverName: String
    let attempt: Int
    let retryCount: Int
    let isFailure: Bool
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let latencyMS: Int?
    let timeToFirstTokenMS: Int?
    let reasoningMS: Int?
    let toolDurationMS: Int?
    let approvalWaitMS: Int?
    let interTokenMeanMS: Double?
    /// The export line: the stored row's own JSONL, or a plain rendering of a
    /// cloud row.
    let jsonl: String?
    /// Thread membership (docs/THREADS.md §2), from a cloud row's `thread_id`
    /// and `in_reply_to`; nil on this device's own runtime rows.
    var threadID: String?
    var inReplyTo: String?

    init(_ e: AgentLogEntry) {
        id = e.id; runID = e.runID; sequence = e.sequence; timestamp = e.timestamp; kind = e.kind
        text = e.text; toolName = e.toolName; toolArguments = e.toolArguments; disposition = e.disposition
        serverName = e.serverName; attempt = e.attempt; retryCount = e.retryCount; isFailure = e.isFailure
        promptTokens = e.promptTokens; completionTokens = e.completionTokens; totalTokens = e.totalTokens
        latencyMS = e.latencyMS; timeToFirstTokenMS = e.timeToFirstTokenMS; reasoningMS = e.reasoningMS
        toolDurationMS = e.toolDurationMS; approvalWaitMS = e.approvalWaitMS; interTokenMeanMS = e.interTokenMeanMS
        jsonl = e.jsonlLine()
    }

    init(record r: AgentMirrorRecord) {
        id = UUID(uuidString: r.id) ?? AgentLogView.runUUID("line:" + r.id)
        runID = AgentLogView.runUUID(r.runID); sequence = r.sequence; timestamp = r.timestamp; kind = r.kind
        text = r.text; toolName = r.toolName; toolArguments = nil; disposition = nil
        serverName = r.siteName ?? r.siteID8 ?? "cloud"; attempt = 1; retryCount = 0
        isFailure = r.kind == .error
        promptTokens = nil; completionTokens = nil; totalTokens = nil; latencyMS = nil
        timeToFirstTokenMS = nil; reasoningMS = nil; toolDurationMS = nil; approvalWaitMS = nil; interTokenMeanMS = nil
        threadID = r.threadID; inReplyTo = r.inReplyTo
        var object: [String: Any] = [
            "id": r.id, "run_id": r.runID, "sequence": r.sequence, "kind": r.kind.rawValue, "text": r.text,
            "timestamp": AgentMirrorRecord.timestampFormatter.string(from: r.timestamp),
            "site_id8": r.siteID8 ?? "", "site_name": r.siteName ?? "", "tool_name": r.toolName ?? "",
        ]
        if let thread = r.threadID { object["thread_id"] = thread }
        if let reply = r.inReplyTo { object["in_reply_to"] = reply }
        if let target = r.target { object["target"] = target }
        jsonl = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}

private struct AgentRun: Identifiable {
    let id: UUID
    let entries: [LogItem]

    var startedAt: Date { entries.first?.timestamp ?? Date() }
    var serverName: String { entries.first?.serverName ?? "" }

    /// The request that opened this trajectory, used as the card's title.
    var prompt: String {
        entries.first { $0.kind == .userMessage }?.text
            ?? entries.first?.text
            ?? "Run"
    }

    var totalTokens: Int { entries.compactMap(\.totalTokens).reduce(0, +) }
    var toolCallCount: Int { entries.filter { $0.kind == .toolCall }.count }
    var failureCount: Int { entries.filter(\.isFailure).count }
    var retryCount: Int { entries.map(\.retryCount).reduce(0, +) }
    var hasDenial: Bool { entries.contains { $0.disposition == .denied } }

    /// Model time only — approval waits are human time and are reported separately.
    var modelMS: Int { entries.compactMap(\.latencyMS).reduce(0, +) }
    var toolMS: Int { entries.compactMap(\.toolDurationMS).reduce(0, +) }
    var approvalWaitMS: Int { entries.compactMap(\.approvalWaitMS).reduce(0, +) }
    var reasoningMS: Int { entries.compactMap(\.reasoningMS).reduce(0, +) }
}

// MARK: - Summary

private struct SummaryPanel: View {
    let runs: [AgentRun]
    let entries: [LogItem]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Stat(label: "Runs", value: "\(runs.count)")
                Divider().frame(height: 26)
                Stat(label: "Tokens", value: totalTokens > 0 ? totalTokens.compactString : "—")
                Divider().frame(height: 26)
                Stat(label: "Median TTFT", value: ttftLabel)
            }
            Divider()
            HStack(spacing: 0) {
                Stat(label: "Approved", value: "\(approvals)", tint: approvals > 0 ? .green : nil)
                Divider().frame(height: 26)
                Stat(label: "Denied", value: "\(denials)", tint: denials > 0 ? .orange : nil)
                Divider().frame(height: 26)
                Stat(label: "Failures", value: failureLabel, tint: failures > 0 ? .red : nil)
            }
        }
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var totalTokens: Int { entries.compactMap(\.totalTokens).reduce(0, +) }
    private var approvals: Int { entries.filter { $0.disposition == .approved }.count }
    private var denials: Int { entries.filter { $0.disposition == .denied }.count }
    private var failures: Int { entries.filter(\.isFailure).count }
    private var retries: Int { entries.map(\.retryCount).reduce(0, +) }

    private var failureLabel: String {
        retries > 0 ? "\(failures) · \(retries)r" : "\(failures)"
    }

    private var ttftLabel: String {
        let values = entries.compactMap(\.timeToFirstTokenMS).sorted()
        guard !values.isEmpty else { return "—" }
        return "\(values[values.count / 2]) ms"
    }

    private struct Stat: View {
        let label: String
        let value: String
        var tint: Color?

        var body: some View {
            VStack(spacing: 3) {
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Run card

private struct RunCard: View {
    let run: AgentRun
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.leading, 14)
                timeline
            }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(run.failureCount > 0 ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 5) {
                    Text(run.prompt)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? 3 : 2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(run.startedAt, format: .dateTime.month().day().hour().minute())
                        if !run.serverName.isEmpty {
                            Text("·")
                            Text(run.serverName).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    chips
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chips: some View {
        HStack(spacing: 5) {
            if run.totalTokens > 0 {
                MetricChip(icon: "number", text: run.totalTokens.compactString)
            }
            if run.toolCallCount > 0 {
                MetricChip(icon: "wrench.adjustable", text: "\(run.toolCallCount)", tint: .teal)
            }
            if run.modelMS > 0 {
                MetricChip(icon: "clock", text: formatMS(run.modelMS))
            }
            if run.hasDenial {
                MetricChip(icon: "hand.raised.fill", text: "denied", tint: .orange)
            }
            if run.failureCount > 0 {
                MetricChip(
                    icon: "exclamationmark.triangle.fill",
                    text: run.retryCount > 0 ? "\(run.failureCount) · \(run.retryCount)r" : "\(run.failureCount)",
                    tint: .red
                )
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(Array(run.entries.enumerated()), id: \.element.id) { index, entry in
                TraceRow(
                    entry: entry,
                    isFirst: index == 0,
                    isLast: index == run.entries.count - 1
                )
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Trace row

private struct TraceRow: View {
    let entry: LogItem
    let isFirst: Bool
    let isLast: Bool

    @State private var isExpanded = false
    @State private var isArgumentsExpanded = false

    /// Long payloads (tool output, reasoning traces) start collapsed so the shape of a
    /// trajectory stays readable; short ones are shown whole since hiding them would add
    /// a tap for nothing.
    private var isCollapsible: Bool {
        entry.text.count > 180 || entry.text.contains("\n")
    }

    /// `entry.text` for a tool-call row is a hand-written one-line summary (e.g.
    /// "remember: some title"), not the real payload — the model's actual raw JSON
    /// arguments live in `toolArguments` and are shown separately, behind their own
    /// disclosure, so drilling into a step's exact input doesn't depend on the summary
    /// string having been worth writing for every tool.
    private var arguments: String? {
        guard entry.kind == .toolCall, let raw = entry.toolArguments, !raw.isEmpty, raw != "{}" else {
            return nil
        }
        return raw
    }

    private var tint: Color {
        if entry.isFailure { return .red }
        if entry.disposition == .denied { return .orange }
        return entry.kind.tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rail
            content
        }
        .padding(.horizontal, 14)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : Color.secondary.opacity(0.25))
                .frame(width: 1.5, height: 6)
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(isLast ? Color.clear : Color.secondary.opacity(0.25))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            body(for: entry)
            if !metricsLine.isEmpty {
                Text(metricsLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.kind.systemImage)
                .font(.caption2)
            Text(entry.kind.label)
                .font(.caption2.weight(.semibold))
            if let toolName = entry.toolName {
                Text(toolName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let disposition = entry.disposition, disposition != .unguarded {
                DispositionBadge(disposition: disposition)
            }
            if isCollapsible {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .foregroundStyle(tint)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCollapsible else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
    }

    @ViewBuilder
    private func body(for entry: LogItem) -> some View {
        let isCode = entry.kind == .toolCall || entry.kind == .toolResult
        Text(entry.text)
            .font(isCode ? .system(.caption, design: .monospaced) : .callout)
            .foregroundStyle(entry.kind == .reasoning ? .secondary : .primary)
            .lineLimit(isCollapsible && !isExpanded ? 2 : nil)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isCode ? 8 : 0)
            .background(
                isCode ? Color.codeBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        if let arguments {
            argumentsDisclosure(arguments)
        }
    }

    /// The tool-result half of a step (`entry.text` for a `.toolResult` row) is already
    /// the model's full, real output — no summarizing happens there, so it's shown
    /// whole above with no separate disclosure needed. This is the missing other half:
    /// the exact input the model sent, pretty-printed and collapsed by default since
    /// arguments can run long (e.g. a full file write).
    private func argumentsDisclosure(_ raw: String) -> some View {
        DisclosureGroup(isExpanded: $isArgumentsExpanded) {
            Text(ToolCallFormatting.prettyPrinted(raw))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: 6))
        } label: {
            Text("Arguments")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var metricsLine: String {
        var parts: [String] = []
        if let total = entry.totalTokens {
            let up = entry.promptTokens.map { "\($0)↑" }
            let down = entry.completionTokens.map { "\($0)↓" }
            let split = [up, down].compactMap { $0 }.joined(separator: " ")
            parts.append(split.isEmpty ? "\(total) tok" : "\(split) · \(total) tok")
        }
        if let ttft = entry.timeToFirstTokenMS { parts.append("ttft \(ttft)ms") }
        if let itl = entry.interTokenMeanMS, itl > 0 {
            parts.append(String(format: "itl %.0fms", itl))
        }
        if let reasoning = entry.reasoningMS { parts.append("think \(reasoning)ms") }
        if let tool = entry.toolDurationMS { parts.append("tool \(tool)ms") }
        if let wait = entry.approvalWaitMS { parts.append("waited \(formatMS(wait))") }
        if let latency = entry.latencyMS, entry.timeToFirstTokenMS == nil {
            parts.append("\(latency)ms")
        }
        if entry.retryCount > 0 { parts.append("retry \(entry.retryCount)") }
        return parts.joined(separator: "  ")
    }
}

// MARK: - Small pieces

private struct DispositionBadge: View {
    let disposition: AgentToolDisposition

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var text: String {
        switch disposition {
        case .approved: return "approved"
        case .denied: return "denied"
        case .autoExecuted: return "auto"
        case .unguarded: return "read"
        }
    }

    private var tint: Color {
        switch disposition {
        case .approved: return .green
        case .denied: return .orange
        case .autoExecuted: return .blue
        case .unguarded: return .secondary
        }
    }
}

private struct MetricChip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

private struct FilterChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accentColor
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10))
                }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isOn ? tint.opacity(0.9) : Color.cardBackground,
                in: Capsule()
            )
            .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct ExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                Text("One JSON object per event, oldest first, grouped by run_id.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Share Export", systemImage: "square.and.arrow.up")
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

// MARK: - Helpers

private func formatMS(_ milliseconds: Int) -> String {
    milliseconds >= 1000
        ? String(format: "%.1fs", Double(milliseconds) / 1000)
        : "\(milliseconds)ms"
}

private extension Int {
    /// Keeps token counts from crowding a chip once they run to five digits.
    var compactString: String {
        self >= 10_000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}

private extension Color {
    /// Platform-appropriate surfaces so cards stay legible in both light and dark without
    /// hardcoding either theme's values.
    static var groupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.6)
        #else
        Color(uiColor: .tertiarySystemGroupedBackground)
        #endif
    }
}

/// `sheet(item:)` needs an `Identifiable`; a file URL is a natural identity here.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

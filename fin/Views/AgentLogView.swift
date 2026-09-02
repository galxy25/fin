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
        }
    }
}

// MARK: - Root

struct AgentLogView: View {
    let agent: Agent

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [AgentLogEntry]

    @State private var kindFilter: AgentLogKind?
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if !entries.isEmpty {
                    SummaryPanel(runs: runs, entries: entries)
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
        .task {
            guard !didSetInitialExpansion else { return }
            didSetInitialExpansion = true
            // Most recent trajectory open, older ones collapsed — the common case is
            // checking what just happened.
            if let newest = runs.first { expandedRuns.insert(newest.id) }
        }
    }

    // MARK: Data shaping

    /// Entries grouped into trajectories, newest run first, steps within a run in the
    /// order they actually happened.
    private var runs: [AgentRun] {
        let source = kindFilter.map { filter in entries.filter { $0.kind == filter } } ?? entries
        var order: [UUID] = []
        var grouped: [UUID: [AgentLogEntry]] = [:]
        for entry in source {
            if grouped[entry.runID] == nil { order.append(entry.runID) }
            grouped[entry.runID, default: []].append(entry)
        }
        return order.map { id in
            AgentRun(id: id, entries: (grouped[id] ?? []).sorted { $0.sequence < $1.sequence })
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
                .disabled(entries.isEmpty)
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if entries.isEmpty {
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
        let ordered = entries.sorted {
            $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp
        }
        let body = ordered.compactMap { $0.jsonlLine() }.joined(separator: "\n")
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

private struct AgentRun: Identifiable {
    let id: UUID
    let entries: [AgentLogEntry]

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
    let entries: [AgentLogEntry]

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
    let entry: AgentLogEntry
    let isFirst: Bool
    let isLast: Bool

    @State private var isExpanded = false

    /// Long payloads (tool output, reasoning traces) start collapsed so the shape of a
    /// trajectory stays readable; short ones are shown whole since hiding them would add
    /// a tap for nothing.
    private var isCollapsible: Bool {
        entry.text.count > 180 || entry.text.contains("\n")
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
    private func body(for entry: AgentLogEntry) -> some View {
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

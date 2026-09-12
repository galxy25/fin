import SwiftUI

/// docs/THREADS.md §4: the thread selector shown everywhere the current
/// transcript is — a `Menu` of "All activity" plus one row per thread with its
/// status chip, title, and relative time. The hidden "Thread debug" item (and a
/// long press on the label, where the platform lets a Menu take one) opens the
/// raw events tail so a wrong status is diagnosable on the phone.
struct ThreadPicker: View {
    @ObservedObject var store: ThreadStore
    /// Compact: chip glyph and a short title, for a header strip. Otherwise the
    /// full label with the chip's words.
    var compact = false

    @State private var showsDebug = false

    var body: some View {
        Menu {
            Button {
                store.select(nil)
            } label: {
                Label("All activity", systemImage: store.selectedThreadID == nil ? "checkmark" : "list.bullet")
            }
            if !store.threads.isEmpty { Divider() }
            ForEach(store.threads) { thread in
                Button {
                    store.select(thread.threadId)
                } label: {
                    Label {
                        Text(Self.menuTitle(thread))
                    } icon: {
                        Image(systemName: store.selectedThreadID == thread.threadId ? "checkmark" : thread.status.chip.systemImage)
                    }
                }
            }
            if store.threads.isEmpty {
                Text(store.isAvailable ? "No threads yet" : "Threads need the control plane")
            }
            Divider()
            Button {
                showsDebug = true
            } label: {
                Label("Thread debug", systemImage: "ladybug")
            }
            .disabled(store.selectedThreadID == nil)
        } label: {
            label
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("threadPicker")
        #if os(iOS) || os(visionOS)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.7).onEnded { _ in
            if store.selectedThreadID != nil { showsDebug = true }
        })
        #endif
        .sheet(isPresented: $showsDebug) {
            if let id = store.selectedThreadID {
                ThreadDebugSheet(store: store, threadID: id)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if let thread = store.selectedThread {
                let chip = thread.status.chip
                Image(systemName: chip.systemImage)
                    .foregroundStyle(chip.color)
                Text(compact ? Self.shortTitle(thread.displayTitle) : thread.displayTitle)
                    .lineLimit(1)
                if !compact {
                    Text(chip.label)
                        .foregroundStyle(.secondary)
                }
            } else if let id = store.selectedThreadID {
                Image(systemName: "number")
                Text("thread \(id.prefix(8))")
                    .lineLimit(1)
            } else {
                Image(systemName: "list.bullet")
                Text("All activity")
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.medium))
    }

    /// "waiting on you · Check the deploy… · 4 min ago". Pure so the chip →
    /// words mapping is testable.
    static func menuTitle(_ thread: ThreadSummary, now: Date = Date()) -> String {
        var parts = [thread.status.chip.label, shortTitle(thread.displayTitle)]
        if let at = thread.lastActivityAt ?? thread.createdAt {
            parts.append(relative(at, now: now))
        }
        return parts.joined(separator: " · ")
    }

    static func shortTitle(_ title: String, limit: Int = 40) -> String {
        let flat = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

extension ThreadChip {
    var color: Color {
        switch tint {
        case .orange: return .orange
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .gray: return .gray
        }
    }
}

/// A status chip: glyph + words, tinted. Used by the picker's rows, the hub
/// sidebar and the console's thread items.
struct ThreadChipView: View {
    let chip: ThreadChip
    var body: some View {
        Label(chip.label, systemImage: chip.systemImage)
            .font(.caption2)
            .foregroundStyle(chip.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chip.color.opacity(0.12), in: Capsule())
    }
}

/// The instrumentation surface for the first iterations (docs/THREADS.md §4):
/// the raw `/threads/{id}/events` tail — seq, at, kind, actor, detail JSON —
/// with a refresh button. Read-only; nothing here is pretty on purpose.
struct ThreadDebugSheet: View {
    @ObservedObject var store: ThreadStore
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @State private var events: [ThreadEvent] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("thread", value: threadID)
                    if let thread = store.selectedThread, thread.threadId == threadID {
                        LabeledContent("status", value: thread.status.rawValue)
                        LabeledContent("messages", value: "\(thread.messageCount)")
                        LabeledContent("participants", value: thread.participants.joined(separator: ", "))
                        if let goal = thread.openGoal { LabeledContent("openGoal", value: goal) }
                    }
                    if let error {
                        Text(error).foregroundStyle(.orange)
                    }
                }
                Section("events (\(events.count))") {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(event.seq)").monospacedDigit()
                                Text(event.kind).fontWeight(.medium)
                                Spacer()
                                Text(event.actor).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            if let at = event.at {
                                Text(at.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(event.detailText)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Thread debug")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isLoading)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Cached detail first so the sheet is never blank, then the live tail.
        if events.isEmpty, let detail = store.detail(for: threadID) { events = detail.events }
        switch await store.events(for: threadID) {
        case .success(let fetched): events = fetched; error = nil
        case .failure(let failure):
            switch failure {
            case .notConfigured: error = "control plane not configured"
            case .network: error = "network error"
            case .http(let status, let message): error = "HTTP \(status): \(message)"
            }
        }
    }
}

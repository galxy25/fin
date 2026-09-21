#if os(macOS) || os(visionOS)
import SwiftUI
import SwiftData

/// The macOS replacement for `AgentHubView`'s push-stack: one agent's whole world
/// (settings, logs/traces, memory, remote conversation, artifacts, SSH key) as a
/// standalone, resizable window with a sidebar, opened via
/// `openWindow(id: FinScene.agentHub, value: agent.id)`.
///
/// Why a separate window rather than `NavigationSplitView` pushed inside the terminal
/// window: the terminal session and an agent's logs/traces are two things worth
/// looking at side by side on a Mac — a sheet or in-window split can't sit next to the
/// terminal window the way a second real window can. The sidebar inside THIS window is
/// the progressive-disclosure layer for the agent's own sections; it doesn't need to
/// be its own window per section, since those sections aren't things you'd want open
/// simultaneously the way "the session" and "its agent" are.
struct AgentHubWindowView: View {
    /// From `WindowGroup(for: UUID.self)`'s binding — optional because macOS can
    /// restore a window from state restoration before the value round-trips, and
    /// because `openWindow` itself takes a plain (non-optional) UUID.
    let agentID: UUID?

    @EnvironmentObject private var sessionManager: SessionManager
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @State private var selection: HubSection? = .settings
    /// Answered threads stay reachable but collapsed — see the sidebar section.
    @State private var showingAnsweredThreads = false
    /// docs/THREADS.md §4: the "Threads" sidebar section — one row per open
    /// thread, selecting one opens the conversation filtered to it.
    @StateObject private var threadStore = ThreadStore()
    /// The thread a swipe-to-delete confirmation is pending for.
    @State private var threadPendingDelete: ThreadSummary?

    private enum HubSection: Hashable {
        case settings, logs, memory, remote, artifacts, key
        /// The conversation, filtered to one thread.
        case thread(String)

        var title: String {
            switch self {
            case .settings: return "Settings"
            case .logs: return "Logs & Traces"
            case .memory: return "Memory"
            case .remote: return CloudControlPlaneConfig.isConfigured ? "Conversation" : "Remote"
            case .artifacts: return "Artifacts"
            case .key: return "Fin's Key"
            case .thread: return "Thread"
            }
        }

        var systemImage: String {
            switch self {
            case .settings: return "gearshape"
            case .logs: return "list.bullet.rectangle"
            case .memory: return "brain"
            case .remote: return CloudControlPlaneConfig.isConfigured ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right"
            case .artifacts: return "externaldrive"
            case .key: return "key"
            case .thread: return "number"
            }
        }
    }

    /// A plain lookup, not a filtered `@Query` predicate — mirrors the same
    /// find-by-id-in-memory pattern `RootView`/`ControlStripView` already use for
    /// notification-tap routing, and sidesteps building a `#Predicate` around a
    /// captured optional `UUID`.
    private var agent: Agent? {
        guard let agentID else { return nil }
        return agents.first { $0.id == agentID }
    }

    var body: some View {
        if let agent {
            // Plain HStack, NOT NavigationSplitView. Live-tested (both via automation
            // and directly by hand): with NavigationSplitView here, Settings' Form
            // failed to scroll past the Limits section — real, human-confirmed, not
            // just a static-analysis guess — and a separate live test showed the
            // window's content vanishing on some interactions. NavigationSplitView is
            // a comparatively new API; on this Mac's bleeding-edge macOS/Xcode this
            // combination (secondary WindowGroup(for:) scene + NavigationSplitView +
            // Form) is unreliable enough that removing it is the more trustworthy
            // fix than continuing to patch around it.
            HStack(spacing: 0) {
                sidebar(for: agent)
                    .frame(width: 220)
                Divider()
                detail(for: agent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 760, minHeight: 480)
            .onAppear { ScreenshotFixtures.sizeWindowForCapture(width: 1440, height: 900) }
            // No identifier on this HStack itself: it has no AX surface of its own,
            // and live-testing showed SwiftUI on macOS hoists an ancestor's
            // `.accessibilityIdentifier` onto the nearest accessible descendant —
            // here, the sidebar's own List — silently overwriting `hubSidebar`
            // below it. Each accessible piece (sidebar, detail content) keeps its
            // own identifier instead of the container claiming one too.
        } else {
            // Reachable if the agent was deleted (on this or another synced device)
            // while this window was still open, or during state restoration before
            // CloudKit's import has landed the record yet.
            // Live, 2026-09-12: macOS restored ONLY this window after an update, for
            // an agent that no longer existed (a screenshot fixture, since cleaned
            // up) — the app opened to a blank "Agent Not Found" with no way in.
            // Give CloudKit a moment to land the record, then open the main window
            // and close this one.
            OrphanedWindowView(
                title: "Agent Not Found",
                description: "This agent may have been deleted."
            )
        }
    }

    private func sidebar(for agent: Agent) -> some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.settings)
            }
            Section("What's going on") {
                sidebarRow(.logs)
                sidebarRow(.memory)
                if sessionManager.isRemotelyHosted(agent) || CloudControlPlaneConfig.isConfigured {
                    sidebarRow(.remote)
                }
                sidebarRow(.artifacts)
            }
            if threadStore.isAvailable {
                Section("Threads") {
                    if threadStore.openThreads.isEmpty {
                        Text(threadStore.lastFetchAt == nil ? "Loading…" : "No open threads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(threadStore.openThreads) { thread in
                        threadRow(thread)
                    }
                }
                // Answered threads are still conversations. They used to leave the sidebar
                // the instant Fin replied, which made an answered thread unreachable from
                // this window — the question gone along with the answer. Collapsed by
                // default so the open work stays at the top, where it was.
                if !threadStore.answeredThreads.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingAnsweredThreads) {
                            ForEach(threadStore.answeredThreads.prefix(20)) { thread in
                                threadRow(thread)
                            }
                        } label: {
                            Text("Answered (\(threadStore.answeredThreads.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                sidebarRow(.key)
            }
        }
        .accessibilityIdentifier("hubSidebar")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        .task(id: agent.name) { threadStore.start(agentName: agent.name) }
        .onDisappear { threadStore.stop() }
        .alert(
            "Delete this thread?",
            isPresented: Binding(get: { threadPendingDelete != nil }, set: { if !$0 { threadPendingDelete = nil } }),
            presenting: threadPendingDelete
        ) { thread in
            Button("Delete", role: .destructive) {
                Task { await threadStore.delete(thread.threadId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { thread in
            Text("\"\(thread.displayTitle)\" and everything in it will be gone for good.")
        }
    }

    private func threadRow(_ thread: ThreadSummary) -> some View {
        let chip = thread.status.chip
        return HStack(spacing: 6) {
            Image(systemName: chip.systemImage)
                .foregroundStyle(chip.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(ThreadPicker.shortTitle(thread.displayTitle, limit: 32))
                    .lineLimit(1)
                Text(chip.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(HubSection.thread(thread.threadId))
        .accessibilityIdentifier("hubSidebarThread_\(thread.threadId.prefix(8))")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                threadPendingDelete = thread
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if thread.status.isRetryable {
                Button {
                    Task { await threadStore.retry(thread.threadId) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
    }

    /// One sidebar row, identified for UI-test/automation drive-through
    /// (`hubSidebarRow_settings`, `hubSidebarRow_logs`, …) — a stable hook that
    /// doesn't depend on localized title text.
    private func sidebarRow(_ section: HubSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
            .accessibilityIdentifier("hubSidebarRow_\(section)")
    }

    /// Wrapped in its own `NavigationStack` per selection — `NavigationSplitView`'s
    /// detail column is documented to want one (it's what gives a pushed
    /// destination, like Settings' "Connected Services"/"Fin's Key" links, a place
    /// to push into, and what supplies `.navigationTitle`/`.toolbar` a real
    /// navigation context). Without it, `AgentEditView`'s bare `Form` had no bounded
    /// scroll container to size against and simply clipped instead of scrolling —
    /// this is also what fixes that.
    @ViewBuilder
    private func detail(for agent: Agent) -> some View {
        NavigationStack {
            // THE SIDEBAR'S CONDITION AND THIS ONE MUST BE THE SAME EXPRESSION.
            // They drifted: the row is offered when the agent is remotely hosted OR a
            // control plane is configured, while this switch asked only about hosting and
            // fell back to `AgentEditView` — so with a control plane and no CloudKit-style
            // hosting, tapping "Conversation" rendered the SETTINGS screen. Reported as
            // "conversation is a dupe of the settings screen", and it was exactly that.
            // The comment that used to sit here asserted `.remote` was unreachable unless
            // hosted, which stopped being true the day the control-plane clause was added
            // to the sidebar; an assertion in a comment does not hold itself up.
            //
            // The fallback still exists, because hosting really can flip in the background
            // (an in-flight migration, another device changing it) while this window sits
            // on the selection — but it now says so instead of impersonating another screen.
            switch selection ?? .settings {
            case .settings:
                AgentEditView(agent: agent)
            case .logs:
                AgentLogView(agent: agent)
            case .memory:
                AgentMemoryView(agent: agent)
            case .remote:
                if sessionManager.isRemotelyHosted(agent) || CloudControlPlaneConfig.isConfigured {
                    AgentRemoteConsoleView(agent: agent)
                } else {
                    ContentUnavailableView(
                        "No conversation here",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("This agent isn\u{2019}t hosted on another device and no control "
                            + "plane is configured, so there is no shared conversation to show.")
                    )
                }
            case .artifacts:
                ArtifactsView()
            case .key:
                AgentKeyView()
            case .thread(let threadID):
                // `.id` so picking another thread rebuilds the console with the new
                // preselection rather than reusing the first one's state.
                AgentRemoteConsoleView(agent: agent, initialThreadID: threadID)
                    .id(threadID)
            }
        }
    }
}
/// A secondary window whose subject is gone: wait briefly for sync, then open
/// the main window and dismiss this one. A button does the same immediately.
struct OrphanedWindowView: View {
    let title: String
    let description: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "questionmark.circle")
        } description: {
            Text(description)
        } actions: {
            Button("Open Fin") { recover() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("orphanedWindowOpenFin")
        }
        .frame(minWidth: 480, minHeight: 320)
        .task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            recover()
        }
    }

    private func recover() {
        openWindow(id: FinScene.main)
        dismissWindow()
    }
}

#endif

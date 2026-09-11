#if os(macOS)
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

    private enum HubSection: Hashable, CaseIterable {
        case settings, logs, memory, remote, artifacts, key

        var title: String {
            switch self {
            case .settings: return "Settings"
            case .logs: return "Logs & Traces"
            case .memory: return "Memory"
            case .remote: return "Remote"
            case .artifacts: return "Artifacts"
            case .key: return "Fin's Key"
            }
        }

        var systemImage: String {
            switch self {
            case .settings: return "gearshape"
            case .logs: return "list.bullet.rectangle"
            case .memory: return "brain"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .artifacts: return "externaldrive"
            case .key: return "key"
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
            NavigationSplitView {
                sidebar(for: agent)
            } detail: {
                detail(for: agent)
            }
            .navigationTitle(agent.name.isEmpty ? "Agent" : agent.name)
            // Same lesson as HomeView's sheet-collapse fix: an explicit minimum keeps
            // this window from opening too small to be useful on first launch.
            .frame(minWidth: 760, minHeight: 480)
        } else {
            // Reachable if the agent was deleted (on this or another synced device)
            // while this window was still open, or during state restoration before
            // CloudKit's import has landed the record yet.
            ContentUnavailableView(
                "Agent Not Found",
                systemImage: "questionmark.circle",
                description: Text("This agent may have been deleted.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }

    private func sidebar(for agent: Agent) -> some View {
        List(selection: $selection) {
            Section {
                Label(HubSection.settings.title, systemImage: HubSection.settings.systemImage)
                    .tag(HubSection.settings)
            }
            Section("What's going on") {
                Label(HubSection.logs.title, systemImage: HubSection.logs.systemImage)
                    .tag(HubSection.logs)
                Label(HubSection.memory.title, systemImage: HubSection.memory.systemImage)
                    .tag(HubSection.memory)
                if sessionManager.isRemotelyHosted(agent) {
                    Label(HubSection.remote.title, systemImage: HubSection.remote.systemImage)
                        .tag(HubSection.remote)
                }
                Label(HubSection.artifacts.title, systemImage: HubSection.artifacts.systemImage)
                    .tag(HubSection.artifacts)
            }
            Section {
                Label(HubSection.key.title, systemImage: HubSection.key.systemImage)
                    .tag(HubSection.key)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    @ViewBuilder
    private func detail(for agent: Agent) -> some View {
        // `.remote` can only be reached while `isRemotelyHosted` is true (it's the only
        // way the sidebar row appears) — but hosting can flip in the background (an
        // in-flight migration, another device changing it) while this window sits on
        // that selection, so the fallback isn't dead code.
        switch selection ?? .settings {
        case .settings:
            AgentEditView(agent: agent)
        case .logs:
            AgentLogView(agent: agent)
        case .memory:
            AgentMemoryView(agent: agent)
        case .remote:
            if sessionManager.isRemotelyHosted(agent) {
                AgentRemoteConsoleView(agent: agent)
            } else {
                AgentEditView(agent: agent)
            }
        case .artifacts:
            ArtifactsView()
        case .key:
            AgentKeyView()
        }
    }
}
#endif

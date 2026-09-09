import SwiftUI

/// The one-tap-away home for everything about one agent — settings, logs, memory, the
/// remote conversation (when hosted elsewhere), and the shared artifacts store.
///
/// Replaces `AgentEditView` as `AgentListView`'s row destination. Logs, memory, and the
/// remote conversation used to be reachable ONLY behind a leading swipe on the agent
/// row — a real, reported gap ("when the user wants to see logs we shouldn't be hiding
/// away what the cloud agent is up to"). Everything here is one tap from the list, not
/// a swipe-gesture guess.
struct AgentHubView: View {
    let agent: Agent

    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AgentEditView(agent: agent)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            Section {
                NavigationLink {
                    AgentLogView(agent: agent)
                } label: {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    AgentMemoryView(agent: agent)
                } label: {
                    Label("Memory", systemImage: "brain")
                }
                if sessionManager.isRemotelyHosted(agent) {
                    NavigationLink {
                        AgentRemoteConsoleView(agent: agent)
                    } label: {
                        Label("Remote", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                NavigationLink {
                    ArtifactsView()
                } label: {
                    Label("Artifacts", systemImage: "externaldrive")
                }
            } header: {
                Text("What's going on")
            } footer: {
                Text("Logs and memory are this agent's own. Artifacts are a shared "
                    + "space every agent can read and write, not scoped to just this one.")
            }
        }
        .navigationTitle(agent.name.isEmpty ? "Agent" : agent.name)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

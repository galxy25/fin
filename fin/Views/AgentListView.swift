import SwiftUI
import SwiftData

struct AgentListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var sessionManager: SessionManager
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    var body: some View {
        List {
            ForEach(agents) { agent in
                // One NavigationLink per row, with the log reachable from a swipe action.
                // Two links in a single row is unsupported by List and mis-routes taps.
                NavigationLink {
                    AgentEditView(agent: agent)
                } label: {
                    AgentRow(agent: agent)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    NavigationLink {
                        AgentLogView(agent: agent)
                    } label: {
                        Label("Logs", systemImage: "list.bullet.rectangle")
                    }
                    .tint(.indigo)
                    NavigationLink {
                        AgentMemoryView(agent: agent)
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                    .tint(.teal)
                    // Whenever this device holds no live runtime: the mirror
                    // view and relay compose work regardless of arming, and
                    // requiring armed-elsewhere left unarmed conversations
                    // unreachable from other devices (live UX failure).
                    if isRemotelyHosted(agent) {
                        NavigationLink {
                            AgentRemoteConsoleView(agent: agent)
                        } label: {
                            Label("Remote", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tint(.blue)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    let agent = agents[index]
                    KeychainStore.deleteAgentAPIKey(for: agent.id)
                    // The agent's semantic index files (plaintext memory text) go
                    // with it — no self-heal pass can ever run for a deleted agent.
                    AgentMemoryIndexRegistry.destroyIndex(agent.id)
                    modelContext.delete(agent)
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Inserted only — the new row appears in the list and the user taps
                    // into it. Programmatic navigation to a just-inserted model is what
                    // makes this path fragile.
                    modelContext.insert(Agent(name: "New Agent"))
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if agents.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "sparkles",
                    description: Text("Tap + to connect a model endpoint.")
                )
            }
        }
        .task {
            seedDefaultAgentIfNeeded()
            // Agents still carrying a stock prompt from an earlier build get the current
            // one; anything the user edited is left untouched. The heartbeat upgrade is
            // the same shape: one-shot 0→60 for pre-default agents, then hands off.
            for agent in agents {
                agent.upgradeStockPromptIfNeeded()
                agent.upgradeHeartbeatDefaultIfNeeded()
            }
        }
    }

    /// An armed monitor whose home device is some other install AND no live
    /// runtime here: only then is the conversation provably elsewhere. The
    /// local-runtime check closes the applier's sender-side hole — a device
    /// holding its own live runtime for the agent must not offer the remote
    /// composer, whose relayed message would be injected into THIS device's
    /// separate transcript rather than the conversation the view displays.
    private func isRemotelyHosted(_ agent: Agent) -> Bool {
        // A cloud-hosted agent is remote by definition — no device ever holds
        // its runtime, so the residence checks below don't apply.
        if !agent.hostsLocally { return true }
        // Armed-here means the conversation is (or resumes) local; anything
        // else without a live local runtime is viewable remotely.
        if sessionManager.hasLiveRuntime(agentID: agent.id) { return false }
        if agent.monitoringArmed, agent.monitoringDeviceID == DeviceIdentity.id { return false }
        return true
    }

    /// Ships one agent named Fin that works out of the box on capable hardware — Apple's
    /// on-device model needs no endpoint, no key, and no account. Everything about it is
    /// editable, including the provider, so it's a starting point rather than a fixture.
    private func seedDefaultAgentIfNeeded() {
        guard agents.isEmpty else { return }
        modelContext.insert(
            Agent(
                name: "Fin",
                provider: .appleOnDevice,
                contextWindowTokens: 8192,
                defaultMode: .manual
            )
        )
    }
}

/// Small green antenna shown only while remote supervision is live and healthy —
/// enabled, last poll succeeded, and it happened within the last 90 seconds. Green
/// on purpose (the user's explicit choice), not a themed variant. Re-reads health
/// on the channel's config and poll-outcome notifications, so it lights up and goes
/// dark without the hosting view doing anything.
struct RemoteSupervisionBadge: View {
    @State private var healthy = RemoteSupervisionConfig.isHealthy()

    var body: some View {
        Group {
            if healthy {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Remote supervision active")
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: RemoteSupervisionConfig.changedNotification
        )) { _ in healthy = RemoteSupervisionConfig.isHealthy() }
        .onReceive(NotificationCenter.default.publisher(
            for: RemoteSupervisionConfig.pollOutcomeNotification
        )) { _ in healthy = RemoteSupervisionConfig.isHealthy() }
    }
}

private struct AgentRow: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(agent.name.isEmpty ? "Untitled Agent" : agent.name)
                    .font(.headline)
                Image(systemName: agent.defaultMode.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if agent.monitoringArmed {
                    Image(systemName: "binoculars.fill")
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .accessibilityLabel("Monitoring armed")
                }
                RemoteSupervisionBadge()
            }
            HStack(spacing: 5) {
                Image(systemName: agent.provider.systemImage)
                    .font(.caption2)
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            if let warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }
        }
    }

    private var subtitle: String {
        switch agent.provider {
        case .appleOnDevice:
            return "Apple on-device model"
        case .openAICompatible:
            let model = agent.modelIdentifier.trimmingCharacters(in: .whitespaces)
            let host = URL(string: agent.endpointURL.trimmingCharacters(in: .whitespaces))?.host
            switch (model.isEmpty, host) {
            case (false, let host?): return "\(model) · \(host)"
            case (false, nil): return model
            case (true, let host?): return host
            case (true, nil): return "Not configured"
            }
        }
    }

    private var warning: String? {
        switch agent.provider {
        case .appleOnDevice:
            return AppleOnDeviceBackend.availability.message
        case .openAICompatible:
            return agent.isRunnable ? nil : "Needs an endpoint and model."
        }
    }
}

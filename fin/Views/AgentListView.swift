import SwiftUI
import SwiftData

struct AgentListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    // Reaching this list at all means either the standalone `.home` window or a
    // sheet presented over a terminal session (`ControlStripView`'s server-rack
    // button) — dismissing after opening the hub window matches ServerListView's own
    // "connect, then get out of the way" behavior for the sheet case, and is a no-op
    // when there's nothing presented to dismiss (the `.home` window case).
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        List {
            ForEach(agents) { agent in
                // The row's single tap target is the per-agent hub — settings, logs,
                // memory, remote conversation, and artifacts are all one tap away from
                // there instead of behind a leading-swipe secret.
                #if os(macOS)
                // A NavigationLink push here would still work, but a Mac has room for
                // the hub to be its own resizable window beside the terminal session —
                // see AgentHubWindowView.
                Button {
                    openWindow(id: FinScene.agentHub, value: agent.id)
                    dismiss()
                } label: {
                    AgentRow(agent: agent)
                }
                .buttonStyle(.plain)
                #else
                NavigationLink {
                    AgentHubView(agent: agent)
                } label: {
                    AgentRow(agent: agent)
                }
                #endif
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

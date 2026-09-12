import SwiftUI
import SwiftData

/// Read-only window into what the agent remembers: the cumulative user profile it
/// injects into every conversation, and this agent's recent episodic memories.
///
/// Deliberately not an editor — memories are written by the runtime (auto-digest,
/// the remember tool, consolidation) and hand-editing them would put the store and
/// the audit trail out of agreement. The lookback is the agent's own setting
/// (memoryViewDays) so a long-running agent can be reviewed at whatever horizon
/// its owner cares about.
struct AgentMemoryView: View {
    let agent: Agent

    @Query private var memories: [AgentMemory]
    /// What Fin's computers reported in their last heartbeat — the dated,
    /// observed half of memory, next to the distilled profile. Fed by the same
    /// `SiteDirectory` cache the console and servers list use; renders nothing
    /// (not even a spinner) when no control plane is configured, so the
    /// store-only render tests stay honest.
    @ObservedObject private var sites = SiteDirectory.shared

    init(agent: Agent) {
        self.agent = agent
        _memories = Query(sort: \AgentMemory.updatedAt, order: .reverse)
    }

    private var cumulative: AgentMemory? {
        // Oldest-created is the canonical profile record, matching MemoryStore's
        // convergence rule for duplicates.
        memories
            .filter { $0.kind == .cumulative }
            .min(by: { $0.createdAt < $1.createdAt })
    }

    private var recentEpisodic: [AgentMemory] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(agent.memoryViewDays, 1),
            to: Date()
        ) ?? .distantPast
        return memories.filter {
            $0.kind == .episodic && $0.agentID == agent.id && $0.updatedAt >= cutoff
        }
    }

    var body: some View {
        List {
            Section {
                if let cumulative, !cumulative.content.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cumulative.content)
                            .font(.callout)
                            .textSelection(.enabled)
                        Text("Updated \(cumulative.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No profile yet — it builds up as conversations are consolidated.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("User Profile")
            } footer: {
                Text("Distilled from recent conversations across all agents and injected "
                    + "into every system prompt.")
            }

            if CloudControlPlaneConfig.isConfigured {
                Section {
                    if sites.sites.isEmpty {
                        Text(sites.lastError.map { "Couldn't reach the control plane: \($0)" }
                            ?? "No computers have checked in yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sites.sites.filter { $0.state != "retired" }) { site in
                            siteRow(site)
                        }
                    }
                } header: {
                    Text("What Fin Sees Right Now")
                } footer: {
                    Text("Each computer Fin lives on reports what its terminal sessions are doing. "
                        + "This is observed, dated, and folded into the profile above; the panes "
                        + "themselves are the freshest signal.")
                }
                .accessibilityIdentifier("memoryRightNowSection")
            }

            Section {
                if recentEpisodic.isEmpty {
                    Text("No conversations remembered in the last \(agent.memoryViewDays) days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentEpisodic) { memory in
                        episodicRow(memory)
                    }
                }
            } header: {
                Text("Conversations — last \(agent.memoryViewDays) days")
            } footer: {
                Text("The lookback window is set per agent in its settings.")
            }
        }
        .navigationTitle("Memory")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard CloudControlPlaneConfig.isConfigured else { return }
            await sites.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await sites.refresh()
            }
        }
    }

    /// One computer: name, status, and one line per tmux pane naming what it is
    /// doing (the pane title, which coding agents set to their current task),
    /// plus any model-written session note. Display names only — never a host
    /// or an id.
    private func siteRow(_ site: FinSite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: site.kindGlyph)
                    .font(.caption)
                    .foregroundStyle(site.live ? Color.green : Color.secondary)
                Text(site.displayName)
                    .font(.subheadline.weight(.medium))
                Text("· \(site.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let at = site.lastHeartbeatAt {
                    Text(at.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            let sessions = site.capabilities.tmuxSessions ?? []
            if sessions.isEmpty {
                Text(site.live ? "No terminal sessions reported." : "Last report is stale.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(sessions, id: \.session) { session in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.panes ?? [], id: \.target) { pane in
                        HStack(alignment: .top, spacing: 6) {
                            Text(pane.target)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(paneSummary(pane))
                                .font(.caption)
                        }
                    }
                    if (session.panes ?? []).isEmpty {
                        Text("tmux \(session.session)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let note = session.activityNote, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("memorySite_\(site.siteId8)")
    }

    private func paneSummary(_ pane: FinSite.Capabilities.TmuxSession.Pane) -> String {
        var parts: [String] = []
        if let cwd = pane.cwd, let last = cwd.split(separator: "/").last { parts.append(String(last)) }
        if let title = pane.title, !title.isEmpty { parts.append(title) }
        else if let command = pane.command, !command.isEmpty { parts.append(command) }
        return parts.isEmpty ? "idle shell" : parts.joined(separator: " — ")
    }

    private func episodicRow(_ memory: AgentMemory) -> some View {
        DisclosureGroup {
            Text(memory.content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.title.isEmpty ? "Untitled conversation" : memory.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(memory.updatedAt.formatted(.relative(presentation: .named)))
                    if memory.stoppedAt == nil {
                        Text("· open")
                    }
                    if !memory.tags.isEmpty {
                        Text("· \(memory.tags)")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

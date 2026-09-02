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

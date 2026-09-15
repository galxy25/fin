import SwiftUI
import SwiftData

/// This agent's recent episodic memories — the conversations it remembers having.
///
/// These used to live in the Memory screen, under the cumulative profile. They were moved
/// here (2026-09-15) because Memory answers "what does Fin know about me", a distilled and
/// mostly static thing, while these are *conversations* — the same kind of object the
/// Conversation screen is about, one screen away from the live one. Memory keeps the
/// profile and the live per-computer picture; this is reached from the conversation it
/// belongs beside.
///
/// Read-only on purpose, as it was in Memory: memories are written by the runtime (the
/// auto-digest, the `remember` tool, consolidation), and hand-editing them would put the
/// store and the audit trail out of agreement.
struct RememberedConversationsView: View {
    let agent: Agent

    @Environment(\.dismiss) private var dismiss
    @Query private var memories: [AgentMemory]

    init(agent: Agent) {
        self.agent = agent
        _memories = Query(sort: \AgentMemory.updatedAt, order: .reverse)
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
        NavigationStack {
            List {
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
                } footer: {
                    Text("Written by the runtime as conversations happen. The lookback window "
                        + "is set per agent in its settings.")
                }
            }
            .navigationTitle("Remembered")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("rememberedConversations")
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

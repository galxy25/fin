import Foundation

/// Xanadu's transcript: the SAME merge every thread view uses
/// (`ThreadMembership` for the transcript's turns, `ThreadTimeline.build` for
/// rows + records + events), folded for a conversation pane — the work in
/// between (reasoning, tool calls, pane relays) collapses into one "N steps"
/// row between what was said. Pure, so the folding is testable.
enum XanaduTimeline {
    enum Row: Identifiable, Equatable {
        case said(ThreadItem)
        case steps(id: String, items: [ThreadItem])

        var id: String {
            switch self {
            case .said(let item): return item.id
            case .steps(let id, _): return id
            }
        }
    }

    static func isStep(_ item: ThreadItem) -> Bool {
        switch item.kind {
        case .step, .relaySent, .relayRead: return true
        case .prompt, .reply, .notify, .event: return false
        }
    }

    static func rows(from items: [ThreadItem]) -> [Row] {
        var rows: [Row] = []
        var pending: [ThreadItem] = []
        func flush() {
            guard let first = pending.first else { return }
            rows.append(.steps(id: "steps:" + first.id, items: pending))
            pending = []
        }
        for item in items {
            if isStep(item) {
                pending.append(item)
            } else {
                flush()
                rows.append(.said(item))
            }
        }
        flush()
        return rows
    }

    /// The thread's items. With a control plane and no thread selected Xanadu
    /// is composing a NEW thread, so it shows nothing yet rather than every
    /// thread at once. Without a control plane there are no threads: the whole
    /// transcript is the conversation.
    static func items(
        usesControlPlane: Bool,
        selectedThreadID: String?,
        detail: ControlPlaneClient.ThreadDetail?,
        sentRows: [ControlPlaneClient.Message],
        records: [AgentMirrorRecord]
    ) -> [ThreadItem] {
        guard usesControlPlane else {
            return ThreadTimeline.build(thread: nil, messages: [], records: records, events: [])
        }
        guard let selected = selectedThreadID else { return [] }
        var messages = detail?.messages ?? []
        let known = Set(messages.map(\.messageId))
        messages += sentRows.filter { $0.resolvedThreadID == selected && !known.contains($0.messageId) }
        var threadOfMessage: [String: String] = [:]
        for message in messages { threadOfMessage[message.messageId] = message.resolvedThreadID }
        let turns = ThreadMembership.turns(TranscriptTurns.turns(from: records), in: selected, threadOfMessage: threadOfMessage)
        let threadRecords = turns.flatMap { [$0.prompt].compactMap { $0 } + $0.steps + [$0.reply].compactMap { $0 } }
        return ThreadTimeline.build(thread: detail?.thread, messages: messages, records: threadRecords, events: detail?.events ?? [])
    }

    /// "via Siri" for a message Siri carried. Pure.
    static func originLabel(_ origin: String?) -> String? {
        switch origin {
        case "voice": return "via Siri"
        case "app", nil: return nil
        case "agent": return nil
        case let other?: return "via \(other)"
        }
    }
}

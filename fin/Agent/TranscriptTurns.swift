import Foundation

/// Grouping a merged transcript into turns — shared by the remote console, the
/// tvOS agent mode, and tests. Pure.
enum TranscriptTurns {
    /// One exchange: the prompt, the steps the agent took, and its reply. The
    /// default rendering is prompt + reply; the steps open on tap. A heartbeat
    /// (the agent's own reflective tick) has no prompt of yours and collapses to
    /// one quiet line.
    struct Turn: Identifiable {
        let id: String
        let prompt: AgentMirrorRecord?
        let steps: [AgentMirrorRecord]
        let reply: AgentMirrorRecord?
        let isHeartbeat: Bool
    }

    /// Pure: group a merged transcript into turns. A turn opens at a user line
    /// (or a turnStarted with no user line); everything until the next opener is
    /// its steps; the reply is the last assistant line with real text.
    static func turns(from records: [AgentMirrorRecord]) -> [Turn] {
        var turns: [Turn] = []
        var prompt: AgentMirrorRecord?
        var steps: [AgentMirrorRecord] = []
        var open = false
        func close() {
            guard open else { return }
            let replyIndex = steps.lastIndex { $0.kind == .assistantMessage && !$0.text.isEmpty && $0.text != "(tool call only)" }
            let reply = replyIndex.map { steps[$0] }
            var middle = steps
            if let replyIndex { middle.remove(at: replyIndex) }
            let id = prompt?.id ?? middle.first?.id ?? reply?.id ?? UUID().uuidString
            turns.append(Turn(id: id, prompt: prompt, steps: middle, reply: reply,
                              isHeartbeat: prompt?.text.hasPrefix("[heartbeat]") ?? false))
            prompt = nil; steps = []; open = false
        }
        for record in records {
            switch record.kind {
            case .userMessage:
                close(); prompt = record; open = true
            case .turnStarted:
                if !open || !steps.isEmpty { close(); open = true }
            default:
                if !open { open = true }
                steps.append(record)
            }
        }
        close()
        return turns
    }
}

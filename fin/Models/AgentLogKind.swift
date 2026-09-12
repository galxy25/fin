import Foundation

/// The kinds of transcript line every Fin surface understands — split from
/// `AgentLogEntry` so targets without SwiftData log storage (tvOS) can still
/// decode a mirrored transcript.
enum AgentLogKind: String, Codable, CaseIterable {
    case userMessage
    case assistantMessage
    case reasoning
    case toolCall
    case toolResult
    case approval
    case notice
    case error
    /// A headless daemon's turn-visibility signal: the moment `submit()` records the
    /// user message, BEFORE any tool call or LLM round trip — flushed immediately by
    /// `DaemonTranscriptUplink` (not on the batched interval) so the app sees "received"
    /// within seconds of a relay/directive/cloud message landing on the daemon. The app
    /// itself never emits this — only decodes it from a daemon mirror line.
    case turnStarted
    /// Reserved alongside `turnStarted` for the same daemon turn-visibility schema — a
    /// future heartbeat/wedge signal mid-turn. No emitter exists yet on either side;
    /// the case exists now so the wire schema and every exhaustive switch over this
    /// enum are already correct the day emission is added, rather than being a second,
    /// separate migration.
    case turnProgress

    var label: String {
        switch self {
        case .userMessage: return "You"
        case .assistantMessage: return "Agent"
        case .reasoning: return "Reasoning"
        case .toolCall: return "Tool call"
        case .toolResult: return "Tool result"
        case .approval: return "Approval"
        case .notice: return "Notice"
        case .error: return "Error"
        case .turnStarted: return "Turn started"
        case .turnProgress: return "Progress"
        }
    }

    var systemImage: String {
        switch self {
        case .userMessage: return "person"
        case .assistantMessage: return "sparkles"
        case .reasoning: return "brain"
        case .toolCall: return "arrow.right.square"
        case .toolResult: return "text.alignleft"
        case .approval: return "hand.raised"
        case .notice: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .turnStarted: return "bolt.circle"
        case .turnProgress: return "ellipsis.circle"
        }
    }
}

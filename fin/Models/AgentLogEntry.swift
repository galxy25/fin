import Foundation
import SwiftData

enum AgentLogKind: String, Codable, CaseIterable {
    case userMessage
    case assistantMessage
    case reasoning
    case toolCall
    case toolResult
    case approval
    case notice
    case error

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
        }
    }
}

/// How a tool call was authorized. Doubles as the human-preference signal in exported
/// trajectories: `approved` and `denied` are a person's explicit judgement on a specific
/// proposed action, which is the expensive half of a preference pair to collect.
enum AgentToolDisposition: String, Codable {
    /// Ran without asking — the console was in auto mode and nothing tripped the guard.
    case autoExecuted
    /// A person was asked and said yes.
    case approved
    /// A person was asked and said no.
    case denied
    /// Read-only tool; never gated.
    case unguarded
}

/// One durable line in an agent's audit trail.
///
/// Two jobs, which is why the schema carries more than the console displays. It is the
/// user-facing record of what an agent did on their machines — and it is also the raw
/// material for later fine-tuning, so entries keep everything needed to reassemble a
/// trajectory offline: a `runID` grouping one user request through to its final answer,
/// a monotonic `sequence` within that run, verbatim tool arguments rather than the
/// prettified display string, the model and sampling temperature that produced it, and
/// the human's approve/deny verdict on each gated action.
///
/// Deliberately local-only (never CloudKit-mirrored): these records quote raw terminal
/// output verbatim, which is exactly the material most likely to contain secrets from the
/// user's servers. This store never leaves the device; the one deliberate exception is
/// `AgentLogMirror`, which copies redacted lines to iCloud Drive behind a per-agent
/// toggle so a supervisor elsewhere can read the trail.
@Model
final class AgentLogEntry {
    var id: UUID = UUID()
    var agentID: UUID = UUID()
    var agentName: String = ""
    /// Which session produced this, so one agent's trail across several servers stays legible.
    var serverName: String = ""
    /// Groups every entry from one user message through to the agent's final answer.
    var runID: UUID = UUID()
    /// Position within the run, so ordering survives equal timestamps.
    var sequence: Int = 0
    var timestamp: Date = Date()
    var kindRaw: String = AgentLogKind.notice.rawValue
    var text: String = ""
    var toolName: String?
    /// Raw JSON arguments exactly as the model emitted them.
    var toolArguments: String?
    var dispositionRaw: String?
    /// Provenance for the turn that produced this entry.
    var modelIdentifier: String = ""
    var temperature: Double = 0

    // MARK: Token accounting (authoritative, from the endpoint's usage block)
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    // MARK: Timing
    /// Wall-clock time for a model turn, in milliseconds.
    var latencyMS: Int?
    var timeToFirstTokenMS: Int?
    var interTokenMeanMS: Double?
    /// Streamed span spent on reasoning vs. the visible answer.
    var reasoningMS: Int?
    var contentMS: Int?
    /// Tool execution only — deliberately excludes any time the call sat waiting for a
    /// human, which is tracked separately so machine latency and human latency never get
    /// averaged together.
    var toolDurationMS: Int?
    var approvalWaitMS: Int?

    // MARK: Reliability
    /// 1-based attempt number for the model call that produced this entry.
    var attempt: Int = 1
    /// Retries consumed before this entry succeeded.
    var retryCount: Int = 0
    /// Whether this entry represents a failed operation.
    var isFailure: Bool = false

    var kind: AgentLogKind {
        AgentLogKind(rawValue: kindRaw) ?? .notice
    }

    var disposition: AgentToolDisposition? {
        dispositionRaw.flatMap(AgentToolDisposition.init(rawValue:))
    }

    init(record: AgentLogRecord) {
        self.id = UUID()
        self.agentID = record.agentID
        self.agentName = record.agentName
        self.serverName = record.serverName
        self.runID = record.runID
        self.sequence = record.sequence
        self.timestamp = Date()
        self.kindRaw = record.kind.rawValue
        self.text = record.text
        self.toolName = record.toolName
        self.toolArguments = record.toolArguments
        self.dispositionRaw = record.disposition?.rawValue
        self.modelIdentifier = record.modelIdentifier
        self.temperature = record.temperature
        self.promptTokens = record.promptTokens
        self.completionTokens = record.completionTokens
        self.totalTokens = record.totalTokens
        self.latencyMS = record.latencyMS
        self.timeToFirstTokenMS = record.timeToFirstTokenMS
        self.interTokenMeanMS = record.interTokenMeanMS
        self.reasoningMS = record.reasoningMS
        self.contentMS = record.contentMS
        self.toolDurationMS = record.toolDurationMS
        self.approvalWaitMS = record.approvalWaitMS
        self.attempt = record.attempt
        self.retryCount = record.retryCount
        self.isFailure = record.isFailure
    }

    /// One JSON object per line — the shape training pipelines expect, and stable enough
    /// to concatenate across exports from several devices.
    func jsonlLine() -> String? {
        var object: [String: Any] = [
            "id": id.uuidString,
            "run_id": runID.uuidString,
            "sequence": sequence,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "agent_id": agentID.uuidString,
            "agent_name": agentName,
            "server": serverName,
            "kind": kindRaw,
            "text": text,
            "model": modelIdentifier,
            "temperature": temperature,
        ]
        if let toolName { object["tool_name"] = toolName }
        if let toolArguments { object["tool_arguments"] = toolArguments }
        if let dispositionRaw { object["disposition"] = dispositionRaw }

        var tokens: [String: Any] = [:]
        if let promptTokens { tokens["prompt"] = promptTokens }
        if let completionTokens { tokens["completion"] = completionTokens }
        if let totalTokens { tokens["total"] = totalTokens }
        if !tokens.isEmpty { object["tokens"] = tokens }

        var timing: [String: Any] = [:]
        if let latencyMS { timing["total_ms"] = latencyMS }
        if let timeToFirstTokenMS { timing["ttft_ms"] = timeToFirstTokenMS }
        if let interTokenMeanMS { timing["inter_token_mean_ms"] = interTokenMeanMS }
        if let reasoningMS { timing["reasoning_ms"] = reasoningMS }
        if let contentMS { timing["content_ms"] = contentMS }
        if let toolDurationMS { timing["tool_ms"] = toolDurationMS }
        if let approvalWaitMS { timing["approval_wait_ms"] = approvalWaitMS }
        if !timing.isEmpty { object["timing"] = timing }

        object["attempt"] = attempt
        object["retry_count"] = retryCount
        object["is_failure"] = isFailure

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }
}

/// Transport type between the runtime and whatever persists the trail, so `AgentRuntime`
/// doesn't have to hold a `ModelContext`.
struct AgentLogRecord {
    let agentID: UUID
    let agentName: String
    let serverName: String
    let runID: UUID
    let sequence: Int
    let kind: AgentLogKind
    let text: String
    var toolName: String?
    var toolArguments: String?
    var disposition: AgentToolDisposition?
    var modelIdentifier: String = ""
    var temperature: Double = 0

    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    var latencyMS: Int?
    var timeToFirstTokenMS: Int?
    var interTokenMeanMS: Double?
    var reasoningMS: Int?
    var contentMS: Int?
    var toolDurationMS: Int?
    var approvalWaitMS: Int?

    var attempt: Int = 1
    var retryCount: Int = 0
    var isFailure: Bool = false
}

// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// What a runner's `remember` hook hands back.
public enum AgentRememberOutcome: Equatable, Sendable {
    case saved
    case failed(String)
}

/// One matched memory, for a `recall` hook's result — mirrors what the app's own
/// `MemoryStore.searchMemories`/`semanticRecall` surface (title + content); kept minimal
/// since the tool result is prose the model reads, not a structured payload it parses.
public struct AgentRecallHit: Equatable, Sendable {
    public let title: String
    public let content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

/// What a runner's `recall` hook hands back.
public enum AgentRecallOutcome: Equatable, Sendable {
    case found([AgentRecallHit])
    case failed(String)
}

// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// What a runner's `write_artifact` hook hands back.
public enum AgentArtifactWriteOutcome: Equatable, Sendable {
    case saved(size: Int)
    case failed(String)
}

/// What a runner's `read_artifact` hook hands back. `.notFound` is kept apart from
/// `.failed` (mirrors `AgentReadSessionOutcome`'s honesty rule) so the tool result can
/// tell the model plainly "no such file" instead of a generic error.
public enum AgentArtifactReadOutcome: Equatable, Sendable {
    case found(content: String)
    case notFound
    case failed(String)
}

/// One entry in a `list_artifacts` result.
public struct AgentArtifactEntry: Equatable, Sendable {
    public let path: String
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

/// What a runner's `list_artifacts` hook hands back.
public enum AgentArtifactListOutcome: Equatable, Sendable {
    case found([AgentArtifactEntry])
    case failed(String)
}

/// What a runner's `delete_artifact` hook hands back. S3 DELETE is idempotent, so this
/// has no `.notFound` case — deleting an absent file is still `.deleted`.
public enum AgentArtifactDeleteOutcome: Equatable, Sendable {
    case deleted
    case failed(String)
}

/// What a runner's `attach_file` hook hands back (docs/XANADU.md "Fin replies with
/// files"): the file was queued to go back with the reply under `name` (`size` bytes),
/// or `refused` with a reason the model can act on (too big, not a regular file, not
/// readable, the per-turn cap…).
public enum AgentAttachFileOutcome: Equatable, Sendable {
    case queued(name: String, size: Int)
    case refused(String)
}

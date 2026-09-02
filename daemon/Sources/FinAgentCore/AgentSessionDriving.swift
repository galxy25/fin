// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// What `AgentTurnEngine` needs from a terminal session: an event log to read, a way to
/// type into it, and a live/dead signal for the await-output loop. The app's
/// SwiftTerm-backed `TerminalSession` and the daemon's `HeadlessTerminalSession` both fit
/// this shape; the engine never learns which one it is driving.
@MainActor
public protocol AgentSessionDriving: AnyObject {
    var eventLog: TerminalEventLog { get }
    /// True only while the SSH channel is actually up. A disconnected session's write
    /// path silently drops bytes, so the engine checks this before and during sends.
    var isSessionConnected: Bool { get }
    /// Types the given text into the live terminal exactly as the agent produced it —
    /// callers normalize the tail to `\r` via `AgentTurnLogic.submittable` first.
    func sendAgentInput(_ text: String)
}

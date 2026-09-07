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
    /// The reason the most recent `sendAgentInput` write failed, if it did — folded into
    /// the tool error a caller reports so "sending failed" carries more than that alone.
    /// Defaulted to `nil` below so a test double that never fails a send needn't implement
    /// it.
    var lastError: String? { get }
    /// Types the given text into the live terminal exactly as the agent produced it —
    /// callers normalize the tail to `\r` via `AgentTurnLogic.submittable` first.
    ///
    /// Returns the real outcome of the write, not just that it was attempted — mirrors
    /// the app's `TerminalSession.sendAgentInput`. `nil` only means "empty text, nothing
    /// to send" (a no-op, not a failure); otherwise the `Task` resolves to whether the
    /// bytes actually reached the channel, so a disconnected session's silently-dropped
    /// write can be told apart from a confirmed send instead of both looking the same to
    /// the caller.
    @discardableResult
    func sendAgentInput(_ text: String) -> Task<Bool, Never>?

    /// Asks the LIVE shell what one environment variable holds. Nil means it did not
    /// answer inside `timeout` — busy in a full-screen program, mid-reconnect, gone.
    ///
    /// This is how `AgentTurnEngine` re-takes the tmux guard's confinement proof (R0)
    /// before it types a tmux command: the whole private-socket design rests on the shell
    /// being INSIDE its own tmux server, and the shell can leave (`tmux detach`, `exit`) at
    /// any time without telling anyone. "No answer" is therefore not "probably fine", it is
    /// "unproven", and the guard fails closed on it.
    func probeEnvironment(_ name: String, timeout: TimeInterval) async -> String?
}

public extension AgentSessionDriving {
    /// A driver that cannot ask the shell anything cannot prove anything either. Nil is
    /// the fail-closed answer, and the only host that arms the tmux guard —
    /// `HeadlessTerminalSession` — implements this for real.
    func probeEnvironment(_ name: String, timeout: TimeInterval) async -> String? { nil }

    /// No error recorded is the right default for a conformer that never fails a send
    /// (most test doubles); `HeadlessTerminalSession`'s own stored property shadows this.
    var lastError: String? { nil }
}

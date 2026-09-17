// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// What the daemon is blocked on when the model calls `request_input`: the question
/// itself, and enough of the message/thread it belongs to that a restart can tell
/// "still the same question" from "a fresh one." Mirrors `StallNotifyState`'s shape —
/// one small JSON object on disk, because `awaitingUserInput` is a local `var` in the
/// run loop and does NOT survive a process restart.
public struct AwaitingUserInputState: Codable, Equatable, Sendable {
    public var question: String
    public var messageID: String?
    public var threadID: String?
    public var since: Date

    public init(question: String, messageID: String?, threadID: String?, since: Date) {
        self.question = question
        self.messageID = messageID
        self.threadID = threadID
        self.since = since
    }
}

/// The on-disk record that makes `awaitingUserInput` survive a daemon restart. Live
/// bug: `awaitingUserInput` gates `onRequestInput` from re-asking the same question on
/// every heartbeat (one push per interval, forever, without it) — but as a plain `var`
/// it resets to `false` on the very restart the crash loop or the 5-consecutive-failure
/// `fail()` path causes. A daemon still blocked on the SAME unanswered question then
/// runs a fresh heartbeat turn, the model asks it again, and the control plane — before
/// its own thread-reuse dedup — could mint a second "stalled" thread for one stall.
/// Deleted the moment the block lifts, so a stale marker never survives past the
/// question it named.
public enum AwaitingUserInputMarker {
    /// Nil on a missing or corrupt file — the same "unreadable is unblocked" fallback
    /// `StallNotifyMarker` uses: a broken marker must not wedge the daemon permanently
    /// paused, it just means one extra re-ask at worst.
    public static func state(at path: String) -> AwaitingUserInputState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AwaitingUserInputState.self, from: data)
    }

    /// Best-effort write, same as `StallNotifyMarker.write` — a failed write must not
    /// take the pause itself down, it only means a restart mid-block re-asks once.
    public static func write(_ state: AwaitingUserInputState, at path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func clear(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

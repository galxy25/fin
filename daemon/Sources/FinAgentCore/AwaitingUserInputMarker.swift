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
    /// The short "what's needed" title (`InputHeadline`) — written once the model (or
    /// the fallback) produced it, so the heartbeat can carry it and a restart doesn't
    /// re-generate it. Optional: markers from before 1.14.0 don't have it.
    public var headline: String?

    public init(question: String, messageID: String?, threadID: String?, since: Date, headline: String? = nil) {
        self.question = question
        self.messageID = messageID
        self.threadID = threadID
        self.since = since
        self.headline = headline
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
/// When a request_input pause has outlived its reason. Live on 2026-10-22: the MacBook
/// Neo sat paused for two weeks on "can't find tmux session data-anamoly-reporter-agent"
/// — a question its mission tick asked about goal g-kio-rebase, which Levi dropped on
/// 2026-10-07. Nothing ever re-checked, so the pause (and its needs-input pings)
/// outlived the goal. Pure, so the rule is testable.
public enum AwaitingUserInputRevalidation {
    /// How often a paused daemon re-checks.
    public static let checkInterval: TimeInterval = 10 * 60
    /// A mission question still unanswered after this is re-decided from scratch: the
    /// next tick sees the current ledger and sessions and asks again only if the
    /// question still matters — at most daily, matching the push backoff cap.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// Why to lift the pause, or nil to keep waiting. Only MISSION questions (no
    /// `messageID`: asked by a heartbeat tick to drive a goal) are released — a
    /// question asked inside a conversation with Levi waits for his answer.
    public static func releaseReason(
        _ state: AwaitingUserInputState, ledger: LedgerDocument?, now: Date = Date()
    ) -> String? {
        guard state.messageID == nil else { return nil }
        if let ledger, !ledger.goals.contains(where: { $0.state != .done }) {
            return "no open goal needs an answer any more"
        }
        if now.timeIntervalSince(state.since) >= maxAge {
            return "unanswered for a day; re-deciding with the current ledger and sessions"
        }
        return nil
    }
}

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

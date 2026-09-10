// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// Rate-limits the daemon's own "agent-stalled" push (`consecutiveFailures >= 5` in
/// fin-agentd's run loop) so a launchd `KeepAlive` restart loop doesn't re-page a human
/// every time the same root failure recurs. A live incident (2026-09-09/10) saw the
/// daemon crash-loop on "The model stopped without producing an answer" every ~17
/// minutes for two hours, twice — seven pushes each time for what was, from the human's
/// side, one ongoing problem, not fourteen distinct ones. Mirrors the wake-sweep's
/// "surface once, then go quiet" ceiling (`_already_notified`/`WAKE_NOTIFY_CEILING_HOURS`
/// in the control plane's lambda.py) — same shape, scoped to a local marker file instead
/// of an S3 object, since this is a per-machine crash loop, not a per-user inbox signal.
public enum StallNotifyGate {
    /// Much shorter than the wake-sweep's 72-hour ceiling on purpose: this fires many
    /// times an hour when the daemon is crash-looping, so it needs a tight window to
    /// actually collapse the spam — comfortably longer than the ~17-minute interval
    /// observed live, short enough that a human checking back later still gets paged
    /// if the daemon is still stuck.
    public static let defaultCooldown: TimeInterval = 30 * 60

    /// Pure decision: notify if there's no record of a prior push, or the prior one is
    /// at least `cooldown` old. Doesn't touch the filesystem — callers own reading and
    /// writing the marker (`StallNotifyMarker`) so this stays trivially testable.
    public static func shouldNotify(
        lastNotifiedAt: Date?,
        now: Date,
        cooldown: TimeInterval = defaultCooldown
    ) -> Bool {
        guard let lastNotifiedAt else { return true }
        return now.timeIntervalSince(lastNotifiedAt) >= cooldown
    }
}

/// The on-disk record `StallNotifyGate.shouldNotify` is gated on — one JSON object,
/// one field, living next to the audit log like the directive/goals-ledger/
/// routing-registry sibling files. Survives the very process restart the crash loop
/// causes, which is the whole point: `consecutiveFailures` is a local var in the run
/// loop and does NOT survive restart, so without a persisted marker every fresh
/// process gets its own free first strike at 5 failures — the exact bug this fixes.
public enum StallNotifyMarker {
    private struct Payload: Codable {
        var lastNotifiedAt: Date
    }

    /// Nil on a missing or corrupt file — a marker that can't be read is the same as
    /// "never notified," never a crash: a broken cooldown file must not take the
    /// agent-stalled push down with it.
    public static func lastNotifiedAt(at path: String) -> Date? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data).lastNotifiedAt
    }

    /// Best-effort write — a failure here is swallowed the same way `notify` itself
    /// swallows a dead control plane: a bad cooldown file must never take down the
    /// agent, it just means the next stall pages again instead of staying quiet.
    public static func recordNotified(at path: String, now: Date) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(lastNotifiedAt: now)) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

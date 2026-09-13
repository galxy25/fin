// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// What the daemon remembers between stalls — one small JSON object on disk (see
/// `StallNotifyMarker`), because `consecutiveFailures` is a local in the run loop and
/// the crash-loop restart wipes it.
///
/// `failureKey` and `pageCount` are what turn a flat cooldown into a backoff: the
/// 2026-09-12/13 night paged 12 times, one per 30-minute window, for what were two
/// problems (LM Studio refusing to load the model for three hours, then answering
/// every turn with nothing for four). A human told once and then every 30 minutes
/// about the SAME failure learns nothing from pages 2–6; a human told about a NEW
/// failure does. `active` is what the recovery note keys off: true from the first page
/// until a turn succeeds again, so "Fin is back" goes out exactly once per incident.
public struct StallNotifyState: Codable, Equatable, Sendable {
    public var lastNotifiedAt: Date
    public var failureKey: String?
    public var pageCount: Int
    public var active: Bool

    public init(lastNotifiedAt: Date, failureKey: String? = nil, pageCount: Int = 1, active: Bool = true) {
        self.lastNotifiedAt = lastNotifiedAt
        self.failureKey = failureKey
        self.pageCount = pageCount
        self.active = active
    }

    enum CodingKeys: String, CodingKey { case lastNotifiedAt, failureKey, pageCount, active }

    /// Tolerates the pre-backoff marker (`{"lastNotifiedAt": …}` only): a daemon
    /// updating in place must read its own old file as "paged once, still active".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastNotifiedAt = try c.decode(Date.self, forKey: .lastNotifiedAt)
        failureKey = try c.decodeIfPresent(String.self, forKey: .failureKey)
        pageCount = max(1, try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }
}

/// Rate-limits the daemon's own "agent-stalled" push (`consecutiveFailures >= 5` in
/// fin-agentd's run loop) so a launchd `KeepAlive` restart loop doesn't re-page a human
/// every time the same root failure recurs. A live incident (2026-09-09/10) saw the
/// daemon crash-loop on "The model stopped without producing an answer" every ~17
/// minutes for two hours, twice — seven pushes each time for what was, from the human's
/// side, one ongoing problem, not fourteen distinct ones. The flat 30-minute cooldown
/// that fixed that still paged 12 times on 2026-09-12/13, so the cooldown now DOUBLES
/// for every repeat page about the same failure (30m, 1h, 2h, 4h cap) and resets to the
/// base when the failure text changes — a different error is news, a repeat is not.
public enum StallNotifyGate {
    /// The first repeat of a failure waits this long; each later repeat waits double.
    public static let defaultCooldown: TimeInterval = 30 * 60
    /// The backoff ceiling: a daemon stuck all night still pages at least this often.
    public static let maxCooldown: TimeInterval = 4 * 60 * 60

    /// Pure decision: notify if there's no record of a prior push, if the failure is a
    /// different one from the last page (after at least the base cooldown), or if the
    /// backed-off cooldown for a repeat has elapsed. Doesn't touch the filesystem —
    /// callers own reading and writing the marker (`StallNotifyMarker`).
    public static func shouldNotify(
        state: StallNotifyState?,
        failure: String,
        now: Date,
        cooldown: TimeInterval = defaultCooldown,
        maxCooldown: TimeInterval = maxCooldown
    ) -> Bool {
        guard let state else { return true }
        let elapsed = now.timeIntervalSince(state.lastNotifiedAt)
        guard sameFailure(state.failureKey, failureKey(failure)) else {
            // A new problem after the old one was paged: worth a page, but never two
            // inside one base window — a daemon flapping between two errors (the
            // 2026-09-13 loop had one HTTP 500 amid the 400s) must not page for both.
            return elapsed >= cooldown
        }
        return elapsed >= repeatCooldown(pageCount: state.pageCount, base: cooldown, cap: maxCooldown)
    }

    /// The state to persist after a page just went out for `failure`.
    public static func statePaged(after previous: StallNotifyState?, failure: String, now: Date) -> StallNotifyState {
        let key = failureKey(failure)
        if let previous, previous.active, sameFailure(previous.failureKey, key) {
            return StallNotifyState(lastNotifiedAt: now, failureKey: key, pageCount: previous.pageCount + 1, active: true)
        }
        return StallNotifyState(lastNotifiedAt: now, failureKey: key, pageCount: 1, active: true)
    }

    /// The state to persist once a turn succeeds again; nil when there is nothing to
    /// close out (no marker, or the incident was already closed) — so the recovery
    /// push goes out at most once per incident, and never on an ordinary good turn.
    public static func stateRecovered(from previous: StallNotifyState?, now: Date) -> StallNotifyState? {
        guard let previous, previous.active else { return nil }
        var recovered = previous
        recovered.active = false
        return recovered
    }

    /// The cooldown before page N+1 of the same failure: base × 2^(N−1), capped.
    public static func repeatCooldown(pageCount: Int, base: TimeInterval = defaultCooldown, cap: TimeInterval = maxCooldown) -> TimeInterval {
        let exponent = max(0, min(pageCount - 1, 16))
        return min(cap, base * pow(2.0, Double(exponent)))
    }

    /// Two failures are "the same" when their normalized text matches. Whitespace and
    /// case are noise; the body is kept (an HTTP 400 with a model-load error and an
    /// HTTP 400 with a context-length error are different problems). Clipped so a long
    /// HTML error page compares by its head rather than its every byte.
    public static func failureKey(_ failure: String) -> String {
        let collapsed = failure
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(200))
    }

    private static func sameFailure(_ recorded: String?, _ current: String) -> Bool {
        guard let recorded else { return false }
        return recorded == current
    }

    /// The pre-backoff decision, kept for callers (and tests) that only have a
    /// timestamp: a flat cooldown, no failure comparison.
    public static func shouldNotify(
        lastNotifiedAt: Date?,
        now: Date,
        cooldown: TimeInterval = defaultCooldown
    ) -> Bool {
        guard let lastNotifiedAt else { return true }
        return now.timeIntervalSince(lastNotifiedAt) >= cooldown
    }
}

/// The on-disk record `StallNotifyGate` is gated on — one JSON object living next to
/// the audit log like the directive/goals-ledger/routing-registry sibling files.
/// Survives the very process restart the crash loop causes, which is the whole point:
/// `consecutiveFailures` is a local var in the run loop and does NOT survive restart,
/// so without a persisted marker every fresh process gets its own free first strike at
/// 5 failures — the exact bug this fixes.
public enum StallNotifyMarker {
    /// Nil on a missing or corrupt file — a marker that can't be read is the same as
    /// "never notified," never a crash: a broken cooldown file must not take the
    /// agent-stalled push down with it.
    public static func state(at path: String) -> StallNotifyState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StallNotifyState.self, from: data)
    }

    /// Best-effort write — a failure here is swallowed the same way `notify` itself
    /// swallows a dead control plane: a bad cooldown file must never take down the
    /// agent, it just means the next stall pages again instead of staying quiet.
    public static func write(_ state: StallNotifyState, at path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func lastNotifiedAt(at path: String) -> Date? {
        state(at: path)?.lastNotifiedAt
    }

    public static func recordNotified(at path: String, now: Date) {
        write(StallNotifyState(lastNotifiedAt: now), at: path)
    }
}

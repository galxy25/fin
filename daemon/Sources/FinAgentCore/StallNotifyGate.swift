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
    /// When the CURRENT give-up-worthy failure streak (>=5 consecutive) began, for the
    /// failure named by `pendingFailureKey` — see the "Dwell before paging" section
    /// below. Nil when nothing is pending. Persisted, and deliberately NOT reset by a
    /// page going out (`statePaged` carries it forward) — only by real recovery.
    public var pendingSince: Date?
    /// The normalized failure text `pendingSince` was started for. A different failure
    /// arriving restarts the dwell clock, same as `statePaged` treats a new failure as
    /// news rather than a continuation.
    public var pendingFailureKey: String?
    /// Consecutive successful turns seen while a streak is pending, toward
    /// `StallNotifyGate.successesToClearPending`. Reset to 0 by every failure.
    public var pendingSuccessStreak: Int

    public init(
        lastNotifiedAt: Date, failureKey: String? = nil, pageCount: Int = 1, active: Bool = true,
        pendingSince: Date? = nil, pendingFailureKey: String? = nil, pendingSuccessStreak: Int = 0
    ) {
        self.lastNotifiedAt = lastNotifiedAt
        self.failureKey = failureKey
        self.pageCount = pageCount
        self.active = active
        self.pendingSince = pendingSince
        self.pendingFailureKey = pendingFailureKey
        self.pendingSuccessStreak = pendingSuccessStreak
    }

    enum CodingKeys: String, CodingKey {
        case lastNotifiedAt, failureKey, pageCount, active
        case pendingSince, pendingFailureKey, pendingSuccessStreak
    }

    /// Tolerates the pre-backoff marker (`{"lastNotifiedAt": …}` only) and the
    /// pre-dwell marker (no `pending*` fields at all): a daemon updating in place must
    /// read its own old file as "paged once, still active, nothing pending" rather than
    /// fail to decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastNotifiedAt = try c.decode(Date.self, forKey: .lastNotifiedAt)
        failureKey = try c.decodeIfPresent(String.self, forKey: .failureKey)
        pageCount = max(1, try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        pendingSince = try c.decodeIfPresent(Date.self, forKey: .pendingSince)
        pendingFailureKey = try c.decodeIfPresent(String.self, forKey: .pendingFailureKey)
        pendingSuccessStreak = try c.decodeIfPresent(Int.self, forKey: .pendingSuccessStreak) ?? 0
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

    /// The state to persist after a page just went out for `failure`. Carries the
    /// pending-dwell bookkeeping forward from `previous` unchanged — paging is not
    /// recovery, so `pendingSince` must survive a page the same way it survives a
    /// restart; only real recovery (`stateRecovered`/`statePendingSucceeded`) clears it.
    public static func statePaged(after previous: StallNotifyState?, failure: String, now: Date) -> StallNotifyState {
        let key = failureKey(failure)
        var state: StallNotifyState
        if let previous, previous.active, sameFailure(previous.failureKey, key) {
            state = StallNotifyState(lastNotifiedAt: now, failureKey: key, pageCount: previous.pageCount + 1, active: true)
        } else {
            state = StallNotifyState(lastNotifiedAt: now, failureKey: key, pageCount: 1, active: true)
        }
        state.pendingSince = previous?.pendingSince
        state.pendingFailureKey = previous?.pendingFailureKey
        state.pendingSuccessStreak = previous?.pendingSuccessStreak ?? 0
        return state
    }

    /// The state to persist once a turn succeeds again; nil when there is nothing to
    /// close out (no marker, or the incident was already closed) — so the recovery
    /// push goes out at most once per incident, and never on an ordinary good turn.
    /// Also closes out any pending (not-yet-paged) dwell: a full recovery ends both.
    public static func stateRecovered(from previous: StallNotifyState?, now: Date) -> StallNotifyState? {
        guard let previous, previous.active else { return nil }
        var recovered = previous
        recovered.active = false
        recovered.pendingSince = nil
        recovered.pendingFailureKey = nil
        recovered.pendingSuccessStreak = 0
        return recovered
    }

    // MARK: - Dwell before paging

    /// How long a give-up-worthy failure streak (>=5 consecutive) must keep failing,
    /// unresolved, before it is worth waking a human — see
    /// docs/NOTIFICATION-NOISE-AUDIT.md item 2. The max observed page-to-recovery gap
    /// in the audited week was 15.8 minutes, so this window silenced 26 of 27 pages
    /// that self-healed before a human could have done anything with the page anyway.
    public static let dwellBeforePaging: TimeInterval = 30 * 60

    /// How many CONSECUTIVE successful turns, while a streak is pending, count as real
    /// recovery rather than one lucky answer inside a mostly-failing run. Set above 1
    /// on purpose: a brain that flaps (4 failures, 1 success, 4 failures, …) must not
    /// cancel the dwell on every single interleaved success, or it can fail ~80% of its
    /// turns forever without ever paging a human — the risk a reviewer flagged against
    /// a naive "any success clears it" design.
    public static let successesToClearPending = 2

    /// The state to persist the moment a give-up-worthy streak is seen (every failed
    /// turn once `consecutiveFailures >= 5`, not just the first). Starts `pendingSince`
    /// the first time; a later call for the SAME failure text leaves the clock running
    /// — it must survive every subsequent failed turn AND every process restart,
    /// because `consecutiveFailures` is an in-memory local that a crash-loop restart
    /// wipes. Without this persisted clock, a daemon restarting every ~90 seconds would
    /// never accumulate an unbroken 30 minutes inside one process lifetime and would
    /// never page — silencing exactly the 2026-09-09/10 crash-loop class this whole
    /// mechanism exists for. A DIFFERENT failure text restarts the dwell, the same way
    /// `statePaged` treats a new failure as news. Any failure — same text or not —
    /// breaks a success streak that was building toward `successesToClearPending`.
    public static func statePending(after previous: StallNotifyState?, failure: String, now: Date) -> StallNotifyState {
        let key = failureKey(failure)
        var state = previous ?? StallNotifyState(lastNotifiedAt: .distantPast, pageCount: 0, active: false)
        if state.pendingFailureKey != key {
            state.pendingSince = now
            state.pendingFailureKey = key
        }
        state.pendingSuccessStreak = 0
        return state
    }

    /// The state to persist after a turn SUCCEEDS, for a stall that may still be
    /// pending (not yet paged). Nil when there is nothing pending to update. Recovery
    /// only clears the dwell once `successesToClearPending` successes land in a row —
    /// see that constant's doc. Independent of `stateRecovered`, which only fires once
    /// a page has actually gone out; this is what lets a streak be cancelled BEFORE it
    /// ever reaches a human.
    public static func statePendingSucceeded(after previous: StallNotifyState?) -> StallNotifyState? {
        guard var state = previous, state.pendingSince != nil else { return previous }
        state.pendingSuccessStreak += 1
        if state.pendingSuccessStreak >= successesToClearPending {
            state.pendingSince = nil
            state.pendingFailureKey = nil
            state.pendingSuccessStreak = 0
        }
        return state
    }

    /// Whether a pending streak — still the SAME unresolved failure named by
    /// `pendingFailureKey` — has dwelled long enough to be worth paging.
    public static func pendingHasDwelled(
        state: StallNotifyState?, failure: String, now: Date, dwell: TimeInterval = dwellBeforePaging
    ) -> Bool {
        guard let state, let pendingSince = state.pendingSince, state.pendingFailureKey == failureKey(failure)
        else { return false }
        return now.timeIntervalSince(pendingSince) >= dwell
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

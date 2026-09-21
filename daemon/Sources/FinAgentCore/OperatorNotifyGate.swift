// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// One "an operator Claude Code session is blocked on Levi" watch. Registered by a
/// Claude Code session running on this same Mac (not Fin itself) — see
/// `scripts/dev/watch-for-answer.sh` — the instant it asks Levi something blocking
/// and he might not be watching. Deliberately NOT part of the goals ledger: the
/// ledger's schema is governed by the eval harness (evals/goals-ledger, see
/// GoalsLedger.swift's header) and is round-tripped through the model's own
/// `goal_upsert` tool, which would either need a schema change gated on that
/// process or risk the model silently dropping fields it was never told about.
/// This is its own small sibling file next to the other local markers
/// (`StallNotifyMarker`, `AwaitingUserInputMarker`) instead.
public struct OperatorNotifyRequest: Codable, Equatable, Sendable {
    public var id: String
    /// The question Levi is being asked, verbatim — this IS the push body, so the
    /// operator session should keep it short.
    public var question: String
    public var createdAt: Date
    /// When unanswered-too-long becomes worth a push. Chosen by the caller at
    /// registration time (docs/... "let me pick the interval when I ask") — there
    /// is no single fixed dwell, because how urgent a question is varies by what
    /// it's blocking.
    public var notifyAfter: Date
    /// Set the moment the gate actually fires, so a goal already pushed is never
    /// pushed twice — a restart mid-dwell re-reads this file and must not treat a
    /// fired request as fresh.
    public var notifiedAt: Date?
    /// The Fin thread (docs/THREADS.md) this question rides, if any, so the push
    /// can deep-link and the Lock Screen groups it correctly.
    public var threadID: String?

    enum CodingKeys: String, CodingKey {
        case id, question, createdAt, notifyAfter, notifiedAt, threadID = "threadId"
    }

    public init(
        id: String, question: String, createdAt: Date, notifyAfter: Date,
        notifiedAt: Date? = nil, threadID: String? = nil
    ) {
        self.id = id
        self.question = question
        self.createdAt = createdAt
        self.notifyAfter = notifyAfter
        self.notifiedAt = notifiedAt
        self.threadID = threadID
    }
}

/// The on-disk file `scripts/dev/watch-for-answer.sh` writes and the daemon reads
/// every heartbeat — a plain array, not a single value, because more than one
/// operator session (or more than one pending question in the same session) can be
/// outstanding at once.
public struct OperatorNotifyState: Codable, Equatable, Sendable {
    public var requests: [OperatorNotifyRequest]

    public init(requests: [OperatorNotifyRequest] = []) {
        self.requests = requests
    }
}

/// Decides when a pending "operator blocked on Levi" watch is due, and marks it
/// fired — pure, no I/O, so the dwell math is directly testable the same way
/// `StallNotifyGate`'s is. Deliberately NOT the model's own judgment: a prose
/// "wait N minutes, then tell Levi" instruction handed to Fin's heartbeat is not
/// reliable enough to build a time-sensitive push on (see the repetition/
/// recency-confusion failure modes already on file for this exact local model) —
/// due-ness here is a plain timestamp comparison, decided before the model is ever
/// asked, the same way `StallNotifyGate`'s dwell is.
public enum OperatorNotifyGate {
    /// A request the gate should fire now: not already notified, and its dwell
    /// has elapsed.
    public static func due(in state: OperatorNotifyState, now: Date = Date()) -> [OperatorNotifyRequest] {
        state.requests.filter { $0.notifiedAt == nil && $0.notifyAfter <= now }
    }

    /// The state to persist right after firing `id` — sets `notifiedAt` so a
    /// restart mid-tick, or the next heartbeat before the file write below lands,
    /// can never fire it twice.
    public static func notified(_ state: OperatorNotifyState, id: String, at now: Date) -> OperatorNotifyState {
        var state = state
        if let index = state.requests.firstIndex(where: { $0.id == id }) {
            state.requests[index].notifiedAt = now
        }
        return state
    }

    /// The state to persist once Levi has answered (or the operator session no
    /// longer needs the watch) — removed outright, not just marked done, so the
    /// file never grows across a long-running daemon.
    public static func cleared(_ state: OperatorNotifyState, id: String) -> OperatorNotifyState {
        var state = state
        state.requests.removeAll { $0.id == id }
        return state
    }

    /// Garbage collection for a watch nobody ever cleared — an operator session
    /// that crashed, or a question Levi answered somewhere the clear call never
    /// ran from. Drops anything older than `maxAge` regardless of whether it ever
    /// fired, so a forgotten watch can't sit in the file (or keep re-arming a
    /// stale question) forever. Read at load time, before `due` runs.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public static func prunedOfStale(_ state: OperatorNotifyState, now: Date = Date(), maxAge: TimeInterval = maxAge) -> OperatorNotifyState {
        var state = state
        state.requests.removeAll { now.timeIntervalSince($0.createdAt) > maxAge }
        return state
    }
}

/// File I/O for `OperatorNotifyState` — same shape as `StallNotifyMarker`/
/// `AwaitingUserInputMarker`: best-effort, a missing or corrupt file reads as
/// "nothing pending" rather than an error, because a broken marker must never
/// wedge the heartbeat.
public enum OperatorNotifyMarker {
    public static func state(at path: String) -> OperatorNotifyState {
        guard let data = FileManager.default.contents(atPath: path) else { return OperatorNotifyState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OperatorNotifyState.self, from: data)) ?? OperatorNotifyState()
    }

    public static func write(_ state: OperatorNotifyState, at path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
